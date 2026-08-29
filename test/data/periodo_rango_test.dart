// El rango de un periodo relativo llega hasta el final de hoy.
//
// El bug que fija: un gasto se guarda fechado a mediodía —es una fecha, no una
// hora— y el rango terminaba en "ahora". Anotabas un café a las 8 de la mañana
// y el movimiento quedaba en el futuro respecto del filtro: desaparecía del
// calendario de días, del anillo de categorías y del reparto, mientras el
// patrimonio de la tarjeta —que lo calcula el motor, no el filtro— sí lo
// mostraba. Dos cifras de la misma pantalla contando cosas distintas.

import 'package:financial_strategist_local/data/allocation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Como lo guarda la app: la fecha elegida, a mediodía.
  DateTime gastoDelDia(DateTime dia) => DateTime(dia.year, dia.month, dia.day, 12);

  bool dentro(DateTime cuando, (DateTime, DateTime) rango) =>
      !cuando.isBefore(rango.$1) && cuando.isBefore(rango.$2);

  test('un gasto de hoy entra aunque sean las 8 de la mañana', () {
    final ahora = DateTime(2026, 8, 24, 8);
    final rango = const PeriodoElegido.relativo(Periodo.mes).rango(ahora);
    expect(dentro(gastoDelDia(ahora), rango), isTrue);
  });

  test('y también si se anota pasada la medianoche', () {
    final ahora = DateTime(2026, 8, 24, 0, 5);
    final rango = const PeriodoElegido.relativo(Periodo.mes).rango(ahora);
    expect(dentro(gastoDelDia(ahora), rango), isTrue);
  });

  test('pero mañana sigue estando fuera', () {
    final ahora = DateTime(2026, 8, 24, 8);
    final rango = const PeriodoElegido.relativo(Periodo.mes).rango(ahora);
    expect(dentro(gastoDelDia(DateTime(2026, 8, 25)), rango), isFalse);
  });

  test('un mes cerrado termina donde termina el mes', () {
    final rango = const PeriodoElegido.mes('2026-07').rango(DateTime(2026, 8, 24));
    expect(dentro(gastoDelDia(DateTime(2026, 7, 31)), rango), isTrue);
    expect(dentro(gastoDelDia(DateTime(2026, 8, 1)), rango), isFalse);
  });
}
