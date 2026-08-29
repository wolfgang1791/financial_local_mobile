import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/exchange.dart' as fx;
import '../data/models.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../state/providers.dart';
import '../ui/debt_history_chart.dart';
import '../ui/format.dart';
import '../ui/icons.dart';
import '../ui/refreshable_screen.dart';
import '../ui/surface.dart';
import 'debt_detail_screen.dart';
import 'debt_form.dart';
import 'shell.dart';
import 'tipo_de_cambio_modal.dart';

/// Deudas, ordenadas por lo que **cuestan**, no por lo que se deben.
///
/// Es la decisión central de la pantalla. Ordenar por saldo pone arriba el
/// préstamo grande y barato y esconde la tarjeta chica al 60%, que es la que se
/// está comiendo el dinero. La tasa decide, el saldo solo acompaña.
class DeudasScreen extends ConsumerStatefulWidget {
  const DeudasScreen({super.key});

  @override
  ConsumerState<DeudasScreen> createState() => _DeudasScreenState();
}

class _DeudasScreenState extends ConsumerState<DeudasScreen> {
  String? _monedaVista;

  /// Lo descontado con el ojito, por id. Sale del total y del aviso de arriba:
  /// una deuda tachada abajo que no mueve la cifra sería un ojo que no hace
  /// nada.
  final _ocultas = <String>{};

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final deudas = ref.watch(debtsProvider);
    final user = ref.watch(userProvider);
    final tasas = ref.watch(exchangeRatesProvider).valueOrNull ?? const <ExchangeRate>[];

