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
import '../ui/category_field.dart';
import '../ui/fields.dart';
import '../ui/format.dart';
import '../ui/icons.dart';
import '../ui/modal.dart';

/// "2026-08-19" — la fecha como la espera el API, sin hora ni zona de por medio.
String _fechaCorta(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// "2026-08" → "agosto". Sin instantes de por medio: la clave ya trae el mes, y
/// armar una fecha para volver a leerlo es la vía rápida a que se corra al mes
/// anterior.
String _nombreMes(String clave) {
  const meses = [
    'enero',
    'febrero',
    'marzo',
    'abril',
    'mayo',
    'junio',
    'julio',
    'agosto',
    'septiembre',
    'octubre',
    'noviembre',
    'diciembre',
  ];
  final n = int.tryParse(clave.split('-')[1]) ?? 1;
  return meses[(n - 1).clamp(0, 11)];
}

const _frecuencias = [
  ('WEEKLY', 'Semanal'),
  ('BIWEEKLY', 'Quincenal'),
  ('MONTHLY', 'Mensual'),
  ('QUARTERLY', 'Trimestral'),
  ('YEARLY', 'Anual'),
];

/// Un ingreso recurrente o un gasto fijo, nuevo.
Future<bool> abrirNuevoFlujo(BuildContext context, {required bool esGasto}) async {
  final creado = await showAppModal<bool>(
    context,
    title: esGasto ? 'Nuevo gasto fijo' : 'Nuevo ingreso recurrente',
    builder: (context) => _FormularioFlujo(esGasto: esGasto),
  );
  return creado ?? false;
}

/// Editar uno que ya existe (o borrarlo).
///
/// [mes] es el que está elegido en las pastillas. El formulario edita **ese**
/// mes y lo dice con todas sus letras: el monto y el vencimiento son de un mes
/// concreto, y un campo que no diga de cuál es el que hacía que editar julio
/// cambiara agosto.
Future<bool> abrirEditarFlujo(
  BuildContext context, {
  required RecurringFlow flujo,
  required String mes,
}) async {
  final cambiado = await showAppModal<bool>(
    context,
    title: flujo.isExpense ? 'Editar gasto fijo' : 'Editar ingreso recurrente',
    builder: (context) => _FormularioFlujo(esGasto: flujo.isExpense, flujo: flujo, mes: mes),
  );
  return cambiado ?? false;
}

class _FormularioFlujo extends ConsumerStatefulWidget {
  const _FormularioFlujo({required this.esGasto, this.flujo, this.mes});

  final bool esGasto;
  final RecurringFlow? flujo;

  /// El mes elegido, al editar. Null al crear: ahí todavía no hay meses.
  final String? mes;

  @override
  ConsumerState<_FormularioFlujo> createState() => _FormularioFlujoState();
}

class _FormularioFlujoState extends ConsumerState<_FormularioFlujo> {
  late final _nombre = TextEditingController(text: widget.flujo?.name ?? '');

  /// El monto: la semilla al crear, y el de la ficha del mes elegido al editar.
  ///
  /// Al editar **no** es el monto del flujo. Ahí es solo la semilla del primer
  /// mes, y escribirlo desde este formulario fue exactamente el bug que costó
  /// media tarde: cambiabas el monto mirando julio y no se movía nada en
  /// pantalla, porque lo que se guardaba no era el mes de nadie.
  late final _monto = TextEditingController(
    text: widget.flujo == null
        ? ''
        : (_fichaDelMes?.amount ?? widget.flujo!.amount).toStringAsFixed(2),
  );
  late String _frecuencia = widget.flujo?.frequency ?? 'MONTHLY';
  late DateTime _proxima = widget.flujo?.nextDueDate.toLocal() ?? DateTime.now();

  /// La caducidad de ese mes, al editar. Cae siempre dentro de su mes: una
  /// ficha de agosto con fecha de septiembre ya se coló una vez y no la
  /// corregía nadie.
  late DateTime _vence = _fichaDelMes?.dueDate.toLocal() ?? _ultimoDiaDelMes();

  /// Cuándo se marcó pagado o cobrado ese mes. Null si todavía no se marcó:
  /// ahí no hay fecha que corregir porque no hay hecho que fechar.
  late DateTime? _marcado = _fichaDelMes?.paidAt?.toLocal();
  Category? _categoria;
  late String? _cuentaId = widget.flujo?.accountId;
  bool _guardando = false;
  bool _borrando = false;
  String? _error;
  bool _categoriaInicializada = false;

  @override
  void dispose() {
    _nombre.dispose();
    _monto.dispose();
    super.dispose();
  }

  /// El monto, si lo escrito es un número que se puede guardar.
  ///
  /// Cero vale: un ingreso fijo puede estar en pausa —un alquiler que este año
  /// no se cobra, un bono que quedó en nada— y obligar a borrarlo para
  /// registrar eso pierde su historia y su categoría. Lo que no vale es un
  /// negativo: el sentido lo da el tipo del flujo (ingreso o gasto), y un
  /// monto en negativo lo invertiría por la puerta de atrás.
  double? get _montoValido {
    final v = double.tryParse(_monto.text.replaceAll(',', ''));
    return v != null && v >= 0 ? v : null;
  }

  /// La ficha del mes elegido, si existe. No existe en los meses anteriores al
  /// alta del flujo: HBO Max no tenía monto en julio porque no estaba
  /// contratado.
  FlowMonth? get _fichaDelMes => widget.mes == null ? null : widget.flujo?.months[widget.mes!];

  DateTime _ultimoDiaDelMes() {
    final mes = widget.mes;
    if (mes == null) return DateTime.now();
    final partes = mes.split('-');
    return DateTime(int.parse(partes[0]), int.parse(partes[1]) + 1, 0);
  }

  Future<void> _guardar(List<Account> cuentas) async {
    if (_nombre.text.trim().isEmpty) {
      setState(() => _error = 'Ponle un nombre.');
      return;
    }
    final monto = _montoValido;
    if (monto == null) {
      setState(() => _error = 'Escribe un monto: cero o más, nunca negativo.');
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      // Un formulario, dos tablas.
      //
      // Los datos viven repartidos desde que cada mes tiene su ficha: el
      // nombre, la frecuencia, la categoría y la cuenta son del flujo entero, y
      // el monto y el vencimiento son del mes que se está mirando. Eso no es
      // razón para partir el formulario en dos —quien edita HBO Max quiere
      // corregir "el gasto", no elegir en qué tabla escribe—, así que se
      // muestran juntos y cada campo se manda a donde vive.
      final api = ref.read(apiProvider);
      if (widget.flujo == null) {
        final hoy = DateTime.now();
        await api.post('/recurring-flows', {
          'name': _nombre.text.trim(),
          'type': widget.esGasto ? 'EXPENSE' : 'INCOME',
          'amount': monto,
          'frequency': _frecuencia,
          // Desde cuándo existe. Faltaba, y sin ella el alta fallaba entera:
          // es la fecha desde la que se cuentan los meses, así que un flujo
          // dado de alta hoy no aparece en los meses anteriores.
          'startDate': _fechaCorta(hoy),
          'nextDueDate': _fechaCorta(_proxima),
          if (_categoria != null && _categoria!.id.isNotEmpty) 'categoryId': _categoria!.id,
          if (_cuentaId != null) 'accountId': _cuentaId,
        });
      } else {
        await api.patch('/recurring-flows/${widget.flujo!.id}', {
          'name': _nombre.text.trim(),
          'frequency': _frecuencia,
          if (_categoria != null && _categoria!.id.isNotEmpty) 'categoryId': _categoria!.id,
          if (_cuentaId != null) 'accountId': _cuentaId,
        });
        // La ficha del mes, a su tabla. Solo si la había: un mes anterior al
        // alta del flujo no tiene ficha, y el formulario no muestra sus campos.
        if (widget.mes != null && _fichaDelMes != null) {
          await api.patch('/recurring-flows/${widget.flujo!.id}/month', {
            'month': widget.mes,
            'amount': monto,
            'dueDate': _fechaCorta(_vence),
            if (_marcado != null) 'paidAt': _fechaCorta(_marcado!),
          });
        }
      }
      ref
        ..invalidate(recurringFlowsProvider)
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
      title: '¿Eliminar "${widget.flujo!.name}"?',
      message:
          'Esto no borra los movimientos ya registrados, solo deja de pedir que se marque cada mes.',
      tone: FeedbackTone.aviso,
      confirmLabel: 'Sí, eliminar',
      cancelLabel: 'Cancelar',
      destructive: true,
    );
    if (ok != true || !mounted) return;
    setState(() => _borrando = true);
    try {
      await ref.read(apiProvider).delete('/recurring-flows/${widget.flujo!.id}');
      ref.invalidate(recurringFlowsProvider);
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
    final cuentas = ref.watch(accountsProvider).valueOrNull ?? const <Account>[];
    final categorias = ref.watch(categoriesProvider).valueOrNull ?? const <Category>[];
    final cuenta =
        cuentas.where((c) => c.id == _cuentaId).firstOrNull ??
        (cuentas.isEmpty ? null : cuentas.first);

    // La categoría del flujo existente llega como nombre desde el backend; se
    // resuelve contra el catálogo recién cuando ya cargó, y solo una vez —si
    // se repitiera en cada build pisaría lo que el usuario acabe de elegir.
    if (!_categoriaInicializada && widget.flujo?.categoryName != null && categorias.isNotEmpty) {
      _categoriaInicializada = true;
      _categoria = categorias.where((c) => c.name == widget.flujo!.categoryName).firstOrNull;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const FieldLabel('Nombre'),
        FieldBox(
          child: AppTextField(
            controller: _nombre,
            autofocus: widget.flujo == null,
            placeholder: 'Ej. Alquiler',
          ),
        ),
        // El monto: la semilla al crear, y la ficha del mes al editar.
        //
        // Antes acá había un aviso diciendo "el monto se edita en la lista": el
        // formulario se abría, se cambiaba algo y no pasaba nada, que es peor
        // que no tener formulario. Ahora el campo está, pero dice de qué mes
        // habla y se guarda en la tabla de ese mes.
        const SizedBox(height: Spacing.lg),
        if (widget.flujo != null && widget.mes != null && _fichaDelMes == null)
          Builder(
            builder: (context) => Text(
              '${_nombreMes(widget.mes!)} no tiene ficha: '
              '${widget.esGasto ? "este gasto" : "este ingreso"} todavía no existía. '
              'Elige un mes desde el alta para ponerle monto y vencimiento.',
              style: AppText.tiny(AppTheme.of(context).oliveInk.withValues(alpha: 0.7)),
            ),
          )
        else ...[
          FieldLabel(widget.flujo == null ? 'Monto' : 'Monto de ${_nombreMes(widget.mes!)}'),
          FieldBox(
            child: Row(
              children: [
                Text(
                  cuenta?.currency == 'USD' ? r'$' : 'S/',
                  style: AppText.money(colors.oliveInk.withValues(alpha: 0.6)),
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: AppTextField(
                    controller: _monto,
                    placeholder: '0.00',
                    style: AppText.money(colors.foreground, size: 18, weight: FontWeight.w600),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
          ),
          // La caducidad de ese mes, al lado de su monto: son los dos campos de
          // la misma ficha, y separarlos obliga a abrir dos cosas para corregir
          // un mes.
          if (widget.flujo != null) ...[
            const SizedBox(height: Spacing.lg),
            FieldLabel('Vence en ${_nombreMes(widget.mes!)}'),
            FieldSelector(
              texto: Fechas.diaConAnio(_vence),
              icon: AppIconData.calendar,
              // Sin acotar al mes: una tarjeta con cierre el 28 se paga el 5
              // del siguiente, y un recibo de diciembre vence en enero. La
              // ficha sigue siendo la de su mes — eso lo decide la pastilla,
              // no la fecha.
              onTap: () async {
                final elegida = await pickDate(context, inicial: _vence);
                if (elegida != null) setState(() => _vence = elegida);
              },
            ),
            // Cuándo se marcó, y se puede corregir.
            //
            // Arregla el caso normal: lo pagaste el martes y lo marcaste el
            // viernes. Cambiarla mueve el movimiento con ella —son la misma
            // cosa vista desde dos tablas— así que el gasto pasa a contar el
            // día que de verdad ocurrió. El saldo no se entera: la plata ya se
            // movió y sigue siendo la misma.
            if (_marcado != null) ...[
              const SizedBox(height: Spacing.lg),
              FieldLabel(widget.esGasto ? 'Pagado el' : 'Recibido el'),
              FieldSelector(
                texto: Fechas.diaConAnio(_marcado!),
                icon: AppIconData.calendar,
                onTap: () async {
                  final elegida = await pickDate(context, inicial: _marcado!);
                  if (elegida != null) setState(() => _marcado = elegida);
                },
              ),
            ] else ...[
              const SizedBox(height: Spacing.sm),
              Builder(
                builder: (context) => Text(
                  'Todavía sin marcar ${widget.esGasto ? "como pagado" : "como recibido"}.',
                  style: AppText.tiny(AppTheme.of(context).oliveInk.withValues(alpha: 0.7)),
                ),
              ),
            ],
            const SizedBox(height: Spacing.sm),
            Builder(
              builder: (context) => Text(
                'Cambiar esto no toca los otros meses. El mes que viene nace copiando a este.',
                style: AppText.tiny(AppTheme.of(context).oliveInk.withValues(alpha: 0.7)),
              ),
            ),
          ],
        ],
        const SizedBox(height: Spacing.lg),
        const FieldLabel('Categoría'),
        FieldSelector(
          texto: _categoria?.ruta ?? 'Sin categoría',
          onTap: () async {
            final elegida = await elegirCategoria(
              context,
              categorias.where((c) => c.type == (widget.esGasto ? 'EXPENSE' : 'INCOME')).toList(),
            );
            if (elegida != null) setState(() => _categoria = elegida);
          },
        ),
        const SizedBox(height: Spacing.lg),
        if (cuentas.length > 1) ...[
          const FieldLabel('Cuenta'),
          FieldSelector(
            texto: cuenta?.name ?? 'Elige una',
            onTap: () async {
              final elegida = await showAppModal<Account>(
                context,
                title: 'Elige la cuenta',
                builder: (context) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final c in cuentas)
                      FieldOption(titulo: c.name, onTap: () => Navigator.of(context).pop(c)),
                  ],
                ),
              );
              if (elegida != null) setState(() => _cuentaId = elegida.id);
            },
          ),
          const SizedBox(height: Spacing.lg),
        ],
        const FieldLabel('Frecuencia'),
        FieldSelector(
          texto: _frecuencias.firstWhere((f) => f.$1 == _frecuencia).$2,
          onTap: () async {
            final elegida = await showAppModal<String>(
              context,
              title: 'Frecuencia',
              builder: (context) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (codigo, etiqueta) in _frecuencias)
                    FieldOption(
                      titulo: etiqueta,
                      seleccionado: codigo == _frecuencia,
                      onTap: () => Navigator.of(context).pop(codigo),
                    ),
                ],
              ),
            );
            if (elegida != null) setState(() => _frecuencia = elegida);
          },
        ),
        // Solo al crear: es de dónde sale la primera ficha. Al editar, el
        // vencimiento es el del mes que se está mirando y vive arriba.
        if (widget.flujo == null) ...[
          const SizedBox(height: Spacing.lg),
          const FieldLabel('Próxima fecha'),
          FieldSelector(
            texto: Fechas.diaConAnio(_proxima),
            icon: AppIconData.calendar,
            onTap: () async {
              final elegida = await pickDate(context, inicial: _proxima);
              if (elegida != null) setState(() => _proxima = elegida);
            },
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: Spacing.md),
          Text(_error!, style: AppText.small(colors.danger)),
        ],
        const SizedBox(height: Spacing.xl),
        AppButton(
          label: widget.flujo == null ? 'Guardar' : 'Guardar cambios',
          busy: _guardando,
          onPressed: _guardando || _borrando ? null : () => _guardar(cuentas),
        ),
        if (widget.flujo != null) ...[
          const SizedBox(height: Spacing.sm),
          AppButton(
            label: 'Eliminar',
            variant: AppButtonVariant.destructive,
            busy: _borrando,
            onPressed: _guardando || _borrando ? null : _borrar,
          ),
        ],
      ],
    );
  }
}
