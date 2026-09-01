// A qué cuenta fue cada movimiento, y que el saldo lo siga.
//
// Elegir la cuenta al registrar no sirve de nada si después ninguna pantalla
// puede decir a dónde fue la plata: había que abrir el editor para comprobarlo.

import 'dart:io';

import 'package:financial_strategist_local/data/api.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_support.dart';

void main() {
  late Directory tmp;
  late ApiClient api;

  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(inicializarMotorDePrueba);

  setUp(() async {
    tmp = await prepararDirectorioTemporal('cuenta_mov_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<List<Map<String, dynamic>>> cuentas() async =>
      (await api.get('/accounts') as List).cast<Map<String, dynamic>>();

  test('el movimiento vuelve diciendo en qué cuenta cayó', () async {
    final destino = (await cuentas()).last;

    final creado =
        await api.post('/transactions', {
              'accountId': destino['id'],
              'type': 'EXPENSE',
              'amount': 12.5,
              'occurredAt': DateTime.now().toUtc().toIso8601String(),
            })
            as Map<String, dynamic>;

    expect(creado['accountId'], destino['id']);
    // El nombre viaja con el movimiento: sin esto, una lista solo tiene un id y
    // no puede decir nada útil sin ir a buscarlo por su cuenta.
    expect((creado['account'] as Map)['name'], destino['name']);
  });

  test('la lista trae la cuenta de cada fila', () async {
    final items = ((await api.get('/transactions?take=20') as Map)['items'] as List)
        .cast<Map<String, dynamic>>();
    expect(items, isNotEmpty);
    for (final t in items) {
      expect((t['account'] as Map?)?['name'], isNotNull, reason: 'la fila ${t['id']}');
    }
  });

  test('el saldo de esa cuenta baja, y el de la otra no se mueve', () async {
    final antes = await cuentas();
    final destino = antes.last;
    final otra = antes.first;

    await api.post('/transactions', {
      'accountId': destino['id'],
      'type': 'EXPENSE',
      'amount': 30,
      'occurredAt': DateTime.now().toUtc().toIso8601String(),
    });

    final despues = await cuentas();
    double saldo(List<Map<String, dynamic>> lista, String id) =>
        (lista.firstWhere((c) => c['id'] == id)['currentBalance'] as num).toDouble();

    expect(saldo(despues, destino['id']), closeTo(saldo(antes, destino['id']) - 30, 0.01));
    expect(saldo(despues, otra['id']), closeTo(saldo(antes, otra['id']), 0.01));
  });

  test('mover el movimiento de cuenta arrastra el saldo con él', () async {
    final antes = await cuentas();
    final origen = antes.first;
    final destino = antes.last;

    final creado =
        await api.post('/transactions', {
              'accountId': origen['id'],
              'type': 'EXPENSE',
              'amount': 40,
              'occurredAt': DateTime.now().toUtc().toIso8601String(),
            })
            as Map<String, dynamic>;

    await api.patch('/transactions/${creado['id']}', {'accountId': destino['id']});

    final despues = await cuentas();
    double saldo(List<Map<String, dynamic>> lista, String id) =>
        (lista.firstWhere((c) => c['id'] == id)['currentBalance'] as num).toDouble();

    // La de origen queda como si nunca hubiera pasado, y la de destino carga con
    // el gasto entero: si solo se descontara del nuevo, el dinero se duplicaría.
    expect(saldo(despues, origen['id']), closeTo(saldo(antes, origen['id']), 0.01));
    expect(saldo(despues, destino['id']), closeTo(saldo(antes, destino['id']) - 40, 0.01));
  });
}
