// El desgravamen sale de la cuota antes que el capital.
//
// Es lo que hace cualquier estado de cuenta: de S/ 1,694.80, S/ 110.75 son
// seguro y no bajan un céntimo de la deuda. Sin descontarlo, esos 110 se
// acreditaban al capital y el saldo de la app bajaba más rápido que el del
// banco — un desvío que se acumula todos los meses.

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
    tmp = await prepararDirectorioTemporal('debts_insurance_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<Map> crearPrestamo({double? desgravamen}) async {
    return await api.post('/debts', {
          'debtTypeCode': 'PERSONAL_LOAN',
          'name': 'Préstamo con seguro',
          'currency': 'PEN',
          'originalPrincipal': 101000,
          'currentBalance': 93199.41,
          'interestRateAnnual': 0.139,
          'minimumPayment': 1694.80,
          'termMonths': 103,
          'originationDate': '2026-07-15',
          'dueDay': 30,
          if (desgravamen != null) 'monthlyInsurance': desgravamen,
        })
        as Map;
  }

  test('el seguro se descuenta de la cuota y no baja la deuda', () async {
    final deuda = await crearPrestamo(desgravamen: 110.75);
    final cuentas = await api.get('/accounts') as List;

    final pago =
        await api.post('/debts/${deuda['id']}/pay', {
              'accountId': (cuentas.first as Map)['id'],
              'amount': 1694.80,
            })
            as Map;

    expect((pago['insurance'] as num).toDouble(), closeTo(110.75, 0.01));
    // Y las tres partes suman la cuota: nada se pierde ni se cuenta dos veces.
    final partes =
        (pago['principal'] as num) + (pago['interest'] as num) + (pago['insurance'] as num);
    expect(partes, closeTo(1694.80, 0.01));
  });

  test('sin seguro configurado, todo lo que no es interés baja la deuda', () async {
    final deuda = await crearPrestamo();
    final cuentas = await api.get('/accounts') as List;

    final pago =
        await api.post('/debts/${deuda['id']}/pay', {
              'accountId': (cuentas.first as Map)['id'],
              'amount': 1694.80,
            })
            as Map;

    expect((pago['insurance'] as num).toDouble(), 0);
    expect(
      (pago['principal'] as num).toDouble(),
      closeTo(1694.80 - (pago['interest'] as num).toDouble(), 0.01),
    );
  });

  test('con seguro, el capital baja 110.75 menos que sin él', () async {
    // La cifra del desvío, dicha como cifra: es lo que se acreditaba de más al
    // capital todos los meses.
    final cuentas = await api.get('/accounts') as List;
    final cuentaId = (cuentas.first as Map)['id'];

    final sinSeguro = await crearPrestamo();
    final pagoSin =
        await api.post('/debts/${sinSeguro['id']}/pay', {'accountId': cuentaId, 'amount': 1694.80})
            as Map;

    final conSeguro = await crearPrestamo(desgravamen: 110.75);
    final pagoCon =
        await api.post('/debts/${conSeguro['id']}/pay', {'accountId': cuentaId, 'amount': 1694.80})
            as Map;

    expect(
      (pagoSin['principal'] as num).toDouble() - (pagoCon['principal'] as num).toDouble(),
      closeTo(110.75, 0.01),
    );
  });
}
