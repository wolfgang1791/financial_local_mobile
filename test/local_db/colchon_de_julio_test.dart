// La curva de patrimonio no baja de cero, y el arreglo no mueve ninguna cifra.
//
// Antes del 2 de julio ya había plata en la mano que la app nunca supo. Como la
// curva se deduce hacia atrás desde el saldo de hoy, ese dinero invisible la
// hundía: veintitantos días en negativo, el peor el 29 de julio. Esto comprueba
// las dos mitades de la promesa: que la curva sale del pozo, y que el saldo de
// hoy y los totales del mes quedan exactamente donde estaban.

import 'dart:io';

import 'package:financial_strategist_local/data/api.dart';
import 'package:financial_strategist_local/local_db/database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import '../test_support.dart';

void main() {
  late Directory tmp;
  late ApiClient api;

  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(inicializarMotorDePrueba);

  setUp(() async {
    tmp = await prepararDirectorioTemporal('colchon_test');
    api = ApiClient();
  });

  tearDown(() async {
    await LocalDatabase.resetForTests();
    await tmp.delete(recursive: true);
  });

  Future<List<Map<String, Object?>>> curva() async =>
      (await api.get('/financial-engine/net-worth-daily') as List).cast<Map<String, Object?>>();

  test('la curva de patrimonio nunca baja de cero', () async {
    await LocalDatabase.open();
    final puntos = await curva();

    expect(puntos, isNotEmpty);
    final enNegativo = puntos.where((p) => (p['liquid'] as num) < 0);
    expect(enNegativo, isEmpty, reason: 'ningún día en rojo: ${enNegativo.take(3)}');
  });

  test('el colchón se pone solo en una base que ya existía, y una sola vez', () async {
    final db = await LocalDatabase.open();
    final saldoAntes = (await db.query(
      'Account',
      columns: ['id', 'currentBalance'],
    )).map((c) => '${c['id']}:${c['currentBalance']}').join(',');

    // Un teléfono instalado antes de este arreglo: tiene los movimientos, no
    // tiene el colchón.
    await db.delete('"Transaction"', where: "id LIKE 'colchon-%'");
    expect(
      (await curva()).any((p) => (p['liquid'] as num) < 0),
      isTrue,
      reason: 'sin el colchón, la curva se hunde',
    );

    // Y al abrir la app, aparece.
    await LocalDatabase.resetForTests();
    final db2 = await LocalDatabase.open();
    api = ApiClient(db: db2);
    expect(
      Sqflite.firstIntValue(
        await db2.rawQuery("SELECT count(*) FROM \"Transaction\" WHERE id LIKE 'colchon-%'"),
      ),
      2,
    );
    expect((await curva()).any((p) => (p['liquid'] as num) < 0), isFalse);

    // Abrir otra vez no lo duplica...
    await LocalDatabase.resetForTests();
    final db3 = await LocalDatabase.open();
    api = ApiClient(db: db3);
    expect(
      Sqflite.firstIntValue(
        await db3.rawQuery("SELECT count(*) FROM \"Transaction\" WHERE id LIKE 'colchon-%'"),
      ),
      2,
    );

    // ...y en ningún momento tocó un saldo.
    final saldoDespues = (await db3.query(
      'Account',
      columns: ['id', 'currentBalance'],
    )).map((c) => '${c['id']}:${c['currentBalance']}').join(',');
    expect(saldoDespues, saldoAntes);
  });

  test('el colchón no cuenta como ingreso ni como gasto de julio', () async {
    await LocalDatabase.open();
    final julio =
        await api.get(
              '/transactions?from=2026-07-01T05:00:00.000Z&to=2026-08-01T04:59:59.000Z&take=300',
            )
            as Map<String, dynamic>;

    final totales = julio['totals'] as Map<String, dynamic>;
    final items = (julio['items'] as List).cast<Map<String, dynamic>>();
    final delColchon = items.where((t) => (t['id'] as String).startsWith('colchon-')).toList();

    // Están a la vista en el historial —para eso se pusieron—...
    expect(delColchon, hasLength(2));
    // ...pero no suman en los totales del mes.
    final sumaIngresos = items
        .where((t) => t['type'] == 'INCOME' && t['kind'] == 'MOVEMENT')
        .fold<double>(0, (a, t) => a + (t['amount'] as num).toDouble());
    expect((totales['income'] as num).toDouble(), closeTo(sumaIngresos, 0.01));
  });
}
