import 'package:flutter/services.dart' show FilteringTextInputFormatter, TextInputType;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api.dart';
import '../data/models.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../state/providers.dart';
import '../ui/buttons.dart';
import '../ui/calendar.dart';
import '../ui/fields.dart';
import '../ui/format.dart';
import '../ui/icons.dart';
import '../local_engine/amortization.dart' show monthlyRateFromEffectiveAnnual;
import '../local_engine/debts_engine.dart' show proyectarDeuda;
import '../ui/modal.dart';
import '../ui/surface.dart';

/// Una deuda nueva.
Future<bool> abrirNuevaDeuda(BuildContext context) async {
  final creada = await showAppModal<bool>(
    context,
    title: 'Nueva deuda',
    builder: (context) => const _FormularioDeuda(),
  );
  return creada ?? false;
}

/// Editar una que ya existe.
Future<bool> abrirEditarDeuda(BuildContext context, {required Debt deuda}) async {
  final cambiada = await showAppModal<bool>(
    context,
    title: 'Editar deuda',
    subtitle: 'Cambiar el saldo, la tasa o el plazo rehace el cronograma de pagos.',
    builder: (context) => _FormularioDeuda(deuda: deuda),
  );
  return cambiada ?? false;
}

double? _num(String texto) => double.tryParse(texto.replaceAll(',', '').trim());

class _FormularioDeuda extends ConsumerStatefulWidget {
  const _FormularioDeuda({this.deuda});

  final Debt? deuda;

  @override
  ConsumerState<_FormularioDeuda> createState() => _FormularioDeudaState();
}

class _FormularioDeudaState extends ConsumerState<_FormularioDeuda> {
  late final _nombre = TextEditingController(text: widget.deuda?.name ?? '');
  late final _institucion = TextEditingController(text: widget.deuda?.institution ?? '');
  late final _principal = TextEditingController(
    text: widget.deuda == null ? '' : widget.deuda!.originalPrincipal.toStringAsFixed(2),
  );
  late final _saldo = TextEditingController(
    text: widget.deuda == null ? '' : widget.deuda!.balance.toStringAsFixed(2),
  );
  late final _tea = TextEditingController(
    text: widget.deuda == null ? '' : (widget.deuda!.interestRateAnnual * 100).toStringAsFixed(2),
  );
  late final _tcea = TextEditingController(
    text: widget.deuda?.costRateAnnual == null
        ? ''
        : (widget.deuda!.costRateAnnual! * 100).toStringAsFixed(2),
  );
  late final _cuota = TextEditingController(
    text: widget.deuda == null ? '' : widget.deuda!.minimumPayment.toStringAsFixed(2),
  );
  late final _plazo = TextEditingController(text: widget.deuda?.termMonths?.toString() ?? '');

  // El seguro de desgravamen y cuántas cuotas van pagadas. Los dos salen del
  // estado de cuenta y son los que hacen que el cronograma de la app coincida
  // con el del banco.
  late final _desgravamen = TextEditingController(
    text: widget.deuda?.monthlyInsurance == null
        ? ''
        : widget.deuda!.monthlyInsurance!.toStringAsFixed(2),
  );
  final _pagadas = TextEditingController();
  late String? _tipo = widget.deuda?.debtTypeCode;
  late String _moneda = widget.deuda?.currency ?? 'PEN';
  late DateTime _origen = widget.deuda?.originationDate ?? DateTime.now();
  late int? _diaVencimiento = widget.deuda?.dueDay;
  late DateTime? _fechaDevolucion = widget.deuda?.dueDate;

  /// Si están a la vista los campos de afinar.
  ///
  /// Lo esencial —nombre, saldo, tasa y cuota— basta para que la app proyecte,
  /// cobre y avise; el resto afina. Pedir catorce datos antes de dejar guardar
  /// nada es una declaración jurada, y la mitad de la gente abandona en "TCEA
  /// (opcional)" porque no sabe qué es y sospecha que se equivoca.
  ///
  /// Al editar una deuda que ya existe se abre solo: ahí ya no estás creando,
  /// estás corrigiendo un dato concreto que puede ser cualquiera.
  late bool _afinando = widget.deuda != null;

  bool _guardando = false;
  bool _borrando = false;
  String? _error;

  @override
  void dispose() {
    _nombre.dispose();
    _institucion.dispose();
    _principal.dispose();
    _saldo.dispose();
    _tea.dispose();
    _tcea.dispose();
    _cuota.dispose();
    _plazo.dispose();
    _desgravamen.dispose();
    _pagadas.dispose();
    super.dispose();
  }

