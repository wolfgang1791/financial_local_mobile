import 'user_clock.dart';

/// Puerto directo de `backend/src/common/due-dates.util.ts`.
///
/// Cuándo vence lo próximo, siempre derivado — nunca una columna que haya
/// que ir corriendo mes a mes. El dato guardado es el ancla (cuándo empezó
/// y qué día del mes toca); lo que se muestra se calcula al leer.

const _monthsBetween = {'MONTHLY': 1, 'QUARTERLY': 3, 'YEARLY': 12};

const _daysBetween = {'WEEKLY': 7, 'BIWEEKLY': 14};

const _dayMs = 24 * 60 * 60 * 1000;

int _daysInMonth(DateTime monthStart, UserClock clock) {
  final next = clock.addMonths(monthStart, 1);
  return (next.millisecondsSinceEpoch - monthStart.millisecondsSinceEpoch) ~/ _dayMs;
}

class FlowAnchor {
  const FlowAnchor({
    required this.frequency,
    required this.startDate,
    required this.nextDueDate,
    this.endDate,
  });

  final String frequency;
  final DateTime startDate;
  final DateTime nextDueDate;
  final DateTime? endDate;
}

DateTime _capToEnd(DateTime candidate, DateTime? endDate) {
  return endDate != null && candidate.isAfter(endDate) ? endDate : candidate;
}

DateTime nextDueDate(FlowAnchor flow, UserClock clock, [DateTime? nowArg]) {
  final now = nowArg ?? clock.now();
  // El ancla es la fecha declarada: de ella salen el día del mes (o el día
  // de la semana) que se repite. La más tardía entre inicio y guardada,
  // porque al editar el usuario puede haber corrido la fecha.
  final anchor = flow.nextDueDate.isAfter(flow.startDate) ? flow.nextDueDate : flow.startDate;
  final today = clock.startOfDayOf(now);

  // Todavía no llegó: la próxima es ella misma.
  if (!anchor.isBefore(today)) return anchor;

  final days = _daysBetween[flow.frequency];
  if (days != null) {
    // Semanal y quincenal caen siempre en el mismo día de la semana: basta
    // avanzar de a bloques enteros desde el ancla.
    final elapsed =
        ((today.millisecondsSinceEpoch - anchor.millisecondsSinceEpoch) / (days * _dayMs)).floor() +
        1;
    final candidate = DateTime.fromMillisecondsSinceEpoch(
      anchor.millisecondsSinceEpoch + elapsed * days * _dayMs,
      isUtc: true,
    );
    return _capToEnd(candidate, flow.endDate);
  }

  final step = _monthsBetween[flow.frequency] ?? 1;
  final anchorDay = clock.parts(anchor).day;

  // Se avanza mes a mes desde el ancla hasta pasar hoy. No puede dispararse:
  // como mucho recorre los meses transcurridos desde el alta.
  var cursor = clock.startOfMonth(anchor);
  for (var i = 0; i < 1200; i++) {
    cursor = clock.addMonths(cursor, step);
    // Un flujo que vence el 31 no puede vencer el 31 de febrero: cae en el
    // último día del mes, como hacen los bancos con los débitos.
    final dia = anchorDay < _daysInMonth(cursor, clock) ? anchorDay : _daysInMonth(cursor, clock);
    final p = clock.parts(cursor);
    final candidate = clock.startOfDay(
      '${p.year}-${p.month.toString().padLeft(2, '0')}-${dia.toString().padLeft(2, '0')}',
    );
    if (!candidate.isBefore(today)) return _capToEnd(candidate, flow.endDate);
  }

  return anchor;
}
