// Cuánto mes queda. Es aritmética de calendario, que es donde se cuela el error
// de uno: febrero, los bisiestos y el último día del mes.

import 'package:flutter_test/flutter_test.dart';

import 'package:financial_strategist_local/ui/format.dart';

void main() {
  test('cuenta los días que faltan sin contar hoy', () {
    final r = Fechas.diasDelMes(DateTime(2026, 8, 19));
    expect(r.faltan, 12);
    expect(r.total, 31);
    expect(r.dia, 19);
  });

  test('el último día del mes no deja ninguno por delante', () {
    expect(Fechas.diasDelMes(DateTime(2026, 8, 31)).faltan, 0);
    expect(Fechas.diasDelMes(DateTime(2026, 4, 30)).faltan, 0);
  });

  test('febrero y los bisiestos', () {
    expect(Fechas.diasDelMes(DateTime(2026, 2, 1)).total, 28);
    // 2028 sí es bisiesto; 2100 no lo sería, pero está fuera de rango útil.
    expect(Fechas.diasDelMes(DateTime(2028, 2, 1)).total, 29);
    expect(Fechas.diasDelMes(DateTime(2028, 2, 28)).faltan, 1);
  });

  test('diciembre no se pasa al año siguiente', () {
    final r = Fechas.diasDelMes(DateTime(2026, 12, 25));
    expect(r.total, 31);
    expect(r.faltan, 6);
  });
}
