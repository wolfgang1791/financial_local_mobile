import 'package:flutter/services.dart' show FilteringTextInputFormatter, TextInputType;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api.dart';
import '../data/models.dart';
import '../data/payment_method.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../state/providers.dart';
import '../ui/buttons.dart';
import '../ui/fields.dart';
import '../ui/format.dart';
import '../ui/icons.dart';
import '../ui/modal.dart';
import '../ui/refreshable_screen.dart';
import '../ui/surface.dart';
import 'balance_editor_modal.dart';
import 'category_management.dart';
import 'edit_transaction_modal.dart';
import 'historial_screen.dart';
import 'nuevo_movimiento.dart';
import 'recurring_flow_form.dart';
import 'shell.dart';

/// Movimientos: lo que entra, lo que sale fijo y lo que registraste suelto.
///
/// El patrimonio primero, después los últimos movimientos —lo que más
/// cambia, varias veces al día— y recién después los flujos fijos, que se
/// mueven una vez al mes y se marcan pagados desde acá.
class MovimientosScreen extends ConsumerWidget {
  const MovimientosScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(userProvider);
    final flujos = ref.watch(recurringFlowsProvider);
    final recientes = ref.watch(recentTransactionsProvider);
    final posicion = ref.watch(cashPositionProvider);

    return RefreshableScreen(
      onRefresh: () async {
        ref
          ..invalidate(recurringFlowsProvider)
          ..invalidate(recentTransactionsProvider)
          ..invalidate(cashPositionProvider);
      },
      children: [
        const ScreenHeader(
          kicker: 'Gestión de dinero',
          title: 'Movimientos',
          subtitle: 'Lo que entra, lo que sale y lo que decidiste tú.',
        ),
        const SizedBox(height: Spacing.lg),
        posicion.maybeWhen(
          data: (p) => _TarjetaPatrimonio(posicion: p, currency: user.currency),
          orElse: () => const SizedBox.shrink(),
        ),
        const SizedBox(height: Spacing.md),
        // Registrar va arriba, pegado al patrimonio: es la acción que se hace
        // llegando, y ponerla al final obliga a recorrer la pantalla entera para
        // anotar un café.
        _BotonRegistrar(
          onDone: () {
            ref
              ..invalidate(recentTransactionsProvider)
              ..invalidate(cashPositionProvider);
          },
        ),
        const SizedBox(height: Spacing.lg),
        // Los últimos movimientos van primero: es lo que se acaba de
        // registrar y lo que más se viene a revisar — los flujos fijos
        // cambian una vez al mes, esto cambia varias veces al día.
        recientes.when(
          loading: () => const _Cargando(alto: 220),
          error: (_, __) => const _Fallo(),
          data: (lista) => _Recientes(
            transacciones: lista.where((t) => t.kind != 'OPENING_BALANCE').take(12).toList(),
            currency: user.currency,
            mostrarCuenta: (ref.watch(accountsProvider).valueOrNull ?? const []).length > 1,
          ),
        ),
        const SizedBox(height: Spacing.xl),
        // Lo de arriba se toca varias veces al día —anotar un café, revisar lo
        // último— y lo de acá abajo una vez al mes. Estaban las cinco secciones
        // con el mismo peso, y las categorías —lo que menos se toca de toda la
        // app— ocupaban lo mismo que el botón de registrar.
        const BandLabel('Lo que se repite'),
        const SizedBox(height: Spacing.lg),
        flujos.when(
          loading: () => const _Cargando(alto: 200),
          error: (_, __) => const _Fallo(),
          data: (lista) {
            final ingresos = lista.where((f) => !f.isExpense).toList();
            final fijos = lista.where((f) => f.isExpense).toList();
            return Column(
              children: [
                _SeccionFlujos(
                  titulo: 'Ingresos recurrentes',
                  flujos: ingresos,
                  currency: user.currency,
                  vacio: 'Todavía no registraste ningún ingreso fijo.',
                  esGasto: false,
                ),
                const SizedBox(height: Spacing.lg),
                _SeccionFlujos(
                  titulo: 'Gastos fijos',
                  flujos: fijos,
                  currency: user.currency,
                  vacio: 'Todavía no registraste ningún gasto fijo.',
                  esGasto: true,
                ),
              ],
            );
          },
        ),
        const SizedBox(height: Spacing.xl),
        const BandLabel('Configuración'),
        const SizedBox(height: Spacing.lg),
        const CategoryManagementSection(),
      ],
    );
  }
}

class _BotonRegistrar extends StatelessWidget {
  const _BotonRegistrar({required this.onDone});

  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        if (await abrirNuevoMovimiento(context)) onDone();
      },
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colors.sageDark,
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const AppIcon(AppIconData.plus, size: 18, color: Color(0xFFFFFFFF)),
            const SizedBox(width: Spacing.sm),
            Text('Registrar un movimiento', style: AppText.bodyMedium(const Color(0xFFFFFFFF))),
          ],
        ),
      ),
    );
  }
}

