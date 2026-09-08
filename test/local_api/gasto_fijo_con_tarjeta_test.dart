// Un gasto fijo pagado con la tarjeta de crédito.
//
// En una tarjeta el saldo es lo que **debes**, así que un gasto lo sube. Con el
// signo plano —el mismo que sirve para una cuenta de banco— marcar el fijo del
// mes bajaba la deuda, como si en vez de comprar con la tarjeta le hubieras
// abonado. Y revertirlo la subía.

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
    tmp = await prepararDirectorioTemporal('gasto_fijo_con_tarjeta_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<Map<String, dynamic>> cuenta(String id) async =>
      ((await api.get('/accounts') as List).cast<Map<String, dynamic>>()).firstWhere(
        (c) => c['id'] == id,
      );

  Future<double> patrimonio() async =>
      ((await api.get('/financial-engine/cash-position') as Map)['total'] as num).toDouble();

  test('marcarlo sube lo que debes, y revertirlo lo baja', () async {
    final tarjeta =
        await api.post('/accounts', {
              'name': 'Tarjeta del día a día',
              'type': 'CREDIT_CARD',
              'currentBalance': 200.0,
            })
            as Map<String, dynamic>;

    final flujo =
        await api.post('/recurring-flows', {
              'name': 'Suscripción con tarjeta',
              'type': 'EXPENSE',
              'amount': 50.0,
              'frequency': 'MONTHLY',
              'accountId': tarjeta['id'],
              'startDate': '${(await hoyDelUsuario()).substring(0, 7)}-01',
              'nextDueDate': '${(await hoyDelUsuario()).substring(0, 7)}-15',
            })
            as Map<String, dynamic>;

    final patrimonioAntes = await patrimonio();

    await api.post('/recurring-flows/${flujo['id']}/pay', {});
    expect(
      ((await cuenta(tarjeta['id'] as String))['currentBalance'] as num).toDouble(),
      250.0,
      reason: 'comprar con la tarjeta hace que debas más',
    );
    expect(
      await patrimonio(),
      patrimonioAntes,
      reason: 'una tarjeta no es plata tuya: el patrimonio no se mueve',
    );

    await api.post('/recurring-flows/${flujo['id']}/revert-payment', {});
    expect(
      ((await cuenta(tarjeta['id'] as String))['currentBalance'] as num).toDouble(),
      200.0,
      reason: 'revertir devuelve la deuda a donde estaba',
    );
    expect(await patrimonio(), patrimonioAntes);
  });

  test('corregir el monto del mes mueve la deuda por la diferencia', () async {
    final tarjeta =
        await api.post('/accounts', {
              'name': 'Otra tarjeta',
              'type': 'CREDIT_CARD',
              'currentBalance': 0.0,
            })
            as Map<String, dynamic>;
    final flujo =
        await api.post('/recurring-flows', {
              'name': 'Otra suscripción',
              'type': 'EXPENSE',
              'amount': 30.0,
              'frequency': 'MONTHLY',
              'accountId': tarjeta['id'],
              'startDate': '${(await hoyDelUsuario()).substring(0, 7)}-01',
              'nextDueDate': '${(await hoyDelUsuario()).substring(0, 7)}-10',
            })
            as Map<String, dynamic>;

    await api.post('/recurring-flows/${flujo['id']}/pay', {});
    await api.patch('/recurring-flows/${flujo['id']}/month', {
      'month': (await hoyDelUsuario()).substring(0, 7),
      'amount': 45.0,
    });

    expect(((await cuenta(tarjeta['id'] as String))['currentBalance'] as num).toDouble(), 45.0);
  });
}
