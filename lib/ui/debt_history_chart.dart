import 'package:flutter/widgets.dart';

import '../data/exchange.dart' as fx;
import '../data/models.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import 'format.dart';

/// Cómo se movió la deuda mes a mes.
///
/// **Dos gráficos y no uno con dos ejes.** La cuota del mes son cientos y el
/// saldo son decenas de miles: en un solo eje la cuota queda pegada al suelo, y
/// con dos ejes cualquier cruce entre las barras y la línea sería una casualidad
/// de las escalas elegidas. Arriba en qué se fue lo que pagaste, abajo cuánto
/// sigues debiendo, con el mismo eje de meses.
///
/// **Toca una barra para leer su detalle.** En un teléfono no hay hover, así que
/// el toque reemplaza al cursor y el desglose sale arriba, en el mismo sitio
/// siempre, en vez de en un globo que el dedo tapa.
class DebtHistoryChart extends StatefulWidget {
  const DebtHistoryChart({super.key, required this.serie});

  final DebtHistorySeries serie;

  @override
  State<DebtHistoryChart> createState() => _DebtHistoryChartState();
}

class _DebtHistoryChartState extends State<DebtHistoryChart> {
  int? _tocado;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final meses = widget.serie.months;
    final moneda = widget.serie.currency;
    if (meses.isEmpty) return const SizedBox.shrink();

    final indice = _tocado ?? meses.length - 1;
    final mes = meses[indice];
    // Color fijo por concepto y no por posición: si un mes no tuvo seguro, el
    // capital y el interés no pueden cambiar de color detrás. La terna es la
    // misma que en la web, validada en los dos temas.
    final capital = colors.chart[2];
    final interes = colors.chart[1];
    final otros = colors.chart[6];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _rotulo(mes.month).toUpperCase(),
          style: AppText.kicker(colors.oliveInk.withValues(alpha: 0.55)).copyWith(fontSize: 9.5),
        ),
        const SizedBox(height: 4),
        Text(
          mes.paid == 0 ? 'Sin pagos registrados' : '${Money.format(mes.paid, moneda)} pagado',
          style: AppText.money(colors.foreground, size: 20, weight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(
          'Quedaba debiendo ${Money.format(mes.balance, moneda)}',
          style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.7)),
        ),
        const SizedBox(height: Spacing.md),
        // El desglose del mes que se está mirando: es lo que un globo diría, en
        // un sitio fijo. Los conceptos en cero no se listan — una fila que dice
        // "Interés 0" ocupa lo mismo que una que informa.
        Wrap(
          spacing: Spacing.md,
          runSpacing: 4,
          children: [
            if (mes.principal > 0)
              _Concepto(color: capital, etiqueta: 'Capital', valor: mes.principal, moneda: moneda),
            if (mes.interest > 0)
              _Concepto(color: interes, etiqueta: 'Interés', valor: mes.interest, moneda: moneda),
            if (mes.other > 0)
              _Concepto(
                color: otros,
                etiqueta: 'Seguro y portes',
                valor: mes.other,
                moneda: moneda,
              ),
          ],
        ),
        const SizedBox(height: Spacing.md),
        SizedBox(
          height: 120,
          child: LayoutBuilder(
            builder: (context, c) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _elegir(d.localPosition.dx, c.maxWidth),
              onHorizontalDragUpdate: (d) => _elegir(d.localPosition.dx, c.maxWidth),
              child: CustomPaint(
                size: Size(c.maxWidth, 120),
                painter: _BarrasPainter(
                  meses: meses,
                  destacado: indice,
                  capital: capital,
                  interes: interes,
                  otros: otros,
                  fondo: colors.surface,
                  vacio: colors.foreground.withValues(alpha: 0.06),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: Spacing.sm),
        // La línea de tiempo, mes por mes y **debajo de su barra**.
        //
        // Antes eran dos rótulos pegados a los extremos: con dos meses en la
        // serie, "jul." quedaba en el borde izquierdo y "ago." en el derecho,
        // lejísimos de las dos barras que estaban en el medio — se leía como si
        // el gráfico cubriera un año. Cada mes bajo su barra dice de un vistazo
        // cuántos meses hay y cuál es cuál.
        _LineaDeTiempo(meses: meses, destacado: indice, color: colors.oliveInk),
        const SizedBox(height: Spacing.lg),
        Text(
          'SALDO AL CIERRE DE CADA MES',
          style: AppText.kicker(colors.oliveInk.withValues(alpha: 0.55)).copyWith(fontSize: 9),
        ),
        const SizedBox(height: Spacing.sm),
        SizedBox(
          height: 76,
          child: CustomPaint(
            size: Size.infinite,
            painter: _SaldoPainter(
              meses: meses,
              destacado: indice,
              linea: colors.sage,
              relleno: colors.sage.withValues(alpha: 0.16),
              guia: colors.foreground.withValues(alpha: 0.18),
            ),
          ),
        ),
      ],
    );
  }

  void _elegir(double x, double ancho) {
    final n = widget.serie.months.length;
    final i = ((x / ancho) * n).floor().clamp(0, n - 1);
    if (i != _tocado) setState(() => _tocado = i);
  }
}

