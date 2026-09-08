import 'package:flutter/widgets.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import 'format.dart';

/// Cuánto de tu cupo llevas usado.
///
/// La barra contesta de un vistazo lo que dos cifras sueltas no: "debes 1,200 de
/// 5,000" obliga a dividir; una barra al 24% se lee sin leer. Y el número que de
/// verdad hace falta al decidir una compra no es lo que debes sino **lo que te
/// queda**, así que ese va primero.
///
/// Sin cupo declarado no se dibuja: una barra sin final no dice nada, y fingir
/// uno sería inventarse el dato más importante.
class CupoDeTarjeta extends StatelessWidget {
  const CupoDeTarjeta({
    super.key,
    required this.debe,
    required this.cupo,
    required this.currency,
    this.compacta = false,
  });

  final double debe;
  final double? cupo;
  final String currency;

  /// En una fila estrecha —el chip de la tarjeta— solo la barra y una línea.
  final bool compacta;

  @override
  Widget build(BuildContext context) {
    final limite = cupo;
    if (limite == null || limite <= 0) return const SizedBox.shrink();

    final colors = AppTheme.of(context);
    // Pagar de más deja saldo **a favor**: la tarjeta queda en negativo y el cupo
    // disponible es mayor que el cupo. No se acota ni se esconde — es plata tuya,
    // y taparla haría dudar de dónde fue.
    final aFavor = debe < 0;
    final usado = (debe / limite).clamp(0.0, 1.0);
    final queda = limite - debe;
    // Tres tramos, y el color es un refuerzo: la cifra de "te queda" ya lo dice.
    // Rojo pasado el 90% porque ahí una compra normal puede rebotar.
    final tono = usado >= 0.9
        ? colors.danger
        : usado >= 0.7
        ? colors.chartAt(7)
        : colors.sageDark;

    return Padding(
      padding: EdgeInsets.only(top: compacta ? 4 : Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.pill),
            child: LayoutBuilder(
              builder: (context, c) => Stack(
                children: [
                  Container(height: 6, color: colors.foreground.withValues(alpha: 0.12)),
                  Container(height: 6, width: c.maxWidth * usado, color: tono),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            aFavor
                ? 'Tienes ${Money.format(-debe, currency)} a favor · te quedan '
                      '${Money.format(queda, currency)} para gastar'
                : 'Te quedan ${Money.format(queda, currency)} de ${Money.format(limite, currency)} '
                      '· ${(usado * 100).round()}% usado',
            style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.65)),
          ),
        ],
      ),
    );
  }
}
