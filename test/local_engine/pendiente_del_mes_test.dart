// Lo que falta por pagar este mes: gastos fijos sin marcar más cuotas sin cubrir.
//
// Las dos mitades responden a la misma pregunta pero viven en dos pantallas
// distintas, y hasta ahora nadie las sumaba. Es la cifra que decide si el saldo
// de hoy alcanza, así que tiene que contar exactamente lo que se debe: ni un
// sueldo pendiente de cobrar, ni un flujo que aún no existía ese mes, ni una
// cuota ya pagada.

import 'package:financial_strategist_local/data/models.dart';
import 'package:financial_strategist_local/local_engine/pendiente_del_mes.dart';
import 'package:flutter_test/flutter_test.dart';

const _mes = '2026-08';

RecurringFlow _flujo({
  required String nombre,
  required String tipo,
  required double monto,
  bool pagado = false,
  bool conFicha = true,
  String frecuencia = 'MONTHLY',
}) => RecurringFlow.fromJson({
  'id': nombre,
  'name': nombre,
  'type': tipo,
  'amount': monto,
  'frequency': frecuencia,
  'nextDueDate': '$_mes-15T12:00:00.000Z',
  'startDate': '2026-01-01T12:00:00.000Z',
  'paidMonths': <String>[],
  'monthlyRecords': <dynamic>[],
  'missedMonths': <String>[],
  'months': conFicha
      ? {
          _mes: {
            'amount': monto,
            'dueDate': '$_mes-15',
            'paidAt': pagado ? '$_mes-10T12:00:00.000Z' : null,
          },
        }
      : <String, dynamic>{},
});

Debt _deuda({
  required String nombre,
  required double cuota,
  required double falta,
  double saldo = 1000,
  String moneda = 'PEN',
  bool activa = true,
}) => Debt.fromJson({
  'id': nombre,
  'accountId': 'a-$nombre',
  'account': {'name': nombre, 'currency': moneda},
  'debtKind': {'code': 'CREDIT_CARD', 'label': 'Tarjeta', 'icon': '💳'},
  'currentBalance': saldo,
  'originalPrincipal': saldo,
  'interestRateAnnual': 0.5,
  'minimumPayment': cuota,
  'installmentAmount': cuota,
  'pendingThisMonth': falta,
  'isActive': activa,
});

void main() {
  test('suma los fijos sin marcar y las cuotas sin cubrir', () {
    final p = pendienteDelMes(
      flujos: [
        _flujo(nombre: 'Alquiler', tipo: 'EXPENSE', monto: 1700),
        _flujo(nombre: 'Internet', tipo: 'EXPENSE', monto: 99, pagado: true),
      ],
      deudas: [
        _deuda(nombre: 'Tarjeta', cuota: 500, falta: 500),
        _deuda(nombre: 'Préstamo', cuota: 300, falta: 0),
      ],
      mes: _mes,
      moneda: 'PEN',
      tasas: const [],
    );

    expect(p.fijos, 1700);
    expect(p.fijosCuantos, 1);
    expect(p.deudas, 500);
    expect(p.deudasCuantas, 1);
    expect(p.total, 2200);
    // Lo comprometido incluye lo ya pagado: es contra eso que "te falta" se lee.
    expect(p.comprometido, 1700 + 99 + 500 + 300);
  });

  test('un ingreso fijo no es algo que debas pagar', () {
    final p = pendienteDelMes(
      flujos: [_flujo(nombre: 'Sueldo', tipo: 'INCOME', monto: 8000)],
      deudas: const [],
      mes: _mes,
      moneda: 'PEN',
      tasas: const [],
    );
    expect(p.total, 0);
    expect(p.nadaPendiente, isTrue);
  });

  test('un flujo sin ficha de ese mes no reclama nada', () {
    // Todavía no existía, o ya terminó: no hay compromiso que cobrar.
    final p = pendienteDelMes(
      flujos: [_flujo(nombre: 'Gimnasio', tipo: 'EXPENSE', monto: 120, conFicha: false)],
      deudas: const [],
      mes: _mes,
      moneda: 'PEN',
      tasas: const [],
    );
    expect(p.total, 0);
  });

  test('un gasto anual entra por su equivalente mensual', () {
    // Sumar el monto crudo metería S/ 1,200 en el total del mes y el compromiso
    // saldría doce veces más grande de lo que es.
    final p = pendienteDelMes(
      flujos: [_flujo(nombre: 'Seguro', tipo: 'EXPENSE', monto: 1200, frecuencia: 'YEARLY')],
      deudas: const [],
      mes: _mes,
      moneda: 'PEN',
      tasas: const [],
    );
    expect(p.fijos, closeTo(100, 0.01));
  });

  test('una deuda cancelada o saldada no cuenta', () {
    final p = pendienteDelMes(
      flujos: const [],
      deudas: [
        _deuda(nombre: 'Cancelada', cuota: 400, falta: 400, activa: false),
        _deuda(nombre: 'Saldada', cuota: 400, falta: 400, saldo: 0),
      ],
      mes: _mes,
      moneda: 'PEN',
      tasas: const [],
    );
    expect(p.total, 0);
  });

  test('una cuota en dólares se convierte al tipo de cambio venta', () {
    final tasas = [
      ExchangeRate.fromJson({
        'baseCode': 'USD',
        'quoteCode': 'PEN',
        'date': '2026-08-01T00:00:00.000Z',
        'buy': 3.37,
        'sell': 3.417,
      }),
    ];
    final p = pendienteDelMes(
      flujos: const [],
      deudas: [_deuda(nombre: 'Dólares', cuota: 100, falta: 100, moneda: 'USD')],
      mes: _mes,
      moneda: 'PEN',
      tasas: tasas,
    );
    // Venta y no compra: pagarla obliga a comprar dólares.
    expect(p.deudas, closeTo(341.70, 0.01));
    expect(p.sinCotizacion, isEmpty);
  });

  test('sin cotización, esa cuota queda fuera y se dice cuál', () {
    // Un total al que le falta una deuda es un total equivocado: callarlo sería
    // peor que no mostrarlo.
    final p = pendienteDelMes(
      flujos: const [],
      deudas: [_deuda(nombre: 'Euros', cuota: 100, falta: 100, moneda: 'EUR')],
      mes: _mes,
      moneda: 'PEN',
      tasas: const [],
    );
    expect(p.total, 0);
    expect(p.sinCotizacion, ['EUR']);
  });
}