/// "2026-07" → "jul 26". El año solo en enero, que es donde el salto importa.
String _rotulo(String clave) {
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
  final partes = clave.split('-');
  if (partes.length < 2) return clave;
  final n = int.tryParse(partes[1]);
  if (n == null || n < 1 || n > 12) return clave;
  return partes[1] == '01' ? '${meses[n - 1]} ${partes[0].substring(2)}' : meses[n - 1];
}

class _Concepto extends StatelessWidget {
  const _Concepto({
    required this.color,
    required this.etiqueta,
    required this.valor,
    required this.moneda,
  });

  final Color color;
  final String etiqueta;
  final double valor;
  final String moneda;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2.5)),
        ),
        const SizedBox(width: 5),
        Text(etiqueta, style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.7))),
        const SizedBox(width: 4),
        Text(
          Money.format(valor, moneda),
          style: AppText.money(colors.foreground, size: 11.5, weight: FontWeight.w600),
        ),
      ],
    );
  }
}

/// Las barras apiladas: capital abajo, interés encima, y el resto arriba.
///
/// Apilado y no tres barras al lado: la altura total es la cuota del mes, que es
/// la primera lectura, y los tramos contestan la segunda —en qué se fue— sin
/// pedir un gráfico aparte.
class _BarrasPainter extends CustomPainter {
  _BarrasPainter({
    required this.meses,
    required this.destacado,
    required this.capital,
    required this.interes,
    required this.otros,
    required this.fondo,
    required this.vacio,
  });

  final List<DebtMonth> meses;
  final int destacado;
  final Color capital;
  final Color interes;
  final Color otros;
  final Color fondo;
  final Color vacio;

  @override
  void paint(Canvas canvas, Size size) {
    final max = meses.map((m) => m.paid).fold<double>(0, (a, b) => a > b ? a : b);
    final ancho = size.width / meses.length;
    // 26 de tope: con pocos meses, unas barras de cien puntos de ancho se leen
    // como bloques y no como una serie.
    final barra = (ancho * 0.6).clamp(4.0, 26.0);

    for (var i = 0; i < meses.length; i++) {
      final m = meses[i];
      final centro = ancho * i + ancho / 2;
      final izquierda = centro - barra / 2;

      if (max <= 0 || m.paid <= 0) {
        // Un mes sin pagos deja su hueco marcado: sin esto, doce meses vacíos y
        // uno con datos se leen como un gráfico de un solo mes.
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(izquierda, size.height - 2, barra, 2),
            const Radius.circular(1),
          ),
          Paint()..color = vacio,
        );
        continue;
      }

