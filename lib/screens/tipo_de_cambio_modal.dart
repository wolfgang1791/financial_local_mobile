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
import '../ui/modal.dart';

/// Poner el tipo de cambio a mano.
///
/// No reemplaza al que había: se guarda como una fila más, con la fecha de hoy,
/// y la búsqueda de siempre —la cotización más reciente que no sea posterior al
/// movimiento— hace que la tuya mande de hoy en adelante y que lo anterior siga
/// convirtiéndose con la que le tocaba. Eso es lo que deja al cargado como
/// respaldo sin marcarlo como tal en ningún sitio, y lo que hace que quitar el
/// tuyo devuelva al anterior sin tener que volver a escribirlo.
Future<bool> abrirTipoDeCambio(
  BuildContext context, {
  required String base,
  required String quote,
  ExchangeRate? vigente,
}) async {
  final cambiado = await showAppModal<bool>(
    context,
    title: 'Tipo de cambio',
    subtitle: '$base → $quote',
    builder: (context) => _Formulario(base: base, quote: quote, vigente: vigente),
  );
  return cambiado ?? false;
}

class _Formulario extends ConsumerStatefulWidget {
  const _Formulario({required this.base, required this.quote, this.vigente});

  final String base;
  final String quote;
  final ExchangeRate? vigente;

  @override
  ConsumerState<_Formulario> createState() => _FormularioState();
}

class _FormularioState extends ConsumerState<_Formulario> {
  late final _compra = TextEditingController(text: widget.vigente?.buy.toStringAsFixed(3));
  late final _venta = TextEditingController(text: widget.vigente?.sell.toStringAsFixed(3));
  bool _guardando = false;
  String? _error;

  @override
  void dispose() {
    _compra.dispose();
    _venta.dispose();
    super.dispose();
  }

  double? _valor(TextEditingController c) {
    final v = double.tryParse(c.text.replaceAll(',', ''));
    return v != null && v > 0 ? v : null;
  }

  /// El día de hoy en el calendario del usuario. `DateTime.now()` sirve porque
  /// el teléfono ya está en su zona; el servidor lo recalcula igual si no llega.
  String get _hoy {
    final d = DateTime.now();
    String dd(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${dd(d.month)}-${dd(d.day)}';
  }

  bool get _esMio =>
      widget.vigente?.source == 'manual' &&
      widget.vigente!.date.length >= 10 &&
      widget.vigente!.date.substring(0, 10) == _hoy;

  Future<void> _correr(Future<void> Function() accion) async {
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      await accion();
      ref.invalidate(exchangeRatesProvider);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'No llegué al servidor. Inténtalo otra vez.');
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  Future<void> _guardar() {
    final compra = _valor(_compra);
    final venta = _valor(_venta);
    if (compra == null || venta == null) {
      setState(() => _error = 'Compra y venta tienen que ser mayores que 0.');
      return Future.value();
    }
    return _correr(
      () async => ref.read(apiProvider).put('/currencies/rates', {
        'baseCode': widget.base,
        'quoteCode': widget.quote,
        'buy': compra,
        'sell': venta,
        'date': _hoy,
      }),
    );
  }

  Future<void> _quitar() => _correr(
    () async => ref
        .read(apiProvider)
        .delete('/currencies/rates?base=${widget.base}&quote=${widget.quote}&date=$_hoy'),
  );

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);

    Widget campo(String rotulo, TextEditingController control) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldLabel(rotulo),
        FieldBox(
          child: Row(
            children: [
              Text(
                widget.quote == 'USD' ? r'$' : 'S/',
                style: AppText.money(colors.oliveInk.withValues(alpha: 0.6)),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: AppTextField(
                  controller: control,
                  placeholder: '0.000',
                  style: AppText.money(colors.foreground, size: 20, weight: FontWeight.w600),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                ),
              ),
            ],
          ),
        ),
      ],
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: campo('Compra', _compra)),
            const SizedBox(width: Spacing.md),
            Expanded(child: campo('Venta', _venta)),
          ],
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          'Se guarda con la fecha de hoy y manda de hoy en adelante. Lo anterior no se '
          'toca: un pago que registres con fecha vieja se sigue convirtiendo con la '
          'cotización que le tocaba. La venta es la que usa una deuda, porque pagarla '
          'te obliga a comprar esa moneda.',
          style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.6)),
        ),
        if (_error != null) ...[
          const SizedBox(height: Spacing.sm),
          Text(_error!, style: AppText.small(colors.danger)),
        ],
        const SizedBox(height: Spacing.lg),
        AppButton(
          label: _guardando ? 'Guardando...' : 'Guardar',
          onPressed: _guardando ? null : _guardar,
        ),
        if (_esMio) ...[
          const SizedBox(height: Spacing.sm),
          AppButton(
            label: 'Quitar el mío y volver al anterior',
            variant: AppButtonVariant.secondary,
            onPressed: _guardando ? null : _quitar,
          ),
        ],
      ],
    );
  }
}
