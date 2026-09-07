// Marcar un flujo fijo de un mes que ya cerró.
//
// Un ingreso y un gasto viejos no se comportan igual, y la diferencia es de
// dónde está la plata: un sueldo de agosto que te entra hoy todavía no está en
// tu saldo, y el alquiler de julio salió de la cuenta en julio y ya está
// descontado. Contarlos igual deja el patrimonio mal por los dos lados.

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
    tmp = await prepararDirectorioTemporal('otro_mes_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<double> patrimonio() async =>
      ((await api.get('/financial-engine/cash-position') as Map)['total'] as num).toDouble();

  // Un mes cerrado que nadie marcó todavía: el anterior al de hoy.
  final hoy = DateTime.now();
  final anterior = DateTime(hoy.year, hoy.month - 1);
  final mesPasado = '${anterior.year}-${anterior.month.toString().padLeft(2, '0')}';

  Future<Map<String, dynamic>> crearFlujo({required bool ingreso}) async {
    final cuentas = (await api.get('/accounts') as List).cast<Map<String, dynamic>>();
    return await api.post('/recurring-flows', {
          'name': ingreso ? 'Sueldo de prueba' : 'Alquiler de prueba',
          'type': ingreso ? 'INCOME' : 'EXPENSE',
          'amount': 500,
          'frequency': 'MONTHLY',
          'startDate': '$mesPasado-01',
          'nextDueDate': '$mesPasado-05',
          'accountId': cuentas.first['id'],
        })
        as Map<String, dynamic>;
  }

  test('un ingreso de un mes cerrado sube el patrimonio', () async {
    final flujo = await crearFlujo(ingreso: true);
    final antes = await patrimonio();

    await api.post('/recurring-flows/${flujo['id']}/pay', {'month': mesPasado, 'amount': 500});

    // La plata llegó ahora aunque el mes sea viejo: el saldo no la tenía.
    expect(await patrimonio(), closeTo(antes + 500, 0.01));
  });

  test('un gasto de un mes cerrado no lo mueve', () async {
    final flujo = await crearFlujo(ingreso: false);
    final antes = await patrimonio();

    await api.post('/recurring-flows/${flujo['id']}/pay', {'month': mesPasado, 'amount': 500});

    // Ya había salido de la cuenta en su mes: descontarlo otra vez lo contaría
    // dos veces y la curva mentiría desde ahí.
    expect(await patrimonio(), closeTo(antes, 0.01));
  });

  test('revertir deshace exactamente lo que hizo cada uno', () async {
    for (final ingreso in [true, false]) {
      final flujo = await crearFlujo(ingreso: ingreso);
      final antes = await patrimonio();
      await api.post('/recurring-flows/${flujo['id']}/pay', {'month': mesPasado, 'amount': 500});
      await api.post('/recurring-flows/${flujo['id']}/revert-payment', {'month': mesPasado});
      expect(
        await patrimonio(),
        closeTo(antes, 0.01),
        reason: ingreso ? 'revertir el ingreso' : 'revertir el gasto',
      );
    }
  });
}
