import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import 'breakpoints.dart';
import 'format.dart';
import 'icons.dart';

class DonutSegment {
  const DonutSegment({
    required this.id,
    required this.label,
    required this.value,
    this.fullValue,
    this.isOther = false,
    this.colorIndex,
    this.abre = false,
  });

  final String id;
  final String label;

  /// Lo que aporta al total después de los ojitos: es lo que se dibuja.
  final double value;

  /// Lo que aportaba antes de descontar. Solo se usa cuando difiere.
  final double? fullValue;
  final bool isOther;

  /// Fija el color de la paleta en vez de tomar el que toque por posición.
  /// Sirve cuando el color significa algo —"disponible" en verde— y no puede
  /// depender de qué otras porciones tengan monto y en qué orden queden: sin
  /// esto, la misma categoría cambia de color según qué más haya ese mes.
  final int? colorIndex;

  /// Si esta porción abre la lista de lo que la compone, en vez de solo
  /// señalarse. La fila lleva una flechita y el toque —en la fila o en la
  /// porción del anillo— llama a `onAbrir`. Sin esto todo sigue igual: no toda
  /// porción tiene una lista detrás ("Disponible" es un saldo, no un conjunto
  /// de movimientos).
  final bool abre;
}

/// El anillo de gastos por categoría.
///
/// Pintado con `CustomPainter` y sin librería de gráficos. No es por evitar una
/// dependencia: es que las librerías traen su propio tooltip flotante, su propia
/// leyenda y sus propias animaciones, y ninguna de las tres coincide con este
/// producto. Acá el centro del anillo **es** el tooltip —siempre en el mismo
/// sitio, grande y legible— y la leyenda es una tabla de montos, que es como se
/// lee un gasto por rubro.
///
/// **Responsive de verdad, no escalado.** En un teléfono el anillo va arriba y la
/// tabla debajo, porque en 390 puntos no caben lado a lado sin que los nombres
/// se corten. A partir de una tablet van en fila, que es como se ve en la web.
/// El diámetro se calcula del ancho disponible, no de una constante.
class DonutChart extends StatefulWidget {
  const DonutChart({
    super.key,
    required this.segments,
    required this.total,
    required this.centerLabel,
    required this.currency,
    this.hidden = const {},
    this.onToggleHide,
    this.onTapSegment,
    this.onAbrir,
  });

  final List<DonutSegment> segments;

  /// El total del centro. Llega calculado: el gráfico no suma nada, porque el
  /// total que se muestra tiene que ser el mismo que calculó quien lo llamó.
  final double total;
  final String centerLabel;
  final String currency;
  final Set<String> hidden;
  final void Function(String id)? onToggleHide;
  final void Function(String id)? onTapSegment;

  /// Abrir la lista de lo que compone una porción. Se llama solo por las que
  /// están marcadas con `abre`, y tocar la porción del anillo hace lo mismo que
  /// tocar su fila: si hicieran cosas distintas, el gráfico y su tabla
  /// parecerían dos controles.
  final void Function(String id)? onAbrir;

  @override
  State<DonutChart> createState() => _DonutChartState();
}

class _DonutChartState extends State<DonutChart> {
  /// La porción señalada. Un toque la fija, otro la suelta: en un teléfono no
  /// hay hover, así que el toque tiene que hacer las dos cosas.
  int? _activo;

  /// Qué hace un toque sobre la porción [i]. Devuelve true si abrió su lista,
  /// para que quien llame no siga con lo suyo.
  bool _tocar(int i) {
    final segmento = widget.segments[i];
    if (segmento.abre && widget.onAbrir != null) {
      widget.onAbrir!(segmento.id);
      return true;
    }
    setState(() => _activo = _activo == i ? null : i);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final enFila = !Breakpoints.isCompact(constraints.maxWidth);
        // El anillo ocupa el menor entre la mitad del ancho (en fila) o el ancho
        // completo (apilado), con un techo para que en una tablet no se coma la
        // pantalla y un piso para que siga siendo tocable en un teléfono chico.
        final disponible = enFila ? constraints.maxWidth * 0.42 : constraints.maxWidth;
        final diametro = disponible.clamp(180.0, 260.0);

        final anillo = _Ring(
          diametro: diametro,
          segments: widget.segments,
          hidden: widget.hidden,
          total: widget.total,
          activo: _activo,
          colors: colors,
          currency: widget.currency,
          centerLabel: widget.centerLabel,
          onPick: _tocar,
        );

        final tabla = _Legend(
          segments: widget.segments,
          hidden: widget.hidden,
          total: widget.total,
          activo: _activo,
          colors: colors,
          currency: widget.currency,
          onTapRow: (i) {
            if (_tocar(i)) return;
            widget.onTapSegment?.call(widget.segments[i].id);
          },
          onToggleHide: widget.onToggleHide,
        );

        if (enFila) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              anillo,
              const SizedBox(width: Spacing.xl),
              Expanded(child: tabla),
            ],
          );
        }
        return Column(
          children: [
            anillo,
            const SizedBox(height: Spacing.lg),
            tabla,
          ],
        );
      },
    );
  }
}