    return RefreshableScreen(
      onRefresh: () async {
        ref
          ..invalidate(debtsProvider)
          ..invalidate(debtHistoryProvider)
          ..invalidate(exchangeRatesProvider);
      },
      children: [
        ScreenHeader(
          kicker: 'Gestión de dinero',
          title: 'Deudas',
          subtitle: 'Ordenadas por lo que te cuestan al año, no por lo que debes.',
          action: _BotonNueva(onCreada: () => ref.invalidate(debtsProvider)),
        ),
        const SizedBox(height: Spacing.lg),
        deudas.when(
          loading: () => const _Hueco(alto: 260),
          error: (_, __) => const _SinCargar(),
          data: (lista) {
            if (lista.isEmpty) {
              return const AppCard(
                dashed: true,
                child: Text('No tienes deudas registradas. Nada que priorizar.'),
              );
            }
            // Tres cajones, por tres razones distintas de no estar en la
            // lista viva: las que cuentan, las que llegaron a cero, y las que
            // apagaste a mano. Las canceladas se separan primero — una
            // cancelada con saldo cero no es un logro, es algo que diste por
            // terminado, y mezclarla con las pagadas contaría otra historia.
            final canceladas = lista.where((d) => !d.isActive).toList();
            final vivas = lista.where((d) => d.isActive).toList();
            final activas = vivas.where((d) => !d.saldada).toList()
              ..sort((a, b) => b.tasaReal.compareTo(a.tasaReal));
            final saldadas = vivas.where((d) => d.saldada).toList();

            final monedas = {user.currency, ...activas.map((d) => d.currency)}.toList()..sort();
            final vista = _monedaVista != null && monedas.contains(_monedaVista)
                ? _monedaVista!
                : user.currency;

            // Dos cifras y no una: lo que debes dice el tamaño del problema, y
            // lo que se va cada mes dice cuánto pesa **ahora**. Se pueden mover
            // en direcciones distintas —refinanciar baja la cuota y alarga el
            // saldo— y quien mira Deudas está preguntando por las dos.
            double total = 0;
            double cuotas = 0;
            var faltaCotizacion = false;
            for (final d in activas) {
              if (_ocultas.contains(d.id)) continue;
              if (d.currency == vista) {
                total += d.balance;
                cuotas += d.minimumPayment;
                continue;
              }
              // Al tipo **venta**: para pagarlas hay que comprar esa moneda, y
              // el de compra las subestima.
              final saldo = fx.convert(
                d.balance,
                d.currency,
                vista,
                tasas,
                purpose: fx.ConversionPurpose.debt,
              );
              final cuota = fx.convert(
                d.minimumPayment,
                d.currency,
                vista,
                tasas,
                purpose: fx.ConversionPurpose.debt,
              );
              if (saldo == null || cuota == null) {
                faltaCotizacion = true;
              } else {
                total += saldo.amount;
                cuotas += cuota.amount;
              }
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (monedas.length > 1) ...[
                  Row(
                    children: [
                      Text(
                        'Ver en: ',
                        style: AppText.small(colors.oliveInk.withValues(alpha: 0.6)),
                      ),
                      for (final m in monedas)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: _Pastilla(
                            texto: m,
                            activa: vista == m,
                            onTap: () => setState(() => _monedaVista = m),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: Spacing.sm),
                ],
                AppCard(
                  child: Row(
                    children: [
                      Expanded(
                        child: _Cifra(rotulo: 'Total en deudas', valor: Money.format(total, vista)),
                      ),
                      Expanded(
                        child: _Cifra(rotulo: 'Cuotas del mes', valor: Money.format(cuotas, vista)),
                      ),
                    ],
                  ),
                ),
                if (faltaCotizacion)
                  Padding(
                    padding: const EdgeInsets.only(top: Spacing.xs),
                    child: Text(
                      'Falta la cotización de alguna moneda; el total no las incluye.',
                      style: AppText.tiny(colors.chart[3]),
                    ),
                  ),
                // La cotización que se está usando, y un toque para corregirla.
                // Solo cuando hay más de una moneda: sin deudas en otra moneda
                // el tipo de cambio no convierte nada y sería ruido.
                if (monedas.length > 1)
                  Builder(
                    builder: (context) {
                      final otra = monedas.firstWhere((m) => m != vista, orElse: () => vista);
                      final fila = tasas
                          .where(
                            (t) =>
                                (t.baseCode == otra && t.quoteCode == vista) ||
                                (t.baseCode == vista && t.quoteCode == otra),
                          )
                          .firstOrNull;
                      return Padding(
                        padding: const EdgeInsets.only(top: Spacing.xs),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () async {
                            final cambiado = await abrirTipoDeCambio(
                              context,
                              base: fila?.baseCode ?? otra,
                              quote: fila?.quoteCode ?? vista,
                              vigente: fila,
                            );
                            if (cambiado && context.mounted) setState(() {});
                          },
                          child: Text(
                            fila == null
                                ? 'Sin tipo de cambio $otra → $vista · ponerlo'
                                : 'Tipo de cambio venta ${fila.sell.toStringAsFixed(3)} '
                                      '(${fila.date.length >= 10 ? fila.date.substring(0, 10) : fila.date})'
                                      ' · cambiar',
                            style: AppText.tiny(
                              colors.sageInk,
                            ).copyWith(decoration: TextDecoration.underline),
                          ),
                        ),
                      );
                    },
                  ),
                // Que el total no son todas tus deudas hay que decirlo: una
                // cifra descontada sin aviso es una cifra equivocada.
                if (_ocultas.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: Spacing.xs),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(_ocultas.clear),
                      child: Text(
                        'Sin ${_ocultas.length} ${_ocultas.length == 1 ? "deuda descontada" : "deudas descontadas"} · volver a contarlas',
                        style: AppText.tiny(
                          colors.sageInk,
                        ).copyWith(decoration: TextDecoration.underline),
                      ),
                    ),
                  ),
                const SizedBox(height: Spacing.lg),
                for (var i = 0; i < activas.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Spacing.md),
                    child: GestureDetector(
                      onTap: () => abrirDetalleDeuda(context, deuda: activas[i]),
                      child: _TarjetaDeuda(
                        deuda: activas[i],
                        laMasCara: i == 0,
                        oculta: _ocultas.contains(activas[i].id),
                        onAlternar: () => setState(() {
                          if (!_ocultas.remove(activas[i].id)) _ocultas.add(activas[i].id);
                        }),
                      ),
                    ),
                  ),
                if (canceladas.isNotEmpty) ...[
                  const SizedBox(height: Spacing.md),
                  Text('⏸ Deudas canceladas', style: AppText.sectionTitle(colors.foreground)),
                  const SizedBox(height: 4),
                  Text(
                    'No cuentan en tus totales ni en el plan. Ábrelas para reactivarlas.',
                    style: AppText.small(colors.oliveInk.withValues(alpha: 0.7)),
                  ),
                  const SizedBox(height: Spacing.sm),
                  for (final d in canceladas)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Spacing.sm),
                      child: GestureDetector(
                        onTap: () => abrirDetalleDeuda(context, deuda: d),
                        child: AppCard(
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(d.name, style: AppText.bodyMedium(colors.foreground)),
                              ),
                              Text(
                                Money.format(d.balance, d.currency),
                                style: AppText.money(
                                  colors.oliveInk.withValues(alpha: 0.7),
                                  size: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
                if (saldadas.isNotEmpty) ...[
                  const SizedBox(height: Spacing.md),
                  Text('✅ Deudas pagadas', style: AppText.sectionTitle(colors.foreground)),
                  const SizedBox(height: Spacing.sm),
                  for (final d in saldadas)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Spacing.sm),
                      child: GestureDetector(
                        onTap: () => abrirDetalleDeuda(context, deuda: d),
                        child: AppCard(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(d.name, style: AppText.bodyMedium(colors.foreground)),
                              ),
                              Text(
                                'Prestado ${Money.format(d.originalPrincipal, d.currency)}',
                                style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.7)),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: Spacing.lg),
        // La curva vive acá y ya no en Panorama.
        //
        // Es la misma cifra de arriba contada en el tiempo: "cuánto debo" y
        // "cómo viene bajando" son una sola pregunta, y tenerlas en dos
        // pantallas obligaba a saltar entre ellas para responderla. Panorama
        // queda para el mes; el arco de la deuda, para su sección.
        //
        // Contesta además lo que deja abierto "cuánto se fue en deudas": de esa
        // plata, cuánta bajó lo que debes y cuánta se la llevó el banco. Como la
        // curva de patrimonio, no la recorta ningún periodo.
        ref
            .watch(debtHistoryProvider)
            .maybeWhen(
              data: (series) {
                if (series.isEmpty) return const SizedBox.shrink();
                // Todas las monedas convertidas a la del usuario y sumadas, con
                // la misma cotización que usa el total de arriba: es lo que hace
                // que el saldo del último mes sea exactamente esa cifra. Antes
                // cada moneda iba por su lado y las dos no cuadraban nunca — no
                // por un error de cuentas, sino porque medían cosas distintas.
                final (serie, cotizacion) = unirEnUnaMoneda(series, user.currency, tasas);
                final hayDatos = serie.months.any((m) => m.paid > 0 || m.balance > 0);
                if (!hayDatos) return const SizedBox.shrink();
                return AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SectionHeader(title: 'Tu deuda mes a mes', trailing: null),
                      // El mismo aviso que da el total al convertir, y por lo
                      // mismo: la cifra depende de una cotización. Acá además se
                      // aplica a meses viejos con el cambio de hoy — se dice, no
                      // se esconde.
                      if (cotizacion != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Convertido al tipo de cambio ${cotizacion.side} de '
                            '${cotizacion.quote.toStringAsFixed(3)}, el mismo que usa el total '
                            'de arriba. Los meses anteriores también.',
                            style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.65)),
                          ),
                        ),
                      const SizedBox(height: Spacing.lg),
                      DebtHistoryChart(serie: serie),
                    ],
                  ),
                );
              },
              orElse: () => const SizedBox.shrink(),
            ),
      ],
    );
  }
}

