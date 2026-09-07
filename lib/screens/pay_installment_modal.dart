import 'package:flutter/services.dart' show FilteringTextInputFormatter, TextInputType;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api.dart';
import '../data/exchange.dart' as fx;
import '../data/models.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../state/providers.dart';
import '../ui/buttons.dart';
import '../ui/fields.dart';
import '../ui/format.dart';
import '../ui/modal.dart';

/// Pagar una cuota (o abonar lo que sea) de una deuda.
Future<bool> abrirPagoCuota(BuildContext context, {required Debt deuda}) async {
  final pagado = await showAppModal<bool>(
    context,
    title: 'Pagar cuota',
    subtitle: deuda.name,
    builder: (context) => _FormularioPago(deuda: deuda),
  );
  return pagado ?? false;
}

class _FormularioPago extends ConsumerStatefulWidget {
  const _FormularioPago({required this.deuda});

  final Debt deuda;

  @override
  ConsumerState<_FormularioPago> createState() => _FormularioPagoState();
}

class _FormularioPagoState extends ConsumerState<_FormularioPago> {
  final _monto = TextEditingController();
  String? _cuentaId;
  bool _guardando = false;
  String? _error;

  @override
  void dispose() {
    _monto.dispose();
    super.dispose();
  }

  double? get _montoValido {
    final v = double.tryParse(_monto.text.replaceAll(',', ''));
    return v != null && v > 0 ? v : null;
  }

  void _fijar(double v) => setState(() => _monto.text = v.toStringAsFixed(2));

  Future<void> _pagar() async {
    final monto = _montoValido;
    if (monto == null) {
      setState(() => _error = 'Escribe cuánto vas a pagar.');
      return;
    }
    if (_cuentaId == null) {
      setState(() => _error = 'Elige de qué cuenta sale la plata.');
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      await ref.read(apiProvider).post('/debts/${widget.deuda.id}/pay', {
        'accountId': _cuentaId,
        'amount': monto,
      });
      ref
        ..invalidate(debtsProvider)
        ..invalidate(cashPositionProvider)
        ..invalidate(recentTransactionsProvider);
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
    final d = widget.deuda;
    final cuentas = ref.watch(accountsProvider).valueOrNull ?? const <Account>[];
    final tasas = ref.watch(exchangeRatesProvider).valueOrNull ?? const <ExchangeRate>[];
    _cuentaId ??=
        cuentas.where((c) => c.currency == d.currency).firstOrNull?.id ?? cuentas.firstOrNull?.id;
    final cuenta = cuentas.where((c) => c.id == _cuentaId).firstOrNull;

    final quedaDeCuota = (d.installmentAmount - d.paidAmountThisMonth)
        .clamp(0, double.infinity)
        .toDouble();
    final conversion = cuenta != null && cuenta.currency != d.currency
        ? fx.convert(
            _montoValido ?? 0,
            d.currency,
            cuenta.currency,
            tasas,
            purpose: fx.ConversionPurpose.debt,
          )
        : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _Dato(
                rotulo: 'CUOTA',
                valor: Money.format(d.installmentAmount, d.currency),
                colors: colors,
              ),
            ),
            Expanded(
              child: _Dato(
                rotulo: 'PAGADO ESTE MES',
                valor: Money.format(d.paidAmountThisMonth, d.currency),
                colors: colors,
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.lg),
        const FieldLabel('Monto a pagar'),
        FieldBox(
          child: Row(
            children: [
              Text(
                d.currency == 'USD' ? r'$' : 'S/',
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
        const SizedBox(height: Spacing.sm),
        Wrap(
          spacing: Spacing.sm,
          runSpacing: Spacing.sm,
          children: [
            if (quedaDeCuota > 0)
              _BotonMonto(
                texto: d.paidAmountThisMonth > 0 ? 'Lo que falta' : 'Cuota completa',
                onTap: () => _fijar(quedaDeCuota),
              ),
            if (d.installmentAmount > 0)
              _BotonMonto(texto: 'Media cuota', onTap: () => _fijar(d.installmentAmount / 2)),
            if (d.balance > 0) _BotonMonto(texto: 'Saldar todo', onTap: () => _fijar(d.balance)),
          ],
        ),
        const SizedBox(height: Spacing.lg),
        const FieldLabel('Cuenta'),
        FieldSelector(
          texto: cuenta == null ? 'Elige una' : '${cuenta.name} (${cuenta.currency})',
          onTap: () async {
            final elegida = await showAppModal<Account>(
              context,
              title: 'Elige la cuenta',
              builder: (context) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final c in cuentas)
                    FieldOption(
                      titulo: c.name,
                      subtitulo: c.avisoDePatrimonio,
                      detalle: Money.format(c.balance, c.currency),
                      onTap: () => Navigator.of(context).pop(c),
                    ),
                ],
              ),
            );
            if (elegida != null) setState(() => _cuentaId = elegida.id);
          },
        ),
        if (conversion != null) ...[
          const SizedBox(height: Spacing.sm),
          Text(
            'Se cobran ${Money.format(conversion.amount, cuenta!.currency)} de tu cuenta '
            '(tipo de cambio ${conversion.side}: ${conversion.quote.toStringAsFixed(3)}).',
            style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.65)),
          ),
        ],
        if (_montoValido != null && _montoValido! > quedaDeCuota && quedaDeCuota >= 0) ...[
          const SizedBox(height: Spacing.sm),
          Text(
            'Pagas más que la cuota: el excedente va directo a bajar el capital.',
            style: AppText.tiny(colors.sageInk),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: Spacing.md),
          Text(_error!, style: AppText.small(colors.danger)),
        ],
        const SizedBox(height: Spacing.xl),
        AppButton(
          label: 'Pagar',
          busy: _guardando,
          onPressed: _montoValido == null || _guardando ? null : _pagar,
        ),
      ],
    );
  }
}

class _BotonMonto extends StatelessWidget {
  const _BotonMonto({required this.texto, required this.onTap});

  final String texto;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md, vertical: 7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.pill),
          border: Border.all(color: colors.surfaceBorder),
        ),
        child: Text(
          texto,
          style: AppText.tiny(colors.foreground).copyWith(fontWeight: FontWeight.w500),
        ),
      ),
    );
  }
}

class _Dato extends StatelessWidget {
  const _Dato({required this.rotulo, required this.valor, required this.colors});

  final String rotulo;
  final String valor;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          rotulo,
          style: AppText.kicker(colors.oliveInk.withValues(alpha: 0.5)).copyWith(fontSize: 9),
        ),
        const SizedBox(height: 2),
        Text(valor, style: AppText.money(colors.foreground, size: 15, weight: FontWeight.w600)),
      ],
    );
  }
}
