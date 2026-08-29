// El final de un rango, con un filtro que compara con `<=`.
//
// El bug que fija: "hasta el día 21" traía un gasto del 22. El corte se armaba
// como el inicio del día siguiente, y un gasto anotado sin hora se guarda justo
// a las 00:00 — o sea, dentro del rango.

import 'package:financial_strategist_local/local_engine/months_util.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('deja fuera la medianoche del día siguiente', () {
    final corte = finInclusivo(DateTime(2026, 7, 22));
    final gastoDel22 = DateTime(2026, 7, 22);
    expect(gastoDel22.isAfter(corte), isTrue, reason: 'el del 22 se queda fuera');
  });

  test('no pierde los de última hora del último día', () {
    final corte = finInclusivo(DateTime(2026, 7, 22));
    for (final tarde in [
      DateTime(2026, 7, 21, 23, 59, 59),
      DateTime(2026, 7, 21, 23, 59, 59, 999),
    ]) {
      expect(tarde.isAfter(corte), isFalse, reason: '$tarde entra');
    }
  });

  test('sirve igual para el fin de mes', () {
    final corte = finInclusivo(DateTime(2026, 9, 1));
    expect(DateTime(2026, 8, 31, 23, 59).isAfter(corte), isFalse);
    expect(DateTime(2026, 9, 1).isAfter(corte), isTrue);
  });
}