class _BotonNueva extends StatelessWidget {
  const _BotonNueva({required this.onCreada});

  final VoidCallback onCreada;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        if (await abrirNuevaDeuda(context)) onCreada();
      },
      child: Container(
        width: 36,
        height: 36,
        // Sin margen: al lado del avatar de la cuenta, que no lo tiene, dos
        // puntos de diferencia se ven como un botón torcido.
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colors.sage.withValues(alpha: 0.16),
          shape: BoxShape.circle,
        ),
        child: AppIcon(AppIconData.plus, size: 16, color: colors.sageInk),
      ),
    );
  }
}

class _Pastilla extends StatelessWidget {
  const _Pastilla({required this.texto, required this.activa, required this.onTap});

  final String texto;
  final bool activa;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md, vertical: 6),
        decoration: BoxDecoration(
          color: activa ? colors.sageDark : null,
          borderRadius: BorderRadius.circular(Radii.pill),
          border: Border.all(color: activa ? colors.sageDark : colors.surfaceBorder),
        ),
        child: Text(
          texto,
          style: AppText.tiny(
            activa ? const Color(0xFFFFFFFF) : colors.foreground,
          ).copyWith(fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _TarjetaDeuda extends StatelessWidget {
  const _TarjetaDeuda({
    required this.deuda,
    required this.laMasCara,
    required this.oculta,
    required this.onAlternar,
  });

  final Debt deuda;
  final bool laMasCara;

  /// Descontada del total con el ojito. El estado vive en la pantalla, que es
  /// quien suma: la tarjeta solo lo muestra y lo alterna.
  final bool oculta;
  final VoidCallback onAlternar;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final d = deuda;
    final tieneTcea = d.costRateAnnual != null;

    return Opacity(
      opacity: oculta ? 0.45 : 1,
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: Text(d.name, style: AppText.sectionTitle(colors.foreground))),
                if (laMasCara)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: colors.chart[7].withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(Radii.pill),
                    ),
                    // "La más cara" y no un icono de alarma: nombra el hecho, no
                    // lo dramatiza. Es la que conviene atacar primero.
                    child: Text(
                      'LA MÁS CARA',
                      style: AppText.kicker(colors.chart[7]).copyWith(fontSize: 8.5),
                    ),
                  ),
                // En la cabecera y no junto al saldo: acá la fila es una tarjeta
                // entera, y el ojo pertenece a la deuda completa, no a una de sus
                // cifras. El toque no llega a la tarjeta —el gesto de adentro
                // gana— así que no abre el detalle.
                IconTapTarget(
                  semanticLabel: oculta
                      ? 'Volver a contar esta deuda'
                      : 'Descontar esta deuda del total',
                  onTap: onAlternar,
                  child: AppIcon(
                    oculta ? AppIconData.eyeOff : AppIconData.eye,
                    size: 16,
                    color: colors.oliveInk.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Spacing.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'SALDO',
                        style: AppText.kicker(
                          colors.oliveInk.withValues(alpha: 0.55),
                        ).copyWith(fontSize: 9),
                      ),
                      const SizedBox(height: 2),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          Money.format(d.balance, d.currency),
                          style: AppText.money(colors.foreground, size: 20, weight: FontWeight.w600)
                              .copyWith(
                                decoration: oculta
                                    ? TextDecoration.lineThrough
                                    : TextDecoration.none,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      tieneTcea ? 'TCEA' : 'TEA',
                      style: AppText.kicker(
                        colors.oliveInk.withValues(alpha: 0.55),
                      ).copyWith(fontSize: 9),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${(d.tasaReal * 100).toStringAsFixed(2)}%',
                      style: AppText.money(colors.chart[7], size: 20, weight: FontWeight.w600),
                    ),
                  ],
                ),
              ],
            ),
            // La TCEA es la que manda cuando existe: ya incluye seguros y portes,
            // y priorizar por la TEA hace que una deuda cara con muchos cargos
            // parezca barata.
            if (tieneTcea)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'La TCEA incluye seguros y portes. La TEA sola es ${(d.interestRateAnnual * 100).toStringAsFixed(2)}%.',
                  style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.6)),
                ),
              ),
            const SizedBox(height: Spacing.md),
            _Barra(avance: d.avance, colors: colors),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${(d.avance * 100).toStringAsFixed(0)}% amortizado',
                  style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.7)),
                ),
                Text(
                  'de ${Money.format(d.originalPrincipal, d.currency)}',
                  style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.55)),
                ),
              ],
            ),
            const SizedBox(height: Spacing.md),
            Row(
              children: [
                Expanded(
                  child: _Dato(
                    rotulo: 'CUOTA',
                    valor: Money.format(d.minimumPayment, d.currency),
                    colors: colors,
                  ),
                ),
                Expanded(
                  child: _Dato(
                    rotulo: 'PLAZO',
                    valor: d.termMonths == null ? 'Sin plazo' : '${d.termMonths} meses',
                    colors: colors,
                  ),
                ),
                Expanded(
                  child: _Dato(
                    rotulo: 'ESTE MES',
                    valor: d.pagadaEsteMes
                        ? 'Pagada'
                        : d.pagoParcial
                        ? 'Parcial'
                        : 'Pendiente',
                    colors: colors,
                    acento: d.pagadaEsteMes ? colors.sageInk : null,
                  ),
                ),
              ],
            ),
            // Cuánto falta, sin tener que abrir la deuda. Es lo que convierte
            // la lista en algo que se lee de un vistazo: el saldo dice cuánto
            // debes y esto dice cuánto te queda por delante, que casi nunca es
            // lo mismo.
            if (d.projection != null && !d.saldada)
              Padding(
                padding: const EdgeInsets.only(top: Spacing.sm),
                child: d.projection!.monthsLeft == null
                    ? Text(
                        'La cuota no cubre el interés: el saldo sube.',
                        style: AppText.tiny(colors.danger),
                      )
                    : d.projection!.monthsLeft! > 0
                    ? Text(
                        'Faltan ${d.projection!.monthsLeft} '
                        '${d.projection!.monthsLeft == 1 ? "mes" : "meses"} · '
                        '${d.projection!.principalShare}% de lo que pagas baja la deuda',
                        style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.6)),
                      )
                    : const SizedBox.shrink(),
              ),
            if (d.missedMonths.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Spacing.sm),
                child: Row(
                  children: [
                    AppIcon(AppIconData.warning, size: 13, color: colors.chart[3]),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        '${d.missedMonths.length} ${d.missedMonths.length == 1 ? "mes" : "meses"} sin registrar pago',
                        style: AppText.tiny(colors.chart[3]),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Barra extends StatelessWidget {
  const _Barra({required this.avance, required this.colors});

  final double avance;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.pill),
      child: Container(
        height: 6,
        color: colors.foreground.withValues(alpha: 0.08),
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: avance.clamp(0.0, 1.0),
            child: Container(color: colors.sage),
          ),
        ),
      ),
    );
  }
}

class _Dato extends StatelessWidget {
  const _Dato({required this.rotulo, required this.valor, required this.colors, this.acento});

  final String rotulo;
  final String valor;
  final AppColors colors;
  final Color? acento;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          rotulo,
          style: AppText.kicker(colors.oliveInk.withValues(alpha: 0.5)).copyWith(fontSize: 8.5),
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(valor, style: AppText.money(acento ?? colors.foreground, size: 12.5)),
        ),
      ],
    );
  }
}

class _Hueco extends StatelessWidget {
  const _Hueco({required this.alto});

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

class _SinCargar extends StatelessWidget {
  const _SinCargar();

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return AppCard(
      dashed: true,
      child: Text(
        'No pude cargar tus deudas. Arrastra hacia abajo para reintentar.',
        style: AppText.small(colors.oliveInk.withValues(alpha: 0.8)),
      ),
    );
  }
}

/// Una de las dos cifras del resumen: su rótulo arriba y el número abajo.
class _Cifra extends StatelessWidget {
  const _Cifra({required this.rotulo, required this.valor});

  final String rotulo;
  final String valor;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(rotulo, style: AppText.small(colors.oliveInk.withValues(alpha: 0.75))),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            valor,
            style: AppText.money(colors.foreground, size: 18, weight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
