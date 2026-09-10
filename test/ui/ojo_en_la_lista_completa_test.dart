// El ojito en la lista larga de Panorama.
//
// Es la lista que se abre para revisar de verdad —todos los gastos del periodo,
// por fecha— y era la única sin ojito: mostraba apagado lo que ya estaba
// descontado, pero no dejaba descontar nada. Enseñar el resultado de un gesto
// sin dar el gesto.

import 'package:financial_strategist_local/data/models.dart';
import 'package:financial_strategist_local/design/theme.dart';
import 'package:financial_strategist_local/design/tokens.dart';
import 'package:financial_strategist_local/screens/panorama_screen.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  // Las filas formatean la fecha en español: sin esto cada una se cambia por un
  // cuadro de error y el test no prueba lo que cree probar.
  setUpAll(() => initializeDateFormatting('es'));
  Transaction gasto(String id, double monto, int dia) => Transaction.fromJson({
    'id': id,
    'type': 'EXPENSE',
    'kind': 'MOVEMENT',
    'amount': monto,
    'detail': 'Gasto $id',
    'occurredAt': '2026-09-${dia.toString().padLeft(2, '0')}T12:00:00.000Z',
  });

  // Montos que no se repiten ni se suman entre sí: si el total coincidiera con
  // el de una fila, el test no sabría cuál de las dos está mirando.
  final gastos = [gasto('a', 120, 1), gasto('b', 55, 2), gasto('c', 33, 3)];

  Future<List<String>> montar(WidgetTester tester, {Set<String> ocultos = const {}}) async {
    final tocados = <String>[];
    tester.view.physicalSize = const Size(390 * 3, 1200 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      AppTheme(
        colors: AppColors.light,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(390, 1200)),
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ListaCompletaDeGastos(
                  gastos: gastos,
                  ocultos: ocultos,
                  currency: 'PEN',
                  onToggle: tocados.add,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return tocados;
  }

  testWidgets('cada gasto trae su ojito', (tester) async {
    await montar(tester);

    expect(find.bySemanticsLabel('Quitar este gasto de la cuenta'), findsNWidgets(gastos.length));
  });

  testWidgets('descontar uno baja el total de la lista', (tester) async {
    await montar(tester);
    expect(find.text('S/ 208.00'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Quitar este gasto de la cuenta').first);
    await tester.pump();

    // El de arriba es el más nuevo —la lista va por fecha— y son 33.
    expect(find.text('S/ 175.00'), findsOneWidget);
    expect(find.textContaining('SIN 1 DESCONTADO'), findsOneWidget);
  });

  testWidgets('lo descontado viaja hacia arriba: el anillo no puede discrepar', (tester) async {
    final tocados = await montar(tester);

    await tester.tap(find.bySemanticsLabel('Quitar este gasto de la cuenta').first);
    await tester.pump();

    expect(tocados, ['c'], reason: 'Panorama se entera del mismo toque');
  });

  testWidgets('lo que ya estaba descontado llega descontado, y se puede devolver', (tester) async {
    await montar(tester, ocultos: {'a'});

    expect(find.text('S/ 88.00'), findsOneWidget, reason: '208 menos los 120 de "a"');
    expect(find.bySemanticsLabel('Volver a contar este gasto'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Volver a contar este gasto'));
    await tester.pump();

    expect(find.text('S/ 208.00'), findsOneWidget);
  });
}