/// La tarjeta de patrimonio: total, el mes, y una cuenta por chip con sus
/// acciones (corregir saldo, ocultar, borrar). Réplica de `BalanceCard` de la
/// web.
class _TarjetaPatrimonio extends ConsumerWidget {
  const _TarjetaPatrimonio({required this.posicion, required this.currency});

  final CashPosition posicion;
  final String currency;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppTheme.of(context);
    final neto = posicion.income - posicion.expenses;
    final ocultos = ref.watch(saldosOcultosProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(Spacing.xl),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.lg),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [colors.sageInk, colors.sage],
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'PATRIMONIO DISPONIBLE',
                      style: AppText.kicker(const Color(0xCCFFFFFF)),
                    ),
                  ),
                  OjoDeLaTarjeta(
                    ocultos: ocultos,
                    onTap: () => ref.read(saldosOcultosProvider.notifier).alternar(),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.sm),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  tapar(Money.format(posicion.total, currency), ocultos),
                  style: AppText.money(const Color(0xFFFFFFFF), size: 30, weight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: Spacing.lg),
              Row(
                children: [
                  Expanded(
                    child: _Mini(
                      rotulo: 'INGRESOS',
                      valor: tapar(Money.format(posicion.income, currency), ocultos),
                    ),
                  ),
                  Expanded(
                    child: _Mini(
                      rotulo: 'GASTOS',
                      valor: tapar(Money.format(posicion.expenses, currency), ocultos),
                    ),
                  ),
                  Expanded(
                    child: _Mini(
                      rotulo: 'NETO',
                      valor: tapar(Money.signed(neto, currency), ocultos),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.md),
        Wrap(
          spacing: Spacing.sm,
          runSpacing: Spacing.sm,
          children: [
            for (final c in posicion.accounts) _ChipCuenta(cuenta: c),
            const _ChipAgregarCuenta(),
          ],
        ),
      ],
    );
  }
}

class _Mini extends StatelessWidget {
  const _Mini({required this.rotulo, required this.valor});

  final String rotulo;
  final String valor;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(rotulo, style: AppText.tiny(const Color(0x99FFFFFF))),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(valor, style: AppText.money(const Color(0xFFFFFFFF), size: 13)),
        ),
      ],
    );
  }
}

class _ChipCuenta extends ConsumerWidget {
  const _ChipCuenta({required this.cuenta});

  final CashPositionAccount cuenta;

  Account get _comoAccount => Account(
    id: cuenta.id,
    name: cuenta.name,
    currency: cuenta.currency,
    balance: cuenta.currentBalance,
    isHidden: cuenta.isHidden,
  );

