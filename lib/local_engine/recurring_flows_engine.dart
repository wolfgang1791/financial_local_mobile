import 'due_dates_util.dart';
import 'months_util.dart';
import 'user_clock.dart';

/// Puerto directo de la parte de lectura de
/// `backend/src/recurring-flows/recurring-flows.service.ts`
/// (`findAllForUser`'s decoration — no la escritura, eso es Fase 3).

/// Solo estas vencen al menos una vez al mes, así que solo para estas un mes
/// sin registro significa un mes sin pagar.
const monthlyOrTighter = {'WEEKLY', 'BIWEEKLY', 'MONTHLY'};

/// Frecuencias en las que "pagado este mes" significa que el ciclo se
/// cerró — un flujo semanal se paga cuatro veces al mes, así que ahí no
/// dice nada sobre si toca de nuevo el viernes.
const onePerMonthOrLess = {'MONTHLY', 'QUARTERLY', 'YEARLY'};

class FlowDerivedState {
  const FlowDerivedState({
    required this.nextDueDate,
    required this.statusThisMonth,
    required this.lastPaidMonth,
    required this.missedMonths,
  });

  final DateTime nextDueDate;
  final String statusThisMonth;
  final String? lastPaidMonth;
  final List<String> missedMonths;
}

FlowDerivedState decorateRecurringFlow({
  required String frequency,
  required DateTime startDate,
  required DateTime storedNextDueDate,
  DateTime? endDate,
  DateTime? settledThrough,
  required Set<String> paidMonths,
  required UserClock clock,
  required DateTime now,
}) {
  final thisMonth = clock.monthKey(now);
  final pagadoEsteMes = paidMonths.contains(thisMonth);
  // Ni antes de su alta ni después de su baja.
  final until = endDate != null && endDate.isBefore(now) ? endDate : now;
  // Ni meses anteriores al último "estoy al día" — lo que permite que un
  // aviso se pueda cerrar marcando pagado hoy.
  final desde = settledThrough != null && settledThrough.isAfter(startDate)
      ? settledThrough
      : startDate;

  final ancla = FlowAnchor(
    frequency: frequency,
    startDate: startDate,
    nextDueDate: storedNextDueDate,
    endDate: endDate,
  );
  final vence = nextDueDate(ancla, clock, now);
  final cicloCerrado =
      pagadoEsteMes && onePerMonthOrLess.contains(frequency) && clock.monthKey(vence) == thisMonth;
  // Si el ciclo ya se cerró, se pregunta de nuevo desde el día siguiente al
  // vencimiento — da la ocurrencia siguiente sin duplicar la aritmética.
  final proximo = cicloCerrado
      ? nextDueDate(ancla, clock, vence.add(const Duration(days: 1)))
      : vence;

  final ordenados = paidMonths.toList()..sort();

  return FlowDerivedState(
    nextDueDate: proximo,
    statusThisMonth: pagadoEsteMes ? 'PAID' : 'PENDING',
    lastPaidMonth: ordenados.isEmpty ? null : ordenados.last,
    missedMonths: monthlyOrTighter.contains(frequency)
        ? missedMonthsSince(desde, paidMonths, until, clock)
        : [],
  );
}
