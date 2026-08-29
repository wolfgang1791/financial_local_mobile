// Traer la base del teléfono a lo que dice la web.
//
// Las dos apps no se sincronizan: cada una escribe en su propia base. Al
// compararlas el 26 de agosto de 2026 habían divergido en trece filas —textos
// distintos para el mismo gasto, dos cobros marcados otro día y dos pagos que
// solo estaban en la web—. Todas las diferencias eran neutras para el saldo,
// que es por lo que las dos mostraban el mismo patrimonio mientras julio se
// leía distinto en cada pantalla.

import 'dart:io';

import 'package:financial_strategist_local/data/api.dart';
import 'package:financial_strategist_local/local_db/database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import '../test_support.dart';

void main() {
  late Directory tmp;

  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(inicializarMotorDePrueba);

  setUp(() async {
    tmp = await prepararDirectorioTemporal('unificacion_test');
  });

  tearDown(() async {
    await LocalDatabase.resetForTests();
    await tmp.delete(recursive: true);
  });

  test('el pago de Netflix de julio queda, con su contrapartida y su ficha', () async {
    final db = await LocalDatabase.open();

    final pago = await db.query(
      '"Transaction"',
      where: "description = 'Pago de Netflix' AND occurredAt = 1785171600000",
    );
    expect(pago, hasLength(1), reason: 'el movimiento que la web sí tenía');
    expect((pago.first['amount'] as num).toDouble(), 55.90);

    // Y su contrapartida, con el mismo instante: es lo que evita que el saldo
    // se mueva dos veces al registrar el pago de un mes ya pasado.
    final contra = await db.query(
      '"Transaction"',
      where: "kind = 'ADJUSTMENT' AND occurredAt = 1785171600000 AND type = 'INCOME'",
    );
    expect(contra, hasLength(1));
    expect((contra.first['amount'] as num).toDouble(), 55.90);

    // Si la ficha de ese mes existe, queda marcada en el mismo instante: es el
    // enlace que usa "revertir" para encontrar el pago. Si no existe no se
    // inventa —la web tampoco la tiene—, y el mes igual se ve pagado porque se
    // deduce del movimiento.
    final ficha = await db.rawQuery('''
      SELECT m.paidAt FROM RecurringFlowMonth m
      JOIN RecurringFlow f ON f.id = m.recurringFlowId
      WHERE f.name = 'Netflix' AND m.month = '2026-07'
    ''');
    if (ficha.isNotEmpty) expect(ficha.first['paidAt'], 1785171600000);

    // Lo que de verdad importa: la pantalla da julio por pagado.
    final api = ApiClient(db: db);
    final flujos = (await api.get('/recurring-flows') as List).cast<Map<String, dynamic>>();
    final netflix = flujos.firstWhere((f) => f['name'] == 'Netflix');
    expect((netflix['paidMonths'] as List).cast<String>(), contains('2026-07'));
  });

  test('el par no mueve el saldo, y correrlo otra vez no duplica nada', () async {
    final db = await LocalDatabase.open();
    final saldos = (await db.query('Account', columns: ['id', 'currentBalance'], orderBy: 'id'))
        .map((c) => '${c['id']}:${c['currentBalance']}')
        .join(',');
    final cuantos = Sqflite.firstIntValue(
      await db.rawQuery('SELECT count(*) FROM "Transaction"'),
    );

    await LocalDatabase.resetForTests();
    final db2 = await LocalDatabase.open();

    expect(
      Sqflite.firstIntValue(await db2.rawQuery('SELECT count(*) FROM "Transaction"')),
      cuantos,
    );
    expect(
      (await db2.query('Account', columns: ['id', 'currentBalance'], orderBy: 'id'))
          .map((c) => '${c['id']}:${c['currentBalance']}')
          .join(','),
      saldos,
    );
  });

  test('las tarjetas quedan con el saldo y el nombre de la web', () async {
    final db = await LocalDatabase.open();
    for (final (nombre, saldo) in const [
      ('DEUDA EN DOLARES', 3546.02),
      ('DEUDA EN SOLES', 8116.57),
    ]) {
      final cuenta = await db.query('Account', where: 'name = ?', whereArgs: [nombre]);
      expect(cuenta, hasLength(1), reason: 'renombrada como en la web');
      expect((cuenta.first['currentBalance'] as num).toDouble(), saldo);

      // La cuenta y la deuda son el mismo número visto desde dos tablas: si se
      // separan, la pantalla de deudas y la de patrimonio dicen cosas distintas.
      final deuda = await db.query(
        'Debt',
        where: 'accountId = ?',
        whereArgs: [cuenta.first['id']],
      );
      expect((deuda.first['currentBalance'] as num).toDouble(), saldo);
    }
  });

  test('abrir dos veces a la vez no corre las migraciones por duplicado', () async {
    // `open()` memoriza el Future, no la instancia. Con lo segundo, dos
    // llamadas antes de que la primera termine hacían el trabajo entero dos
    // veces: dos conexiones y `_alDia` corriendo en paralelo. Mientras las
    // migraciones solo agregaban columnas no se notaba; la primera que inserta
    // filas reventó con un UNIQUE —las dos pasaban el "¿ya está?" antes de que
    // ninguna hubiera escrito—. En un teléfono no habría reventado: habría
    // duplicado el movimiento.
    final abiertas = await Future.wait([
      LocalDatabase.open(),
      LocalDatabase.open(),
      LocalDatabase.open(),
    ]);
    expect(identical(abiertas[0], abiertas[1]), isTrue);
    expect(identical(abiertas[1], abiertas[2]), isTrue);

    final repetidos = await abiertas.first.rawQuery('''
      SELECT id, count(*) n FROM "Transaction" GROUP BY id HAVING n > 1
    ''');
    expect(repetidos, isEmpty);
  });

  test('los textos de la web pisan a los del teléfono', () async {
    final api = ApiClient(db: await LocalDatabase.open());
    final todos = ((await api.get('/transactions?take=300') as Map)['items'] as List)
        .cast<Map<String, dynamic>>();
    final textos = todos.map((t) => t['detail'] ?? t['description']).toSet();

    // Los seis pares eran el mismo movimiento escrito distinto en cada app. La
    // base sembrada tiene unos y no otros; lo que no puede quedar es la
    // versión del teléfono cuando la web decía otra cosa.
    for (final delTelefono in const [
      'Maas retención',
      'iu Test',
      'cdv',
      'taller pizza mesario',
      'sanguchon campesino',
      'Viajecito de Alem',
    ]) {
      expect(textos, isNot(contains(delTelefono)), reason: 'manda la web');
    }
  });
}
