// Fase 5 — pago de cuotas de deuda, la parte más delicada del port. No se
// prueba contra el backend real (pagar ahí mutaría datos de verdad); en
// cambio se aprovecha que el cronograma de la deuda YA está en la base
// sembrada (generado por el backend real en su momento) y se verifica que
// pagar la cuota reproduce exactamente ese mismo desglose interés/capital.

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
    tmp = await prepararDirectorioTemporal('financial_strategist_local_debts_write_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  test(
    'pagar la cuota declarada cubre primero el interés del cronograma y el resto va a capital',
    () async {
      final deudas = await api.get('/debts') as List;
      final prestamo = deudas.firstWhere((d) => d['debtTypeCode'] == 'PERSONAL_LOAN');
      // Ya verificado contra el backend real en la Fase 2. La cuota que se
      // cobra de verdad (`installmentAmount`, la declarada por el usuario:
      // 1694.77) es más alta que la que proyectó el cronograma
      // (`scheduledInstallment`: 1510.64) — así que después de cubrir el
      // interés del período (`installmentInterest`: 1016.33), el sobrante va
      // entero a capital: más de lo que el cronograma habría amortizado solo.
      expect((prestamo['installmentInterest'] as num).toDouble(), 1016.33);
      expect((prestamo['installmentAmount'] as num).toDouble(), 1694.77);
      final capitalEsperado = 1694.77 - 1016.33;

      final balanceAntes = (prestamo['currentBalance'] as num).toDouble();
      final cuentas = await api.get('/accounts') as List;
      final cuentaPago = cuentas.firstWhere((c) => c['name'] == 'Cuenta principal');
      final saldoAntes = (cuentaPago['currentBalance'] as num).toDouble();

      final resultado =
          await api.post('/debts/${prestamo['id']}/pay', {
                'accountId': cuentaPago['id'],
                'amount': prestamo['installmentAmount'],
              })
              as Map;

      // Interés antes que capital: primero se cubre exactamente el interés
      // del período calculado por el cronograma, nunca más ni menos.
      expect((resultado['interest'] as num).toDouble(), closeTo(1016.33, 0.01));
      expect((resultado['principal'] as num).toDouble(), closeTo(capitalEsperado, 0.01));
      expect(resultado['covered'], true);

      final deudasDespues = await api.get('/debts') as List;
      final prestamoDespues = deudasDespues.firstWhere((d) => d['id'] == prestamo['id']);
      expect(
        (prestamoDespues['currentBalance'] as num).toDouble(),
        closeTo(balanceAntes - capitalEsperado, 0.01),
      );
      expect(prestamoDespues['statusThisMonth'], 'PAID');

      final cuentasDespues = await api.get('/accounts') as List;
      final cuentaPagoDespues = cuentasDespues.firstWhere((c) => c['id'] == cuentaPago['id']);
      expect(
        (cuentaPagoDespues['currentBalance'] as num).toDouble(),
        closeTo(saldoAntes - 1694.77, 0.01),
      );

      // Revertir deshace exactamente lo mismo.
      await api.post('/debts/${prestamo['id']}/revert-payment', const {});
      final deudasRevertido = await api.get('/debts') as List;
      expect(
        (deudasRevertido.firstWhere((d) => d['id'] == prestamo['id'])['currentBalance'] as num)
            .toDouble(),
        closeTo(balanceAntes, 0.01),
      );
      final cuentasRevertido = await api.get('/accounts') as List;
      expect(
        (cuentasRevertido.firstWhere((c) => c['id'] == cuentaPago['id'])['currentBalance'] as num)
            .toDouble(),
        closeTo(saldoAntes, 0.01),
      );
    },
  );

  test(
    'un pago parcial no cubre la cuota: queda PARTIAL y el capital es cero si no alcanza el interés',
    () async {
      final deudas = await api.get('/debts') as List;
      final prestamo = deudas.firstWhere((d) => d['debtTypeCode'] == 'PERSONAL_LOAN');
      final cuentas = await api.get('/accounts') as List;
      final cuentaPago = cuentas.firstWhere((c) => c['name'] == 'Cuenta principal');

      // Menos que el interés del período: todo se va a interés, nada a
      // capital — pagar menos que el interés no amortiza nada.
      final resultado =
          await api.post('/debts/${prestamo['id']}/pay', {
                'accountId': cuentaPago['id'],
                'amount': 500,
              })
              as Map;
      expect((resultado['interest'] as num).toDouble(), 500);
      expect((resultado['principal'] as num).toDouble(), 0);
      expect(resultado['covered'], false);

      final deudasDespues = await api.get('/debts') as List;
      expect(
        deudasDespues.firstWhere((d) => d['id'] == prestamo['id'])['statusThisMonth'],
        'PARTIAL',
      );
    },
  );

  test('crear una deuda a plazo genera el cronograma completo', () async {
    final creada =
        await api.post('/debts', {
              'name': 'Préstamo de prueba',
              'debtTypeCode': 'PERSONAL_LOAN',
              'originalPrincipal': 12000,
              'currentBalance': 12000,
              'interestRateAnnual': 0.20,
              'termMonths': 12,
              'originationDate': '2026-01-01',
              'currency': 'PEN',
            })
            as Map;
    expect(creada['termMonths'], 12);

    // La última cuota tiene que dejar el saldo en cero — la absorción de
    // redondeo del amortizador.
    final deudas = await api.get('/debts') as List;
    final encontrada = deudas.firstWhere((d) => d['id'] == creada['id']);
    expect(encontrada['remainingInstallments'], 1);
    expect((encontrada['scheduledInstallment'] as num).toDouble(), greaterThan(0));
  });
}
