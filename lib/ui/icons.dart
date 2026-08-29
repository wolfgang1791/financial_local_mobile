import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Los iconos de la interfaz, dibujados acá.
///
/// **No se usa `Icons.*` de Material.** Ese set es el lenguaje visual de
/// Android: en un iPhone, una equis de Material al lado de la barra del sistema
/// se lee como una app portada a medias. Y al revés con los de Cupertino en
/// Android. Dibujarlos es la única forma de que el producto se vea igual en los
/// dos, que es justo lo que pide tener un sistema de diseño propio.
///
/// Son trazos, no rellenos, con el mismo grosor relativo que los SVG de la web
/// (1.75 sobre una caja de 24), así que un ícono de la app y uno del navegador
/// se ven hermanos.
///
/// Los iconos de **categoría** siguen siendo emoji, igual que en la web: los
/// pinta el sistema, ya son parte del lenguaje del producto, y dibujar noventa
/// rubros a mano sería reinventar una fuente que ya existe.
enum AppIconData {
  close,
  chevronLeft,
  chevronRight,
  chevronDown,
  eye,
  eyeOff,
  arrowDown,
  arrowUp,
  plus,
  check,
  warning,
  compass,
  chart,
  wallet,
  card,
  target,
  edit,
  trash,
  swap,
  calendar,
  filter,
  download,
  calculator,
  moon,
  sun,
}

class AppIcon extends StatelessWidget {
  const AppIcon(this.icon, {super.key, this.size = 20, required this.color, this.semanticLabel});

  final AppIconData icon;
  final double size;
  final Color color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final pintura = CustomPaint(
      size: Size.square(size),
      painter: _IconPainter(icon: icon, color: color),
    );
    if (semanticLabel == null) {
      return ExcludeSemantics(
        child: SizedBox.square(dimension: size, child: pintura),
      );
    }
    return Semantics(
      label: semanticLabel,
      child: SizedBox.square(dimension: size, child: pintura),
    );
  }
}

class _IconPainter extends CustomPainter {
  _IconPainter({required this.icon, required this.color});

  final AppIconData icon;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Todo se dibuja sobre una caja de 24 y se escala: así el grosor del trazo
    // crece con el ícono en vez de engordar en los chicos y desaparecer en los
    // grandes.
    final k = size.width / 24.0;
    canvas.scale(k);

    final trazo = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.75
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    void linea(double x1, double y1, double x2, double y2) =>
        canvas.drawLine(Offset(x1, y1), Offset(x2, y2), trazo);

    void ruta(void Function(Path p) construir) {
      final p = Path();
      construir(p);
      canvas.drawPath(p, trazo);
    }

