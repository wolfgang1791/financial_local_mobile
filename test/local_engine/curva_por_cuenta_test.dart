// El desglose por cuenta de la curva de patrimonio.
//
// Es lo que permite que la gráfica deje elegir qué cuentas dibuja **sin tocar
// nada**: filtrar por `isHidden` sacaría esa cuenta de toda la app, y mirar un
// gráfico no debería cambiarle los totales a nadie.

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
    tmp = await prepararDirectorioTemporal('curva_cuentas_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<List<Map<String, dynamic>>> curva() async =>
      (await api.get('/financial-engine/net-worth-daily') as List).cast<Map<String, dynamic>>();

  /// Las cuentas que la curva puede dibujar: las líquidas.
  ///
  /// El desglose por cuenta solo trae esas —lo que debes en una tarjeta no es
  /// patrimonio— así que buscar una tarjeta en él devolvía nulo. Es la misma
  /// regla que el filtro de cuentas del gráfico.
  Future<List<Map<String, dynamic>>> cuentas() async =>
      ((await api.get('/financial-engine/cash-position') as Map)['accounts'] as List)
          .cast<Map<String, dynamic>>()
          .where((c) => const {'CHECKING', 'SAVINGS', 'CASH'}.contains(c['type']))
          .toList();

  test('la suma de las cuentas que cuentan es exactamente el total del día', () async {
    final contadas = (await cuentas())
        .where((c) => c['isHidden'] != true)
        .map((c) => c['id'] as String)
        .toSet();

    for (final punto in await curva()) {
      final desglose = (punto['byAccount'] as Map).cast<String, dynamic>();
      final suma = desglose.entries
          .where((e) => contadas.contains(e.key))
          .fold<double>(0, (a, e) => a + (e.value as num).toDouble());
      expect(
        suma,
        closeTo((punto['liquid'] as num).toDouble(), 0.011),
        reason: 'el día ${punto['date']} no cuadra con su desglose',
      );
    }
  });

  test('las cuentas apagadas viajan en el desglose pero no en el total', () async {
    // Es la mitad de la gracia: poder sumarlas un momento en el gráfico para
    // ver cuánto habría con ellas, sin volver a contarlas en ningún total.
    final apagadas = (await cuentas()).where((c) => c['isHidden'] == true).toList();
    if (apagadas.isEmpty) return;

    final ultimo = (await curva()).last;
    final desglose = (ultimo['byAccount'] as Map).cast<String, dynamic>();
    for (final c in apagadas) {
      expect(desglose.containsKey(c['id']), isTrue, reason: '${c['name']} tiene que estar');
    }

    final conApagadas = desglose.values.fold<double>(0, (a, v) => a + (v as num).toDouble());
    final sinApagadas = (ultimo['liquid'] as num).toDouble();
    final sumaApagadas = apagadas.fold<double>(
      0,
      (a, c) => a + (c['currentBalance'] as num).toDouble(),
    );
    expect(conApagadas, closeTo(sinApagadas + sumaApagadas, 0.011));
  });

  test('el último día del desglose es el saldo de hoy de cada cuenta', () async {
    // La curva se deduce hacia atrás desde el saldo de hoy: si el último punto
    // no coincidiera con él, toda la serie estaría corrida.
    final ultimo = (await curva()).last;
    final desglose = (ultimo['byAccount'] as Map).cast<String, dynamic>();
    for (final c in await cuentas()) {
      expect(
        (desglose[c['id']] as num).toDouble(),
        closeTo((c['currentBalance'] as num).toDouble(), 0.011),
        reason: 'la cuenta ${c['name']}',
      );
    }
  });
}
