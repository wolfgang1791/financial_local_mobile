import 'dart:math' as math;

import 'amortization.dart' show monthlyRateFromEffectiveAnnual;
import 'ledger.dart' show round2;
import 'months_util.dart';
import 'user_clock.dart';

/// Puerto directo de la parte de lectura de
/// `backend/src/debts/debts.service.ts` (`findAllForUser`'s decoration —
/// pagar/revertir es Fase 5, la más riesgosa, y se hace al final a
/// propósito).

class DebtDerivedState {
  const DebtDerivedState({
    required this.statusThisMonth,
    required this.lastPaidMonth,
    required this.missedMonths,
    required this.paidThisMonth,
    required this.pendingThisMonth,
    required this.installmentInterest,
    required this.interestPendingThisMonth,
    required this.installmentAmount,
    required this.scheduledInstallment,
    required this.remainingInstallments,
  });

  final String statusThisMonth;
  final String? lastPaidMonth;
  final List<String> missedMonths;
  final double paidThisMonth;
  final double pendingThisMonth;
  final double installmentInterest;
  final double interestPendingThisMonth;
  final double installmentAmount;
  final double scheduledInstallment;
  final int? remainingInstallments;
}

/// Cuánto falta de una deuda: meses, interés y de cada sol que pagues, cuánto
/// baja lo que debes.
class DebtProjection {
  const DebtProjection({
    required this.monthsLeft,
    required this.interestLeft,
    required this.totalLeft,
    required this.principalShare,
    required this.modeledInstallment,
    required this.installmentGap,
  });

  /// `null` = a este ritmo no se termina: la cuota no cubre el interés del mes
  /// y el saldo sube. No es un error de cálculo, es lo que pasa de verdad.
  final int? monthsLeft;
  final double interestLeft;

  /// Lo que vas a desembolsar hasta terminarla, incluido lo que no amortiza.
  final double totalLeft;

  /// De cada 100 que pagues, cuántos bajan lo que debes.
  final int principalShare;

  /// La cuota que saldaría el saldo de hoy en el plazo que queda. Solo con
  /// plazo: una tarjeta no tiene un "debería ser".
  final double? modeledInstallment;

  /// Cuánto más grande es la cuota real que la modelada. Casi siempre es
  /// desgravamen y portes, y hoy se acredita a capital.
  final double installmentGap;

  Map<String, dynamic> toJson() => {
    'monthsLeft': monthsLeft,
    'interestLeft': interestLeft,
    'totalLeft': totalLeft,
    'principalShare': principalShare,
    'modeledInstallment': modeledInstallment,
    'installmentGap': installmentGap,
  };
}

/// Se simula mes a mes desde el saldo de **hoy** con la cuota declarada, y no
/// se lee del cronograma. El cronograma es una foto del momento en que se creó
/// la deuda: no sabe que pagaste de más el mes pasado ni que el saldo ya no es
/// el mismo. Simulando, la proyección sigue a la realidad.
///
/// La tasa es la TCEA cuando existe —es el costo real, con seguro y portes
/// dentro— y la TEA si no. El desgravamen declarado se resta aparte: si pusiste
/// la TCEA **y** el seguro, se contaría dos veces, y por eso el formulario lo
/// dice.
DebtProjection proyectarDeuda({
  required double currentBalance,
  required double installment,
  required double interestRateAnnual,
  required double? costRateAnnual,
  required double monthlyInsurance,
  required int? termMonths,
}) {
  final tasa = monthlyRateFromEffectiveAnnual(costRateAnnual ?? interestRateAnnual);

  // La cuota que saldaría el saldo de hoy en las cuotas que quedan. Sirve para
  // una cosa concreta: si tu cuota real es mayor, la diferencia casi siempre es
  // desgravamen y portes, y hoy se está acreditando a capital.
  final modelada = (termMonths != null && termMonths > 0 && currentBalance > 0)
      ? round2(
          tasa == 0
              ? currentBalance / termMonths
              : (currentBalance * tasa) / (1 - math.pow(1 + tasa, -termMonths)),
        )
      : null;
  final desajuste = (modelada != null && installment > modelada)
      ? round2(installment - modelada)
      : 0.0;

  if (currentBalance <= 0 || installment <= 0) {
    return DebtProjection(
      monthsLeft: currentBalance <= 0 ? 0 : null,
      interestLeft: 0,
      totalLeft: 0,
      principalShare: 100,
      modeledInstallment: modelada,
      installmentGap: desajuste,
    );
  }

  var restante = currentBalance;
  var meses = 0;
  var interes = 0.0;
  var pagado = 0.0;
  // Tope de 600 meses: a partir de ahí la respuesta útil no es el número, es
  // "así no se termina".
  while (restante > 0.01 && meses < 600) {
    final delMes = round2(restante * tasa);
    final capital = installment - delMes - monthlyInsurance;
    if (capital <= 0) {
      return DebtProjection(
        monthsLeft: null,
        interestLeft: 0,
        totalLeft: 0,
        principalShare: 0,
        modeledInstallment: modelada,
        installmentGap: desajuste,
      );
    }
    // La última cuota es la que queda, no una entera.
    final aplicado = capital < restante ? capital : restante;
    pagado += aplicado + delMes + monthlyInsurance;
    restante = round2(restante - aplicado);
    interes += delMes;
    meses++;
  }

  return DebtProjection(
    monthsLeft: meses,
    interestLeft: round2(interes),
    totalLeft: round2(pagado),
    principalShare: pagado > 0 ? (currentBalance / pagado * 100).round() : 0,
    modeledInstallment: modelada,
    installmentGap: desajuste,
  );
}