    switch (icon) {
      case AppIconData.close:
        linea(6, 6, 18, 18);
        linea(18, 6, 6, 18);

      case AppIconData.chevronLeft:
        ruta(
          (p) => p
            ..moveTo(15, 5)
            ..lineTo(8.5, 12)
            ..lineTo(15, 19),
        );

      case AppIconData.chevronRight:
        ruta(
          (p) => p
            ..moveTo(9, 5)
            ..lineTo(15.5, 12)
            ..lineTo(9, 19),
        );

      case AppIconData.chevronDown:
        ruta(
          (p) => p
            ..moveTo(5, 9)
            ..lineTo(12, 15.5)
            ..lineTo(19, 9),
        );

      // La luna, de un solo trazo: un círculo mordido por otro. Dibujarla como
      // un arco cerrado y no como dos círculos superpuestos es lo que permite
      // que sea un trazo del mismo grosor que el resto del juego.
      case AppIconData.moon:
        ruta(
          (p) => p
            ..moveTo(20, 14.5)
            ..cubicTo(18.8, 15.2, 17.4, 15.6, 16, 15.6)
            ..cubicTo(11.6, 15.6, 8, 12, 8, 7.6)
            ..cubicTo(8, 6.2, 8.4, 4.8, 9.1, 3.6)
            ..cubicTo(5.5, 4.8, 3, 8.2, 3, 12.2)
            ..cubicTo(3, 17.2, 7.1, 21.3, 12.1, 21.3)
            ..cubicTo(16.1, 21.3, 19.5, 18.7, 20, 14.5)
            ..close(),
        );

      case AppIconData.sun:
        canvas.drawCircle(const Offset(12, 12), 4.4, trazo);
        for (var i = 0; i < 8; i++) {
          final angulo = i * 3.14159265 / 4;
          final dx = math.cos(angulo);
          final dy = math.sin(angulo);
          canvas.drawLine(
            Offset(12 + dx * 7.2, 12 + dy * 7.2),
            Offset(12 + dx * 9.4, 12 + dy * 9.4),
            trazo,
          );
        }

      case AppIconData.eye:
        ruta(
          (p) => p
            ..moveTo(3, 12)
            ..cubicTo(6, 7, 9, 6, 12, 6)
            ..cubicTo(15, 6, 18, 7, 21, 12)
            ..cubicTo(18, 17, 15, 18, 12, 18)
            ..cubicTo(9, 18, 6, 17, 3, 12)
            ..close(),
        );
        canvas.drawCircle(const Offset(12, 12), 2.6, trazo);

      case AppIconData.eyeOff:
        ruta(
          (p) => p
            ..moveTo(3, 12)
            ..cubicTo(6, 7, 9, 6, 12, 6)
            ..cubicTo(15, 6, 18, 7, 21, 12)
            ..cubicTo(18, 17, 15, 18, 12, 18)
            ..cubicTo(9, 18, 6, 17, 3, 12)
            ..close(),
        );
        canvas.drawCircle(const Offset(12, 12), 2.6, trazo);
        // La barra que lo tacha, con un hueco a cada lado para que se lea por
        // encima del ojo y no se confunda con su contorno.
        final hueco = Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5
          ..strokeCap = StrokeCap.round
          ..blendMode = BlendMode.clear;
        canvas.saveLayer(const Rect.fromLTWH(0, 0, 24, 24), Paint());
        canvas.drawLine(const Offset(4, 4), const Offset(20, 20), hueco);
        canvas.restore();
        linea(4, 4, 20, 20);

      case AppIconData.arrowDown:
        linea(12, 5, 12, 19);
        ruta(
          (p) => p
            ..moveTo(6.5, 13)
            ..lineTo(12, 19)
            ..lineTo(17.5, 13),
        );

      case AppIconData.arrowUp:
        linea(12, 19, 12, 5);
        ruta(
          (p) => p
            ..moveTo(6.5, 11)
            ..lineTo(12, 5)
            ..lineTo(17.5, 11),
        );

      case AppIconData.plus:
        linea(12, 5, 12, 19);
        linea(5, 12, 19, 12);

      case AppIconData.check:
        ruta(
          (p) => p
            ..moveTo(5, 12.5)
            ..lineTo(10, 17.5)
            ..lineTo(19, 6.5),
        );

      case AppIconData.warning:
        ruta(
          (p) => p
            ..moveTo(12, 4)
            ..lineTo(21, 19.5)
            ..lineTo(3, 19.5)
            ..close(),
        );
        linea(12, 10, 12, 14);
        canvas.drawCircle(const Offset(12, 17), 0.5, trazo..strokeWidth = 1.75);

      case AppIconData.compass:
        canvas.drawCircle(const Offset(12, 12), 8.5, trazo);
        ruta(
          (p) => p
            ..moveTo(15.5, 8.5)
            ..lineTo(13.5, 13.5)
            ..lineTo(8.5, 15.5)
            ..lineTo(10.5, 10.5)
            ..close(),
        );

      case AppIconData.chart:
        linea(4, 20, 20, 20);
        linea(7.5, 20, 7.5, 12);
        linea(12, 20, 12, 6);
        linea(16.5, 20, 16.5, 15);

      case AppIconData.wallet:
        ruta(
          (p) => p
            ..addRRect(
              RRect.fromRectAndRadius(
                const Rect.fromLTWH(3.5, 6.5, 17, 12),
                const Radius.circular(3),
              ),
            ),
        );
        linea(3.5, 11, 20.5, 11);
        canvas.drawCircle(const Offset(16.5, 14.75), 1.1, trazo);

      case AppIconData.card:
        ruta(
          (p) => p
            ..addRRect(
              RRect.fromRectAndRadius(
                const Rect.fromLTWH(3, 5.5, 18, 13),
                const Radius.circular(3),
              ),
            ),
        );
        linea(3, 10, 21, 10);
        linea(6.5, 14.5, 11, 14.5);

      case AppIconData.target:
        for (final r in [8.5, 5.0, 1.6]) {
          canvas.drawCircle(const Offset(12, 12), r, trazo);
        }

      case AppIconData.edit:
        ruta(
          (p) => p
            ..moveTo(4, 20)
            ..lineTo(4.8, 16.2)
            ..lineTo(15.5, 5.5)
            ..lineTo(18.5, 8.5)
            ..lineTo(7.8, 19.2)
            ..close(),
        );
        linea(4.8, 16.2, 7.8, 19.2);

      case AppIconData.trash:
        linea(5, 7, 19, 7);
        ruta(
          (p) => p
            ..moveTo(9, 7)
            ..lineTo(9, 4.5)
            ..lineTo(15, 4.5)
            ..lineTo(15, 7),
        );
        ruta(
          (p) => p
            ..moveTo(6.5, 7)
            ..lineTo(7.3, 20)
            ..lineTo(16.7, 20)
            ..lineTo(17.5, 7),
        );
        linea(10.3, 10, 10.7, 17);
        linea(13.7, 10, 13.3, 17);

      case AppIconData.swap:
        linea(4, 8, 20, 8);
        ruta(
          (p) => p
            ..moveTo(16, 4)
            ..lineTo(20, 8)
            ..lineTo(16, 12),
        );
        linea(20, 16, 4, 16);
        ruta(
          (p) => p
            ..moveTo(8, 12)
            ..lineTo(4, 16)
            ..lineTo(8, 20),
        );

      case AppIconData.calendar:
        ruta(
          (p) => p
            ..addRRect(
              RRect.fromRectAndRadius(
                const Rect.fromLTWH(3.5, 5, 17, 15),
                const Radius.circular(3),
              ),
            ),
        );
        linea(3.5, 9.5, 20.5, 9.5);
        linea(8, 3.5, 8, 6.5);
        linea(16, 3.5, 16, 6.5);

      case AppIconData.filter:
        linea(5, 7, 19, 7);
        linea(5, 12, 19, 12);
        linea(5, 17, 19, 17);
        final nudo = Paint()
          ..color = color
          ..style = PaintingStyle.fill;
        canvas.drawCircle(const Offset(9, 7), 2.1, nudo);
        canvas.drawCircle(const Offset(15, 12), 2.1, nudo);
        canvas.drawCircle(const Offset(10, 17), 2.1, nudo);

      case AppIconData.download:
        linea(12, 4, 12, 15);
        ruta(
          (p) => p
            ..moveTo(7, 10.5)
            ..lineTo(12, 15.5)
            ..lineTo(17, 10.5),
        );
        linea(5, 19, 19, 19);

      case AppIconData.calculator:
        ruta(
          (p) => p
            ..addRRect(
              RRect.fromRectAndRadius(
                const Rect.fromLTWH(5, 3, 14, 18),
                const Radius.circular(2.5),
              ),
            ),
        );
        ruta(
          (p) => p
            ..addRRect(
              RRect.fromRectAndRadius(const Rect.fromLTWH(7, 5.3, 10, 4), const Radius.circular(1)),
            ),
        );
        final punto = Paint()
          ..color = color
          ..style = PaintingStyle.fill;
        for (final fila in [13.2, 16.3, 19.4]) {
          for (final col in [8.5, 12.0, 15.5]) {
            canvas.drawCircle(Offset(col, fila), 1.0, punto);
          }
        }
    }
  }

  @override
  bool shouldRepaint(_IconPainter old) => old.icon != icon || old.color != color;
}

