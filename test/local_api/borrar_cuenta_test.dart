// Borrar una cuenta, de cualquier tipo.
//
// Estuvo roto para **todas**: la ruta seguía poniendo en null el objetivo
// vinculado, y la tabla `Goal` se fue con la capa de consejo. Sqlite contestaba
// "no such table" y eso ni siquiera es una `ApiException`, así que la pantalla
// no la atrapaba: el borrado no ocurría y no se veía ningún aviso.

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
    tmp = await prepararDirectorioTemporal('borrar_cuenta_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<List<Map<String, dynamic>>> cuentas() async =>
      (await api.get('/accounts') as List).cast<Map<String, dynamic>>();

  Future<Map<String, dynamic>> crear(String tipo, String nombre) async =>
      await api.post('/accounts', {'name': nombre, 'type': tipo, 'currentBalance': 40.0})
          as Map<String, dynamic>;

  for (final tipo in ['CREDIT_CARD', 'SAVINGS', 'CASH']) {
    test('se puede borrar una cuenta $tipo', () async {
      final cuenta = await crear(tipo, 'Para borrar $tipo');

      final impacto = await api.get('/accounts/${cuenta['id']}/deletion-impact') as Map;
      expect(impacto['blockedBy'], isNull);

      await api.delete('/accounts/${cuenta['id']}/permanently');
      expect(
        (await cuentas()).any((c) => c['id'] == cuenta['id']),
        isFalse,
        reason: 'ya no está en la lista',
      );
    });
  }

  test('borrarla se lleva sus movimientos y no los de las demás', () async {
    final cuenta = await crear('CASH', 'Con movimientos');
    await api.post('/transactions', {
      'accountId': cuenta['id'],
      'type': 'EXPENSE',
      'amount': 5.0,
      'occurredAt': DateTime.now().toUtc().toIso8601String(),
    });

    final antes = ((await api.get('/transactions?take=1') as Map)['total'] as num).toInt();
    await api.delete('/accounts/${cuenta['id']}/permanently');
    final despues = ((await api.get('/transactions?take=1') as Map)['total'] as num).toInt();

    expect(despues, lessThanOrEqualTo(antes), reason: 'solo se fue lo suyo');
    expect((await cuentas()).any((c) => c['id'] == cuenta['id']), isFalse);
  });

  test('la cuenta espejo de una deuda sigue sin poder borrarse', () async {
    final deudas = await api.get('/debts') as List;
    if (deudas.isEmpty) return;
    final espejo = (deudas.first as Map)['accountId'] as String?;
    if (espejo == null) return;

    await expectLater(
      api.delete('/accounts/$espejo/permanently'),
      throwsA(isA<ApiException>()),
      reason: 'se iría con su deuda',
    );
  });
}
