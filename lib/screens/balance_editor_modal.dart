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

/// Editar una cuenta: su nombre y su saldo.
///
/// El nombre no toca el ledger y podría guardarse al vuelo, pero va por el mismo
/// paso de revisar que el saldo: un solo flujo donde se ve todo lo que va a
/// cambiar, en vez de un campo que guarda solo y otro que pide confirmar.
///
/// No es un `PATCH` del saldo — el backend ya no lo acepta —: la corrección
/// entra al ledger como un `ADJUSTMENT`, así que queda explicable en el
/// historial en vez de simplemente cambiar. Dos pasos: primero se relee el
/// saldo del servidor y se muestra la diferencia sin escribir nada; recién al
/// confirmar se manda `expectedBalance` para que, si algo cambió la cuenta
/// entre medio (otro movimiento, otra pestaña), el backend lo rechace en vez
/// de pisar ese cambio en silencio.
/// Cambiarle el nombre a una cuenta, y nada más.
///
/// Aparte del editor de saldo aunque el campo viviera ahí dentro: son dos
/// decisiones distintas y meterlas en el mismo flujo obligaba a confirmar un
/// saldo que no se quería tocar. Un gesto, un campo, guardar.
Future<bool> abrirRenombrarCuenta(BuildContext context, {required Account cuenta}) async {
  final hecho = await showAppModal<bool>(
    context,
    title: 'Cambiar el nombre',
    subtitle: cuenta.name,
    builder: (context) => _RenombrarCuenta(cuenta: cuenta),
  );
  return hecho ?? false;
}

