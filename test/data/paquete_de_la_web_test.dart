// Traer al teléfono lo que pasó en la web.
//
// Las reglas son distintas de las del camino de ida, y a propósito: acá la web
// manda —una fila que llega distinta se corrige— pero **nada se borra**, porque
// lo que está solo en el teléfono puede ser algo que todavía no subiste.

import 'dart:io';

import 'package:financial_strategist_local/data/bundle.dart';
import 'package:financial_strategist_local/data/bundle_import.dart';
import 'package:financial_strategist_local/local_api/current_user.dart';
import 'package:financial_strategist_local/local_db/database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import '../test_support.dart';

void main() {
  late Directory tmp;
  late Database db;

  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(inicializarMotorDePrueba);

  setUp(() async {
    tmp = await prepararDirectorioTemporal('paquete_web_test');
    db = await LocalDatabase.open();
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<Map<String, dynamic>> paqueteCon(Map<String, List<Map<String, dynamic>>> tablas) async => {
    'formato': formatoDelPaquete,
    'version': versionDelPaquete,
    'generadoEl': DateTime.now().toUtc().toIso8601String(),
    'userId': await currentUserId(db),
    'tablas': {for (final t in tablasDelPaquete) t: tablas[t] ?? const []},
  };

  Future<int> cuantosMovimientos() async =>
      Sqflite.firstIntValue(await db.rawQuery('SELECT count(*) FROM "Transaction"')) ?? 0;

  Future<Map<String, Object?>> unMovimiento() async =>
      (await db.query('Transaction', limit: 1)).first;

  test('un movimiento que solo está en la web entra', () async {
    final cuenta = (await db.query('Account', limit: 1)).first;
    final antes = await cuantosMovimientos();
    final paquete = await paqueteCon({
      'Transaction': [
        {
          'id': 'solo-en-la-web',
          'accountId': cuenta['id'],
          'type': 'EXPENSE',
          'kind': 'MOVEMENT',
          'amount': 33.5,
          'detail': 'Registrado en la web',
          'occurredAt': '2026-09-11T15:00:00.000Z',
          'createdAt': '2026-09-11T15:00:00.000Z',
        },
      ],
    });

    final ensayo = await aplicarPaqueteDeLaWeb(db, paquete, ensayo: true);
    expect(ensayo.nuevas, 1);
    expect(ensayo.aplicado, isFalse);
    expect(await cuantosMovimientos(), antes, reason: 'el ensayo no escribe');

    final hecho = await aplicarPaqueteDeLaWeb(db, paquete, ensayo: false);
    expect(hecho.aplicado, isTrue);
    expect(await cuantosMovimientos(), antes + 1);

    final guardado = (await db.query(
      'Transaction',
      where: 'id = ?',
      whereArgs: ['solo-en-la-web'],
    )).first;
    expect(guardado['detail'], 'Registrado en la web');
    // La fecha llegó en ISO y tiene que quedar guardada como milisegundos, o el
    // registro aparecería en 1970.
    expect(
      DateTime.fromMillisecondsSinceEpoch(guardado['occurredAt']! as int, isUtc: true).year,
      2026,
    );
  });

  test('una corrección hecha en la web pisa lo que hay acá', () async {
    final mio = await unMovimiento();
    final paquete = await paqueteCon({
      'Transaction': [
        {...mio, 'amount': 999.99, 'occurredAt': '2026-09-11T15:00:00.000Z'},
      ],
    });

    final informe = await aplicarPaqueteDeLaWeb(db, paquete, ensayo: false);
    expect(informe.actualizadas, 1);

    final despues = (await db.query('Transaction', where: 'id = ?', whereArgs: [mio['id']])).first;
    expect((despues['amount']! as num).toDouble(), 999.99);
  });

  test('lo que está solo en el teléfono se cuenta pero no se borra', () async {
    final antes = await cuantosMovimientos();
    expect(antes, greaterThan(0));

    // Un paquete sin movimientos: la web "no tiene" ninguno.
    final informe = await aplicarPaqueteDeLaWeb(db, await paqueteCon({}), ensayo: false);

    final deMovimientos = informe.porTabla.firstWhere((t) => t.tabla == 'Transaction');
    expect(deMovimientos.soloEnElTelefono, antes);
    expect(await cuantosMovimientos(), antes, reason: 'no se borra nada');
    expect(informe.avisos, isNotEmpty);
  });

  test('el catálogo del sistema no cuenta como "solo en el teléfono"', () async {
    // Con un paquete vacío, todo lo de acá queda "solo en el teléfono"… salvo lo
    // que el paquete no manda por diseño. Las categorías del sistema viven igual
    // en las dos bases, con los mismos ids: contarlas daba un aviso falso de
    // cien y pico filas en cada importación, y un aviso que siempre grita deja
    // de leerse.
    final informe = await aplicarPaqueteDeLaWeb(db, await paqueteCon({}), ensayo: true);
    final categorias = informe.porTabla.firstWhere((t) => t.tabla == 'Category');

    final delSistema =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT count(*) FROM Category WHERE isSystem = 1'),
        ) ??
        0;
    final propias =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT count(*) FROM Category WHERE isSystem = 0'),
        ) ??
        0;

    expect(delSistema, greaterThan(0), reason: 'la semilla trae el catálogo');
    expect(categorias.soloEnElTelefono, propias, reason: 'solo las tuyas se cuentan');
  });

  test('el saldo de la cuenta llega hecho, no se recalcula', () async {
    final cuenta = (await db.query('Account', limit: 1)).first;
    final paquete = await paqueteCon({
      'Account': [
        {...cuenta, 'currentBalance': 4321.0},
      ],
    });

    await aplicarPaqueteDeLaWeb(db, paquete, ensayo: false);

    final despues = (await db.query('Account', where: 'id = ?', whereArgs: [cuenta['id']])).first;
    expect((despues['currentBalance']! as num).toDouble(), 4321.0);
  });

  test('traerlo dos veces no cambia nada la segunda', () async {
    final cuenta = (await db.query('Account', limit: 1)).first;
    final paquete = await paqueteCon({
      'Transaction': [
        {
          'id': 'dos-veces',
          'accountId': cuenta['id'],
          'type': 'INCOME',
          'kind': 'MOVEMENT',
          'amount': 10,
          'detail': 'Dos veces',
          'occurredAt': '2026-09-11T15:00:00.000Z',
          'createdAt': '2026-09-11T15:00:00.000Z',
        },
      ],
    });

    final primera = await aplicarPaqueteDeLaWeb(db, paquete, ensayo: false);
    expect(primera.nuevas, 1);

    final segunda = await aplicarPaqueteDeLaWeb(db, paquete, ensayo: false);
    expect(segunda.nuevas, 0);
    expect(segunda.actualizadas, 0, reason: 'ni siquiera se reescribe: es idéntica');
  });

  test('un paquete de otra cuenta, o de otro formato, se rechaza', () async {
    final ajeno = await paqueteCon({});
    ajeno['userId'] = 'otra-persona';
    await expectLater(
      aplicarPaqueteDeLaWeb(db, ajeno, ensayo: true),
      throwsA(isA<PaqueteInvalido>()),
    );

    await expectLater(
      aplicarPaqueteDeLaWeb(db, {'formato': 'otra-cosa'}, ensayo: true),
      throwsA(isA<PaqueteInvalido>()),
    );
  });

  test('las columnas que esta base no tiene se descartan en vez de reventar', () async {
    final cuenta = (await db.query('Account', limit: 1)).first;
    final paquete = await paqueteCon({
      'Transaction': [
        {
          'id': 'con-columna-rara',
          'accountId': cuenta['id'],
          'type': 'EXPENSE',
          'kind': 'MOVEMENT',
          'amount': 5,
          'occurredAt': '2026-09-11T15:00:00.000Z',
          'createdAt': '2026-09-11T15:00:00.000Z',
          'columnaDeOtraEpoca': 'x',
        },
      ],
    });

    await aplicarPaqueteDeLaWeb(db, paquete, ensayo: false);

    final guardado = await db.query(
      'Transaction',
      where: 'id = ?',
      whereArgs: ['con-columna-rara'],
    );
    expect(guardado, hasLength(1));
  });
}
