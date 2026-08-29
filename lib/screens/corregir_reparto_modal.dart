import 'package:flutter/services.dart' show FilteringTextInputFormatter, TextInputType;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../state/providers.dart';
import '../ui/buttons.dart';
import '../ui/fields.dart';
import '../ui/format.dart';
import '../ui/modal.dart';

/// Corregir en qué se fue un pago ya registrado.
///
/// La app estima el reparto al pagar; tu estado de cuenta lo dice exacto. Esto
/// es la puerta entre las dos cosas.
///
/// Se editan el interés, el seguro y los portes — **el capital no**: se calcula
/// solo con lo que sobra, porque las cuatro partes tienen que sumar siempre lo
/// que pagaste. Pedirlo por separado abriría la puerta a guardar un pago cuyas
/// partes no cuadran, que es un dato que no significa nada.
///
/// Lo que pagaste tampoco se toca acá: eso es un movimiento del historial, con
/// su fecha y su cuenta, y se corrige allá.
Future<bool> abrirCorregirReparto(
  BuildContext context, {
  required String deudaId,
  required Map<String, dynamic> pago,
  required String moneda,
}) async {
  final cambiado = await showAppModal<bool>(
    context,
    title: 'Corregir el reparto',
    subtitle: 'Pagaste ${Money.format((pago['paid'] as num).toDouble(), moneda)}',
    builder: (context) => _Formulario(deudaId: deudaId, pago: pago, moneda: moneda),
  );
  return cambiado ?? false;
}

class _Formulario extends ConsumerStatefulWidget {
  const _Formulario({required this.deudaId, required this.pago, required this.moneda});

  final String deudaId;
  final Map<String, dynamic> pago;
  final String moneda;

  @override
  ConsumerState<_Formulario> createState() => _FormularioState();
}

class _FormularioState extends ConsumerState<_Formulario> {
  late final _interes = _campo('interest');
  late final _seguro = _campo('insurance');
  late final _portes = _campo('fees');
  bool _guardando = false;
  String? _error;

  TextEditingController _campo(String clave) => TextEditingController(
    text: ((widget.pago[clave] as num?)?.toDouble() ?? 0).toStringAsFixed(2),
  );

  @override
  void dispose() {
    _interes.dispose();
    _seguro.dispose();
    _portes.dispose();
    super.dispose();
  }

  double _valor(TextEditingController c) => double.tryParse(c.text.replaceAll(',', '')) ?? 0;

  double get _pagado => (widget.pago['paid'] as num).toDouble();
  double get _capital =>
      ((_pagado - _valor(_interes) - _valor(_seguro) - _valor(_portes)) * 100).round() / 100;
  bool get _sePasa => _capital < -0.005;

  /// Cuánto se mueve el saldo de la deuda al guardar. Es la consecuencia real de
  /// esta corrección y hay que decirla antes, no después.
  double get _delta =>
      (((widget.pago['principal'] as num).toDouble() - _capital) * 100).round() / 100;

  Future<void> _guardar() async {
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      await ref.read(apiProvider).patch('/debts/${widget.deudaId}/payments/${widget.pago['id']}', {
        'interest': _valor(_interes),
        'insurance': _valor(_seguro),
        'fees': _valor(_portes),
      });
      ref.invalidate(debtsProvider);
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

    Widget campo(String rotulo, TextEditingController control) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FieldLabel(rotulo),
          FieldBox(
            child: AppTextField(
              controller: control,
              placeholder: '0.00',
              style: AppText.money(colors.foreground, size: 16, weight: FontWeight.w600),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              onChanged: (_) => setState(() {}),
            ),
          ),
        ],
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Escribe lo que diga tu estado de cuenta y el capital se calcula solo.',
          style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.65)),
        ),
        const SizedBox(height: Spacing.md),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            campo('Interés', _interes),
            const SizedBox(width: Spacing.sm),
            campo('Seguro', _seguro),
            const SizedBox(width: Spacing.sm),
            campo('Portes', _portes),
          ],
        ),
        const SizedBox(height: Spacing.md),
        Row(
          children: [
            Text('A CAPITAL', style: AppText.kicker(colors.sageInk.withValues(alpha: 0.8))),
            const Spacer(),
            Text(
              Money.format(_capital < 0 ? 0 : _capital, widget.moneda),
              style: AppText.money(
                _sePasa ? colors.danger : colors.sageInk,
                size: 18,
                weight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.sm),
        if (_sePasa)
          Text(
            'Las partes suman más de lo que pagaste. Baja alguna.',
            style: AppText.small(colors.danger),
          )
        else if (_delta != 0)
          Text(
            'Al guardar, la deuda ${_delta > 0 ? "sube" : "baja"} '
            '${Money.format(_delta.abs(), widget.moneda)}: es capital que se había '
            'acreditado ${_delta > 0 ? "de más" : "de menos"}.',
            style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.65)),
          ),
        if (_error != null) ...[
          const SizedBox(height: Spacing.sm),
          Text(_error!, style: AppText.small(colors.danger)),
        ],
        const SizedBox(height: Spacing.lg),
        AppButton(
          label: _guardando ? 'Guardando...' : 'Guardar el reparto',
          onPressed: (_guardando || _sePasa) ? null : _guardar,
        ),
      ],
    );
  }
}
