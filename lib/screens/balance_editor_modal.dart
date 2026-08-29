import 'package:flutter/services.dart' show FilteringTextInputFormatter, TextInputType;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api.dart';
import '../data/models.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../state/providers.dart';
import '../ui/buttons.dart';
import '../ui/fields.dart';
import '../ui/format.dart';
import '../ui/modal.dart';

/// Corregir el saldo de una cuenta.
///
/// No es un `PATCH` del saldo — el backend ya no lo acepta —: la corrección
/// entra al ledger como un `ADJUSTMENT`, así que queda explicable en el
/// historial en vez de simplemente cambiar. Dos pasos: primero se relee el
/// saldo del servidor y se muestra la diferencia sin escribir nada; recién al
/// confirmar se manda `expectedBalance` para que, si algo cambió la cuenta
/// entre medio (otro movimiento, otra pestaña), el backend lo rechace en vez
/// de pisar ese cambio en silencio.
Future<bool> abrirEditorSaldo(BuildContext context, {required Account cuenta}) async {
  final guardado = await showAppModal<bool>(
    context,
    title: 'Corregir saldo',
    subtitle: cuenta.name,
    builder: (context) => _EditorSaldo(cuenta: cuenta),
  );
  return guardado ?? false;
}

/// Agregar una cuenta nueva (además de la del onboarding).
Future<bool> abrirNuevaCuenta(BuildContext context) async {
  final creada = await showAppModal<bool>(
    context,
    title: 'Nueva cuenta',
    builder: (context) => const _NuevaCuenta(),
  );
  return creada ?? false;
}

const _tiposCuenta = [
  ('CASH', 'Efectivo'),
  ('CHECKING', 'Cuenta corriente'),
  ('SAVINGS', 'Cuenta de ahorros'),
  ('INVESTMENT', 'Inversión'),
];

class _EditorSaldo extends ConsumerStatefulWidget {
  const _EditorSaldo({required this.cuenta});

  final Account cuenta;

  @override
  ConsumerState<_EditorSaldo> createState() => _EditorSaldoState();
}

class _EditorSaldoState extends ConsumerState<_EditorSaldo> {
  final _monto = TextEditingController();
  int _paso = 1;
  bool _cargando = false;
  bool _guardando = false;
  String? _error;
  double? _saldoServidor;

  @override
  void dispose() {
    _monto.dispose();
    super.dispose();
  }

  double? get _montoValido => double.tryParse(_monto.text.replaceAll(',', ''));

  Future<void> _previsualizar() async {
    if (_montoValido == null) {
      setState(() => _error = 'Escribe un monto válido.');
      return;
    }
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      final r = await ref.read(apiProvider).get('/accounts') as List;
      final actual = r
          .map((e) => Account.fromJson(e as Map<String, dynamic>))
          .firstWhere((a) => a.id == widget.cuenta.id, orElse: () => widget.cuenta);
      setState(() {
        _saldoServidor = actual.balance;
        _paso = 2;
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'No llegué al servidor. Inténtalo otra vez.');
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _confirmar() async {
    final nuevo = _montoValido;
    if (nuevo == null || _saldoServidor == null) return;
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      await ref.read(apiProvider).post('/accounts/${widget.cuenta.id}/balance', {
        'balance': nuevo,
        'occurredAt': DateTime.now().toIso8601String(),
        'expectedBalance': _saldoServidor,
      });
      ref
        ..invalidate(cashPositionProvider)
        ..invalidate(recentTransactionsProvider)
        ..invalidate(accountsProvider);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      // Un 409 acá es "cambió mientras tanto": se vuelve al paso 1 para que
      // relea el saldo de verdad en vez de insistir con uno que ya no vale.
      setState(() {
        _error = e.message;
        _paso = 1;
      });
    } catch (_) {
      setState(() => _error = 'No llegué al servidor. Inténtalo otra vez.');
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final user = ref.watch(userProvider);

    if (_paso == 1) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Saldo actual: ${Money.format(widget.cuenta.balance, widget.cuenta.currency)}',
            style: AppText.small(colors.oliveInk.withValues(alpha: 0.75)),
          ),
          const SizedBox(height: Spacing.lg),
          const FieldLabel('¿Cuál es el saldo real?'),
          FieldBox(
            child: Row(
              children: [
                Text(
                  widget.cuenta.currency == 'USD' ? r'$' : 'S/',
                  style: AppText.money(colors.oliveInk.withValues(alpha: 0.6)),
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: AppTextField(
                    controller: _monto,
                    autofocus: true,
                    placeholder: '0.00',
                    style: AppText.money(colors.foreground, size: 20, weight: FontWeight.w600),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: Spacing.md),
            Text(_error!, style: AppText.small(colors.danger)),
          ],
          const SizedBox(height: Spacing.xl),
          AppButton(
            label: 'Continuar',
            busy: _cargando,
            onPressed: _montoValido == null || _cargando ? null : _previsualizar,
          ),
        ],
      );
    }

    final diferencia = _montoValido! - _saldoServidor!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          diferencia == 0
              ? 'No hay diferencia con lo que ya tenías registrado.'
              : 'Esto ajusta tu saldo en ${Money.signed(diferencia, user.currency)}.',
          style: AppText.body(colors.foreground),
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          'El movimiento queda como un ajuste, no como un ingreso o un gasto: '
          'no cuenta para tus reportes de gasto.',
          style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.6)),
        ),
        if (_error != null) ...[
          const SizedBox(height: Spacing.md),
          Text(_error!, style: AppText.small(colors.danger)),
        ],
        const SizedBox(height: Spacing.xl),
        AppButton(
          label: 'Confirmar ajuste',
          busy: _guardando,
          onPressed: _guardando ? null : _confirmar,
        ),
      ],
    );
  }
}

