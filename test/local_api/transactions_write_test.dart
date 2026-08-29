// Fase 3 — escritura de movimientos. Acá no se compara contra el backend
// real (escribir contra esa base sería mutar datos de verdad); se verifica
// la propiedad que sí importa: el saldo de la cuenta queda exactamente
// donde la aritmética dice que tiene que quedar, antes y después de cada
// operación.

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
    tmp = await prepararDirectorioTemporal('financial_strategist_local_tx_write_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<String> cuentaPrincipalId() async {
    final cuentas = await api.get('/accounts') as List;
    return cuentas.firstWhere((c) => c['name'] == 'Cuenta principal')['id'] as String;
  }

  Future<double> saldoDe(String accountId) async {
    final cuentas = await api.get('/accounts') as List;
    return (cuentas.firstWhere((c) => c['id'] == accountId)['currentBalance'] as num).toDouble();
  }

  test('crear un gasto baja el saldo de la cuenta exactamente por el monto', () async {
    final cuentaId = await cuentaPrincipalId();
    final antes = await saldoDe(cuentaId);

    final creada =
        await api.post('/transactions', {
              'accountId': cuentaId,
              'type': 'EXPENSE',
              'amount': 25.5,
              'occurredAt': '2026-08-10',
              'detail': 'Test gasto',
            })
            as Map;

    final despues = await saldoDe(cuentaId);
    expect(despues, closeTo(antes - 25.5, 0.001));
    expect(creada['type'], 'EXPENSE');
    expect(creada['kind'], 'MOVEMENT');
    expect((creada['amount'] as num).toDouble(), 25.5);
  });

  test('crear un ingreso sube el saldo, editarlo a otro monto ajusta el delta', () async {
    final cuentaId = await cuentaPrincipalId();
    final antes = await saldoDe(cuentaId);

    final creada =
        await api.post('/transactions', {
              'accountId': cuentaId,
              'type': 'INCOME',
              'amount': 100,
              'occurredAt': '2026-08-10',
            })
            as Map;
    expect(await saldoDe(cuentaId), closeTo(antes + 100, 0.001));

    await api.patch('/transactions/${creada['id']}', {'amount': 150});
    // 100 se deshace, 150 se aplica: delta neto +50 sobre el saldo original.
    expect(await saldoDe(cuentaId), closeTo(antes + 150, 0.001));

    await api.delete('/transactions/${creada['id']}');
    expect(await saldoDe(cuentaId), closeTo(antes, 0.001));
  });

  test('el medio de pago va y vuelve, y se puede dejar en blanco', () async {
    final cuentaId = await cuentaPrincipalId();

    final creada =
        await api.post('/transactions', {
              'accountId': cuentaId,
              'type': 'EXPENSE',
              'amount': 12,
              'occurredAt': '2026-08-10',
              'paymentMethod': 'YAPE',
            })
            as Map;
    expect(creada['paymentMethod'], 'YAPE');

    // Que se relea desde la lista y no solo de la respuesta de creación: lo que
    // se guardó en la columna es lo que van a mostrar las filas.
    final lista = await api.get('/transactions?take=1000') as Map;
    final leida = (lista['items'] as List).firstWhere((t) => t['id'] == creada['id']);
    expect(leida['paymentMethod'], 'YAPE');

    await api.patch('/transactions/${creada['id']}', {'paymentMethod': 'CASH'});
    final trasEditar = await api.get('/transactions?take=1000') as Map;
    expect(
      (trasEditar['items'] as List).firstWhere((t) => t['id'] == creada['id'])['paymentMethod'],
      'CASH',
    );

    // `null` explícito y no campo ausente: es lo que manda el editor cuando se
    // elige "Sin especificar", y tiene que borrar el dato en vez de dejarlo
    // como estaba.
    await api.patch('/transactions/${creada['id']}', {'paymentMethod': null});
    final trasBorrar = await api.get('/transactions?take=1000') as Map;
    expect(
      (trasBorrar['items'] as List).firstWhere((t) => t['id'] == creada['id'])['paymentMethod'],
      isNull,
    );
  });

  test(
    'una transferencia mueve el mismo monto entre las dos cuentas y borrar deshace las dos patas',
    () async {
      final cuentas = await api.get('/accounts') as List;
      final origen = cuentas.firstWhere((c) => c['name'] == 'Cuenta principal');
      // Crea una segunda cuenta en la misma moneda para no chocar con la
      // validación de "no se puede transferir entre monedas distintas".
      final destino =
          await api.post('/accounts', {
                'name': 'Cuenta de prueba',
                'type': 'SAVINGS',
                'currentBalance': 0,
                'currency': origen['currency'],
                'openedAt': '2026-08-01',
              })
              as Map;

      final antesOrigen = await saldoDe(origen['id'] as String);

      final resultado =
          await api.post('/transactions/transfer', {
                'fromAccountId': origen['id'],
                'toAccountId': destino['id'],
                'amount': 40,
                'occurredAt': '2026-08-10',
              })
              as Map;

      expect(await saldoDe(origen['id'] as String), closeTo(antesOrigen - 40, 0.001));
      expect(await saldoDe(destino['id'] as String), closeTo(40, 0.001));

      final movimientos = await api.get('/transactions?take=1000&kind=TRANSFER') as Map;
      final patas = (movimientos['items'] as List)
          .where((t) => t['transferId'] == resultado['transferId'])
          .toList();
      expect(patas.length, 2);

      await api.delete('/transactions/${patas[0]['id']}');
      expect(await saldoDe(origen['id'] as String), closeTo(antesOrigen, 0.001));
      expect(await saldoDe(destino['id'] as String), closeTo(0, 0.001));
    },
  );
}