  /// La fecha de desembolso, corrida hacia atrás por las cuotas ya pagadas.
  ///
  /// Respeta el fin de mes: al 31 de marzo restarle un mes es el 28 de febrero,
  /// no el 3 de marzo.
  DateTime _fechaDeOrigen() {
    final base = DateTime(_origen.year, _origen.month, _origen.day);
    final pagadas = int.tryParse(_pagadas.text.trim()) ?? 0;
    if (pagadas <= 0) return base;
    final ultimo = DateTime(base.year, base.month - pagadas + 1, 0).day;
    return DateTime(base.year, base.month - pagadas, base.day > ultimo ? ultimo : base.day);
  }

  Future<void> _guardar(DebtKind kind) async {
    // Lo que se pide de verdad es el **saldo**: es lo que uno tiene delante y
    // lo que la app necesita para calcular. El monto original afina —de ahí
    // sale el "llevas un 30% pagado"— y si no viene, se asume que aún no has
    // pagado nada. Antes era al revés, y registrar una deuda vieja obligaba a
    // rellenar dos casillas para decir una sola cosa.
    final saldo = _num(_saldo.text);
    final principal = _num(_principal.text) ?? saldo;
    if (_nombre.text.trim().isEmpty) {
      setState(() => _error = 'Ponle un nombre.');
      return;
    }
    if (saldo == null || principal == null) {
      setState(() => _error = 'Escribe cuánto debes hoy.');
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      final cuerpo = {
        'name': _nombre.text.trim(),
        if (_institucion.text.trim().isNotEmpty) 'institution': _institucion.text.trim(),
        'originalPrincipal': principal,
        'currentBalance': saldo,
        if (kind.hasRates && _tea.text.trim().isNotEmpty)
          'interestRateAnnual': _num(_tea.text)! / 100,
        if (kind.hasRates && _tcea.text.trim().isNotEmpty)
          'costRateAnnual': _num(_tcea.text)! / 100,
        if (_cuota.text.trim().isNotEmpty) 'minimumPayment': _num(_cuota.text),
        if (kind.hasTerm && _plazo.text.trim().isNotEmpty)
          'termMonths': int.tryParse(_plazo.text.trim()),
        if (kind.hasRates && _desgravamen.text.trim().isNotEmpty)
          'monthlyInsurance': _num(_desgravamen.text),
        // Las cuotas ya pagadas sitúan el cronograma, y lo hacen corriendo la
        // fecha de desembolso hacia atrás — que es el dato del que ya vive todo
        // el cálculo. Sin esto, una deuda registrada hoy arranca en la cuota 1
        // aunque lleves once pagadas, y la app cobra el interés de la primera
        // cuando el banco ya va por la doceava.
        'originationDate': _fechaDeOrigen().toIso8601String(),
        if (kind.hasDueDay && _diaVencimiento != null) 'dueDay': _diaVencimiento,
        if (!kind.hasDueDay && _fechaDevolucion != null)
          'dueDate': DateTime(
            _fechaDevolucion!.year,
            _fechaDevolucion!.month,
            _fechaDevolucion!.day,
          ).toIso8601String(),
        'currency': _moneda,
      };
      final api = ref.read(apiProvider);
      if (widget.deuda == null) {
        await api.post('/debts', {'debtTypeCode': kind.code, ...cuerpo});
      } else {
        await api.patch('/debts/${widget.deuda!.id}', cuerpo);
      }
      ref
        ..invalidate(debtsProvider)
        ..invalidate(cashPositionProvider);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'No llegué al servidor. Inténtalo otra vez.');
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  Future<void> _borrar() async {
    final ok = await showFeedback(
      context,
      title: '¿Eliminar "${widget.deuda!.name}"?',
      message:
          'Si ya tiene pagos registrados, se archiva en vez de borrarse — sigue en tu historial pero deja de contar como deuda activa.',
      tone: FeedbackTone.aviso,
      confirmLabel: 'Sí, eliminar',
      cancelLabel: 'Cancelar',
      destructive: true,
    );
    if (ok != true || !mounted) return;
    setState(() => _borrando = true);
    try {
      await ref.read(apiProvider).delete('/debts/${widget.deuda!.id}');
      ref
        ..invalidate(debtsProvider)
        ..invalidate(cashPositionProvider);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) {
        await showFeedback(
          context,
          title: 'No se pudo eliminar',
          message: e.message,
          tone: FeedbackTone.error,
        );
      }
    } finally {
      if (mounted) setState(() => _borrando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final tipos = ref.watch(debtKindsProvider).valueOrNull ?? const <DebtKind>[];
    final monedas = ref.watch(currenciesProvider).valueOrNull ?? const <Currency>[];
    final tipoActual = tipos.where((k) => k.code == _tipo).firstOrNull ?? tipos.firstOrNull;

    if (widget.deuda == null && _tipo == null && tipoActual != null) {
      // Se difiere a después del primer build para no llamar setState durante
      // build; con `tipos` recién cargado, elegir el primero de una es mejor
      // que empezar sin ninguno seleccionado.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _tipo = tipoActual.code);
      });
    }

    if (tipoActual == null) {
      return const SizedBox(height: 80, child: Center(child: SizedBox.shrink()));
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.deuda == null) ...[
          const FieldLabel('Tipo de deuda'),
          FieldSelector(
            texto: '${tipoActual.icon} ${tipoActual.label}',
            onTap: () async {
              final elegido = await showAppModal<DebtKind>(
                context,
                title: 'Tipo de deuda',
                builder: (context) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final k in tipos)
                      FieldOption(
                        titulo: '${k.icon}  ${k.label}',
                        subtitulo: k.hint,
                        seleccionado: k.code == _tipo,
                        onTap: () => Navigator.of(context).pop(k),
                      ),
                  ],
                ),
              );
              if (elegido != null) setState(() => _tipo = elegido.code);
            },
          ),
          const SizedBox(height: Spacing.lg),
        ],
        const FieldLabel('Nombre'),
        FieldBox(
          child: AppTextField(controller: _nombre, placeholder: 'Ej. Préstamo vehicular'),
        ),
        const SizedBox(height: Spacing.lg),
        const FieldLabel('¿Cuánto debes hoy?'),
        _CampoMonto(controller: _saldo, onChanged: (_) => setState(() {})),
        const SizedBox(height: Spacing.lg),
        if (widget.deuda == null) ...[
          const FieldLabel('Moneda'),
          FieldSelector(
            texto: _moneda,
            onTap: () async {
              final elegida = await showAppModal<Currency>(
                context,
                title: 'Elige la moneda',
                builder: (context) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final c in monedas)
                      FieldOption(
                        titulo: '${c.code} · ${c.name}',
                        onTap: () => Navigator.of(context).pop(c),
                      ),
                  ],
                ),
              );
              if (elegida != null) setState(() => _moneda = elegida.code);
            },
          ),
          const SizedBox(height: Spacing.lg),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (tipoActual.hasRates) ...[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const FieldLabel('TEA (%)'),
                    _CampoPorcentaje(controller: _tea, onChanged: (_) => setState(() {})),
                  ],
                ),
              ),
              const SizedBox(width: Spacing.md),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FieldLabel(tipoActual.hasTerm ? 'Cuota mensual' : 'Pago mínimo'),
                  _CampoMonto(controller: _cuota, onChanged: (_) => setState(() {})),
                ],
              ),
            ),
            if (tipoActual.hasTerm) ...[
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const FieldLabel('Cuotas'),
                    FieldBox(
                      child: AppTextField(
                        controller: _plazo,
                        placeholder: '0',
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: Spacing.lg),

        // Lo que sale de lo que llevas escrito, mientras lo escribes. Es lo que
        // convierte el formulario en una conversación: si te equivocaste de
        // casilla, el número lo delata acá y no tres pantallas después.
        _Previsualizacion(
          saldo: _num(_saldo.text),
          tasaAnual: (_num(_tcea.text) ?? _num(_tea.text) ?? 0) / 100,
          cuota: _num(_cuota.text),
          seguro: _num(_desgravamen.text) ?? 0,
          plazo: tipoActual.hasTerm ? int.tryParse(_plazo.text) : null,
          moneda: _moneda,
        ),

        // ── Afinar. Todo lo que no hace falta para empezar.
        const SizedBox(height: Spacing.lg),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _afinando = !_afinando),
          child: Row(
            children: [
              Text(
                'Afinar con tu estado de cuenta',
                style: AppText.small(colors.sageInk).copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 4),
              AppIcon(
                _afinando ? AppIconData.chevronDown : AppIconData.chevronRight,
                size: 14,
                color: colors.sageInk,
              ),
            ],
          ),
        ),
        if (_afinando) ...[
          const SizedBox(height: Spacing.md),
          FieldLabel(tipoActual.counterpartyLabel),
          FieldBox(
            child: AppTextField(
              controller: _institucion,
              placeholder: tipoActual.counterpartyLabel,
            ),
          ),
          const SizedBox(height: Spacing.lg),
          FieldLabel(tipoActual.principalLabel),
          _CampoMonto(controller: _principal),
          const SizedBox(height: 6),
          _Ayuda(
            'Lo que te prestaron al principio. Es de donde sale el "llevas un '
            '30% pagado"; si no lo pones, se asume que aún no has pagado nada.',
          ),
          const SizedBox(height: Spacing.lg),
          if (tipoActual.hasRates) ...[
            const FieldLabel('TCEA (%)'),
            _CampoPorcentaje(controller: _tcea, onChanged: (_) => setState(() {})),
            const SizedBox(height: 6),
            _Ayuda(
              'La TEA más el seguro y los portes: con ella la proyección deja de '
              'quedarse corta. Si la pones, no repitas el desgravamen — ya está '
              'adentro.',
            ),
            const SizedBox(height: Spacing.lg),
          ],
          if (tipoActual.hasRates) ...[
            const SizedBox(height: Spacing.lg),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // El desgravamen es una condición del crédito, no un cargo
                      // sorpresa: se configura acá y no se escribe cada vez que
                      // pagas. De la cuota sale antes que el capital, así que sin
                      // él la app cree que bajas la deuda más rápido de lo que la
                      // bajas.
                      const FieldLabel('Desgravamen mensual'),
                      _CampoMonto(controller: _desgravamen),
                      const SizedBox(height: 6),
                      _Ayuda(
                        'Está en el detalle de tu cuota, junto a los portes. Es la '
                        'parte que paga el seguro y no baja un céntimo de la deuda.',
                      ),
                    ],
                  ),
                ),
                // Solo al crear. Al editar, la deuda ya tiene su fecha de origen
                // —está en el campo de abajo— y este atajo la correría *otra vez*
                // hacia atrás cada vez que se guardara: escribir "11" en una
                // deuda que ya estaba bien situada la mandaría once meses más
                // atrás. Para corregirla se edita la fecha, que es el dato real.
                if (tipoActual.hasTerm && widget.deuda == null) ...[
                  const SizedBox(width: Spacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Cuántas van pagadas sitúa el cronograma. Se pregunta
                        // esto y no "cuándo fue la primera cuota" porque es el
                        // dato que el estado de cuenta trae escrito.
                        const FieldLabel('Cuotas pagadas'),
                        FieldBox(
                          child: AppTextField(
                            controller: _pagadas,
                            placeholder: '0',
                            keyboardType: TextInputType.number,
                            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            Builder(
              builder: (context) => Text(
                widget.deuda == null
                    ? 'Los dos están en tu estado de cuenta: el desgravamen en el detalle de '
                          'la cuota, y las cuotas pagadas arriba. Con ellos la app reproduce el '
                          'mismo reparto que te cobra el banco.'
                    : 'El desgravamen está en el detalle de la cuota de tu estado de cuenta. '
                          'Para recolocar el cronograma, corrige la fecha de origen de abajo.',
                style: AppText.tiny(AppTheme.of(context).oliveInk.withValues(alpha: 0.65)),
              ),
            ),
          ],
          const SizedBox(height: Spacing.lg),
          const FieldLabel('Fecha de origen'),
          FieldSelector(
            texto: Fechas.diaConAnio(_origen),
            icon: AppIconData.calendar,
            onTap: () async {
              final elegida = await pickDate(context, inicial: _origen, ultima: DateTime.now());
              if (elegida != null) setState(() => _origen = elegida);
            },
          ),
          const SizedBox(height: Spacing.lg),
          if (tipoActual.hasDueDay) ...[
            const FieldLabel('Día de vencimiento'),
            FieldSelector(
              texto: _diaVencimiento == null
                  ? 'El mismo día de origen'
                  : 'Día $_diaVencimiento de cada mes',
              onTap: () async {
                final elegido = await showAppModal<int>(
                  context,
                  title: 'Día de vencimiento',
                  builder: (context) => Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final d in List.generate(31, (i) => i + 1))
                        FieldOption(titulo: 'Día $d', onTap: () => Navigator.of(context).pop(d)),
                    ],
                  ),
                );
                if (elegido != null) setState(() => _diaVencimiento = elegido);
              },
            ),
          ] else ...[
            const FieldLabel('Fecha de devolución'),
            FieldSelector(
              texto: _fechaDevolucion == null
                  ? 'Elige una fecha'
                  : Fechas.diaConAnio(_fechaDevolucion!),
              icon: AppIconData.calendar,
              onTap: () async {
                final elegida = await pickDate(
                  context,
                  inicial: _fechaDevolucion ?? DateTime.now(),
                );
                if (elegida != null) setState(() => _fechaDevolucion = elegida);
              },
            ),
          ],
        ],
        if (_error != null) ...[
          const SizedBox(height: Spacing.md),
          Text(_error!, style: AppText.small(colors.danger)),
        ],
        const SizedBox(height: Spacing.xl),
        AppButton(
          label: widget.deuda == null ? 'Crear deuda' : 'Guardar cambios',
          busy: _guardando,
          onPressed: _guardando || _borrando ? null : () => _guardar(tipoActual),
        ),
        if (widget.deuda != null) ...[
          const SizedBox(height: Spacing.sm),
          AppButton(
            label: 'Eliminar deuda',
            variant: AppButtonVariant.destructive,
            busy: _borrando,
            onPressed: _guardando || _borrando ? null : _borrar,
          ),
        ],
      ],
    );
  }
}

