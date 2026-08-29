// Las dos pastillas del anillo de categorías: descontar lo que ya estaba
// comprometido.
//
// Un gasto fijo y una cuota son dos cosas distintas —una la puedes renegociar,
// la otra la firmaste— y por eso van separadas: cada combinación contesta una
// pregunta distinta, y las dos juntas contestan "¿en qué se me fue lo que sí
// decidí este mes?".

import 'package:financial_strategist_local/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// El mismo filtro que aplica Panorama antes de armar el anillo.
List<Transaction> contando(
  List<Transaction> gastos, {
  required bool sinFijos,
  required bool sinDeudas,
}) => gastos
    .where((t) => !(sinFijos && t.recurringFlowId != null))
    .where((t) => !(sinDeudas && t.debtId != null))
    .toList();

Transaction _gasto(String id, double monto, {String? flujo, String? deuda}) =>
    Transaction.fromJson({
      'id': id,
      'accountId': 'a1',
      'type': 'EXPENSE',
      'kind': 'MOVEMENT',
      'amount': monto,
      'occurredAt': '2026-08-10T12:00:00.000Z',
      if (flujo != null) 'recurringFlowId': flujo,
      if (deuda != null) 'debtId': deuda,
    });

void main() {
  final gastos = [
    _gasto('suelto', 50),
    _gasto('alquiler', 1700, flujo: 'f1'),
    _gasto('cuota', 500, deuda: 'd1'),
  ];

  double suma(List<Transaction> l) => l.fold(0, (a, t) => a + t.amount);

  test('sin tocar nada, cuentan todos', () {
    expect(suma(contando(gastos, sinFijos: false, sinDeudas: false)), 2250);
  });

  test('sin gastos fijos se va el alquiler y se queda la cuota', () {
    final r = contando(gastos, sinFijos: true, sinDeudas: false);
    expect(suma(r), 550);
    expect(r.map((t) => t.id), containsAll(['suelto', 'cuota']));
  });

  test('sin cuotas se va la deuda y se queda el alquiler', () {
    final r = contando(gastos, sinFijos: false, sinDeudas: true);
    expect(suma(r), 1750);
  });

  test('las dos juntas dejan solo lo que decidiste tú', () {
    final r = contando(gastos, sinFijos: true, sinDeudas: true);
    expect(suma(r), 50);
    expect(r.single.id, 'suelto');
  });
}
