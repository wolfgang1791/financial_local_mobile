// Valores de oro para la Fase 2 — comparados contra el backend NestJS/
// Postgres vivo, mismo usuario, mismas deudas y flujos ya migrados.

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
    tmp = await prepararDirectorioTemporal('financial_strategist_local_debts_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  test('GET /debts/kinds — mismos 4 tipos activos, mismo orden', () async {
    // El catálogo tiene 8 filas, pero solo 4 están activas — confirmado
    // contra el backend real, que tampoco devuelve las otras 4.
    final r = await api.get('/debts/kinds') as List;
    expect(r.map((k) => k['code']).toList(), [
      'PERSONAL_LOAN',
      'CASH_ADVANCE',
      'CREDIT_CARD',
      'INFORMAL_LOAN',
    ]);
    expect(r[0]['hasRates'], true);
    expect(r[0]['hasTerm'], true);
  });

  test(
    'GET /debts — el préstamo personal trae la misma cuota derivada que el backend real',
    () async {
      final r = await api.get('/debts') as List;
      expect(r.length, 4);

      final prestamo = r.firstWhere((d) => d['debtTypeCode'] == 'PERSONAL_LOAN');
      expect((prestamo['currentBalance'] as num).toDouble(), 92665.67);
      expect(prestamo['statusThisMonth'], 'PENDING');
      // Los meses que pasaron sin pagar se acumulan solos, así que la lista
      // vacía no era un valor de oro: estaba escrita `isEmpty` y bastó que
      // llegara septiembre —con agosto sin marcar en la base sembrada— para que
      // fallara. Lo que sí es regla: todos son meses **pasados**. El mes en
      // curso no puede estar incumplido, todavía se puede pagar, y por eso vive
      // en `statusThisMonth`.
      final mesActual = (await hoyDelUsuario()).substring(0, 7);
      for (final mes in prestamo['missedMonths'] as List) {
        expect((mes as String).compareTo(mesActual), lessThan(0), reason: '$mes ya pasó');
      }
      expect((prestamo['pendingThisMonth'] as num).toDouble(), 1694.77);
      expect((prestamo['installmentInterest'] as num).toDouble(), 1044.38);
      expect((prestamo['interestPendingThisMonth'] as num).toDouble(), 1044.38);
      expect((prestamo['installmentAmount'] as num).toDouble(), 1694.77);
      expect((prestamo['scheduledInstallment'] as num).toDouble(), 1501.99);
      expect(prestamo['remainingInstallments'], 1);
      expect((prestamo['account'] as Map)['name'], 'prestamo gigante');
      expect((prestamo['debtKind'] as Map)['label'], 'Préstamo bancario');
    },
  );

  test('GET /recurring-flows — mismos flujos, mismo orden, mismas fechas derivadas', () async {
    final r = await api.get('/recurring-flows') as List;
    expect(r.length, 15);

    // Orden: por monto de mayor a menor. "Sueldo" es el más grande de todos.
    expect(r[0]['name'], 'Sueldo');
    expect((r[0]['amount'] as num).toDouble(), 8068.49);
    expect(r[0]['statusThisMonth'], 'PENDING');
    expect((r[0]['category'] as Map)['name'], 'Salario');

    // El vencimiento se comprueba por su **regla**, no por un día del
    // calendario: cae el día 28 de su mes y nunca en el pasado. Con la fecha
    // escrita a mano el test caducaba —pasaba el 27 y fallaba el 28— y un test
    // que solo pasa algunos días no dice nada de si el código está bien.
    final hoy = DateTime.now();
    final inicioDeHoy = DateTime(hoy.year, hoy.month, hoy.day);
    void venceElDia(Object? iso, int dia) {
      final fecha = DateTime.parse(iso! as String).toLocal();
      expect(fecha.day, dia);
      expect(
        fecha.isBefore(inicioDeHoy),
        isFalse,
        reason: 'el próximo vencimiento no puede estar en el pasado',
      );
    }

    venceElDia(r[0]['nextDueDate'], 30);

    final alquiler = r.firstWhere((f) => f['name'] == 'Alquiler');
    expect((alquiler['amount'] as num).toDouble(), 1700);
    venceElDia(alquiler['nextDueDate'], 27);
  });
}
