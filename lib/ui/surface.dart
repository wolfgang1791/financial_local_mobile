import 'package:flutter/widgets.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import 'icons.dart';

/// El fondo de la app: beige con tres halos de color arriba.
///
/// Son los mismos tres `radial-gradient` de la web, en el mismo orden y con las
/// mismas posiciones relativas. Se pintan en vez de usar una imagen porque el
/// tamaño de un teléfono varía y una imagen se estiraría; y porque cambian con
/// el tema, que una imagen no hace.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(color: colors.background),
      child: CustomPaint(painter: _GlowPainter(colors.glow), child: child),
    );
  }
}

class _GlowPainter extends CustomPainter {
  const _GlowPainter(this.glow);

  final List<Color> glow;

  @override
  void paint(Canvas canvas, Size size) {
    // Las posiciones vienen de la web, expresadas en fracciones del ancho para
    // que el halo caiga donde debe tanto en 390 como en 1024 puntos.
    final capas = [
      (Alignment(-0.4, -1.15), 1.55, glow[0]),
      (Alignment(-0.76, -1.1), 1.25, glow[1]),
      (Alignment(1.0, -1.0), 1.05, glow[2]),
    ];
    for (final (alineacion, escala, color) in capas) {
      final centro = alineacion.alongSize(size);
      final radio = size.width * escala;
      canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = RadialGradient(
            colors: [color, color.withValues(alpha: 0)],
            stops: const [0, 1],
          ).createShader(Rect.fromCircle(center: centro, radius: radio)),
      );
    }
  }

  @override
  bool shouldRepaint(_GlowPainter old) => old.glow != glow;
}

/// Una tarjeta. El contenedor de todo lo que no es texto suelto.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Spacing.xl),
    this.dashed = false,
    this.discreta = false,
  });

  final Widget child;
  final EdgeInsets padding;

  /// Borde punteado: se usa para lo que todavía no existe o está vacío, para que
  /// se distinga de una tarjeta con contenido real sin necesidad de leerla.
  final bool dashed;

  /// La caja que se aparta: mismo radio y mismo aire, sin relleno ni sombra.
  ///
  /// Para lo secundario y para la vista larga — lo que está ahí si lo buscas, no
  /// lo que viniste a ver. Existe porque una pantalla donde todas las tarjetas
  /// pesan igual no tiene jerarquía: media docena de superficies elevadas
  /// idénticas gritan a la vez y no dicen por dónde empezar.
  final bool discreta;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: dashed || discreta ? null : colors.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(
          color: dashed || discreta
              ? colors.surfaceBorder.withValues(alpha: 0.5)
              : colors.surfaceBorder,
        ),
        boxShadow: dashed || discreta
            ? null
            : [
                BoxShadow(
                  color: colors.sageDark.withValues(alpha: 0.06),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
      ),
      child: child,
    );
  }
}

/// El encabezado de una sección: kicker + título.
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, this.kicker, required this.title, this.trailing});

  final String? kicker;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (kicker != null) ...[
                Text(
                  kicker!.toUpperCase(),
                  style: AppText.kicker(colors.sageInk.withValues(alpha: 0.8)),
                ),
                const SizedBox(height: 3),
              ],
              Text(title, style: AppText.sectionTitle(colors.foreground)),
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

/// El rótulo que parte una pantalla larga en tramos: dos palabras y una línea.
///
/// Media docena de tarjetas seguidas se leen como media docena de temas; con dos
/// rótulos se leen como tres tramos y se puede saltar el que no interesa. Es
/// navegación, no explicación — ahorra leer una tarjeta entera para descubrir
/// que no era la que buscabas.
class BandLabel extends StatelessWidget {
  const BandLabel(this.texto, {super.key});

  final String texto;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(texto.toUpperCase(), style: AppText.kicker(colors.sageInk.withValues(alpha: 0.8))),
        const SizedBox(width: Spacing.md),
        Expanded(child: Container(height: 1, color: colors.surfaceBorder.withValues(alpha: 0.6))),
      ],
    );
  }
}

/// La barra de avance: un canal y lo recorrido, de izquierda a derecha.
///
/// Existe como widget y no suelta en cada pantalla por cómo se rompe: la forma
/// obvia —un `Stack` con el canal al fondo y un `FractionallySizedBox` encima—
/// se dibuja vacía: donde el alto llega flojo, un `ColoredBox` sin hijo toma el
/// mínimo —cero— y la barra parece no avanzar nunca. Y aun con alto,
/// `FractionallySizedBox` centra por defecto, así que el relleno flotaría en el
/// medio en vez de crecer desde la izquierda. Las dos trampas se resuelven acá
/// una sola vez, con un test que las fija.
class BarraAvance extends StatelessWidget {
  const BarraAvance({
    super.key,
    required this.avance,
    required this.color,
    required this.canal,
    this.alto = 8,
  });

  /// De 0 a 1. Se acota, para que un dato raro no dibuje una barra más larga
  /// que su canal.
  final double avance;
  final Color color;
  final Color canal;
  final double alto;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      // El recorte va afuera: así el relleno se corta contra el mismo radio y
      // su punta izquierda no queda cuadrada dentro de un canal redondo.
      borderRadius: BorderRadius.circular(Radii.pill),
      child: SizedBox(
        height: alto,
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: canal)),
            Positioned.fill(
              child: FractionallySizedBox(
                // `heightFactor: 1` no es decorativo: sin él, el alto que le
                // llega al relleno es flojo y un `ColoredBox` sin hijo toma el
                // mínimo, que es cero. Es la misma trampa que deja la barra
                // vacía, una capa más adentro.
                heightFactor: 1,
                widthFactor: avance.clamp(0.0, 1.0),
                alignment: Alignment.centerLeft,
                child: ColoredBox(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Una línea divisoria de un punto lógico.
///
/// Propia porque `Divider` es de Material: trae altura, indentación y un color
/// del tema que acá no existe, y termina metiendo huecos que nadie pidió.
class HairLine extends StatelessWidget {
  const HairLine({super.key, required this.color, this.height = 1});

  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) => Container(height: height, color: color);
}

/// El ojito de la tarjeta: tapa y destapa **todas** sus cifras.
///
/// Va sobre la placa y no en un menú porque es un gesto de un segundo —alguien
/// se asomó— y esconderlo detrás de dos toques lo volvería inútil.
class OjoDeLaTarjeta extends StatelessWidget {
  const OjoDeLaTarjeta({super.key, required this.ocultos, required this.onTap});

  final bool ocultos;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconTapTarget(
      semanticLabel: ocultos ? 'Mostrar los montos' : 'Tapar los montos',
      onTap: onTap,
      child: AppIcon(
        ocultos ? AppIconData.eyeOff : AppIconData.eye,
        size: 18,
        color: const Color(0xCCFFFFFF),
      ),
    );
  }
}
