// El monto de un flujo, mes a mes.
//
// El bug que fija, y que costó dos intentos: el monto vivía solo en el flujo,
// uno para todos los meses. Poner 0 en agosto ponía 0 en julio. Y como el único
// sitio donde podía vivir un monto era el pago, un mes sin pagar no tenía dónde
// guardar el suyo.

import 'package:flutter_test/flutter_test.dart';

import 'package:financial_strategist_local/data/models.dart';

RecurringFlow flujo({required double semilla, Map<String, double> montos = const {}}) =>
    RecurringFlow(
      id: 'f1',
      name: 'Luz',
      type: 'EXPENSE',
      amount: semilla,
      frequency: 'MONTHLY',
      nextDueDate: DateTime(2026, 8, 5),
      paidThisMonth: false,
      missedMonths: const [],
      paidMonths: const [],
      monthlyRecords: const [],
      months: {
        for (final e in montos.entries)
          e.key: FlowMonth(
            amount: e.value,
            // La caducidad por defecto de una ficha: el último día de su mes.
            dueDate: DateTime(
              int.parse(e.key.split('-')[0]),
              int.parse(e.key.split('-')[1]) + 1,
              0,
            ),
          ),
      },
      categoryName: null,
      accountId: 'a1',
    );

void main() {
  test('cada mes muestra el suyo, sin arrastrar a los demás', () {
    final f = flujo(semilla: 0, montos: {'2026-07': 450, '2026-08': 0});
    // Este es el caso exacto que se reportó: poner 0 en agosto ponía 0 en julio.
    expect(f.montoDe('2026-07'), 450);
    expect(f.montoDe('2026-08'), 0);
  });

  test('un mes sin ficha no hereda de nadie al mostrarse', () {
    final f = flujo(semilla: 100, montos: {'2026-06': 180, '2026-07': 210});
    // Este era el bug que se veía en pantalla: editabas julio y septiembre
    // pasaba a mostrar 210, porque lo heredaba en vivo. La herencia va al
    // *crear* la ficha del mes nuevo, no al pintarla.
    expect(f.montoDe('2026-09'), 100);
  });

  test('escribir un mes no mueve a los demás', () {
    final f = flujo(semilla: 100, montos: {'2026-07': 210, '2026-08': 999});
    expect(f.montoDe('2026-07'), 210);
    expect(f.montoDe('2026-08'), 999);
  });

  test('sin ningún mes escrito cae en la semilla del flujo', () {
    expect(flujo(semilla: 150).montoDe('2026-08'), 150);
  });
}