      // De abajo hacia arriba, en el orden en que se leen: primero lo que baja
      // la deuda, después lo que se lleva el banco.
      var y = size.height;
      final tramos = [(m.principal, capital), (m.interest, interes), (m.other, otros)];
      for (final (valor, color) in tramos) {
        if (valor <= 0) continue;
        final alto = (valor / max) * size.height;
        final arriba = y - alto;
        canvas.drawRect(
          Rect.fromLTRB(izquierda, arriba, izquierda + barra, y),
          Paint()..color = color,
        );
        // Dos puntos de superficie entre tramos, para que capital e interés no
        // se lean como un solo bloque de dos tonos.
        if (arriba > 0) {
          canvas.drawRect(
            Rect.fromLTRB(izquierda, arriba - 1, izquierda + barra, arriba + 1),
            Paint()..color = fondo,
          );
        }
        y = arriba;
      }

      if (i == destacado) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(izquierda - 3, y - 4, izquierda + barra + 3, size.height),
            const Radius.circular(Radii.sm),
          ),
          Paint()
            ..color = capital.withValues(alpha: 0.9)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_BarrasPainter old) => old.meses != meses || old.destacado != destacado;
}

/// El saldo al cierre de cada mes: un área con su línea, como la de patrimonio.
class _SaldoPainter extends CustomPainter {
  _SaldoPainter({
    required this.meses,
    required this.destacado,
    required this.linea,
    required this.relleno,
    required this.guia,
  });

  final List<DebtMonth> meses;
  final int destacado;
  final Color linea;
  final Color relleno;
  final Color guia;

  @override
  void paint(Canvas canvas, Size size) {
    if (meses.length < 2) return;
    final valores = meses.map((m) => m.balance).toList();
    final max = valores.reduce((a, b) => a > b ? a : b);
    // Desde cero y no desde el mínimo: en una deuda lo que importa es cuánto
    // falta para llegar a cero, y un eje recortado convierte una bajada del 3%
    // en una pendiente que promete el final.
    final tope = max <= 0 ? 1.0 : max;

    double y(double v) => size.height - (v / tope) * size.height;
    // Alineado con el centro de cada barra del gráfico de arriba: los dos ejes
    // son el mismo, y un punto corrido medio mes desmentiría eso.
    final ancho = size.width / meses.length;
    double x(int i) => ancho * i + ancho / 2;

    final trazo = Path()..moveTo(x(0), y(valores[0]));
    for (var i = 1; i < valores.length; i++) {
      trazo.lineTo(x(i), y(valores[i]));
    }
    final area = Path.from(trazo)
      ..lineTo(x(valores.length - 1), size.height)
      ..lineTo(x(0), size.height)
      ..close();

    canvas.drawPath(area, Paint()..color = relleno);
    canvas.drawPath(
      trazo,
      Paint()
        ..color = linea
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );

    canvas.drawLine(
      Offset(x(destacado), 0),
      Offset(x(destacado), size.height),
      Paint()
        ..color = guia
        ..strokeWidth = 1,
    );
    canvas.drawCircle(Offset(x(destacado), y(valores[destacado])), 3.5, Paint()..color = linea);
  }

  @override
  bool shouldRepaint(_SaldoPainter old) => old.meses != meses || old.destacado != destacado;
}

