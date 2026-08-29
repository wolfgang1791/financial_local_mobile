import 'dart:math' as math;

import 'ledger.dart' show round2;

/// Puerto directo de `backend/src/financial-engine/amortization.util.ts`.

class AmortizationEntry {
  const AmortizationEntry({
    required this.month,
    required this.dueDate,
    required this.payment,
    required this.principalPortion,
    required this.interestPortion,
    required this.remainingBalance,
  });

  final int month;
  final DateTime dueDate;
  final double payment;
  final double principalPortion;
  final double interestPortion;
  final double remainingBalance;
}

class AmortizationResult {
  const AmortizationResult({
    required this.schedule,
    required this.totalInterest,
    required this.payoffMonths,
  });

  final List<AmortizationEntry> schedule;
  final double totalInterest;
  final int payoffMonths;
}

/// La tasa mensual equivalente a una tasa anual EFECTIVA (TEA/TCEA, la
/// definición de la SBS: ya incluye la capitalización del año) — por eso no
/// se divide entre 12, eso solo vale para una tasa nominal.
double monthlyRateFromEffectiveAnnual(double annualRate) {
  if (annualRate == 0) return 0;
  return math.pow(1 + annualRate, 1 / 12).toDouble() - 1;
}

DateTime _addMonths(DateTime date, int months) {
  // Mismo desborde que `Date.setMonth` en JS: el día se conserva y, si el
  // mes destino tiene menos días, se pasa al siguiente — es el
  // comportamiento del que depende el original, no un efecto secundario a
  // corregir acá.
  return DateTime.utc(
    date.year,
    date.month + months,
    date.day,
    date.hour,
    date.minute,
    date.second,
  );
}

/// Préstamo a cuotas fijas (personal/auto/hipotecario): la cuota estándar
/// de un préstamo amortizado, con un aporte extra opcional.
AmortizationResult amortizeInstallmentLoan({
  required double principal,
  required double annualRate,
  required int termMonths,
  required DateTime startDate,
  // Un aporte extraordinario, UNA sola vez, en el mes indicado.
  double extraPayment = 0,
  int extraPaymentMonth = 1,
  // Un aporte extra TODOS los meses — distinto del anterior: no es lo mismo
  // pagar 500 una vez que 500 todos los meses durante ocho años.
  double recurringExtra = 0,
}) {
  final monthlyRate = monthlyRateFromEffectiveAnnual(annualRate);
  final basePayment = monthlyRate == 0
      ? principal / termMonths
      : (principal * monthlyRate) /
            (1 - math.pow(1 + monthlyRate, -termMonths.toDouble()).toDouble());

  final schedule = <AmortizationEntry>[];
  var balance = principal;
  var totalInterest = 0.0;
  var month = 0;

  while (balance > 0.01 && month < termMonths + 360) {
    month += 1;
    final interestPortion = round2(balance * monthlyRate);
    var payment = basePayment + recurringExtra;
    if (month == extraPaymentMonth) payment += extraPayment;

    // La última cuota absorbe el residuo del redondeo — igual que hace un
    // banco de verdad. Sin esto, un préstamo a 103 meses terminaba con
    // céntimos vivos y el bucle agregaba un mes 104 fantasma.
    var principalPortion = round2(payment - interestPortion);
    if (principalPortion >= balance || month >= termMonths) {
      principalPortion = balance;
      payment = round2(principalPortion + interestPortion);
    }

    balance = round2(balance - principalPortion);
    totalInterest = round2(totalInterest + interestPortion);

    schedule.add(
      AmortizationEntry(
        month: month,
        dueDate: _addMonths(startDate, month),
        payment: payment,
        principalPortion: principalPortion,
        interestPortion: interestPortion,
        remainingBalance: balance,
      ),
    );
  }

  return AmortizationResult(schedule: schedule, totalInterest: totalInterest, payoffMonths: month);
}

/// Crédito revolvente (tarjeta): una cuota fija mensual contra un saldo que
/// sigue generando interés hasta pagarse entero. Para simular "¿y si pago
/// X/mes?" o "¿y si dejo de usar la tarjeta?".
AmortizationResult amortizeRevolvingCredit({
  required double balance,
  required double annualRate,
  required double monthlyPayment,
  required DateTime startDate,
  double extraPayment = 0,
  int extraPaymentMonth = 1,
  int maxMonths = 600,
}) {
  final monthlyRate = monthlyRateFromEffectiveAnnual(annualRate);

  final schedule = <AmortizationEntry>[];
  var saldo = balance;
  var totalInterest = 0.0;
  var month = 0;

  while (saldo > 0.01 && month < maxMonths) {
    month += 1;
    final interestPortion = round2(saldo * monthlyRate);
    final payment = math.min(
      monthlyPayment + (month == extraPaymentMonth ? extraPayment : 0),
      saldo + interestPortion,
    );
    var principalPortion = round2(payment - interestPortion);
    if (principalPortion < 0) principalPortion = 0;

    saldo = round2(saldo + interestPortion - payment);
    if (saldo < 0) saldo = 0;
    totalInterest = round2(totalInterest + interestPortion);

    schedule.add(
      AmortizationEntry(
        month: month,
        dueDate: _addMonths(startDate, month),
        payment: round2(payment),
        principalPortion: principalPortion,
        interestPortion: interestPortion,
        remainingBalance: saldo,
      ),
    );
  }

  return AmortizationResult(schedule: schedule, totalInterest: totalInterest, payoffMonths: month);
}
