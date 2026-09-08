// Una tarjeta de crédito de uso diario: la que pagas entera cada mes y no es un
// préstamo con tasa, cuota mínima ni plazo.
//
// Se modela como una cuenta `CREDIT_CARD` **sin deuda asociada**. Comprar sube
// lo que debes y no toca el patrimonio; pagar el estado de cuenta es una
// transferencia que baja el efectivo y baja la tarjeta, sin volver a contar el
// gasto.
//
// Los signos son lo que este test protege: en una cuenta de crédito el saldo es
// lo que debes, así que un cargo lo **sube**. Con la regla de las cuentas
// líquidas, comprar reduciría la deuda y pagar la subiría — y nada avisaría.

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
    tmp = await prepararDirectorioTemporal('tarjeta_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<Map<String, dynamic>> crearTarjeta() async =>
      await api.post('/accounts', {
            'name': 'CMR del día a día',
            'type': 'CREDIT_CARD',
            'currentBalance': 0,
            'currency': 'PEN',
          })
          as Map<String, dynamic>;

  Future<double> saldoDe(String id) async =>
      ((await api.get('/accounts') as List)
                  .cast<Map<String, dynamic>>()
                  .firstWhere((c) => c['id'] == id)['currentBalance']
              as num)
          .toDouble();

  Future<double> patrimonio() async =>
      ((await api.get('/financial-engine/cash-position') as Map)['total'] as num).toDouble();

  test('la tarjeta sin deuda sí aparece en las cuentas', () async {
    final tarjeta = await crearTarjeta();
    final ids = (await api.get('/accounts') as List).map((c) => (c as Map)['id']);
    // Antes se excluía por tipo y no había forma de tenerla: no salía en ningún
    // selector.
    expect(ids, contains(tarjeta['id']));
  });

  test('comprar sube lo que debes y no mueve el patrimonio', () async {
    final tarjeta = await crearTarjeta();
    final antes = await patrimonio();

    await api.post('/transactions', {
      'accountId': tarjeta['id'],
      'type': 'EXPENSE',
      'amount': 120,
      'occurredAt': DateTime.now().toUtc().toIso8601String(),
    });

    expect(await saldoDe(tarjeta['id']), closeTo(120, 0.01), reason: 'debes 120');
    expect(await patrimonio(), closeTo(antes, 0.01), reason: 'no salió efectivo');
  });

  test('el cargo cuenta como gasto igual', () async {
    // No tocar el patrimonio no es no haber gastado: el almuerzo se comió.
    final tarjeta = await crearTarjeta();
    final antes =
        (((await api.get('/transactions?take=1') as Map)['totals'] as Map)['expense'] as num)
            .toDouble();

    await api.post('/transactions', {
      'accountId': tarjeta['id'],
      'type': 'EXPENSE',
      'amount': 80,
      'occurredAt': DateTime.now().toUtc().toIso8601String(),
    });

    final despues =
        (((await api.get('/transactions?take=1') as Map)['totals'] as Map)['expense'] as num)
            .toDouble();
    expect(despues, closeTo(antes + 80, 0.01));
  });

  test('pagar el estado de cuenta baja las dos y no cuenta como gasto nuevo', () async {
    final tarjeta = await crearTarjeta();
    final liquida = (await api.get('/accounts') as List).cast<Map<String, dynamic>>().firstWhere(
      (c) => c['type'] == 'CHECKING',
    );

    await api.post('/transactions', {
      'accountId': tarjeta['id'],
      'type': 'EXPENSE',
      'amount': 200,
      'occurredAt': DateTime.now().toUtc().toIso8601String(),
    });
    final efectivoAntes = await saldoDe(liquida['id']);
    final gastoAntes =
        (((await api.get('/transactions?take=1') as Map)['totals'] as Map)['expense'] as num)
            .toDouble();

    await api.post('/transactions/transfer', {
      'fromAccountId': liquida['id'],
      'toAccountId': tarjeta['id'],
      'amount': 200,
      'occurredAt': DateTime.now().toUtc().toIso8601String(),
    });

    expect(await saldoDe(tarjeta['id']), closeTo(0, 0.01), reason: 'ya no debes nada');
    expect(await saldoDe(liquida['id']), closeTo(efectivoAntes - 200, 0.01));
    // Y el gasto no se cuenta dos veces: la transferencia no es un gasto.
    final gastoDespues =
        (((await api.get('/transactions?take=1') as Map)['totals'] as Map)['expense'] as num)
            .toDouble();
    expect(gastoDespues, closeTo(gastoAntes, 0.01));
  });

  test('borrar el cargo deshace exactamente lo que hizo', () async {
    final tarjeta = await crearTarjeta();
    final creado =
        await api.post('/transactions', {
              'accountId': tarjeta['id'],
              'type': 'EXPENSE',
              'amount': 55,
              'occurredAt': DateTime.now().toUtc().toIso8601String(),
            })
            as Map<String, dynamic>;

    expect(await saldoDe(tarjeta['id']), closeTo(55, 0.01));
    await api.delete('/transactions/${creado['id']}');
    expect(await saldoDe(tarjeta['id']), closeTo(0, 0.01));
  });
}
