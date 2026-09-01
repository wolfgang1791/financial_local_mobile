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
import '../ui/calendar.dart';
import '../ui/category_field.dart';
import '../ui/fields.dart';
import '../ui/format.dart';
import '../ui/icons.dart';
import '../ui/modal.dart';
import '../ui/payment_method_field.dart';

/// Abre el modal correcto para una fila de movimientos, según su naturaleza.
///
/// `OPENING_BALANCE` no se llama nunca desde acá: el backend rechaza editarla
/// y las listas que muestran movimientos ni siquiera la hacen tocable.
Future<void> abrirDetalleMovimiento(BuildContext context, Transaction t) async {
  switch (t.kind) {
    case 'ADJUSTMENT':
      await showAppModal<bool>(
        context,
        title: 'Ajuste de saldo',
        builder: (context) => _EditorAjuste(transaccion: t),
      );
    case 'TRANSFER':
      await showAppModal<bool>(
        context,
        title: 'Transferencia',
        builder: (context) => _DetalleTransferencia(transaccion: t),
      );
    default:
      await showAppModal<bool>(
        context,
        title: 'Editar movimiento',
        builder: (context) => _EditorMovimiento(transaccion: t),
      );
  }
}

void _invalidarTodo(WidgetRef ref) {
  ref
    ..invalidate(cashPositionProvider)
    ..invalidate(recentTransactionsProvider)
    ..invalidate(periodTransactionsProvider)
    // Y las cuentas: un movimiento cambia el saldo de la suya, y sin esto el
    // selector del formulario —y el de pagar una cuota— seguían mostrando el
    // saldo de antes. Registrar en una cuenta y que la cuenta no se entere es
    // exactamente lo que hace desconfiar de la cifra.
    ..invalidate(accountsProvider);
}

class _EditorMovimiento extends ConsumerStatefulWidget {
  const _EditorMovimiento({required this.transaccion});

  final Transaction transaccion;

  @override
  ConsumerState<_EditorMovimiento> createState() => _EditorMovimientoState();
}

class _EditorMovimientoState extends ConsumerState<_EditorMovimiento> {
  late final _monto = TextEditingController(text: widget.transaccion.amount.toStringAsFixed(2));
  late final _detalle = TextEditingController(text: widget.transaccion.detail);
  late bool _esGasto = widget.transaccion.isExpense;
  late String _cuentaId = widget.transaccion.accountId;
  late Category? _categoria = widget.transaccion.category;
  late String? _medioDePago = widget.transaccion.paymentMethod;
  late DateTime _fecha = widget.transaccion.occurredAt.toLocal();
  bool _guardando = false;
  bool _borrando = false;
  String? _error;

  double? get _montoValido {
    final v = double.tryParse(_monto.text.replaceAll(',', ''));
    return v != null && v > 0 ? v : null;
  }

