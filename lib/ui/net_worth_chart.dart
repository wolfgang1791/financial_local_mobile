import 'package:flutter/widgets.dart';

import '../data/models.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import 'format.dart';

/// La curva de patrimonio.
///
/// Es un área con su línea, no barras: la pregunta es "¿cómo vengo?", que es una
/// tendencia, y unas barras invitarían a comparar meses sueltos entre sí — otra
/// pregunta, que ya responde el informe mensual.
///
/// **Toca y arrastra para leer un punto.** En un teléfono no hay hover, así que
/// el gesto de arrastre reemplaza al cursor: el valor sale arriba, en el mismo
/// sitio siempre, no en un globo que persigue al dedo y queda tapado por él.
class NetWorthChart extends StatefulWidget {
  const NetWorthChart({
    super.key,
    required this.points,
    required this.currency,
    this.diasRestantes = 0,
    this.subirEsMalo = false,
    this.mostrarMontos = false,
  });

  final List<NetWorthPoint> points;
  final String currency;

  /// Pinta cada tramo de verde cuando baja y de rojo cuando sube.
  ///
  /// Solo tiene sentido donde menos es mejor —el gasto—; en el patrimonio es al
  /// revés, y por eso no se activa solo. Va acompañado siempre de los montos y
  /// de una flecha fuera del gráfico: rojo y verde son el par que más se
  /// confunde con daltonismo, y una línea que solo se distingue por el tono no
  /// dice nada a quien no lo ve.
  final bool subirEsMalo;

  /// El monto encima de cada punto. La pregunta "¿cuánto fue ese mes?" no
  /// debería costar un toque, y menos en un teléfono.
  final bool mostrarMontos;

  /// Cuántos días le faltan al mes en curso.
  ///
  /// Se reserva ese ancho a la derecha, vacío: la curva llega hasta hoy —no hay
  /// saldo futuro que dibujar— pero cortada al borde el gráfico no dice si el
  /// mes va por la mitad o por el final. El hueco *es* lo que falta, y se lee
  /// sin leer ninguna cifra. En cero, el gráfico se dibuja como siempre.
  final int diasRestantes;

  @override
  State<NetWorthChart> createState() => _NetWorthChartState();
}

class _NetWorthChartState extends State<NetWorthChart> {
  int? _tocado;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final puntos = widget.points;

    if (puntos.length < 2) {
      return Text(
        'Todavía no hay suficiente historia para dibujar tu evolución.',
        style: AppText.small(colors.oliveInk.withValues(alpha: 0.75)),
      );
    }

