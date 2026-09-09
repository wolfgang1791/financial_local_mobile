// El grupo de pastillas con cuatro opciones.
//
// Reparte el ancho en partes iguales, así que en un teléfono cada opción se
// queda con unos ochenta píxeles: "Pagar tarjeta" no entraba y se salía de la
// pastilla, encima del borde redondeado. Lo que se prueba es que **ninguna**
// etiqueta se pinte fuera de su celda, sea cual sea la fuente con la que corra
// el test — que es justo lo que un `Row` de `Expanded` no garantiza solo.

import 'package:financial_strategist_local/design/theme.dart';
import 'package:financial_strategist_local/design/tokens.dart';
import 'package:financial_strategist_local/ui/fields.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> montar(WidgetTester tester, List<String> etiquetas, double ancho) async {
    tester.view.physicalSize = Size(ancho * 3, 600 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      AppTheme(
        colors: AppColors.light,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: MediaQueryData(size: Size(ancho, 600)),
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: FieldSwitch<int>(
                  opciones: [for (var i = 0; i < etiquetas.length; i++) (etiquetas[i], i)],
                  valor: 0,
                  onChange: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  const cuatro = ['Gasto', 'Ingreso', 'Transferir', 'Pagar tarjeta'];

  for (final ancho in [360.0, 390.0]) {
    testWidgets('con cuatro opciones nada se sale de su celda en ${ancho.toInt()}dp', (
      tester,
    ) async {
      await montar(tester, cuatro, ancho);

      final control = tester.getRect(find.byType(FieldSwitch<int>));
      for (final etiqueta in cuatro) {
        final texto = tester.getRect(find.text(etiqueta));
        expect(
          texto.width,
          lessThanOrEqualTo(control.width / cuatro.length),
          reason: '«$etiqueta» ocupa más que su cuarto',
        );
        expect(texto.left, greaterThanOrEqualTo(control.left - 0.5), reason: '«$etiqueta»');
        expect(texto.right, lessThanOrEqualTo(control.right + 0.5), reason: '«$etiqueta»');
      }
    });
  }

  testWidgets('con dos opciones la letra se queda como estaba', (tester) async {
    await montar(tester, ['Gasto', 'Ingreso'], 390);
    final estilo = tester.widget<Text>(find.text('Gasto')).style!;
    expect(estilo.fontSize, 15, reason: 'lo apretado es solo para cuatro');
  });

  testWidgets('con cuatro, todas comparten tamaño de letra', (tester) async {
    await montar(tester, cuatro, 390);
    final tamanos = cuatro.map((e) => tester.widget<Text>(find.text(e)).style!.fontSize).toSet();
    expect(tamanos.length, 1, reason: 'cuatro tamaños distintos se leen como cuatro botones');
  });
}