/// Lo que sale de lo que llevas escrito, mientras lo escribes.
///
/// Es lo que convierte el formulario en una conversación: pones saldo, tasa y
/// cuota y te dice cuántos meses y cuánto interés — y si te equivocaste de
/// casilla, el número lo delata ahí mismo en vez de tres pantallas después.
///
/// También es la única validación que cruza campos: una cuota que no cubre el
/// interés del mes es una deuda que no se paga nunca, y hasta ahora se podía
/// guardar en silencio.
class _Previsualizacion extends StatelessWidget {
  const _Previsualizacion({
    required this.saldo,
    required this.tasaAnual,
    required this.cuota,
    required this.seguro,
    required this.plazo,
    required this.moneda,
  });

  final double? saldo;
  final double tasaAnual;
  final double? cuota;
  final double seguro;
  final int? plazo;
  final String moneda;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    if (saldo == null || cuota == null || saldo! <= 0 || cuota! <= 0) {
      return const SizedBox.shrink();
    }

    final p = proyectarDeuda(
      currentBalance: saldo!,
      installment: cuota!,
      interestRateAnnual: tasaAnual,
      costRateAnnual: null,
      monthlyInsurance: seguro,
      termMonths: plazo,
    );

    if (p.monthsLeft == null) {
      final interesDelMes = saldo! * monthlyRateFromEffectiveAnnual(tasaAnual);
      return AppCard(
        child: Text(
          'Con esta cuota, esta deuda no se termina. Solo el interés del primer mes '
          'son ${Money.format(interesDelMes, moneda)}, así que pagando '
          '${Money.format(cuota!, moneda)} el saldo sube. Revisa la cuota o la tasa.',
          style: AppText.small(colors.danger),
        ),
      );
    }

