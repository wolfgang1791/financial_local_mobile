// Cuánto falta de una deuda: meses, interés y qué parte de lo que pagas sirve
// para deber menos.
//
// Se simula desde el saldo de hoy con la cuota declarada, no desde el
// cronograma: el cronograma es una foto de cuando se creó la deuda y no sabe
// que pagaste de más el mes pasado.

import 'package:financial_strategist_local/local_engine/debts_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('un préstamo con plazo: la suma cuadra con lo que se va a desembolsar', () {
    final p = proyectarDeuda(
      currentBalance: 93199.41,
      installment: 1510.64,
      interestRateAnnual: 0.139,
      costRateAnnual: null,
      monthlyInsurance: 0,
      termMonths: 103,
    );

    expect(p.monthsLeft, closeTo(103, 1), reason: 'la cuota modelada salda en su plazo');
    // Lo que vas a pagar es el capital que debes más el interés que corre. Sin
    // esa identidad, cualquiera de los dos números está inventado.
    expect(p.totalLeft, closeTo(93199.41 + p.interestLeft, 1));
    expect(p.principalShare, closeTo(60, 2));
    // Y no hay desajuste: se está pagando exactamente la cuota que sale de la
    // tasa.
    expect(p.installmentGap, 0);
  });

  test('pagar más que la cuota modelada acorta el plazo y se marca el desajuste', () {
    final p = proyectarDeuda(
      currentBalance: 93199.41,
      installment: 1694.77, // lo que cobra el banco de verdad
      interestRateAnnual: 0.139,
      costRateAnnual: null,
      monthlyInsurance: 0,
      termMonths: 103,
    );

    expect(p.monthsLeft, lessThan(103), reason: 'pagando de más se termina antes');
    // El desajuste es la diferencia entre lo que pagas y lo que sale de la
    // tasa. Casi siempre es desgravamen y portes, y mientras no se declare, la
    // app lo cuenta como capital: por eso el aviso existe.
    expect(p.modeledInstallment, closeTo(1510.64, 1));
    expect(p.installmentGap, closeTo(184.13, 1));
  });

  test('declarar el desgravamen devuelve la proyección a su sitio', () {
    // La misma deuda, con la diferencia anotada donde va: deja de amortizar y
    // el plazo vuelve a ser el del contrato.
    final p = proyectarDeuda(
      currentBalance: 93199.41,
      installment: 1694.77,
      interestRateAnnual: 0.139,
      costRateAnnual: null,
      monthlyInsurance: 184.13,
      termMonths: 103,
    );
    expect(p.monthsLeft, closeTo(103, 1));
    // Y lo que vas a desembolsar ahora incluye el seguro de todos esos meses:
    // es plata que sale y que no baja la deuda.
    expect(p.totalLeft, greaterThan(93199.41 + p.interestLeft));
  });

  test('una tarjeta sin plazo también se proyecta, y no tiene cuota modelada', () {
    final p = proyectarDeuda(
      currentBalance: 8116.57,
      installment: 545.58,
      interestRateAnnual: 0.66,
      costRateAnnual: null,
      monthlyInsurance: 25,
      termMonths: null,
    );

    expect(p.monthsLeft, isNotNull);
    expect(p.monthsLeft, closeTo(27, 1));
    expect(p.interestLeft, greaterThan(5000), reason: 'al 66% anual el interés pesa');
    // Sin plazo no hay un "debería ser": cualquier pago por encima del interés
    // amortiza, y comparar contra una cuota inventada sería un aviso falso.
    expect(p.modeledInstallment, isNull);
    expect(p.installmentGap, 0);
  });

  test('si la cuota no cubre el interés, la deuda no se termina y se dice', () {
    // Pagar menos que el interés hace que el saldo suba. No es un error de
    // cálculo: es lo que pasa de verdad, y devolver un número de meses
    // cualquiera lo escondería.
    final p = proyectarDeuda(
      currentBalance: 8116.57,
      installment: 100,
      interestRateAnnual: 0.66,
      costRateAnnual: null,
      monthlyInsurance: 0,
      termMonths: null,
    );
    expect(p.monthsLeft, isNull);
    expect(p.principalShare, 0);
  });

  test('una deuda saldada no proyecta nada', () {
    final p = proyectarDeuda(
      currentBalance: 0,
      installment: 300,
      interestRateAnnual: 0.66,
      costRateAnnual: null,
      monthlyInsurance: 0,
      termMonths: null,
    );
    expect(p.monthsLeft, 0);
    expect(p.interestLeft, 0);
  });

  test('la TCEA manda sobre la TEA: es lo que de verdad cuesta', () {
    final conTea = proyectarDeuda(
      currentBalance: 3385.44,
      installment: 369.21,
      interestRateAnnual: 0.625,
      costRateAnnual: null,
      monthlyInsurance: 0,
      termMonths: 14,
    );
    final conTcea = proyectarDeuda(
      currentBalance: 3385.44,
      installment: 369.21,
      interestRateAnnual: 0.625,
      costRateAnnual: 0.6674,
      monthlyInsurance: 0,
      termMonths: 14,
    );
    expect(conTcea.interestLeft, greaterThan(conTea.interestLeft));
  });
}