/// Una flecha que gira. Sirve para el acordeón: el mismo ícono señalando en dos
/// direcciones dice "esto se abre y se cierra" mejor que dos iconos distintos.
class RotatingChevron extends StatelessWidget {
  const RotatingChevron({super.key, required this.expanded, required this.color, this.size = 18});

  final bool expanded;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return AnimatedRotation(
      turns: expanded ? -0.5 : 0,
      duration: const Duration(milliseconds: 180),
      child: AppIcon(AppIconData.chevronDown, size: size, color: color),
    );
  }
}

/// Un arco de progreso, para las metas. Se usa en varias pantallas, así que vive
/// acá y no dentro de una.
class ProgressRing extends StatelessWidget {
  const ProgressRing({
    super.key,
    required this.progress,
    required this.color,
    required this.track,
    this.size = 44,
    this.thickness = 4,
  });

  final double progress;
  final Color color;
  final Color track;
  final double size;
  final double thickness;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _RingPainter(
          progress: progress.clamp(0, 1),
          color: color,
          track: track,
          thickness: thickness,
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.color,
    required this.track,
    required this.thickness,
  });

  final double progress;
  final Color color;
  final Color track;
  final double thickness;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final centro = rect.center;
    final radio = (size.shortestSide - thickness) / 2;

    final base = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness;
    canvas.drawCircle(centro, radio, base);

    if (progress <= 0) return;
    final arco = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: centro, radius: radio),
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      arco,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.color != color || old.track != track;
}

/// Un objetivo táctil de 44 puntos alrededor de un ícono chico.
///
/// El ícono se ve de 20; el área que responde al dedo es de 44, que es el
/// mínimo de las guías de Apple y de Material. Sin esto, cerrar un modal en un
/// teléfono es un ejercicio de puntería.
class IconTapTarget extends StatelessWidget {
  const IconTapTarget({
    super.key,
    required this.child,
    required this.onTap,
    required this.semanticLabel,
  });

  final Widget child;
  final VoidCallback onTap;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(width: 44, height: 44, child: Center(child: child)),
      ),
    );
  }
}