DebtDerivedState decorateDebt({
  required double currentBalance,
  required double minimumPayment,
  required DateTime originationDate,
  required int? termMonths,
  required double paidThisMonth,
  required double interestPaidThisMonth,
  required Set<String> paidMonths,
  required double? nextScheduledAmount,
  required double? nextInterestPortion,
  required bool hasScheduledPayment,
  required UserClock clock,
  bool isActive = true,
}) {
  // Misma precedencia en todos lados: la cuota declarada manda sobre la
  // calculada, para que lo que se ve y lo que se cobra no puedan diferir.
  final declared = minimumPayment;
  final installment = round2(declared > 0 ? declared : (nextScheduledAmount ?? 0));

  // Tres estados, no dos: un pago parcial no es "pagada" ni "no pagada".
  final status = paidThisMonth <= 0
      ? 'PENDING'
      : (paidThisMonth + 0.005 >= installment ? 'PAID' : 'PARTIAL');

  final ordenados = paidMonths.toList()..sort();

  // Una deuda saldada no debe meses. Una cancelada tampoco: dejó de vencer el
  // día que se canceló, y arrastrar "3 meses sin registrar pago" sobre algo que
  // ya no cuenta es reclamar una deuda que el usuario dio por terminada.
  //
  // La primera cuota vence el mes siguiente al desembolso — el mes en que
  // prestaron la plata no se debe nada.
  final missedMonths = isActive && currentBalance > 0
      ? missedMonthsSince(clock.addMonths(originationDate, 1), paidMonths, clock.now(), clock)
      : <String>[];

  return DebtDerivedState(
    statusThisMonth: status,
    lastPaidMonth: ordenados.isEmpty ? null : ordenados.last,
    missedMonths: missedMonths,
    paidThisMonth: paidThisMonth,
    // Nunca negativo: pagar de más no deja "cuota negativa", deja la cuota
    // cumplida y capital adelantado.
    pendingThisMonth: round2((installment - paidThisMonth).clamp(0, double.infinity)),
    installmentInterest: round2(nextInterestPortion ?? 0),
    interestPendingThisMonth: round2(
      ((nextInterestPortion ?? 0) - interestPaidThisMonth).clamp(0, double.infinity),
    ),
    installmentAmount: installment,
    scheduledInstallment: round2(nextScheduledAmount ?? 0),
    // El original filtra una lista `distinct: ['debtId']` por ese mismo
    // debtId, así que ese conteo es siempre 0 o 1 — el resultado real
    // termina siendo "1 si hay una cuota programada, si no 0", nunca la
    // cantidad real de cuotas que faltan. Se replica tal cual: es lo que
    // devuelve el backend real, no lo que el nombre del campo sugiere.
    remainingInstallments: termMonths != null ? (hasScheduledPayment ? 1 : 0) : null,
  );
}