    final desajuste = p.installmentGap;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Con estos datos: ${p.monthsLeft} ${p.monthsLeft == 1 ? "mes" : "meses"} hasta '
            'terminarla y ${Money.format(p.interestLeft, moneda)} de interés — pagarías '
            '${Money.format(p.totalLeft, moneda)} en total.',
            style: AppText.small(colors.foreground),
          ),
          if (desajuste > 0.5) ...[
            const SizedBox(height: 4),
            Text(
              'Tu cuota es ${Money.format(desajuste, moneda)} mayor que la que sale de la tasa '
              'y el plazo; esa diferencia suele ser el seguro y los portes.',
              style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.7)),
            ),
          ],
        ],
      ),
    );
  }
}

/// Una línea de ayuda debajo de un campo.
///
/// Un formulario de deuda pide TEA, TCEA y desgravamen: tres palabras que solo
/// significan algo si trabajas en un banco. Sin decir qué son y dónde están
/// escritas, se rellenan a ojo — y la proyección sale de esos números.
class _Ayuda extends StatelessWidget {
  const _Ayuda(this.texto);

  final String texto;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Text(texto, style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.6)));
  }
}

class _CampoMonto extends StatelessWidget {
  const _CampoMonto({required this.controller, this.onChanged});

  final TextEditingController controller;

  /// Para recalcular la previsualización mientras se escribe.
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return FieldBox(
      child: AppTextField(
        controller: controller,
        placeholder: '0.00',
        style: AppText.money(colors.foreground, size: 15, weight: FontWeight.w600),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
        onChanged: onChanged,
      ),
    );
  }
}

class _CampoPorcentaje extends StatelessWidget {
  const _CampoPorcentaje({required this.controller, this.onChanged});

  final TextEditingController controller;

  /// Para recalcular la previsualización mientras se escribe.
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return FieldBox(
      child: AppTextField(
        controller: controller,
        placeholder: '0.0',
        style: AppText.money(colors.foreground, size: 15, weight: FontWeight.w600),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
        onChanged: onChanged,
      ),
    );
  }
}
