// Los días que gastaste y los que no.
//
// Lo que se prueba acá es lo que no se ve en el dibujo: que los días vacíos se
// recorren igual —son la mitad de la respuesta—, que la racha se cuenta seguida
// y que los extremos salen de entre los días con gasto y no de los que están en
// cero.

import 'package:financial_strategist_local/data/models.dart';
import 'package:financial_strategist_local/local_engine/spending_days.dart';
import 'package:flutter_test/flutter_test.dart';

Transaction _gasto(String fecha, double monto, {String? flujo, String? deuda, String? categoria}) =>
    Transaction.fromJson({
      'id': '$fecha-$monto',
      'accountId': 'a',
      'type': 'EXPENSE',
      'kind': 'MOVEMENT',
      'amount': monto,
      'occurredAt': DateTime(
        int.parse(fecha.split('-')[0]),
        int.parse(fecha.split('-')[1]),
        int.parse(fecha.split('-')[2]),
        12,
      ).toUtc().toIso8601String(),
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      if (flujo != null) 'recurringFlowId': flujo,
      if (deuda != null) 'debtId': deuda,
      if (categoria != null) 'category': {'id': categoria, 'name': categoria, 'type': 'EXPENSE'},
    });

void main() {
  final desde = DateTime(2026, 8, 1);
  final hasta = DateTime(2026, 8, 10, 23, 59);

  test('recorre el periodo entero, incluidos los días sin nada', () {
    final r = spendingDays([_gasto('2026-08-03', 50)], desde, hasta);
    expect(r.days.length, 10);
    expect(r.conGasto, 1);
    expect(r.sinGasto, 9);
    expect(r.days.first.date, '2026-08-01');
    expect(r.days.last.date, '2026-08-10');
  });

  test('suma varios movimientos del mismo día', () {
    final r = spendingDays([_gasto('2026-08-03', 50), _gasto('2026-08-03', 25.5)], desde, hasta);
    final dia = r.days.firstWhere((d) => d.date == '2026-08-03');
    expect(dia.amount, 75.5);
    expect(dia.count, 2);
    expect(r.totalGastado, 75.5);
  });

  test('la racha sin gastar se cuenta seguida, no en total', () {
    // Gasta el 1 y el 10: en medio hay ocho días seguidos sin gastar.
    final r = spendingDays([_gasto('2026-08-01', 10), _gasto('2026-08-10', 10)], desde, hasta);
    expect(r.rachaSinGasto, 8);
    // Y no lleva ninguna: el último día tuvo gasto.
    expect(r.rachaActual, 0);
  });

  test('la racha actual cuenta desde el final', () {
    final r = spendingDays([_gasto('2026-08-07', 10)], desde, hasta);
    expect(r.rachaActual, 3, reason: '8, 9 y 10');
  });

  test('los extremos salen de entre los días con gasto', () {
    final r = spendingDays(
      [_gasto('2026-08-02', 300), _gasto('2026-08-05', 12.5), _gasto('2026-08-08', 99)],
      desde,
      hasta,
    );
    expect(r.mayor!.date, '2026-08-02');
    // El menor es el más barato de los que tuvieron gasto — no un día en cero,
    // que ya se cuenta del otro lado.
    expect(r.menor!.date, '2026-08-05');
    expect(r.menor!.amount, 12.5);
  });

  test('sin gastos no hay extremos', () {
    final r = spendingDays(const [], desde, hasta);
    expect(r.mayor, isNull);
    expect(r.menor, isNull);
    expect(r.conGasto, 0);
  });

  test('el primer registro corta por la izquierda', () {
    // Sin esto, mirar un rango largo con poca historia diría "cientos de días
    // sin gastar", que no es austeridad: es que la app no existía.
    final r = spendingDays(
      [_gasto('2026-08-08', 10)],
      desde,
      hasta,
      primerRegistro: DateTime(2026, 8, 6),
    );
    expect(r.days.first.date, '2026-08-06');
    expect(r.days.length, 5);
  });

  test('el lunes es el día 0', () {
    // 2026-08-03 es lunes.
    final r = spendingDays(const [], DateTime(2026, 8, 3), DateTime(2026, 8, 3, 23, 59));
    expect(r.days.single.weekday, 0);
  });

  test('descontar fijos y deudas deja solo lo que decidiste tú', () {
    final todos = [
      _gasto('2026-08-02', 1700, flujo: 'alquiler'),
      _gasto('2026-08-03', 1694.80, deuda: 'prestamo'),
      _gasto('2026-08-04', 25),
    ];
    final variable = spendingDays(
      todos.where((t) => t.recurringFlowId == null && t.debtId == null).toList(),
      desde,
      hasta,
    );
    expect(variable.conGasto, 1);
    expect(variable.totalGastado, 25);
    expect(variable.mayor!.date, '2026-08-04');
  });

  test('cada día lleva las subcategorías que tuvieron gasto', () {
    final r = spendingDays(
      [
        _gasto('2026-08-02', 20, categoria: 'cat-comida-rapida'),
        _gasto('2026-08-02', 60, categoria: 'cat-mercado'),
        _gasto('2026-08-03', 30, categoria: 'cat-combustible'),
      ],
      desde,
      hasta,
    );

    final dos = r.days.firstWhere((d) => d.date == '2026-08-02');
    // Las dos, y sin repetir: es lo que deja a la pantalla marcar con un ícono
    // el día en que pediste delivery sin volver a preguntar nada.
    expect(dos.categorias.toSet(), {'cat-comida-rapida', 'cat-mercado'});
    expect(dos.amount, 80);

    final tres = r.days.firstWhere((d) => d.date == '2026-08-03');
    expect(tres.categorias, ['cat-combustible']);

    // Un día sin gasto no tiene ninguna.
    expect(r.days.firstWhere((d) => d.date == '2026-08-04').categorias, isEmpty);
  });

  test('un movimiento sin categoría no inventa una', () {
    final r = spendingDays([_gasto('2026-08-02', 20)], desde, hasta);
    expect(r.days.firstWhere((d) => d.date == '2026-08-02').categorias, isEmpty);
  });

  test('el último día del rango se dibuja, no se pierde', () {
    // El extremo derecho del periodo es exclusivo; la pantalla resta un
    // milisegundo antes de pedir los días. Con eso, el gasto de hoy —fechado a
    // mediodía— cae dentro y hoy es la última casilla, no la primera que falta.
    final finExclusivo = DateTime(2026, 8, 25);
    final r = spendingDays(
      [_gasto('2026-08-24', 30)],
      DateTime(2026, 8, 1),
      finExclusivo.subtract(const Duration(milliseconds: 1)),
    );
    expect(r.days.last.date, '2026-08-24');
    expect(r.days.last.conGasto, isTrue);
    expect(r.days.any((d) => d.date == '2026-08-25'), isFalse, reason: 'mañana no se dibuja');
  });
}