/// Todas las monedas convertidas a una sola y sumadas mes a mes.
///
/// Se convierte al cambio de hoy, también los meses viejos: es la misma
/// aproximación que ya hace el total de Deudas —y es lo que permite que las dos
/// cifras coincidan— y la alternativa, guardar la cotización de cada mes, sería
/// una segunda verdad para el mismo número. La pantalla avisa con qué cambio se
/// hizo.
///
/// Devuelve también la cotización usada, para poder decirlo, o `null` si no hizo
/// falta convertir nada.
(DebtHistorySeries, fx.Converted?) unirEnUnaMoneda(
  List<DebtHistorySeries> series,
  String moneda,
  List<ExchangeRate> tasas,
) {
  final claves = <String>{for (final s in series) ...s.months.map((m) => m.month)}.toList()..sort();
  final acumulado = {
    for (final k in claves)
      k: {'paid': 0.0, 'principal': 0.0, 'interest': 0.0, 'other': 0.0, 'balance': 0.0},
  };
  fx.Converted? usada;

  for (final s in series) {
    final factor = fx.convert(1, s.currency, moneda, tasas, purpose: fx.ConversionPurpose.debt);
    // Sin cotización esa moneda queda fuera, igual que en el total de Deudas:
    // inventar un cambio sería peor que faltar.
    if (factor == null) continue;
    if (factor.quote != 1) usada = factor;
    final porMes = {for (final m in s.months) m.month: m};
    for (final k in claves) {
      // Un mes que esta moneda no tiene es un mes en que no debía nada: se
      // recortó justamente por estar vacío.
      final m = porMes[k];
      if (m == null) continue;
      acumulado[k]!['paid'] = acumulado[k]!['paid']! + m.paid * factor.amount;
      acumulado[k]!['principal'] = acumulado[k]!['principal']! + m.principal * factor.amount;
      acumulado[k]!['interest'] = acumulado[k]!['interest']! + m.interest * factor.amount;
      acumulado[k]!['other'] = acumulado[k]!['other']! + m.other * factor.amount;
      acumulado[k]!['balance'] = acumulado[k]!['balance']! + m.balance * factor.amount;
    }
  }

  // Al unir pueden reaparecer meses vacíos al principio —una moneda arranca
  // antes que otra—, así que se recorta otra vez.
  final primero = claves.indexWhere(
    (k) => acumulado[k]!['paid']! > 0 || acumulado[k]!['balance']! > 0,
  );
  final visibles = primero <= 0 ? claves : claves.sublist(primero);

  return (
    DebtHistorySeries(
      currency: moneda,
      months: [
        for (final k in visibles)
          DebtMonth(
            month: k,
            paid: acumulado[k]!['paid']!,
            principal: acumulado[k]!['principal']!,
            interest: acumulado[k]!['interest']!,
            other: acumulado[k]!['other']!,
            balance: acumulado[k]!['balance']!,
          ),
      ],
    ),
    usada,
  );
}

/// Los meses debajo de sus barras.
///
/// Se saltean rótulos cuando no entran —siempre dejando el primero y el
/// último—, en vez de encogerlos hasta que no se lean: una tira de doce meses
/// ilegibles no informa más que cuatro que sí se leen.
class _LineaDeTiempo extends StatelessWidget {
  const _LineaDeTiempo({required this.meses, required this.destacado, required this.color});

  final List<DebtMonth> meses;

  /// El mes que está señalado: su rótulo se dibuja siempre, aunque le tocara
  /// saltarse. Es el que el usuario está mirando.
  final int destacado;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // ~34 puntos por rótulo ("dic. 26" con aire). De ahí sale cada cuántos
        // meses cabe uno.
        final cabe = (constraints.maxWidth / 34).floor().clamp(1, meses.length);
        final paso = (meses.length / cabe).ceil().clamp(1, meses.length);

        return Row(
          children: [
            for (var i = 0; i < meses.length; i++)
              Expanded(
                child: Text(
                  // Del final hacia atrás: así el último mes —el que más se
                  // mira— nunca es el que se salta.
                  (meses.length - 1 - i) % paso == 0 || i == destacado
                      ? _rotulo(meses[i].month)
                      : '',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: AppText.tiny(
                    color.withValues(alpha: i == destacado ? 0.85 : 0.5),
                  ).copyWith(fontWeight: i == destacado ? FontWeight.w600 : null),
                ),
              ),
          ],
        );
      },
    );
  }
}
