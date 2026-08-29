// El diagnóstico mira la base de verdad y avisa de lo que ya rompió antes.
//
// Su razón de ser: la base sembrada del repositorio y la que usa la app no son
// la misma. Explicar algo que pasa en el teléfono mirando la de fábrica es
// mirar el sitio equivocado, y eso costó una vuelta entera.

import 'dart:io';

import 'package:financial_strategist_local/data/api.dart';
import 'package:financial_strategist_local/local_db/database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show databaseFactoryFfi;

import '../test_support.dart';

void main() {
  late Directory tmp;
  late ApiClient api;

  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(inicializarMotorDePrueba);

  setUp(() async {
    tmp = await prepararDirectorioTemporal('diagnostico_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  test('cuenta lo que hay y dice de dónde salió', () async {
    final d = await api.get('/diagnostico') as Map<String, dynamic>;

    expect((d['base'] as Map)['existe'], isTrue);
    // La ruta que informa es la que la app abre de verdad, no una escrita a
    // mano en otro sitio.
    expect((d['base'] as Map)['ruta'], await LocalDatabase.rutaDelArchivo());
    expect(((d['base'] as Map)['kb'] as num) > 0, isTrue);

    final tablas = (d['tablas'] as Map).cast<String, dynamic>();
    expect(tablas['Transaction'], greaterThan(0));
    expect(tablas['RecurringFlow'], greaterThan(0));

    final movimientos = (d['movimientos'] as Map).cast<String, dynamic>();
    expect(movimientos['primero'], isNotNull);
    expect(movimientos['ultimo'], isNotNull);
  });

  test('una base sana no inventa avisos', () async {
    final d = await api.get('/diagnostico') as Map<String, dynamic>;
    // La sembrada está limpia; si algún día deja de estarlo, este test lo dice
    // antes que el usuario.
    expect(d['avisos'], isEmpty);
  });

  test('un pago con fecha futura aparece como aviso', () async {
    final db = await LocalDatabase.open();
    final cuentas = await api.get('/accounts') as List;
    final flujos = await api.get('/recurring-flows') as List;

    await db.insert('"Transaction"', {
      'id': 'tx-adelantada',
      'accountId': (cuentas.first as Map)['id'],
      'recurringFlowId': (flujos.first as Map)['id'],
      'type': 'EXPENSE',
      'kind': 'MOVEMENT',
      'amount': 10,
      'occurredAt': DateTime.now().toUtc().add(const Duration(days: 30)).millisecondsSinceEpoch,
      'createdAt': DateTime.now().toUtc().millisecondsSinceEpoch,
    });

    final d = await api.get('/diagnostico') as Map<String, dynamic>;
    final avisos = (d['avisos'] as List).cast<Map<String, dynamic>>();
    expect(avisos, isNotEmpty);
    expect(avisos.any((a) => (a['que'] as String).contains('por delante del reloj')), isTrue);
    // Y el conteo lo respalda: el aviso no es una frase suelta.
    expect((d['movimientos'] as Map)['deGastosFijosEnElFuturo'], 1);
  });

  test('abre una tabla y devuelve sus filas, con las fechas legibles', () async {
    final d = await api.get('/diagnostico/tabla?nombre=Transaction&take=5') as Map<String, dynamic>;

    expect(d['tabla'], 'Transaction');
    expect(d['total'], greaterThan(0));
    final filas = (d['filas'] as List).cast<Map<String, dynamic>>();
    expect(filas.length, lessThanOrEqualTo(5));

    final primera = filas.first;
    expect(primera['id'], isA<String>());
    // Un diagnóstico que muestra 1756093200000 obliga a convertir a mano, que
    // es el trabajo que uno viene a evitar.
    expect(primera['occurredAt'], isA<String>());
    expect(DateTime.parse(primera['occurredAt'] as String), isA<DateTime>());
  });

  test('las más nuevas primero', () async {
    final filas =
        ((await api.get('/diagnostico/tabla?nombre=Transaction&take=10') as Map)['filas'] as List)
            .cast<Map<String, dynamic>>();
    final fechas = filas.map((f) => DateTime.parse(f['occurredAt'] as String)).toList();
    for (var i = 1; i < fechas.length; i++) {
      expect(fechas[i].isAfter(fechas[i - 1]), isFalse, reason: 'orden descendente');
    }
  });

  test('una tabla que no está en la lista blanca no se abre', () async {
    // El nombre entra en el SQL: aceptar cualquiera sería dejar la puerta
    // abierta a leer —o a romper— lo que no toca.
    await expectLater(api.get('/diagnostico/tabla?nombre=User'), throwsA(isA<ApiException>()));
    await expectLater(
      api.get('/diagnostico/tabla?nombre=Transaction; DROP TABLE Account'),
      throwsA(isA<ApiException>()),
    );
  });

  test('el tope de filas se acota', () async {
    final d =
        await api.get('/diagnostico/tabla?nombre=Category&take=99999') as Map<String, dynamic>;
    expect((d['take'] as int), lessThanOrEqualTo(200));
  });

  test('el dump entrega una base abrible y completa', () async {
    final r = await api.get('/diagnostico/dump') as Map<String, dynamic>;
    final copia = File(r['ruta'] as String);
    addTearDown(() async {
      if (await copia.exists()) await copia.delete();
    });

    expect(await copia.exists(), isTrue);
    expect(r['kb'] as int, greaterThan(0));
    expect(r['nombre'] as String, endsWith('.db'));

    // Y es una base de verdad, con los mismos movimientos que la original: una
    // copia del archivo abierto podría llegar sin lo último escrito, que es
    // justo lo que uno quiere que el otro vea.
    final abierta = await databaseFactoryFfi.openDatabase(copia.path);
    addTearDown(abierta.close);
    final enLaCopia = Sqflite.firstIntValue(
      await abierta.rawQuery('SELECT count(*) FROM "Transaction"'),
    );
    final original = (await api.get('/diagnostico') as Map)['tablas'] as Map;
    expect(enLaCopia, original['Transaction']);
  });
}