class _Ring extends StatelessWidget {
  const _Ring({
    required this.diametro,
    required this.segments,
    required this.hidden,
    required this.total,
    required this.activo,
    required this.colors,
    required this.currency,
    required this.centerLabel,
    required this.onPick,
  });

  final double diametro;
  final List<DonutSegment> segments;
  final Set<String> hidden;
  final double total;
  final int? activo;
  final AppColors colors;
  final String currency;
  final String centerLabel;
  final void Function(int index) onPick;

  @override
  Widget build(BuildContext context) {
    final visible = <int>[];
    for (var i = 0; i < segments.length; i++) {
      if (!hidden.contains(segments[i].id) && segments[i].value > 0) visible.add(i);
    }

    final destacado = activo != null ? segments[activo!] : null;
    final montoCentro = destacado?.value ?? total;
    final rotulo = destacado?.label ?? centerLabel;

    return SizedBox.square(
      dimension: diametro,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // El toque se resuelve por ángulo, no por widget: las porciones no son
          // rectángulos, y un `GestureDetector` por porción respondería en su
          // caja envolvente — que en un anillo se solapa con las vecinas.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              final centro = Offset(diametro / 2, diametro / 2);
              final v = d.localPosition - centro;
              final r = v.distance;
              final grosor = diametro * 0.17;
              if (r < diametro / 2 - grosor || r > diametro / 2) return;

              var angulo = math.atan2(v.dy, v.dx) + math.pi / 2;
              if (angulo < 0) angulo += 2 * math.pi;

              final suma = visible.fold<double>(0, (s, i) => s + segments[i].value);
              if (suma <= 0) return;
              var acumulado = 0.0;
              for (final i in visible) {
                final barrido = segments[i].value / suma * 2 * math.pi;
                if (angulo >= acumulado && angulo < acumulado + barrido) {
                  onPick(i);
                  return;
                }
                acumulado += barrido;
              }
            },
            child: CustomPaint(
              size: Size.square(diametro),
              painter: _DonutPainter(
                segments: segments,
                visible: visible,
                activo: activo,
                colors: colors,
                surface: colors.surface,
              ),
            ),
          ),
          // La cifra del centro. `IgnorePointer` para que no se coma el toque
          // del anillo que tiene detrás.
          IgnorePointer(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: diametro * 0.2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    rotulo.toUpperCase(),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.kicker(
                      colors.oliveInk.withValues(alpha: 0.7),
                    ).copyWith(fontSize: 9.5),
                  ),
                  const SizedBox(height: 6),
                  FittedBox(
                    child: Text(
                      Money.format(montoCentro, currency),
                      style: AppText.money(
                        colors.foreground,
                        size: diametro * 0.13,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    destacado != null && total > 0
                        ? '${(destacado.value / total * 100).toStringAsFixed(1)}%'
                        : '${visible.length} categorías',
                    style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.6)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter({
    required this.segments,
    required this.visible,
    required this.activo,
    required this.colors,
    required this.surface,
  });

  final List<DonutSegment> segments;
  final List<int> visible;
  final int? activo;
  final AppColors colors;
  final Color surface;

  @override
  void paint(Canvas canvas, Size size) {
    final suma = visible.fold<double>(0, (s, i) => s + segments[i].value);
    final centro = size.center(Offset.zero);
    final grosor = size.width * 0.17;
    final radio = (size.width - grosor) / 2;

    if (suma <= 0) {
      canvas.drawCircle(
        centro,
        radio,
        Paint()
          ..color = colors.foreground.withValues(alpha: 0.08)
          ..style = PaintingStyle.stroke
          ..strokeWidth = grosor,
      );
      return;
    }

    // Un hueco fijo entre porciones, del ancho de dos puntos convertidos a
    // ángulo. En radianes constantes, una porción chica desaparecería tragada
    // por su propio separador.
    final hueco = radio > 0 ? 3.0 / radio : 0.0;
    var cursor = -math.pi / 2;

    for (final i in visible) {
      final barrido = segments[i].value / suma * 2 * math.pi;
      final esActiva = activo == i;
      final apagada = activo != null && !esActiva;

      final color = segments[i].isOther
          ? colors.chartOther
          : colors.chartAt(segments[i].colorIndex ?? i);
      final pincel = Paint()
        ..color = apagada ? color.withValues(alpha: 0.28) : color
        ..style = PaintingStyle.stroke
        ..strokeWidth = esActiva ? grosor * 1.16 : grosor
        ..strokeCap = StrokeCap.butt;

      canvas.drawArc(
        Rect.fromCircle(center: centro, radius: radio),
        cursor + hueco / 2,
        math.max(barrido - hueco, 0.004),
        false,
        pincel,
      );
      cursor += barrido;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) =>
      old.activo != activo || old.visible.length != visible.length || old.segments != segments;
}

class _Legend extends StatelessWidget {
  const _Legend({
    required this.segments,
    required this.hidden,
    required this.total,
    required this.activo,
    required this.colors,
    required this.currency,
    required this.onTapRow,
    required this.onToggleHide,
  });

  final List<DonutSegment> segments;
  final Set<String> hidden;
  final double total;
  final int? activo;
  final AppColors colors;
  final String currency;
  final void Function(int index) onTapRow;
  final void Function(String id)? onToggleHide;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: Spacing.sm, left: Spacing.xs),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'CATEGORÍA',
                  style: AppText.kicker(
                    colors.oliveInk.withValues(alpha: 0.5),
                  ).copyWith(fontSize: 9.5),
                ),
              ),
              Text(
                'MONTO',
                style: AppText.kicker(
                  colors.oliveInk.withValues(alpha: 0.5),
                ).copyWith(fontSize: 9.5),
              ),
              const SizedBox(width: 52),
            ],
          ),
        ),
        for (var i = 0; i < segments.length; i++)
          _LegendRow(
            segment: segments[i],
            color: segments[i].isOther
                ? colors.chartOther
                : colors.chartAt(segments[i].colorIndex ?? i),
            oculto: hidden.contains(segments[i].id),
            activo: activo == i,
            atenuado: activo != null && activo != i,
            total: total,
            colors: colors,
            currency: currency,
            onTap: () => onTapRow(i),
            onToggleHide: onToggleHide == null ? null : () => onToggleHide!(segments[i].id),
          ),
      ],
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.segment,
    required this.color,
    required this.oculto,
    required this.activo,
    required this.atenuado,
    required this.total,
    required this.colors,
    required this.currency,
    required this.onTap,
    required this.onToggleHide,
  });

  final DonutSegment segment;
  final Color color;
  final bool oculto;
  final bool activo;
  final bool atenuado;
  final double total;
  final AppColors colors;
  final String currency;
  final VoidCallback onTap;
  final VoidCallback? onToggleHide;

  @override
  Widget build(BuildContext context) {
    final aMedias = !oculto && segment.fullValue != null && segment.fullValue != segment.value;
    final porcentaje = oculto || total <= 0
        ? '—'
        : '${(segment.value / total * 100).toStringAsFixed(1)}%';

    final tachado = oculto ? TextDecoration.lineThrough : TextDecoration.none;

    return Opacity(
      opacity: oculto ? 0.45 : (atenuado ? 0.42 : 1),
      child: Container(
        decoration: BoxDecoration(
          color: activo ? colors.sage.withValues(alpha: 0.08) : null,
          border: Border(bottom: BorderSide(color: colors.foreground.withValues(alpha: 0.06))),
        ),
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: oculto ? null : onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 11, horizontal: Spacing.xs),
                  child: Row(
                    children: [
                      Container(
                        width: 3,
                        height: 22,
                        decoration: BoxDecoration(
                          // Transparente y no ausente: si el chip desapareciera,
                          // la fila se correría tres puntos al ocultarla y la
                          // columna dejaría de alinear.
                          color: oculto ? const Color(0x00000000) : color,
                          borderRadius: BorderRadius.circular(Radii.pill),
                        ),
                      ),
                      const SizedBox(width: Spacing.md),
                      Expanded(
                        child: Text(
                          segment.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.body(colors.foreground).copyWith(decoration: tachado),
                        ),
                      ),
                      const SizedBox(width: Spacing.sm),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            Money.format(
                              oculto ? (segment.fullValue ?? segment.value) : segment.value,
                              currency,
                            ),
                            style: AppText.money(
                              colors.foreground,
                              size: 13.5,
                            ).copyWith(decoration: tachado),
                          ),
                          if (aMedias)
                            Text(
                              'de ${Money.format(segment.fullValue!, currency)}',
                              style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.5)),
                            ),
                        ],
                      ),
                      SizedBox(
                        width: 52,
                        child: Text(
                          porcentaje,
                          textAlign: TextAlign.right,
                          style: AppText.money(
                            colors.sageInk,
                            size: 11.5,
                            weight: FontWeight.w600,
                          ).copyWith(),
                        ),
                      ),
                      // La flechita solo donde hay a dónde ir: es lo único que
                      // distingue a simple vista una fila que abre su lista de
                      // una que solo señala su porción.
                      if (segment.abre && !oculto)
                        Padding(
                          padding: const EdgeInsets.only(left: 2),
                          child: AppIcon(
                            AppIconData.chevronRight,
                            size: 13,
                            color: colors.oliveInk.withValues(alpha: 0.4),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (onToggleHide != null)
              IconTapTarget(
                semanticLabel: oculto
                    ? 'Volver a contar ${segment.label}'
                    : 'Quitar ${segment.label} de la cuenta',
                onTap: onToggleHide!,
                child: AppIcon(
                  oculto ? AppIconData.eyeOff : AppIconData.eye,
                  size: 17,
                  color: colors.foreground.withValues(alpha: 0.35),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
