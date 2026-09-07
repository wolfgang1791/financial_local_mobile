import 'package:flutter/widgets.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import 'surface.dart';

/// Todas las cuentas están fuera del patrimonio.
///
/// No es "no hay datos": es un filtro puesto, y hasta ahora las dos pantallas
/// que se apagan con él decían "sin registros todavía" con todo guardado. Pasó
/// de verdad y no había forma de entenderlo desde la app — el patrimonio en
/// cero, el historial vacío y ninguna explicación.
///
/// Dice dónde se arregla, no solo qué pasa: el interruptor vive en la tarjeta de
/// patrimonio, y un mensaje que nombra un problema sin decir dónde está el
/// remedio obliga a buscarlo.
class TodoOculto extends StatelessWidget {
  const TodoOculto({super.key, required this.cuantas});

  final int cuantas;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return AppCard(
      dashed: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text('🙈', style: AppText.title(colors.foreground)),
          const SizedBox(height: Spacing.md),
          Text(
            cuantas == 1 ? 'Tu cuenta está oculta' : 'Tus $cuantas cuentas están ocultas',
            textAlign: TextAlign.center,
            style: AppText.sectionTitle(colors.foreground),
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            'Una cuenta oculta queda fuera del patrimonio y sus movimientos no se listan. '
            'Con todas fuera no queda nada que mostrar — pero no se borró nada: en '
            'Movimientos, toca el chip de cada cuenta para volver a contarla.',
            textAlign: TextAlign.center,
            style: AppText.small(colors.oliveInk.withValues(alpha: 0.7)),
          ),
        ],
      ),
    );
  }
}