class _NuevaCuenta extends ConsumerStatefulWidget {
  const _NuevaCuenta();

  @override
  ConsumerState<_NuevaCuenta> createState() => _NuevaCuentaState();
}

class _NuevaCuentaState extends ConsumerState<_NuevaCuenta> {
  final _nombre = TextEditingController();
  final _monto = TextEditingController();
  String _tipo = 'CASH';
  String? _moneda;
  bool _guardando = false;
  String? _error;

  @override
  void dispose() {
    _nombre.dispose();
    _monto.dispose();
    super.dispose();
  }

  double get _montoValido => double.tryParse(_monto.text.replaceAll(',', '')) ?? 0;

  Future<void> _guardar() async {
    if (_nombre.text.trim().isEmpty) {
      setState(() => _error = 'Ponle un nombre a la cuenta.');
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      final user = ref.read(userProvider);
      await ref.read(apiProvider).post('/accounts', {
        'name': _nombre.text.trim(),
        'type': _tipo,
        'currentBalance': _montoValido,
        'currency': _moneda ?? user.currency,
        'openedAt': DateTime.now().toIso8601String(),
      });
      ref
        ..invalidate(cashPositionProvider)
        ..invalidate(accountsProvider);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'No llegué al servidor. Inténtalo otra vez.');
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final user = ref.watch(userProvider);
    final moneda = _moneda ?? user.currency;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const FieldLabel('Nombre'),
        FieldBox(
          child: AppTextField(
            controller: _nombre,
            autofocus: true,
            placeholder: 'Ej. Cuenta de ahorros',
          ),
        ),
        const SizedBox(height: Spacing.lg),
        const FieldLabel('Tipo'),
        FieldSelector(
          texto: _tiposCuenta.firstWhere((t) => t.$1 == _tipo).$2,
          onTap: () async {
            final elegido = await showAppModal<String>(
              context,
              title: 'Tipo de cuenta',
              builder: (context) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (codigo, etiqueta) in _tiposCuenta)
                    FieldOption(
                      titulo: etiqueta,
                      seleccionado: codigo == _tipo,
                      onTap: () => Navigator.of(context).pop(codigo),
                    ),
                ],
              ),
            );
            if (elegido != null) setState(() => _tipo = elegido);
          },
        ),
        const SizedBox(height: Spacing.lg),
        const FieldLabel('Saldo inicial'),
        FieldBox(
          child: Row(
            children: [
              Text(
                moneda == 'USD' ? r'$' : 'S/',
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
        if (_error != null) ...[
          const SizedBox(height: Spacing.md),
          Text(_error!, style: AppText.small(colors.danger)),
        ],
        const SizedBox(height: Spacing.xl),
        AppButton(label: 'Crear cuenta', busy: _guardando, onPressed: _guardando ? null : _guardar),
      ],
    );
  }
}