  Future<void> _guardar() async {
    final monto = _montoValido;
    if (monto == null) {
      setState(() => _error = 'Escribe un monto mayor que cero.');
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      await ref.read(apiProvider).patch('/transactions/${widget.transaccion.id}', {
        'accountId': _cuentaId,
        'type': _esGasto ? 'EXPENSE' : 'INCOME',
        'amount': monto,
        'occurredAt': DateTime(_fecha.year, _fecha.month, _fecha.day, 12).toIso8601String(),
        'categoryId': _categoria?.id.isEmpty == true ? null : _categoria?.id,
        // Se manda siempre, también cuando quedó en `null`: es lo que permite
        // quitarle el medio de pago a un movimiento que lo tenía mal puesto.
        'paymentMethod': _medioDePago,
        'detail': _detalle.text.trim(),
      });
      _invalidarTodo(ref);
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
      title: '¿Eliminar este movimiento?',
      message:
          'Esto ${_esGasto ? "devuelve" : "quita"} ${Money.format(_montoValido ?? widget.transaccion.amount, ref.read(userProvider).currency)} de tu cuenta. No se puede deshacer.',
      tone: FeedbackTone.aviso,
      confirmLabel: 'Sí, eliminar',
      cancelLabel: 'Cancelar',
      destructive: true,
    );
    if (ok != true || !mounted) return;
    setState(() => _borrando = true);
    try {
      await ref.read(apiProvider).delete('/transactions/${widget.transaccion.id}');
      _invalidarTodo(ref);
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
    final cuenta = cuentas.where((c) => c.id == _cuentaId).firstOrNull;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldSwitch<bool>(
          opciones: const [('Gasto', true), ('Ingreso', false)],
          valor: _esGasto,
          onChange: (v) => setState(() {
            _esGasto = v;
            _categoria = null;
          }),
        ),
        const SizedBox(height: Spacing.xl),
        const FieldLabel('Monto'),
        FieldBox(
          child: AppTextField(
            controller: _monto,
            placeholder: '0.00',
            style: AppText.money(colors.foreground, size: 20, weight: FontWeight.w600),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(height: Spacing.lg),
        const FieldLabel('Detalle'),
        FieldBox(
          child: AppTextField(controller: _detalle, placeholder: 'Ej. Almuerzo con equipo'),
        ),
        const SizedBox(height: Spacing.lg),
        const FieldLabel('Categoría'),
        FieldSelector(
          texto: _categoria?.ruta ?? 'Sin categoría',
          onTap: () async {
            final elegida = await elegirCategoria(
              context,
              categorias.where((c) => c.type == (_esGasto ? 'EXPENSE' : 'INCOME')).toList(),
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
        const FieldLabel('Medio de pago'),
        FieldSelector(
          texto: MediosDePago.etiqueta(_medioDePago) ?? MediosDePago.sinEspecificar,
          onTap: () async {
            final elegido = await elegirMedioDePago(context, actual: _medioDePago);
            if (elegido != null) setState(() => _medioDePago = elegido.codigo);
          },
        ),
        const SizedBox(height: Spacing.lg),
        const FieldLabel('Fecha'),
        FieldSelector(
          texto: Fechas.diaConAnio(_fecha),
          icon: AppIconData.calendar,
          onTap: () async {
            final elegida = await pickDate(context, inicial: _fecha, ultima: DateTime.now());
            if (elegida != null) setState(() => _fecha = elegida);
          },
        ),
        if (_error != null) ...[
          const SizedBox(height: Spacing.md),
          Text(_error!, style: AppText.small(colors.danger)),
        ],
        const SizedBox(height: Spacing.xl),
        AppButton(
          label: 'Guardar cambios',
          busy: _guardando,
          onPressed: _montoValido == null || _guardando || _borrando ? null : _guardar,
        ),
        const SizedBox(height: Spacing.sm),
        AppButton(
          label: 'Eliminar movimiento',
          variant: AppButtonVariant.destructive,
          busy: _borrando,
          onPressed: _guardando || _borrando ? null : _borrar,
        ),
      ],
    );
  }
}

class _EditorAjuste extends ConsumerStatefulWidget {
  const _EditorAjuste({required this.transaccion});

  final Transaction transaccion;

  @override
  ConsumerState<_EditorAjuste> createState() => _EditorAjusteState();
}

class _EditorAjusteState extends ConsumerState<_EditorAjuste> {
  late final _monto = TextEditingController(text: widget.transaccion.amount.toStringAsFixed(2));
  late bool _sube = !widget.transaccion.isExpense;
  late DateTime _fecha = widget.transaccion.occurredAt.toLocal();
  bool _guardando = false;
  bool _borrando = false;
  String? _error;

  double? get _montoValido {
    final v = double.tryParse(_monto.text.replaceAll(',', ''));
    return v != null && v > 0 ? v : null;
  }

  Future<void> _guardar() async {
    final monto = _montoValido;
    if (monto == null) {
      setState(() => _error = 'Escribe un monto mayor que cero.');
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      await ref.read(apiProvider).patch('/transactions/${widget.transaccion.id}', {
        'type': _sube ? 'INCOME' : 'EXPENSE',
        'amount': monto,
        'occurredAt': DateTime(_fecha.year, _fecha.month, _fecha.day, 12).toIso8601String(),
      });
      _invalidarTodo(ref);
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
      title: '¿Eliminar este ajuste?',
      message: 'Tu saldo vuelve a como estaba antes de este ajuste. No se puede deshacer.',
      tone: FeedbackTone.aviso,
      confirmLabel: 'Sí, eliminar',
      cancelLabel: 'Cancelar',
      destructive: true,
    );
    if (ok != true || !mounted) return;
    setState(() => _borrando = true);
    try {
      await ref.read(apiProvider).delete('/transactions/${widget.transaccion.id}');
      _invalidarTodo(ref);
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Un ajuste corrige tu saldo sin categoría ni medio de pago: no cuenta '
          'como ingreso ni como gasto.',
          style: AppText.small(colors.oliveInk.withValues(alpha: 0.75)),
        ),
        const SizedBox(height: Spacing.lg),
        FieldSwitch<bool>(
          opciones: const [('Sube el saldo', true), ('Baja el saldo', false)],
          valor: _sube,
          onChange: (v) => setState(() => _sube = v),
        ),
        const SizedBox(height: Spacing.xl),
        const FieldLabel('Monto'),
        FieldBox(
          child: AppTextField(
            controller: _monto,
            placeholder: '0.00',
            style: AppText.money(colors.foreground, size: 20, weight: FontWeight.w600),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(height: Spacing.lg),
        const FieldLabel('Fecha'),
        FieldSelector(
          texto: Fechas.diaConAnio(_fecha),
          icon: AppIconData.calendar,
          onTap: () async {
            final elegida = await pickDate(context, inicial: _fecha, ultima: DateTime.now());
            if (elegida != null) setState(() => _fecha = elegida);
          },
        ),
        if (_error != null) ...[
          const SizedBox(height: Spacing.md),
          Text(_error!, style: AppText.small(colors.danger)),
        ],
        const SizedBox(height: Spacing.xl),
        AppButton(
          label: 'Guardar cambios',
          busy: _guardando,
          onPressed: _montoValido == null || _guardando || _borrando ? null : _guardar,
        ),
        const SizedBox(height: Spacing.sm),
        AppButton(
          label: 'Eliminar ajuste',
          variant: AppButtonVariant.destructive,
          busy: _borrando,
          onPressed: _guardando || _borrando ? null : _borrar,
        ),
      ],
    );
  }
}

class _DetalleTransferencia extends ConsumerStatefulWidget {
  const _DetalleTransferencia({required this.transaccion});

  final Transaction transaccion;

  @override
  ConsumerState<_DetalleTransferencia> createState() => _DetalleTransferenciaState();
}

class _DetalleTransferenciaState extends ConsumerState<_DetalleTransferencia> {
  bool _borrando = false;

  Future<void> _borrar() async {
    final t = widget.transaccion;
    final user = ref.read(userProvider);
    final ok = await showFeedback(
      context,
      title: '¿Eliminar esta transferencia?',
      message:
          'Se borran las dos partes del movimiento (${Money.format(t.amount, user.currency)}) y las dos cuentas vuelven a su saldo anterior. No se puede deshacer.',
      tone: FeedbackTone.aviso,
      confirmLabel: 'Sí, eliminar',
      cancelLabel: 'Cancelar',
      destructive: true,
    );
    if (ok != true || !mounted) return;
    setState(() => _borrando = true);
    try {
      await ref.read(apiProvider).delete('/transactions/${t.id}');
      _invalidarTodo(ref);
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
    final t = widget.transaccion;
    final user = ref.watch(userProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            AppIcon(AppIconData.swap, size: 20, color: colors.sageInk),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                t.detail.isNotEmpty ? t.detail : 'Transferencia entre cuentas',
                style: AppText.bodyMedium(colors.foreground),
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.md),
        Text(
          Money.format(t.amount, user.currency),
          style: AppText.money(colors.foreground, size: 22, weight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          Fechas.diaConAnio(t.occurredAt.toLocal()),
          style: AppText.small(colors.oliveInk.withValues(alpha: 0.7)),
        ),
        const SizedBox(height: Spacing.lg),
        Text(
          'Una transferencia no se edita: se borra y se vuelve a registrar si '
          'hace falta corregirla.',
          style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.6)),
        ),
        const SizedBox(height: Spacing.xl),
        AppButton(
          label: 'Eliminar transferencia',
          variant: AppButtonVariant.destructive,
          busy: _borrando,
          onPressed: _borrando ? null : _borrar,
        ),
      ],
    );
  }
}
