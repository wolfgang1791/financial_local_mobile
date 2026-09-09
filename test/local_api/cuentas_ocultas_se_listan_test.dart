// "Transferir" no puede depender de cuántas cuentas estás contando.
//
// La pastilla aparece cuando hay dos cuentas donde tener plata, y la lista de
// cuentas dejaba fuera las ocultas: con dos de tres apagadas quedaba una sola y
// la opción desaparecía de la pantalla, como si la app hubiera perdido las
// transferencias. Ocultar una cuenta es "no la sumes a mi patrimonio", no "ya no
// existe".

import 'dart:io';

import 'package:financial_strategist_local/data/api.dart';
import 'package:financial_strategist_local/data/models.dart';
import 'package:financial_strategist_local/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_support.dart';

void main() {
  late Directory tmp;

  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(inicializarMotorDePrueba);

  setUp(() async {
    tmp = await prepararDirectorioTemporal('transferir_ocultas_test');
  });

  tearDown(() => tmp.delete(recursive: true));

  test('ocultar cuentas no las saca de la lista con la que se registra', () async {
    final api = ApiClient();
    // Se apagan todas las líquidas menos una: el estado en el que la pastilla de
    // "Transferir" había desaparecido —hacen falta dos cuentas—.
    final cuentas = (await api.get('/accounts') as List).cast<Map<String, dynamic>>();
    final liquidas = cuentas
        .where((c) => const {'CHECKING', 'SAVINGS', 'CASH'}.contains(c['type']))
        .toList();
    expect(liquidas.length, greaterThanOrEqualTo(2));
    for (final c in liquidas.skip(1)) {
      if (c['isHidden'] != true) {
        await api.patch('/accounts/${c['id']}', {'isHidden': true});
      }
    }

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final lista = await container.read(accountsProvider.future);

    expect(
      lista.where((c) => c.isHidden).length,
      greaterThanOrEqualTo(1),
      reason: 'las apagadas siguen ofreciéndose, con su aviso',
    );
    expect(
      lista.where((c) => !c.esDeCredito).length,
      greaterThanOrEqualTo(2),
      reason: 'con dos donde tener plata, transferir sigue siendo posible',
    );
  });

  test('la cuenta que se propone sola sigue siendo una que cuenta', () {
    const lista = [
      Account(
        id: 'a',
        name: 'Ahorros apagados',
        type: 'SAVINGS',
        currency: 'PEN',
        balance: 900,
        isHidden: true,
      ),
      Account(
        id: 'b',
        name: 'Corriente',
        type: 'CHECKING',
        currency: 'PEN',
        balance: 20,
        isHidden: false,
      ),
    ];
    expect(
      cuentaPorDefecto(lista)?.id,
      'b',
      reason: 'ofrecerla en la lista no es empezar cada movimiento fuera del patrimonio',
    );
  });
}
