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
import '../ui/cupo_de_tarjeta.dart';

/// Registrar un movimiento.
///
/// Va en un modal y no en una pantalla propia: es una tarea corta que se hace
/// desde donde estabas y te devuelve ahí mismo. Empujar una ruta obligaría a
/// volver, y volver a una lista que ya no es la que dejaste.
Future<bool> abrirNuevoMovimiento(BuildContext context) async {
  final creado = await showAppModal<bool>(
    context,
    title: 'Nuevo movimiento',
    subtitle: 'Se descuenta o se suma a tu cuenta al guardarlo',
    builder: (context) => const _Formulario(),
  );
  return creado ?? false;
}

class _Formulario extends ConsumerStatefulWidget {
  const _Formulario();

  @override
  ConsumerState<_Formulario> createState() => _FormularioState();
}

/// Pagar la tarjeta es su propio modo y no un gasto con otro nombre: mueve plata
/// de tu cuenta al plástico, así que **no cuenta como gasto nuevo** — el gasto
/// fue la compra. Se registra como transferencia, igual que en la web.
enum _Modo { gasto, ingreso, transferencia, tarjeta }

class _FormularioState extends ConsumerState<_Formulario> {
  /// Gasto por defecto: es lo que se registra el 90% de las veces. Un ingreso
  /// suele ser el sueldo, y ese ya está como flujo recurrente.
  _Modo _modo = _Modo.gasto;
  final _monto = TextEditingController();
  final _detalle = TextEditingController();
  String? _cuentaId;
  String? _cuentaDestinoId;

  /// Qué tarjeta se está pagando. `null` es la que más debe, que es la que se
  /// paga.
  String? _tarjetaId;
  Category? _categoria;

  /// El medio de pago, o `null` mientras no se elija ninguno.
  ///
  /// Sin valor por defecto a propósito: adivinar "Efectivo" llenaría la base de
  /// movimientos que dicen efectivo sin que nadie lo haya dicho, y eso es peor
  /// que no tener el dato — un filtro por medio de pago pasaría a mentir.
  String? _medioDePago;
  DateTime _fecha = DateTime.now();
  bool _guardando = false;
  String? _error;

  @override
  void dispose() {
    _monto.dispose();
    _detalle.dispose();
    super.dispose();
  }

  double? get _montoValido {
    final v = double.tryParse(_monto.text.replaceAll(',', ''));
    return v != null && v > 0 ? v : null;
  }

