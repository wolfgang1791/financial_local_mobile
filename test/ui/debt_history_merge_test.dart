// Unir las monedas en una sola: lo que hace que el saldo del gráfico y el total
// de la pantalla de Deudas sean el mismo número.
//
// Mientras cada moneda iba por su lado, las dos cifras no cuadraban nunca — no
// por un error de cuentas, sino porque medían cosas distintas — y desde afuera
// eso se lee como un bug.

import 'package:flutter_test/flutter_test.dart';

import 'package:financial_strategist_local/data/models.dart';
import 'package:financial_strategist_local/ui/debt_history_chart.dart';

DebtMonth mes(String m, {double paid = 0, double balance = 0, double principal = 0}) =>
    DebtMonth(month: m, paid: paid, principal: principal, interest: 0, other: 0, balance: balance);

void main() {
  // USD→PEN a 3.417 (el lado venta: pagar una deuda en dólares obliga a
  // comprarlos).
  final tasas = [
    const ExchangeRate(
      baseCode: 'USD',
      quoteCode: 'PEN',
      buy: 3.37,
      sell: 3.417,
      date: '2026-08-20',
    ),
  ];

  test('suma las dos monedas al cambio de venta', () {
    final (serie, cotizacion) = unirEnUnaMoneda(
      [
        DebtHistorySeries(currency: 'PEN', months: [mes('2026-08', balance: 100)]),
        DebtHistorySeries(currency: 'USD', months: [mes('2026-08', balance: 10)]),
      ],
      'PEN',
      tasas,
    );

    expect(serie.currency, 'PEN');
    expect(serie.months.single.balance, closeTo(100 + 34.17, 0.01));
    expect(cotizacion!.side, 'venta');
  });

  test('un mes que una moneda no tiene cuenta como cero, no como hueco', () {
    // La serie de cada moneda se recorta por su lado: la de dólares puede
    // empezar más tarde. Ese mes no es "sin datos", es "no debía nada".
    final (serie, _) = unirEnUnaMoneda(
      [
        DebtHistorySeries(
          currency: 'PEN',
          months: [mes('2026-07', balance: 100), mes('2026-08', balance: 90)],
        ),
        DebtHistorySeries(currency: 'USD', months: [mes('2026-08', balance: 10)]),
      ],
      'PEN',
      tasas,
    );

    expect(serie.months.length, 2);
    expect(serie.months.first.balance, closeTo(100, 0.01));
    expect(serie.months.last.balance, closeTo(90 + 34.17, 0.01));
  });

  test('sin cotización esa moneda queda fuera, como en el total de Deudas', () {
    final (serie, cotizacion) = unirEnUnaMoneda(
      [
        DebtHistorySeries(currency: 'PEN', months: [mes('2026-08', balance: 100)]),
        DebtHistorySeries(currency: 'EUR', months: [mes('2026-08', balance: 50)]),
      ],
      'PEN',
      const [],
    );

    expect(serie.months.single.balance, closeTo(100, 0.01));
    expect(cotizacion, isNull, reason: 'no hubo conversión que avisar');
  });

  test('los meses vacíos del principio se recortan otra vez tras unir', () {
    final (serie, _) = unirEnUnaMoneda(
      [
        DebtHistorySeries(currency: 'PEN', months: [mes('2026-06'), mes('2026-07', balance: 80)]),
      ],
      'PEN',
      tasas,
    );

    expect(serie.months.first.month, '2026-07');
  });
}
