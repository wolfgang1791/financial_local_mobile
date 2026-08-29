// La barra de avance: que el relleno se vea y crezca desde la izquierda.
//
// La forma obvia de armarla se dibuja vacía —el hijo sin posicionar de un
// `Stack` recibe restricciones flojas y el `ColoredBox` de adentro toma alto
// cero—, y así estuvo: se veía el canal y nunca el avance. El bug no rompe nada
// ni sale en el análisis; solo se nota mirando la pantalla.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:financial_strategist_local/ui/surface.dart';

void main() {
  const canal = Color(0xFFDDDDDD);
  const relleno = Color(0xFF00AAFF);

  Future<Rect> pintar(WidgetTester tester, double avance) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 200,
            child: BarraAvance(avance: avance, color: relleno, canal: canal, alto: 8),
          ),
        ),
      ),
    );
    // El relleno es el `ColoredBox` del color de avance; el otro es el canal.
    final caja = find.byWidgetPredicate((w) => w is ColoredBox && w.color == relleno);
    return tester.getRect(caja);
  }

  testWidgets('el relleno tiene el alto de la barra, no cero', (tester) async {
    final r = await pintar(tester, 0.5);
    expect(r.height, 8);
  });

  testWidgets('crece desde la izquierda, en proporción', (tester) async {
    final mitad = await pintar(tester, 0.5);
    expect(mitad.left, 0, reason: 'arranca pegado al borde izquierdo, no centrado');
    expect(mitad.width, closeTo(100, 0.5));

    final cuarto = await pintar(tester, 0.25);
    expect(cuarto.width, closeTo(50, 0.5));
  });

  testWidgets('un avance fuera de rango no desborda el canal', (tester) async {
    expect((await pintar(tester, 1.8)).width, closeTo(200, 0.5));
    expect((await pintar(tester, -1)).width, 0);
  });
}
