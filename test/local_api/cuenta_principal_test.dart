// La cuenta principal: la que los formularios proponen solos al preguntar de
// dónde salió la plata.
//
// Lo que se prueba acá es que sea **una**. Si encender una no apaga la anterior,
// "la principal" pasa a depender del orden en que salgan las filas de la base, y
// el formulario propone una cosa distinta cada vez sin que nadie haya cambiado
// nada.

import 'dart:io';

import 'package:financial_strategist_local/data/api.dart';
import 'package:financial_strategist_local/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_support.dart';

void main() {
  late Directory tmp;
  late ApiClient api;

  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(inicializarMotorDePrueba);

  setUp(() async {
    tmp = await prepararDirectorioTemporal('cuenta_principal_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<List<Map<String, dynamic>>> cuentas() async =>
      (await api.get('/accounts') as List).cast<Map<String, dynamic>>();

  Future<List<Map<String, dynamic>>> liquidas() async => (await cuentas())
      .where((c) => const {'CHECKING', 'SAVINGS', 'CASH'}.contains(c['type']))
      .toList();

  test('solo una cuenta es la principal a la vez', () async {
    final lista = await liquidas();
    expect(lista.length, greaterThanOrEqualTo(2), reason: 'la base sembrada tiene varias');

    await api.patch('/accounts/${lista[0]['id']}', {'isPrimary': true});
    await api.patch('/accounts/${lista[1]['id']}', {'isPrimary': true});

    final despues = await cuentas();
    final principales = despues.where((c) => c['isPrimary'] == true).toList();
    expect(principales.length, 1);
    expect(principales.single['id'], lista[1]['id'], reason: 'la última que se eligió');
  });

  test('una tarjeta de crédito no puede ser la principal', () async {
    final tarjeta = (await cuentas()).firstWhere(
      (c) => c['type'] == 'CREDIT_CARD',
      orElse: () => {},
    );
    if (tarjeta.isEmpty) {
      // Sin tarjetas en la base sembrada se crea una: la regla es sobre el tipo,
      // no sobre esta base en particular.
      final creada =
          await api.post('/accounts', {
                'name': 'Tarjeta de prueba',
                'type': 'CREDIT_CARD',
                'currentBalance': 0,
              })
              as Map<String, dynamic>;
      await expectLater(
        api.patch('/accounts/${creada['id']}', {'isPrimary': true}),
        throwsA(isA<ApiException>()),
      );
      return;
    }
    await expectLater(
      api.patch('/accounts/${tarjeta['id']}', {'isPrimary': true}),
      throwsA(isA<ApiException>()),
    );
  });

  test('al ocultarla deja de ser la principal', () async {
    // Todas visibles primero: ocultar la última que cuenta está prohibido por
    // otra regla, y acá se prueba esta.
    for (final c in await liquidas()) {
      if (c['isHidden'] == true) {
        await api.patch('/accounts/${c['id']}', {'isHidden': false});
      }
    }
    final lista = await liquidas();
    await api.patch('/accounts/${lista[0]['id']}', {'isPrimary': true});
    await api.patch('/accounts/${lista[0]['id']}', {'isHidden': true});

    final despues = (await cuentas()).firstWhere((c) => c['id'] == lista[0]['id']);
    expect(despues['isHidden'], true);
    expect(despues['isPrimary'], false, reason: 'no se propone una cuenta que no cuenta');
  });

  test('la posición de caja dice cuál es, para poder marcarla en la lista', () async {
    final lista = await liquidas();
    await api.patch('/accounts/${lista[1]['id']}', {'isPrimary': true});

    final posicion = CashPosition.fromJson(
      await api.get('/financial-engine/cash-position') as Map<String, dynamic>,
    );
    final principales = posicion.accounts.where((c) => c.isPrimary).toList();
    expect(principales.length, 1);
    expect(principales.single.id, lista[1]['id']);
  });

  test('sin ninguna elegida, se propone la primera cuenta corriente', () {
    const cuentasDePrueba = [
      Account(
        id: 'a',
        name: 'Efectivo',
        type: 'CASH',
        currency: 'PEN',
        balance: 10,
        isHidden: false,
      ),
      Account(
        id: 'b',
        name: 'Corriente',
        type: 'CHECKING',
        currency: 'PEN',
        balance: 20,
        isHidden: false,
      ),
      Account(
        id: 'c',
        name: 'Ahorros',
        type: 'SAVINGS',
        currency: 'PEN',
        balance: 30,
        isHidden: false,
        isPrimary: true,
      ),
    ];
    expect(cuentaPorDefecto(cuentasDePrueba)?.id, 'c', reason: 'manda la elegida');
    expect(
      cuentaPorDefecto(cuentasDePrueba.sublist(0, 2))?.id,
      'b',
      reason: 'sin elegida, la primera corriente',
    );
    expect(
      cuentaPorDefecto(const [
        Account(
          id: 'd',
          name: 'Tarjeta',
          type: 'CREDIT_CARD',
          currency: 'PEN',
          balance: 5,
          isHidden: false,
        ),
        Account(
          id: 'e',
          name: 'Billetera',
          type: 'CASH',
          currency: 'PEN',
          balance: 5,
          isHidden: false,
        ),
      ])?.id,
      'e',
      reason: 'nunca una tarjeta mientras haya de dónde sacar plata',
    );
  });
}
