// Marcar un flujo fijo en una cuenta distinta de la que tiene declarada.
//
// El motor lo aceptaba desde siempre y ninguna pantalla se lo mandaba, así que
// nunca se había comprobado que de verdad funcionara de punta a punta: que el
// movimiento caiga en la cuenta elegida y que sea **esa** la que mueve el saldo.

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
    tmp = await prepararDirectorioTemporal('otra_cuenta_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<List<Map<String, dynamic>>> cuentas() async =>
      (await api.get('/accounts') as List).cast<Map<String, dynamic>>();

  double saldo(List<Map<String, dynamic>> lista, String id) =>
      (lista.firstWhere((c) => c['id'] == id)['currentBalance'] as num).toDouble();

  test('hay más de una cuenta donde elegir', () async {
    // Si esto falla, el selector no tiene por qué aparecer y el resto del test
    // no probaría nada: se dice acá en vez de dejarlo implícito.
    expect((await cuentas()).length, greaterThan(1));
  });

  test('el cobro cae en la cuenta elegida, no en la declarada del flujo', () async {
    final lista = await cuentas();
    final declarada = lista.first;
    final elegida = lista.last;

    final flujo =
        await api.post('/recurring-flows', {
              'name': 'Sueldo con cuenta declarada',
              'type': 'INCOME',
              'amount': 700,
              'frequency': 'MONTHLY',
              'startDate': '2026-03-01',
              'nextDueDate': '2026-03-05',
              'accountId': declarada['id'],
            })
            as Map<String, dynamic>;

    final antes = await cuentas();
    final r =
        await api.post('/recurring-flows/${flujo['id']}/pay', {
              'month': '2026-03',
              'amount': 700,
              'accountId': elegida['id'],
            })
            as Map<String, dynamic>;

    expect(r['transactionId'], isNotNull);

    // Y es esa la que se mueve: si el saldo lo cargara la declarada, la plata
    // aparecería donde nunca entró.
    final despues = await cuentas();
    expect(saldo(despues, elegida['id']), closeTo(saldo(antes, elegida['id']) + 700, 0.01));
    expect(saldo(despues, declarada['id']), closeTo(saldo(antes, declarada['id']), 0.01));
  });

  test('una cuenta oculta se lleva la plata fuera del patrimonio', () async {
    // No es un fallo: una cuenta oculta es una que dijiste que no se cuente. Pero
    // hay que decirlo al elegirla — marcar el sueldo ahí sube su saldo y deja el
    // patrimonio igual, y sin aviso eso se lee como que la app perdió la plata.
    final ocultas = (await cuentas()).where((c) => c['isHidden'] == true).toList();
    if (ocultas.isEmpty) return;
    final oculta = ocultas.first;

    final flujo =
        await api.post('/recurring-flows', {
              'name': 'Sueldo a cuenta oculta',
              'type': 'INCOME',
              'amount': 300,
              'frequency': 'MONTHLY',
              'startDate': '2026-03-01',
              'nextDueDate': '2026-03-05',
              'accountId': oculta['id'],
            })
            as Map<String, dynamic>;

    final patrimonioAntes =
        ((await api.get('/financial-engine/cash-position') as Map)['total'] as num).toDouble();
    final antes = await cuentas();

    await api.post('/recurring-flows/${flujo['id']}/pay', {
      'month': '2026-03',
      'amount': 300,
      'accountId': oculta['id'],
    });

    // El saldo de la cuenta sube...
    expect(saldo(await cuentas(), oculta['id']), closeTo(saldo(antes, oculta['id']) + 300, 0.01));
    // ...y el patrimonio no se entera, porque esa cuenta no cuenta.
    expect(
      ((await api.get('/financial-engine/cash-position') as Map)['total'] as num).toDouble(),
      closeTo(patrimonioAntes, 0.01),
    );
  });
}
