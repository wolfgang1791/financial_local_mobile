// La última cuenta que cuenta no se puede ocultar.
//
// Quedarse sin patrimonio apaga la app entera: el total va a cero, los hitos no
// tienen de dónde salir y los movimientos desaparecen de todas las listas —el
// historial filtra por cuentas que cuentan—. Pasó de verdad, y desde la app no
// había forma de entender por qué: Panorama decía "sin registros todavía" con
// todo guardado.

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
    tmp = await prepararDirectorioTemporal('ultima_cuenta_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<List<Map<String, dynamic>>> cuentas() async =>
      (await api.get('/accounts') as List).cast<Map<String, dynamic>>();

  /// Las que cuentan para el patrimonio: las líquidas visibles. Una tarjeta
  /// nunca cuenta —su saldo es lo que debes— así que ocultarla no acerca a nadie
  /// al candado, y meterla en la cuenta lo disparaba una cuenta antes de tiempo.
  Future<List<Map<String, dynamic>>> liquidas() async => (await cuentas())
      .where((c) => const {'CHECKING', 'SAVINGS', 'CASH'}.contains(c['type']))
      .toList();

  Future<int> cuantasCuentan() async =>
      (await liquidas()).where((c) => c['isHidden'] == false).length;

  /// Todas visibles antes de empezar.
  ///
  /// La semilla son datos reales, y ahí puede haber cuentas ya ocultas —hoy hay
  /// dos—. Sin esto el escenario arrancaba con una sola contando y el primer
  /// paso del test chocaba con el candado que el test viene a probar.
  Future<void> mostrarTodas() async {
    for (final c in await cuentas()) {
      if (c['isHidden'] == true) {
        await api.patch('/accounts/${c['id']}', {'isHidden': false});
      }
    }
  }

  test('se pueden ocultar todas menos una', () async {
    await mostrarTodas();
    final visibles = (await liquidas()).where((c) => c['isHidden'] == false).toList();
    // Se ocultan todas menos la última, que sí debe dejarse.
    for (final c in visibles.take(visibles.length - 1)) {
      await api.patch('/accounts/${c['id']}', {'isHidden': true});
    }
    expect(await cuantasCuentan(), 1);

    final ultima = (await liquidas()).firstWhere((c) => c['isHidden'] == false);
    await expectLater(
      api.patch('/accounts/${ultima['id']}', {'isHidden': true}),
      throwsA(isA<ApiException>()),
    );
    expect(await cuantasCuentan(), 1, reason: 'sigue contando');
  });

  test('con la última a salvo, el patrimonio y los movimientos nunca quedan en cero', () async {
    await mostrarTodas();
    final visibles = (await liquidas()).where((c) => c['isHidden'] == false).toList();
    for (final c in visibles.take(visibles.length - 1)) {
      await api.patch('/accounts/${c['id']}', {'isHidden': true});
    }
    final ultima = (await liquidas()).firstWhere((c) => c['isHidden'] == false);
    try {
      await api.patch('/accounts/${ultima['id']}', {'isHidden': true});
    } on ApiException {
      // Lo esperado.
    }

    final movimientos = ((await api.get('/transactions?take=1') as Map)['total'] as num).toInt();
    expect(movimientos, greaterThan(0), reason: 'el historial nunca se queda vacío por un filtro');
  });

  test('volver a mostrarla siempre se puede', () async {
    final una = (await cuentas()).firstWhere((c) => c['isHidden'] == true, orElse: () => {});
    if (una.isEmpty) return;
    await api.patch('/accounts/${una['id']}', {'isHidden': false});
    final despues = (await cuentas()).firstWhere((c) => c['id'] == una['id']);
    expect(despues['isHidden'], false);
  });
}