    final indice = _tocado ?? puntos.length - 1;
    final actual = puntos[indice];
    // El cambio contra el punto anterior, que es lo que la cifra necesita al
    // lado para significar algo.
    final delta = indice > 0 ? actual.liquid - puntos[indice - 1].liquid : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _rotulo(actual.etiqueta).toUpperCase() + (actual.enCurso ? ' · EN CURSO' : ''),
          style: AppText.kicker(colors.oliveInk.withValues(alpha: 0.55)).copyWith(fontSize: 9.5),
        ),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  Money.format(actual.liquid, widget.currency),
                  style: AppText.money(colors.foreground, size: 24, weight: FontWeight.w600),
                ),
              ),
            ),
            if (indice > 0) ...[
              const SizedBox(width: Spacing.sm),
              Text(
                Money.signed(delta, widget.currency),
                style: AppText.money(
                  delta >= 0 ? colors.sageInk : colors.danger,
                  size: 12.5,
                  weight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: Spacing.md),
        // 150 de alto: suficiente para leer la forma sin comerse la pantalla de
        // un teléfono, donde debajo todavía hay contenido.
        SizedBox(
          height: 150,
          child: LayoutBuilder(
            builder: (context, c) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _elegir(d.localPosition.dx, c.maxWidth),
              onHorizontalDragUpdate: (d) => _elegir(d.localPosition.dx, c.maxWidth),
              onHorizontalDragEnd: (_) => setState(() => _tocado = null),
              onTapUp: (_) => setState(() => _tocado = null),
              child: CustomPaint(
                size: Size(c.maxWidth, 150),
                painter: _LinePainter(
                  points: puntos,
                  destacado: _tocado,
                  diasRestantes: widget.diasRestantes,
                  linea: colors.sage,
                  relleno: colors.sage.withValues(alpha: 0.16),
                  guia: colors.foreground.withValues(alpha: 0.18),
                  cero: colors.danger.withValues(alpha: 0.35),
                  futuro: colors.foreground.withValues(alpha: 0.05),
                  subirEsMalo: widget.subirEsMalo,
                  // Verde cuando baja y rojo cuando sube: los mismos dos de la
                  // paleta que la app ya usa para "bien" y "mal".
                  baja: colors.sageInk,
                  sube: colors.danger,
                  montos: widget.mostrarMontos
                      ? [for (final p in puntos) Money.compacto(p.liquid)]
                      : null,
                  tinta: colors.oliveInk.withValues(alpha: 0.75),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: Spacing.sm),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _rotulo(puntos.first.etiqueta),
              style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.5)),
            ),
            // Lo que falta del mes se nombra acá y no dentro del dibujo: pintar
            // texto en el lienzo obliga a medirlo a mano y a repetir la
            // tipografía de la app en un `TextPainter`.
            if (widget.diasRestantes > 0)
              Text(
                'faltan ${widget.diasRestantes} ${widget.diasRestantes == 1 ? "día" : "días"} del mes',
                style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.5)),
              )
            else
              Text(
                _rotulo(puntos.last.etiqueta),
                style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.5)),
              ),
          ],
        ),
      ],
    );
  }

  void _elegir(double x, double ancho) {
    final n = widget.points.length;
    // El mismo denominador que el painter: si el eje reserva los días que
    // faltan, tocar el 60% del ancho tiene que caer en el mismo punto que se
    // dibujó al 60%, no en el 60% de la curva.
    final tramos = n - 1 + widget.diasRestantes;
    final i = ((x / ancho) * tramos).round().clamp(0, n - 1);
    if (i != _tocado) setState(() => _tocado = i);
  }

  /// "2026-07" → "jul 2026"; "2026-07-31" → "31 jul".
  String _rotulo(String clave) {
    final partes = clave.split('-');
    const meses = [
      'ene',
      'feb',
      'mar',
      'abr',
      'may',
      'jun',
      'jul',
      'ago',
      'sep',
      'oct',
      'nov',
      'dic',
    ];
    if (partes.length < 2) return clave;
    final mes = int.tryParse(partes[1]);
    if (mes == null || mes < 1 || mes > 12) return clave;
    if (partes.length == 2) return '${meses[mes - 1]} ${partes[0]}';
    return '${int.tryParse(partes[2]) ?? partes[2]} ${meses[mes - 1]}';
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter({
    required this.points,
    required this.destacado,
    required this.diasRestantes,
    required this.linea,
    required this.relleno,
    required this.guia,
    required this.cero,
    required this.futuro,
    required this.subirEsMalo,
    required this.baja,
    required this.sube,
    required this.montos,
    required this.tinta,
  });

  final List<NetWorthPoint> points;
  final int? destacado;
  final int diasRestantes;
  final Color linea;
  final Color relleno;
  final Color guia;
  final Color cero;

  /// El sombreado de lo que falta del mes.
  final Color futuro;

  /// Pinta cada tramo según su dirección. Ver `NetWorthChart.subirEsMalo`.
  final bool subirEsMalo;
  final Color baja;
  final Color sube;

  /// Los montos ya formateados, uno por punto. `null` = no se dibujan.
  final List<String>? montos;
  final Color tinta;

  @override
  void paint(Canvas canvas, Size size) {
    final valores = points.map((p) => p.liquid).toList();
    var min = valores.reduce((a, b) => a < b ? a : b);
    var max = valores.reduce((a, b) => a > b ? a : b);

    // El eje incluye el cero cuando la serie se acerca a él: una curva entre
    // 2,400 y 2,410 con el eje pegado a los datos se ve como una montaña rusa,
    // y con el cero a la vista se ve como lo que es — una línea plana.
    if (min > 0 && min < max * 0.6) min = 0;
    if (max < 0) max = 0;
    if (max == min) max = min + 1;

    double y(double v) => size.height - ((v - min) / (max - min)) * size.height;
    // El eje se reparte entre los días vividos y los que faltan: la curva ocupa
    // su parte y el resto queda en blanco, que es lo que se quiere ver.
    final tramos = points.length - 1 + diasRestantes;
    double x(int i) => tramos == 0 ? size.width / 2 : (i / tramos) * size.width;

    // Lo que falta del mes, sombreado. Va primero, debajo de todo: es fondo, no
    // un dato más — la curva y su guía tienen que quedar por encima.
    if (diasRestantes > 0) {
      canvas.drawRect(
        Rect.fromLTRB(x(points.length - 1), 0, size.width, size.height),
        Paint()..color = futuro,
      );
    }

    // La línea del cero, solo si el patrimonio llegó a ser negativo alguna vez.
    if (min < 0) {
      canvas.drawLine(
        Offset(0, y(0)),
        Offset(size.width, y(0)),
        Paint()
          ..color = cero
          ..strokeWidth = 1,
      );
    }

    final trazo = Path()..moveTo(x(0), y(valores[0]));
    for (var i = 1; i < valores.length; i++) {
      trazo.lineTo(x(i), y(valores[i]));
    }

    final area = Path.from(trazo)
      ..lineTo(x(valores.length - 1), size.height)
      ..lineTo(x(0), size.height)
      ..close();
    canvas.drawPath(area, Paint()..color = relleno);

    // 2 puntos: el mismo grosor que la web. Más grueso tapa las variaciones
    // pequeñas, que en una curva de patrimonio son justo el dato.
    Paint trazoCon(Color color) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    if (!subirEsMalo) {
      canvas.drawPath(trazo, trazoCon(linea));
    } else {
      // Tramo a tramo: cada uno lleva el color de su dirección. Dibujarlo como
      // un solo camino obligaría a elegir un color para toda la curva, que es
      // justo lo que no se quiere.
      for (var i = 1; i < valores.length; i++) {
        canvas.drawLine(
          Offset(x(i - 1), y(valores[i - 1])),
          Offset(x(i), y(valores[i])),
          trazoCon(valores[i] > valores[i - 1] ? sube : baja),
        );
      }
      for (var i = 0; i < valores.length; i++) {
        final color = i == 0
            // El primer punto no sube ni baja: no hay contra qué compararlo.
            ? tinta
            : (valores[i] > valores[i - 1] ? sube : baja);
        canvas.drawCircle(Offset(x(i), y(valores[i])), 3, Paint()..color = color);
      }
    }

    // El monto encima de cada punto.
    if (montos != null) {
      for (var i = 0; i < valores.length && i < montos!.length; i++) {
        final texto = TextPainter(
          text: TextSpan(
            text: montos![i],
            style: TextStyle(fontSize: 9.5, color: tinta, fontWeight: FontWeight.w600),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        // Encima del punto, y por debajo si no cabe arriba: una etiqueta
        // cortada contra el borde es peor que una del otro lado.
        final arriba = y(valores[i]) - texto.height - 6;
        texto.paint(
          canvas,
          Offset(
            (x(i) - texto.width / 2).clamp(0, size.width - texto.width),
            arriba < 0 ? y(valores[i]) + 6 : arriba,
          ),
        );
      }
    }

    if (destacado != null) {
      final px = x(destacado!);
      canvas.drawLine(
        Offset(px, 0),
        Offset(px, size.height),
        Paint()
          ..color = guia
          ..strokeWidth = 1,
      );
      final py = y(valores[destacado!]);
      // El punto lleva un anillo del color del fondo para que se despegue de la
      // línea en vez de fundirse con ella.
      canvas.drawCircle(Offset(px, py), 5.5, Paint()..color = relleno);
      canvas.drawCircle(Offset(px, py), 4, Paint()..color = linea);
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.destacado != destacado ||
      old.points != points ||
      old.diasRestantes != diasRestantes ||
      old.subirEsMalo != subirEsMalo ||
      old.montos != montos;
}
