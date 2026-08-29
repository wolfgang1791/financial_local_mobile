import 'package:flutter/widgets.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import 'surface.dart';

/// Una sección que todavía no existe, dicha como lo que es.
///
/// Vivía copiada dentro de `simulador_screen.dart`; ahora son tres pantallas las
/// que la necesitan —Decisiones, Objetivos y Simulador— y tres copias de un
/// cartel es garantizar que un día digan cosas distintas.
///
/// Ocupa la pantalla entera: es la página completa, no un hueco dentro de otra.
/// Un Panorama sin movimientos no usa esto — ese hueco se llena registrando
/// datos, no esperando una versión.
class Proximamente extends StatelessWidget {
  const Proximamente({
    super.key,
    required this.icono,
    required this.titulo,
    required this.descripcion,
  });

  final String icono;
  final String titulo;
  final String descripcion;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xxl),
        child: AppCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.sage.withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                ),
                child: Text(icono, style: AppText.title(colors.foreground)),
              ),
              const SizedBox(height: Spacing.lg),
              Text(
                'PRÓXIMAMENTE',
                textAlign: TextAlign.center,
                style: AppText.kicker(colors.sageInk.withValues(alpha: 0.8)),
              ),
              const SizedBox(height: 4),
              Text(titulo, textAlign: TextAlign.center, style: AppText.title(colors.foreground)),
              const SizedBox(height: Spacing.sm),
              Text(
                descripcion,
                textAlign: TextAlign.center,
                style: AppText.small(colors.oliveInk.withValues(alpha: 0.7)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