  Future<void> _abrirAcciones(BuildContext context, WidgetRef ref) async {
    final colors = AppTheme.of(context);
    final accion = await showAppModal<String>(
      context,
      title: cuenta.name,
      // `read` y no `watch`: esto corre al tocar el chip, no al construirlo.
      // Un `watch` fuera de `build` suscribe al widget desde un callback —una
      // dependencia que nadie ve al leer el build— y es de los que se pagan
      // caro más tarde.
      subtitle: tapar(
        Money.format(cuenta.currentBalance, cuenta.currency),
        ref.read(saldosOcultosProvider),
      ),
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FieldOption(titulo: 'Corregir saldo', onTap: () => Navigator.of(context).pop('editar')),
          FieldOption(
            titulo: cuenta.isHidden ? 'Mostrar cuenta' : 'Ocultar cuenta del patrimonio',
            onTap: () => Navigator.of(context).pop('ocultar'),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).pop('borrar'),
            child: Container(
              constraints: const BoxConstraints(minHeight: 48),
              alignment: Alignment.centerLeft,
              child: Text(
                'Eliminar cuenta',
                style: AppText.body(colors.danger).copyWith(fontWeight: FontWeight.w500),
              ),
            ),
          ),
        ],
      ),
    );

    if (!context.mounted) return;
    switch (accion) {
      case 'editar':
        await abrirEditorSaldo(context, cuenta: _comoAccount);
      case 'ocultar':
        await _toggleOculta(ref);
      case 'borrar':
        await _confirmarBorrado(context, ref);
    }
  }

  Future<void> _toggleOculta(WidgetRef ref) async {
    try {
      await ref.read(apiProvider).patch('/accounts/${cuenta.id}', {'isHidden': !cuenta.isHidden});
      ref
        ..invalidate(cashPositionProvider)
        ..invalidate(accountsProvider);
    } catch (_) {
      // Sin feedback bloqueante: si falló, la cuenta simplemente no cambió de
      // estado y el usuario lo nota al ver que sigue igual.
    }
  }

  Future<void> _confirmarBorrado(BuildContext context, WidgetRef ref) async {
    Map<String, dynamic>? impacto;
    try {
      impacto =
          await ref.read(apiProvider).get('/accounts/${cuenta.id}/deletion-impact')
              as Map<String, dynamic>;
    } on ApiException catch (e) {
      if (context.mounted) {
        await showFeedback(
          context,
          title: 'No se pudo revisar',
          message: e.message,
          tone: FeedbackTone.error,
        );
      }
      return;
    }

    final bloqueada = impacto['blockedBy'] != null;
    if (bloqueada) {
      if (context.mounted) {
        await showFeedback(
          context,
          title: 'No se puede eliminar',
          message: impacto['blockedBy'] == 'DEBT_ACCOUNT'
              ? 'Esta cuenta respalda una deuda. Borra la deuda primero.'
              : 'Esta cuenta tiene pagos de deuda registrados.',
          tone: FeedbackTone.aviso,
        );
      }
      return;
    }

    final movimientos = (impacto['movements'] as num?)?.toInt() ?? 0;
    final flujos = (impacto['recurringFlows'] as num?)?.toInt() ?? 0;
    if (!context.mounted) return;
    final ok = await showFeedback(
      context,
      title: '¿Eliminar "${cuenta.name}"?',
      message: movimientos == 0 && flujos == 0
          ? 'No tiene movimientos. Se elimina sin dejar rastro.'
          : 'Se van a borrar $movimientos movimientos y $flujos flujos recurrentes junto con la cuenta. No se puede deshacer.',
      tone: FeedbackTone.aviso,
      confirmLabel: 'Sí, eliminar',
      cancelLabel: 'Cancelar',
      destructive: true,
    );
    if (ok != true) return;

    try {
      await ref.read(apiProvider).delete('/accounts/${cuenta.id}/permanently');
      ref
        ..invalidate(cashPositionProvider)
        ..invalidate(accountsProvider)
        ..invalidate(recentTransactionsProvider);
    } on ApiException catch (e) {
      if (context.mounted) {
        await showFeedback(
          context,
          title: 'No se pudo eliminar',
          message: e.message,
          tone: FeedbackTone.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppTheme.of(context);
    // La pastilla también es un saldo de la tarjeta: el ojito la tapa con todo
    // lo demás. Tapar el patrimonio y dejar el saldo de cada cuenta a la vista
    // deja el interruptor a medias, que es como no tenerlo.
    final ocultos = ref.watch(saldosOcultosProvider);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _abrirAcciones(context, ref),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md, vertical: Spacing.sm),
        decoration: BoxDecoration(
          color: colors.surface.withValues(alpha: cuenta.isHidden ? 0.5 : 0.92),
          borderRadius: BorderRadius.circular(Radii.pill),
          border: Border.all(color: colors.surfaceBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (cuenta.isHidden)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: AppIcon(
                  AppIconData.eyeOff,
                  size: 13,
                  color: colors.oliveInk.withValues(alpha: 0.5),
                ),
              ),
            Text(
              cuenta.name,
              style: AppText.small(colors.foreground.withValues(alpha: cuenta.isHidden ? 0.55 : 1)),
            ),
            const SizedBox(width: 6),
            Text(
              tapar(Money.format(cuenta.currentBalance, cuenta.currency), ocultos),
              style: AppText.money(
                colors.oliveInk.withValues(alpha: cuenta.isHidden ? 0.45 : 0.7),
                size: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChipAgregarCuenta extends StatelessWidget {
  const _ChipAgregarCuenta();

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Builder(
      builder: (context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => abrirNuevaCuenta(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.md, vertical: Spacing.sm),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.pill),
            border: Border.all(color: colors.surfaceBorder, style: BorderStyle.solid),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(AppIconData.plus, size: 12, color: colors.sageInk),
              const SizedBox(width: 4),
              Text('Cuenta', style: AppText.small(colors.sageInk)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Una sección de flujos, con su contador de cumplidos.
/// Cuántas veces cae al mes cada frecuencia.
///
/// La misma tabla que `OCCURRENCES_PER_MONTH` del motor financiero del backend,
/// con los mismos números. Sumar los montos crudos metería un gasto anual de
/// S/1,200 en el total del mes como S/1,200, y el compromiso mensual saldría
/// doce veces más grande de lo que es.
const _ocurrenciasPorMes = {
  'WEEKLY': 4.345,
  'BIWEEKLY': 2.1725,
  'MONTHLY': 1.0,
  'QUARTERLY': 1 / 3,
  'YEARLY': 1 / 12,
};

/// El equivalente mensual de un flujo en un mes concreto.
///
/// Sobre lo registrado en ese mes si lo hay, y sobre lo declarado si no: el
/// resumen tiene que sumar lo que de verdad pasó, no una expectativa que quedó
/// vieja.
double _alMes(RecurringFlow f, String mes) =>
    f.montoDe(mes) * (_ocurrenciasPorMes[f.frequency] ?? 1.0);

class _SeccionFlujos extends ConsumerStatefulWidget {
  const _SeccionFlujos({
    required this.titulo,
    required this.flujos,
    required this.currency,
    required this.vacio,
    required this.esGasto,
  });

  final String titulo;
  final List<RecurringFlow> flujos;
  final String currency;
  final String vacio;
  final bool esGasto;

  @override
  ConsumerState<_SeccionFlujos> createState() => _SeccionFlujosState();
}

class _SeccionFlujosState extends ConsumerState<_SeccionFlujos> {
  /// Lo descontado con el ojito, por id. Sale del total, de lo pagado y del
  /// contador: dejarlo en el contador diría "3 de 7" con seis a la vista.
  final _ocultos = <String>{};

  /// El mes que se está mirando, como "2026-03". Arranca en el actual, que es
  /// la pregunta por defecto: qué toca ahora.
  late String _mes = _claveDe(DateTime.now());

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    // Solo los que existían ese mes.
    //
    // Un gasto fijo dado de alta hoy no es un gasto de julio: aparecía en el mes
    // anterior con su monto heredado, contaba como una fila más en "0 de 9
    // pagados" y hacía dudar de si faltaba pagarlo. Un flujo figura en un mes
    // desde que tiene ficha —o desde que tiene un pago registrado, para los
    // meses anteriores a que las fichas existieran—.
    final flujos = widget.flujos
        .where((f) => f.months.containsKey(_mes) || f.paidMonths.contains(_mes))
        .toList();
    final cuentan = flujos.where((f) => !_ocultos.contains(f.id)).toList();
    // "Cumplido" es una pregunta con fecha: la contesta el mes elegido, no el
    // de hoy. Con marzo a la vista, el resumen habla de marzo.
    final cumplidos = cuentan.where((f) => f.pagadoEn(_mes)).toList();
    final total = cuentan.fold<double>(0, (a, f) => a + _alMes(f, _mes));
    final pagado = cumplidos.fold<double>(0, (a, f) => a + _alMes(f, _mes));
    final falta = total - pagado > 0 ? total - pagado : 0.0;

    // En la caja que se aparta: un flujo fijo se registra una vez y se revisa
    // una vez al mes. Lo de arriba —anotar, revisar lo último— es lo de todos
    // los días, y con las dos elevadas igual nada decía por dónde empezar.
    return AppCard(
      discreta: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(title: widget.titulo),
          if (widget.flujos.isNotEmpty) ...[
            const SizedBox(height: Spacing.md),
            _SelectorMes(
              mes: _mes,
              desde: _primerMesConRegistros(widget.flujos),
              onSelect: (m) => setState(() => _mes = m),
            ),
          ],
          if (flujos.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.md),
              child: Text(
                widget.flujos.isEmpty
                    ? widget.vacio
                    : 'Nada registrado en ${_mesLargo(_mes)}: '
                          '${widget.esGasto ? "estos gastos" : "estos ingresos"} empezaron después.',
                style: AppText.small(colors.oliveInk.withValues(alpha: 0.7)),
              ),
            )
          else ...[
            const SizedBox(height: Spacing.md),
            _ResumenFlujos(
              total: total,
              pagado: pagado,
              falta: falta,
              cumplidos: cumplidos.length,
              cuentan: cuentan.length,
              ocultos: _ocultos.length,
              esGasto: widget.esGasto,
              currency: widget.currency,
              onResetear: () => setState(_ocultos.clear),
            ),
            for (final f in flujos)
              _FilaFlujo(
                flujo: f,
                currency: widget.currency,
                mes: _mes,
                oculto: _ocultos.contains(f.id),
                onAlternar: () => setState(() {
                  if (!_ocultos.remove(f.id)) _ocultos.add(f.id);
                }),
              ),
          ],
          const SizedBox(height: Spacing.sm),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () async {
              if (await abrirNuevoFlujo(context, esGasto: widget.esGasto)) {
                ref.invalidate(recurringFlowsProvider);
              }
            },
            child: Padding(
              padding: const EdgeInsets.only(top: Spacing.xs),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIcon(AppIconData.plus, size: 13, color: colors.sageInk),
                  const SizedBox(width: 6),
                  Text(
                    widget.esGasto ? 'Agregar gasto fijo' : 'Agregar ingreso recurrente',
                    style: AppText.small(colors.sageInk).copyWith(fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "2026-03" para una fecha.
String _claveDe(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';

/// Pregunta cuánto fue en ese mes, con la referencia como valor por defecto.
///
/// Devuelve `null` si se cancela. Cero es una respuesta válida: un mes puede no
/// haberse cobrado y aun así querer quedar registrado.
Future<double?> _pedirMonto(
  BuildContext context,
  RecurringFlow f,
  String mes,
  String currency,
) async {
  final controlador = TextEditingController(text: f.montoDe(mes).toStringAsFixed(2));
  final monto = await showAppModal<double>(
    context,
    title: f.isExpense ? '¿Cuánto pagaste?' : '¿Cuánto recibiste?',
    subtitle: f.name,
    builder: (context) => _FormularioMonto(controlador: controlador, currency: currency),
  );
  controlador.dispose();
  return monto;
}

class _FormularioMonto extends StatelessWidget {
  const _FormularioMonto({required this.controlador, required this.currency});

  final TextEditingController controlador;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldBox(
          child: Row(
            children: [
              Text(
                currency == 'USD' ? r'$' : 'S/',
                style: AppText.money(colors.oliveInk.withValues(alpha: 0.6)),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: AppTextField(
                  controller: controlador,
                  autofocus: true,
                  placeholder: '0.00',
                  style: AppText.money(colors.foreground, size: 20, weight: FontWeight.w600),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          'Solo para este mes. Los otros meses no cambian.',
          style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.65)),
        ),
        const SizedBox(height: Spacing.xl),
        AppButton(
          label: 'Guardar',
          onPressed: () {
            final v = double.tryParse(controlador.text.replaceAll(',', ''));
            if (v == null || v < 0) return;
            Navigator.of(context).pop(v);
          },
        ),
      ],
    );
  }
}

/// El primer mes con registro entre varios flujos, o `null` si no hay ninguno.
String? _primerMesConRegistros(List<RecurringFlow> flujos) {
  final todos = [for (final f in flujos) ...f.paidMonths]..sort();
  return todos.isEmpty ? null : todos.first;
}

/// Las pastillas de mes, desde el primer registro hasta el mes en curso.
///
/// **Desde el primer registro y no un año fijo.** Una tira de doce pastillas
/// vacías no dice nada, y la pregunta "¿marqué este?" solo existe donde hubo
/// algo que marcar. Con un flujo recién creado queda una sola pastilla: el mes
/// de hoy, que es el único sobre el que se puede actuar.
///
/// **Y una ventana que cruza el año sin caso especial.** Contando hacia atrás
/// desde hoy, el 2 de enero diciembre sigue estando ahí — que es justo el mes
/// que se viene a marcar, porque un pago se anota tarde. Con "el año en curso"
/// diciembre desaparecía el 1 de enero.
///
/// Hacia adelante no se ofrece nada: "pagado" es algo que ya pasó, y un mes que
/// todavía no llega no puede estar ni pagado ni pendiente.
class _SelectorMes extends StatelessWidget {
  const _SelectorMes({required this.mes, required this.desde, required this.onSelect});

  final String mes;

  /// El mes más viejo que se ofrece, como "2026-03". `null` si no hay registros.
  final String? desde;
  final void Function(String) onSelect;

  static const _nombres = [
    'ene',
    'feb',
    'mar',
    'abr',
    'may',
    'jun',
    'jul',
    'ago',
    'sep',
    'oct',
    'nov',
    'dic',
  ];

  /// Cuántas pastillas. Al menos una y nunca más de veinticuatro: pasado ese
  /// punto la tira deja de ser navegable y lo que hace falta es un historial.
  int _cuantas(DateTime hoy) {
    final inicio = desde;
    if (inicio == null) return 1;
    final partes = inicio.split('-');
    final meses = (hoy.year - int.parse(partes[0])) * 12 + (hoy.month - int.parse(partes[1])) + 1;
    return meses.clamp(1, 24);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final hoy = DateTime.now();

    return SizedBox(
      height: 30,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        // Arranca al final: el mes de hoy es el que se viene a ver, y con la
        // tira larga quedaría fuera de la pantalla de un teléfono.
        reverse: true,
        itemCount: _cuantas(hoy),
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          // Sobre el día 1: restarle meses a un 31 se desborda al siguiente.
          final cuando = DateTime(hoy.year, hoy.month - i, 1);
          final clave = _claveDe(cuando);
          final activo = clave == mes;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onSelect(clave),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
              decoration: BoxDecoration(
                color: activo ? colors.sageDark : null,
                borderRadius: BorderRadius.circular(Radii.pill),
                border: Border.all(color: activo ? colors.sageDark : colors.surfaceBorder),
              ),
              child: Text(
                // El año al lado cuando no es el actual: en enero, "dic" a
                // secas no dice si es el diciembre que pasó o el de hace un año.
                cuando.year == hoy.year
                    ? _nombres[cuando.month - 1]
                    : '${_nombres[cuando.month - 1]} ${cuando.year.toString().substring(2)}',
                style: AppText.small(
                  activo ? const Color(0xFFFFFFFF) : colors.foreground,
                ).copyWith(fontWeight: FontWeight.w500),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// El resumen de una sección: el compromiso del mes, cuánto ya pasó y cuánto
/// falta, más la barra que dice lo mismo sin leer.
///
/// "Pagado" cuenta el equivalente mensual completo del flujo y no el monto de
/// los pagos registrados: `paidThisMonth` solo dice si hubo alguno este mes. Es
/// la misma simplificación que ya hacía el contador de "3/7", ahora en dinero.
class _ResumenFlujos extends StatelessWidget {
  const _ResumenFlujos({
    required this.total,
    required this.pagado,
    required this.falta,
    required this.cumplidos,
    required this.cuentan,
    required this.ocultos,
    required this.esGasto,
    required this.currency,
    required this.onResetear,
  });

  final double total;
  final double pagado;
  final double falta;
  final int cumplidos;
  final int cuentan;
  final int ocultos;
  final bool esGasto;
  final String currency;
  final VoidCallback onResetear;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final avance = total > 0 ? (pagado / total).clamp(0.0, 1.0) : 0.0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.lg, vertical: Spacing.md),
      decoration: BoxDecoration(
        color: colors.sage.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: colors.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text(
                  'TOTAL AL MES',
                  style: AppText.kicker(
                    colors.oliveInk.withValues(alpha: 0.6),
                  ).copyWith(fontSize: 9.5),
                ),
              ),
              Text(
                Money.format(total, currency),
                style: AppText.money(colors.foreground, size: 15, weight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          BarraAvance(
            avance: avance,
            color: colors.sage,
            canal: colors.sage.withValues(alpha: 0.2),
          ),
          const SizedBox(height: Spacing.md),
          Wrap(
            spacing: Spacing.md,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${esGasto ? "Pagado" : "Recibido"} ${Money.format(pagado, currency)}',
                style: AppText.small(colors.sageInk).copyWith(fontWeight: FontWeight.w600),
              ),
              // "Falta" en rojo solo en los gastos: en un ingreso lo que falta
              // es plata por entrar, no una deuda contigo mismo.
              Text(
                'Falta ${Money.format(falta, currency)}',
                style: AppText.small(
                  esGasto ? colors.danger : colors.oliveInk.withValues(alpha: 0.75),
                ).copyWith(fontWeight: FontWeight.w600),
              ),
              Text(
                '($cumplidos de $cuentan)',
                style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.6)),
              ),
              if (ocultos > 0)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onResetear,
                  child: Text(
                    ocultos == 1
                        ? 'volver a contar el descontado'
                        : 'volver a contar los $ocultos descontados',
                    style: AppText.tiny(
                      colors.sageInk,
                    ).copyWith(decoration: TextDecoration.underline),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FilaFlujo extends ConsumerStatefulWidget {
  const _FilaFlujo({
    required this.flujo,
    required this.currency,
    required this.mes,
    required this.oculto,
    required this.onAlternar,
  });

  final RecurringFlow flujo;
  final String currency;

  /// El mes que se está mirando, como "2026-03". Todo lo de esta fila —el
  /// estado, marcar, revertir— habla de él y no del mes de hoy.
  final String mes;

  /// Descontado del total con el ojito. El estado vive en la sección, que es
  /// quien suma: la fila solo lo muestra y lo alterna.
  final bool oculto;
  final VoidCallback onAlternar;

  @override
  ConsumerState<_FilaFlujo> createState() => _FilaFlujoState();
}

class _FilaFlujoState extends ConsumerState<_FilaFlujo> {
  bool _ocupado = false;

  Future<void> _marcar() async {
    final f = widget.flujo;

    // Cuánto fue *este* mes. Se pregunta con la referencia ya escrita —lo del
    // mes anterior— así que el caso normal es un toque en "Guardar"; el mes en
    // que la luz vino distinta se corrige acá, y no editando el flujo, que
    // cambiaría todos los meses a la vez.
    final monto = await _pedirMonto(context, f, widget.mes, widget.currency);
    if (monto == null || !mounted) return;

    setState(() => _ocupado = true);
    try {
      final r =
          await ref.read(apiProvider).post('/recurring-flows/${f.id}/pay', {
                'month': widget.mes,
                'amount': monto,
              })
              as Map<String, dynamic>;
      ref.invalidate(recurringFlowsProvider);
      ref.invalidate(cashPositionProvider);
      ref.invalidate(recentTransactionsProvider);

      final saldados = ((r['saldados'] as List?) ?? []).cast<String>();
      if (saldados.isNotEmpty && mounted) {
        // Qué pasó con los meses que faltaban. Sin decirlo, el aviso de "faltó
        // julio" desaparecería sin explicación — y una advertencia que se
        // esfuma sola es peor que una que se queda.
        await showFeedback(
          context,
          title: 'Al día',
          message:
              '${saldados.map(_mesLargo).join(" y ")} ya no se ${saldados.length == 1 ? "reclama" : "reclaman"}.',
        );
      }
    } on ApiException catch (e) {
      if (mounted) {
        await showFeedback(
          context,
          title: 'No se pudo registrar',
          message: e.message,
          tone: FeedbackTone.error,
        );
      }
    } catch (_) {
      if (mounted) {
        await showFeedback(
          context,
          title: 'No se pudo registrar',
          message: 'No llegué al servidor. Inténtalo otra vez.',
          tone: FeedbackTone.error,
        );
      }
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  Future<void> _revertir() async {
    final f = widget.flujo;
    final ok = await showFeedback(
      context,
      title: '¿Revertir el registro de ${_mesLargo(widget.mes)}?',
      message: f.isExpense
          ? 'Devuelve ${Money.format(f.amount, widget.currency)} a tu cuenta y borra el movimiento.'
          : 'Quita ${Money.format(f.amount, widget.currency)} de tu cuenta y borra el movimiento.',
      tone: FeedbackTone.aviso,
      confirmLabel: 'Sí, revertir',
      cancelLabel: 'Cancelar',
      destructive: true,
    );
    if (ok != true) return;
    try {
      await ref.read(apiProvider).post('/recurring-flows/${f.id}/revert-payment', {
        'month': widget.mes,
      });
      ref.invalidate(recurringFlowsProvider);
      ref.invalidate(cashPositionProvider);
      ref.invalidate(recentTransactionsProvider);
    } catch (_) {
      if (mounted) {
        await showFeedback(context, title: 'No se pudo revertir', tone: FeedbackTone.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final f = widget.flujo;

    return Opacity(
      opacity: widget.oculto ? 0.45 : 1,
      child: Container(
        // Cada fila lleva tres líneas de texto y dos controles; con 12 puntos
        // arriba y abajo, el nombre de una quedaba pegado al botón de la de
        // encima y no se veía dónde terminaba cada flujo.
        padding: const EdgeInsets.symmetric(vertical: Spacing.lg),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors.foreground.withValues(alpha: 0.06))),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () async {
                  if (await abrirEditarFlujo(context, flujo: f, mes: widget.mes)) {
                    ref.invalidate(recurringFlowsProvider);
                  }
                },
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(child: Text(f.name, style: AppText.bodyMedium(colors.foreground))),
                        const SizedBox(width: 5),
                        AppIcon(
                          AppIconData.edit,
                          size: 11,
                          color: colors.oliveInk.withValues(alpha: 0.35),
                        ),
                      ],
                    ),
                    Text(
                      // El vencimiento del mes que se está mirando, no el
                      // próximo: con marzo a la vista, "vence 5 sep" contesta
                      // una pregunta que nadie hizo. Cada mes tiene el suyo.
                      '${f.categoryName ?? "Sin categoría"} · vence ${Fechas.dia(f.caducidadDe(widget.mes))}',
                      style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.6)),
                    ),
                    // Los meses sin registrar van bajo el nombre y no junto al
                    // estado: el estado habla del mes en curso y esto de meses que
                    // ya cerraron. Juntos parecerían contradecirse.
                    if (f.missedMonths.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Row(
                          children: [
                            AppIcon(AppIconData.warning, size: 12, color: colors.chart[3]),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                '${f.missedMonths.length} ${f.missedMonths.length == 1 ? "mes" : "meses"} sin registrar',
                                style: AppText.tiny(colors.chart[3]),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // El ojo a la izquierda de las cifras, como en el historial: la
            // columna de dinero se queda pegada al borde y los ojos quedan en
            // fila en vez de correrse con lo largo de cada monto.
            IconTapTarget(
              semanticLabel: widget.oculto
                  ? 'Volver a contar este ${f.isExpense ? "gasto" : "ingreso"}'
                  : 'Descontar este ${f.isExpense ? "gasto" : "ingreso"} del total',
              onTap: widget.onAlternar,
              child: AppIcon(
                widget.oculto ? AppIconData.eyeOff : AppIconData.eye,
                size: 16,
                color: colors.oliveInk.withValues(alpha: 0.4),
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // El monto de *este* mes, y se toca para cambiarlo.
                //
                // Cada mes es su propio número: julio puede decir 450 y agosto
                // 0 sin que uno arrastre al otro.
                //
                // Ya no se edita tocándolo. Tenía su propio editor porque el
                // modal escribía un monto global que no era el de ningún mes;
                // desde que el modal edita la ficha del mes elegido, dos sitios
                // para lo mismo es uno de más.
                Text(
                  '${f.isExpense ? "−" : "+"}${Money.format(f.montoDe(widget.mes), widget.currency)}',
                  style: AppText.money(f.isExpense ? colors.danger : colors.sageInk, size: 14)
                      .copyWith(
                        decoration: widget.oculto
                            ? TextDecoration.lineThrough
                            : TextDecoration.none,
                      ),
                ),
                const SizedBox(height: 4),
                if (f.pagadoEn(widget.mes))
                  GestureDetector(
                    onTap: _revertir,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: colors.sage.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(Radii.pill),
                          ),
                          child: Text(
                            f.isExpense ? 'Pagado' : 'Recibido',
                            style: AppText.tiny(
                              colors.sageInk,
                            ).copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Revertir',
                          style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.55)),
                        ),
                      ],
                    ),
                  )
                else
                  GestureDetector(
                    onTap: _ocupado ? null : _marcar,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: Spacing.md, vertical: 6),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(Radii.pill),
                        border: Border.all(color: colors.surfaceBorder),
                      ),
                      child: Text(
                        // El rótulo nombra el mes cuando no es el de hoy: la
                        // acción crea un movimiento fechado en el pasado, y un
                        // botón que no dice dónde cae invita al error.
                        _ocupado
                            ? 'Un momento…'
                            : widget.mes == _claveDe(DateTime.now())
                            ? (f.isExpense ? 'Marcar pagado' : 'Marcar recibido')
                            : 'Marcar en ${_mesLargo(widget.mes).toLowerCase()}',
                        style: AppText.tiny(
                          colors.foreground,
                        ).copyWith(fontWeight: FontWeight.w500),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _mesLargo(String clave) {
  const meses = [
    'Enero',
    'Febrero',
    'Marzo',
    'Abril',
    'Mayo',
    'Junio',
    'Julio',
    'Agosto',
    'Septiembre',
    'Octubre',
    'Noviembre',
    'Diciembre',
  ];
  final n = int.tryParse(clave.split('-').last) ?? 1;
  return meses[(n - 1).clamp(0, 11)];
}

class _Recientes extends StatelessWidget {
  const _Recientes({
    required this.transacciones,
    required this.currency,
    required this.mostrarCuenta,
  });

  final List<Transaction> transacciones;
  final String currency;
  final bool mostrarCuenta;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Últimos movimientos',
            trailing: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).push(
                PageRouteBuilder<void>(
                  pageBuilder: (context, a, b) => const HistorialScreen(),
                  transitionsBuilder: (context, a, b, child) => FadeTransition(
                    opacity: CurvedAnimation(parent: a, curve: Curves.easeOut),
                    child: child,
                  ),
                ),
              ),
              child: Text(
                'Ver todo',
                style: AppText.small(colors.sageInk).copyWith(fontWeight: FontWeight.w500),
              ),
            ),
          ),
          const SizedBox(height: Spacing.sm),
          if (transacciones.isEmpty)
            Text(
              'Todavía no registraste ningún movimiento.',
              style: AppText.small(colors.oliveInk.withValues(alpha: 0.7)),
            )
          else
            for (final t in transacciones)
              _FilaMovimiento(t: t, currency: currency, mostrarCuenta: mostrarCuenta),
        ],
      ),
    );
  }
}

class _FilaMovimiento extends StatelessWidget {
  const _FilaMovimiento({required this.t, required this.currency, required this.mostrarCuenta});

  final Transaction t;
  final String currency;

  /// Si la fila dice a qué cuenta fue.
  ///
  /// Solo con más de una cuenta: con una sola, repetir su nombre en cada fila es
  /// decir lo mismo veinte veces. Con dos es justo lo que uno quiere comprobar
  /// de un vistazo después de registrar — que la plata cayó donde la mandaste.
  final bool mostrarCuenta;

  String get _etiqueta => switch (t.kind) {
    'TRANSFER' => t.detail.isNotEmpty ? t.detail : 'Transferencia',
    'ADJUSTMENT' => 'Ajuste de saldo',
    _ => t.label,
  };

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final fila = Container(
      padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.foreground.withValues(alpha: 0.06))),
      ),
      child: Row(
        children: [
          if (t.kind == 'TRANSFER')
            Padding(
              padding: const EdgeInsets.only(right: Spacing.sm),
              child: AppIcon(
                AppIconData.swap,
                size: 15,
                color: colors.oliveInk.withValues(alpha: 0.6),
              ),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _etiqueta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body(colors.foreground),
                ),
                Text(
                  [
                    if (t.kind == 'MOVEMENT') t.category?.name,
                    // El medio de pago entre la categoría y la fecha, igual que
                    // en la web: es lo que contesta "¿esto ya salió de la
                    // cuenta o lo pagué con la tarjeta?" sin abrir la fila.
                    if (t.kind == 'MOVEMENT') MediosDePago.etiqueta(t.paymentMethod),
                    if (mostrarCuenta && t.accountName.isNotEmpty) t.accountName,
                    Fechas.dia(t.occurredAt),
                  ].whereType<String>().join(' · '),
                  style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.6)),
                ),
              ],
            ),
          ),
          const SizedBox(width: Spacing.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                t.kind == 'TRANSFER'
                    ? Money.format(t.amount, currency)
                    : '${t.isExpense ? "−" : "+"}${Money.format(t.amount, currency)}',
                style: AppText.money(
                  // Gasto en rojo e ingreso en azul, igual que la web
                  // (`negativeTextClass` / `positiveTextClass`): el signo solo
                  // no alcanza, es un carácter de tres píxeles al lado de una
                  // cifra, y recorriendo la lista lo que se busca es dónde se
                  // fue la plata. Una transferencia queda gris a propósito: no
                  // es ni gasto ni ingreso, solo cambió de bolsillo.
                  t.kind == 'TRANSFER'
                      ? colors.oliveInk.withValues(alpha: 0.8)
                      : t.isExpense
                      ? colors.danger
                      : colors.sageInk,
                  size: 13.5,
                ),
              ),
              // El saldo justo antes de este movimiento, igual que en la web:
              // verde salvo en rojo — un saldo negativo pintado de verde
              // diría lo contrario de lo que pasó.
              if (t.balanceBefore != null)
                Text(
                  Money.format(t.balanceBefore!, currency),
                  style: AppText.money(
                    t.balanceBefore! >= 0 ? colors.positiveBalance : colors.danger,
                    size: 11,
                    weight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ],
      ),
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => abrirDetalleMovimiento(context, t),
      child: fila,
    );
  }
}

class _Cargando extends StatelessWidget {
  const _Cargando({required this.alto});

  final double alto;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Container(
      height: alto,
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
    );
  }
}

class _Fallo extends StatelessWidget {
  const _Fallo();

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return AppCard(
      dashed: true,
      child: Text(
        'No pude cargar esto. Arrastra hacia abajo para reintentar.',
        style: AppText.small(colors.oliveInk.withValues(alpha: 0.8)),
      ),
    );
  }
}