  Future<void> _guardar(List<Account> cuentas) async {
    final monto = _montoValido;
    final cuentaId = _cuentaId ?? (cuentas.isEmpty ? null : cuentas.first.id);

    // Se valida antes de llamar y se dice qué falta, en vez de dejar que el
    // backend responda un 400 que hay que traducir.
    if (monto == null) {
      setState(() => _error = 'Escribe un monto mayor que cero.');
      return;
    }
    if (cuentaId == null) {
      setState(() => _error = 'No tienes ninguna cuenta donde registrarlo.');
      return;
    }
    if (_modo == _Modo.transferencia && _cuentaDestinoId == null) {
      setState(() => _error = 'Elige a qué cuenta va la plata.');
      return;
    }
    if (_modo == _Modo.tarjeta && _tarjetaId == null) {
      setState(() => _error = 'Elige qué tarjeta vas a pagar.');
      return;
    }

    setState(() {
      _guardando = true;
      _error = null;
    });

    try {
      if (_modo == _Modo.tarjeta) {
        // Una transferencia, no un gasto: baja lo que debes y sale de la cuenta
        // elegida. Sin acotar el monto — pagar de más deja saldo a favor, que es
        // plata tuya y taparla haría dudar de dónde fue.
        await ref.read(apiProvider).post('/transactions/transfer', {
          'fromAccountId': cuentaId,
          'toAccountId': _tarjetaId,
          'amount': monto,
          'occurredAt': _instanteDe(_fecha).toIso8601String(),
          'detail': _detalle.text.trim().isNotEmpty ? _detalle.text.trim() : 'Pago de tarjeta',
        });
      } else if (_modo == _Modo.transferencia) {
        await ref.read(apiProvider).post('/transactions/transfer', {
          'fromAccountId': cuentaId,
          'toAccountId': _cuentaDestinoId,
          'amount': monto,
          'occurredAt': _instanteDe(_fecha).toIso8601String(),
          if (_detalle.text.trim().isNotEmpty) 'detail': _detalle.text.trim(),
        });
      } else {
        await ref.read(apiProvider).post('/transactions', {
          'accountId': cuentaId,
          'type': _modo == _Modo.gasto ? 'EXPENSE' : 'INCOME',
          'amount': monto,
          'occurredAt': _instanteDe(_fecha).toIso8601String(),
          if (_categoria != null) 'categoryId': _categoria!.id,
          if (_medioDePago != null) 'paymentMethod': _medioDePago,
          if (_detalle.text.trim().isNotEmpty) 'detail': _detalle.text.trim(),
        });
      }

      // Todo lo que muestra dinero se invalida: dejar una pantalla sin
      // refrescar es dejarla mintiendo.
      ref
        ..invalidate(cashPositionProvider)
        ..invalidate(recentTransactionsProvider)
        ..invalidate(periodTransactionsProvider)
        // Y las cuentas: un movimiento cambia el saldo de la suya, y sin esto el
        // selector del formulario —y el de pagar una cuota— seguían mostrando el
        // saldo de antes. Registrar en una cuenta y que la cuenta no se entere es
        // exactamente lo que hace desconfiar de la cifra.
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

  /// El instante de un día, a mediodía local.
  ///
  /// No a medianoche: un movimiento guardado a las 00:00 puede caer en el día
  /// anterior al leerlo en otra zona, que es el error de fechas corridas que ya
  /// arrastran algunos registros viejos. A mediodía no hay frontera que cruzar.
  DateTime _instanteDe(DateTime d) => DateTime(d.year, d.month, d.day, 12);

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final cuentas = ref.watch(accountsProvider).valueOrNull ?? const <Account>[];
    final categorias = ref.watch(categoriesProvider).valueOrNull ?? const <Category>[];
    final user = ref.watch(userProvider);
    // Elegir cuenta enseña una lista de saldos: es la misma plata que tapa el
    // ojito de la tarjeta, y dejarla a la vista acá deja el interruptor a
    // medias.
    final ocultos = ref.watch(saldosOcultosProvider);
    final cuenta =
        cuentas.where((c) => c.id == _cuentaId).firstOrNull ??
        (cuentas.isEmpty ? null : cuentas.first);
    final esTransferencia = _modo == _Modo.transferencia;
    final esPagoDeTarjeta = _modo == _Modo.tarjeta;
    // Las de uso diario: crédito sin deuda asociada. `/accounts` ya las trae y
    // deja fuera el espejo de un préstamo.
    final tarjetas = cuentas.where((c) => c.esDeCredito).toList()
      ..sort((a, b) => b.balance.compareTo(a.balance));
    final liquidas = cuentas.where((c) => !c.esDeCredito).toList();
    final tarjeta = tarjetas.where((c) => c.id == _tarjetaId).firstOrNull ?? tarjetas.firstOrNull;
    // El destino solo puede ser una cuenta de la misma moneda: convertir en
    // el momento de mover plata entre cuentas propias mezclaría dos
    // decisiones (mover y cambiar de moneda) en una sola acción.
    final destinosPosibles = cuentas
        .where(
          (c) => c.id != (cuenta?.id ?? cuentas.firstOrNull?.id) && c.currency == cuenta?.currency,
        )
        .toList();
    final cuentaDestino = destinosPosibles.where((c) => c.id == _cuentaDestinoId).firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        FieldSwitch<_Modo>(
          opciones: [
            ('Gasto', _Modo.gasto),
            ('Ingreso', _Modo.ingreso),
            if (liquidas.length > 1) ('Transferir', _Modo.transferencia),
            // Sin tarjeta o sin de dónde pagarla no aparece: un modo que solo
            // puede fallar no es un modo.
            if (tarjetas.isNotEmpty && liquidas.isNotEmpty) ('Pagar tarjeta', _Modo.tarjeta),
          ],
          valor: _modo,
          onChange: (v) => setState(() {
            _modo = v;
            // La categoría elegida no sobrevive al cambio de tipo: una de gasto
            // no existe para un ingreso, y una transferencia no lleva ninguna.
            _categoria = null;
          }),
        ),
        const SizedBox(height: Spacing.xl),

        FieldLabel(
          esPagoDeTarjeta
              ? 'Cuánto vas a pagar'
              : esTransferencia
              ? 'Monto a mover'
              : 'Monto',
        ),
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
                  autofocus: true,
                  placeholder: '0.00',
                  style: AppText.money(colors.foreground, size: 20, weight: FontWeight.w600),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  // Solo dígitos y un punto: un teclado numérico en iOS igual
                  // deja pegar texto, y "12,50" llegaría al backend como basura.
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.lg),

        const FieldLabel('Detalle'),
        FieldBox(
          child: AppTextField(controller: _detalle, placeholder: 'Ej. Almuerzo con equipo'),
        ),
        const SizedBox(height: Spacing.lg),

        if (!esTransferencia) ...[
          const FieldLabel('Categoría'),
          FieldSelector(
            texto: _categoria?.ruta ?? 'Sin categoría',
            onTap: () async {
              final elegida = await elegirCategoria(
                context,
                categorias
                    .where((c) => c.type == (_modo == _Modo.gasto ? 'EXPENSE' : 'INCOME'))
                    .toList(),
              );
              if (elegida != null) setState(() => _categoria = elegida);
            },
          ),
          const SizedBox(height: Spacing.lg),
        ],

        // En modo tarjeta el selector va siempre, aunque haya una sola cuenta
        // líquida: hay que decir de dónde sale la plata, y "Cuenta" en blanco es
        // exactamente lo que no se entiende al pagar.
        if (cuentas.length > 1 || esPagoDeTarjeta) ...[
          FieldLabel(
            esPagoDeTarjeta
                ? 'Con qué cuenta'
                : esTransferencia
                ? 'Desde'
                : 'Cuenta',
          ),
          FieldSelector(
            texto: cuenta?.nombreConAviso ?? 'Elige una',
            onTap: () async {
              final elegida = await showAppModal<Account>(
                context,
                title: 'Elige la cuenta',
                builder: (context) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Pagando una tarjeta, solo cuentas con dinero de verdad:
                    // pagar plástico con plástico no es una operación.
                    for (final c in esPagoDeTarjeta ? liquidas : cuentas)
                      FieldOption(
                        titulo: c.name,
                        detalle: tapar(Money.format(c.balance, c.currency), ocultos),
                        subtitulo: c.avisoDePatrimonio,
                        onTap: () => Navigator.of(context).pop(c),
                      ),
                  ],
                ),
              );
              if (elegida != null) {
                setState(() {
                  _cuentaId = elegida.id;
                  // Si el destino ya no es válido con la nueva moneda de
                  // origen, se limpia en vez de mandar una combinación que el
                  // backend va a rechazar.
                  if (_cuentaDestinoId == elegida.id) _cuentaDestinoId = null;
                });
              }
            },
          ),
          const SizedBox(height: Spacing.lg),
        ],

        // Qué tarjeta se paga, y cuánto llevas usado de ella.
        //
        // La barra contesta de un vistazo lo que dos cifras sueltas no: "debes
        // 1,200 de 5,000" obliga a dividir, y al decidir si pagas todo o una
        // parte lo que hace falta es cuánto te queda.
        if (esPagoDeTarjeta) ...[
          const FieldLabel('Qué tarjeta'),
          // Listadas y no en un selector que abre otra pantalla.
          //
          // Son dos o tres y cada una lleva la cifra que decide la elección —lo
          // que debes—. Un selector la esconde: hay que abrirlo para ver los
          // montos, elegir a ciegas o abrirlo dos veces. Listadas se comparan de
          // un vistazo y elegir es un toque.
          for (final t in tarjetas)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() {
                  _tarjetaId = t.id;
                  // El monto sigue a la tarjeta: dejar el de la anterior es el
                  // error más silencioso posible acá.
                  _monto.text = t.balance > 0 ? t.balance.toStringAsFixed(2) : '';
                }),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: Spacing.lg, vertical: Spacing.sm),
                  decoration: BoxDecoration(
                    color: t.id == tarjeta?.id ? colors.sage.withValues(alpha: 0.14) : null,
                    borderRadius: BorderRadius.circular(Radii.md),
                    border: Border.all(
                      color: t.id == tarjeta?.id
                          ? colors.sageDark.withValues(alpha: 0.45)
                          : colors.surfaceBorder,
                    ),
                  ),
                  child: Row(
                    children: [
                      Text('💳', style: AppText.small(colors.foreground)),
                      const SizedBox(width: Spacing.sm),
                      Expanded(
                        child: Text(
                          t.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.body(colors.foreground),
                        ),
                      ),
                      Text(
                        t.balance < 0
                            ? '${Money.format(-t.balance, t.currency)} a favor'
                            : 'debes ${Money.format(t.balance, t.currency)}',
                        style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.7)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (tarjeta != null)
            CupoDeTarjeta(
              debe: tarjeta.balance,
              cupo: tarjeta.creditLimit,
              currency: tarjeta.currency,
            ),
          const SizedBox(height: Spacing.lg),
        ],

        // Después de la cuenta y no antes, igual que en la web: primero de
        // dónde salió la plata, después cómo salió. Una transferencia no lo
        // lleva —mover plata entre cuentas propias no se paga con nada— y por
        // eso el campo no aparece en ese modo en vez de aparecer inerte.
        if (!esTransferencia) ...[
          const FieldLabel('Medio de pago'),
          FieldSelector(
            texto: MediosDePago.etiqueta(_medioDePago) ?? MediosDePago.sinEspecificar,
            onTap: () async {
              final elegido = await elegirMedioDePago(context, actual: _medioDePago);
              if (elegido != null) setState(() => _medioDePago = elegido.codigo);
            },
          ),
          const SizedBox(height: Spacing.lg),
        ],

        if (esTransferencia) ...[
          const FieldLabel('Hacia'),
          FieldSelector(
            texto:
                cuentaDestino?.name ??
                (destinosPosibles.isEmpty ? 'Sin cuenta compatible' : 'Elige una'),
            onTap: destinosPosibles.isEmpty
                ? () {}
                : () async {
                    final elegida = await showAppModal<Account>(
                      context,
                      title: 'Elige el destino',
                      builder: (context) => Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final c in destinosPosibles)
                            FieldOption(
                              titulo: c.name,
                              detalle: tapar(Money.format(c.balance, c.currency), ocultos),
                              subtitulo: c.avisoDePatrimonio,
                              onTap: () => Navigator.of(context).pop(c),
                            ),
                        ],
                      ),
                    );
                    if (elegida != null) setState(() => _cuentaDestinoId = elegida.id);
                  },
          ),
          if (destinosPosibles.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'No tienes otra cuenta en ${cuenta?.currency ?? "esta moneda"} para recibir la transferencia.',
                style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.6)),
              ),
            ),
          const SizedBox(height: Spacing.lg),
        ],

        const FieldLabel('Fecha'),
        FieldSelector(
          texto: _esHoy(_fecha) ? 'Hoy' : Fechas.diaConAnio(_fecha),
          icon: AppIconData.calendar,
          onTap: () async {
            final elegida = await pickDate(
              context,
              inicial: _fecha,
              ultima: DateTime.now(),
              titulo: 'Cuándo fue',
            );
            if (elegida != null) setState(() => _fecha = elegida);
          },
        ),

        if (_error != null) ...[
          const SizedBox(height: Spacing.md),
          Text(_error!, style: AppText.small(colors.danger)),
        ],

        const SizedBox(height: Spacing.xl),
        AppButton(
          label: esTransferencia
              ? 'Transferir'
              : _modo == _Modo.gasto
              ? 'Registrar gasto'
              : 'Registrar ingreso',
          busy: _guardando,
          onPressed: _montoValido == null || _guardando ? null : () => _guardar(cuentas),
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          _montoValido == null
              ? 'Escribe cuánto fue para poder guardarlo.'
              : esTransferencia
              ? 'Se mueve ${Money.format(_montoValido!, user.currency)} de ${cuenta?.name ?? "tu cuenta"} a ${cuentaDestino?.name ?? "el destino"}.'
              : _modo == _Modo.gasto
              ? 'Se descuenta ${Money.format(_montoValido!, user.currency)} de ${cuenta?.name ?? "tu cuenta"}.'
              : 'Se suma ${Money.format(_montoValido!, user.currency)} a ${cuenta?.name ?? "tu cuenta"}.',
          textAlign: TextAlign.center,
          style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.65)),
        ),
      ],
    );
  }
}

bool _esHoy(DateTime d) {
  final h = DateTime.now();
  return d.year == h.year && d.month == h.month && d.day == h.day;
}