Future<bool> abrirEditorSaldo(BuildContext context, {required Account cuenta}) async {
  final guardado = await showAppModal<bool>(
    context,
    title: 'Editar cuenta',
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
  // La tarjeta de uso diario, la que pagas entera cada mes. No es una deuda con
  // tasa y plazo —para eso está la pantalla de Deudas— sino una cuenta de lo que
  // debes: comprar sube su saldo, pagarla lo baja, y nunca suma al patrimonio.
  ('CREDIT_CARD', 'Tarjeta de crédito'),
];

class _EditorSaldo extends ConsumerStatefulWidget {
  const _EditorSaldo({required this.cuenta});

  final Account cuenta;

  @override
  ConsumerState<_EditorSaldo> createState() => _EditorSaldoState();
}

class _EditorSaldoState extends ConsumerState<_EditorSaldo> {
  // El nombre y el monto arrancan con lo que hay: así "Continuar" está
  // disponible desde el primer momento y quien solo quiere renombrar no tiene
  // que volver a escribir su saldo para poder avanzar.
  late final _nombre = TextEditingController(text: widget.cuenta.name);
  late final _monto = TextEditingController(text: widget.cuenta.balance.toStringAsFixed(2));
  int _paso = 1;
  String? _nombreServidor;
  bool _cargando = false;
  bool _guardando = false;
  String? _error;
  double? _saldoServidor;

  @override
  void dispose() {
    _nombre.dispose();
    _monto.dispose();
    super.dispose();
  }

  double? get _montoValido => double.tryParse(_monto.text.replaceAll(',', ''));
  String get _nombreNuevo => _nombre.text.trim();
  bool get _renombra => _nombreServidor != null && _nombreNuevo != _nombreServidor;

  Future<void> _previsualizar() async {
    if (_montoValido == null) {
      setState(() => _error = 'Escribe un monto válido.');
      return;
    }
    if (_nombreNuevo.isEmpty) {
      setState(() => _error = 'La cuenta necesita un nombre.');
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
        _nombreServidor = actual.name;
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
      // Primero el nombre, después el saldo. El nombre no puede fallar por
      // concurrencia; el saldo sí. Si el saldo se rechaza, el nombre ya quedó y
      // el error habla solo de lo que falta.
      if (_renombra) {
        await ref.read(apiProvider).patch('/accounts/${widget.cuenta.id}', {'name': _nombreNuevo});
      }
      // Sin diferencia no se llama: evita un 409 falso si el saldo cambió por
      // otro lado mientras solo se quería renombrar.
      if ((nuevo - _saldoServidor!).abs() >= 0.005) {
        await ref.read(apiProvider).post('/accounts/${widget.cuenta.id}/balance', {
          'balance': nuevo,
          'occurredAt': DateTime.now().toIso8601String(),
          'expectedBalance': _saldoServidor,
        });
      }
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
          const FieldLabel('Nombre'),
          FieldBox(
            child: AppTextField(
              controller: _nombre,
              placeholder: 'Ej. Cuenta de ahorros',
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(height: Spacing.lg),
          FieldLabel(widget.cuenta.esDeCredito ? 'Lo que debes' : 'Saldo real'),
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
    final hayAjuste = diferencia.abs() >= 0.005;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_renombra) ...[
          Text(
            'Se renombra de «$_nombreServidor» a «$_nombreNuevo».',
            style: AppText.body(colors.foreground),
          ),
          const SizedBox(height: Spacing.sm),
        ],
        Text(
          !hayAjuste
              ? (_renombra
                    ? 'El saldo no cambia: no se registra ningún ajuste.'
                    : 'No hay diferencia con lo que ya tenías registrado.')
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
          label: hayAjuste
              ? 'Confirmar ajuste'
              : _renombra
              ? 'Guardar el nombre'
              : 'Cerrar',
          busy: _guardando,
          onPressed: _guardando
              ? null
              : (!hayAjuste && !_renombra)
              ? () => Navigator.of(context).pop(false)
              : _confirmar,
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
  /// El cupo, solo para una tarjeta. Vacío es "no lo dije", que es válido.
  final _cupo = TextEditingController();
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
        // Solo si se escribió y solo en una tarjeta: sin cupo se ve lo que debes
        // y no cuánto queda, que es media respuesta pero no una mentira.
        if (_tipo == 'CREDIT_CARD' && double.tryParse(_cupo.text.replaceAll(',', '')) != null)
          'creditLimit': double.parse(_cupo.text.replaceAll(',', '')),
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
        // Solo en una tarjeta: el cupo no significa nada en una cuenta de
        // ahorros, y un campo inerte enseña a ignorar los campos.
        if (_tipo == 'CREDIT_CARD') ...[
          const SizedBox(height: Spacing.lg),
          const FieldLabel('Cupo de la tarjeta (opcional)'),
          FieldBox(
            child: AppTextField(
              controller: _cupo,
              placeholder: '0.00',
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            ),
          ),
          const SizedBox(height: 4),
          Builder(
            builder: (context) => Text(
              'Para poder decirte cuánto te queda, no solo cuánto debes.',
              style: AppText.tiny(AppTheme.of(context).oliveInk.withValues(alpha: 0.65)),
            ),
          ),
        ],
        const SizedBox(height: Spacing.lg),
        FieldLabel(_tipo == 'CREDIT_CARD' ? 'Lo que debes hoy' : 'Saldo inicial'),
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

/// El formulario de renombrar: un campo y un botón.
class _RenombrarCuenta extends ConsumerStatefulWidget {
  const _RenombrarCuenta({required this.cuenta});

  final Account cuenta;

  @override
  ConsumerState<_RenombrarCuenta> createState() => _RenombrarCuentaState();
}

class _RenombrarCuentaState extends ConsumerState<_RenombrarCuenta> {
  late final _nombre = TextEditingController(text: widget.cuenta.name);
  bool _guardando = false;
  String? _error;

  @override
  void dispose() {
    _nombre.dispose();
    super.dispose();
  }

  Future<void> _guardar() async {
    final nuevo = _nombre.text.trim();
    if (nuevo.isEmpty) {
      setState(() => _error = 'La cuenta necesita un nombre.');
      return;
    }
    // Sin cambio no se llama: pedirle al servidor que guarde lo que ya tiene es
    // una petición que solo puede salir mal.
    if (nuevo == widget.cuenta.name) {
      Navigator.of(context).pop(false);
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      await ref.read(apiProvider).patch('/accounts/${widget.cuenta.id}', {'name': nuevo});
      ref
        ..invalidate(accountsProvider)
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

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const FieldLabel('Nombre'),
        FieldBox(
          child: AppTextField(
            controller: _nombre,
            // El foco va acá: es lo único que hay que escribir.
            autofocus: true,
            placeholder: 'Ej. Cuenta de ahorros',
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          'Solo cambia cómo se llama. Su saldo y sus movimientos se quedan como están.',
          style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.65)),
        ),
        if (_error != null) ...[
          const SizedBox(height: Spacing.sm),
          Text(_error!, style: AppText.small(colors.danger)),
        ],
        const SizedBox(height: Spacing.xl),
        AppButton(label: 'Guardar', busy: _guardando, onPressed: _guardando ? null : _guardar),
      ],
    );
  }
}
