import 'user_clock.dart';

/// Puerto directo de `backend/src/common/months.util.ts`.

/// Los meses ya cerrados desde [from] — el mes en curso queda fuera a
/// propósito: todavía se puede pagar, así que no es un mes "sin
/// registrar", es un mes pendiente. Del más viejo al más nuevo, recortado a
/// los últimos [limit].
List<String> closedMonthsSince(DateTime from, DateTime now, UserClock clock, {int limit = 6}) {
  final meses = <String>[];
  final mesActual = clock.startOfMonth(now);
  var cursor = clock.startOfMonth(from);

  while (cursor.isBefore(mesActual)) {
    meses.add(clock.monthKey(cursor));
    cursor = clock.addMonths(cursor, 1);
  }

  return meses.length > limit ? meses.sublist(meses.length - limit) : meses;
}

/// Los meses cerrados en los que algo debía registrarse y no se registró —
/// se derivan restando [paidMonths], sin ninguna bandera que mantener.
List<String> missedMonthsSince(
  DateTime from,
  Set<String> paidMonths,
  DateTime now,
  UserClock clock, {
  int limit = 6,
}) {
  return closedMonthsSince(
    from,
    now,
    clock,
    limit: limit,
  ).where((m) => !paidMonths.contains(m)).toList();
}

/// El final de un rango, para un filtro que compara con `<=`.
///
/// El API —el local y el de verdad— filtra `occurredAt <= to`, así que un `to`
/// armado como "el inicio del día siguiente" deja entrar los movimientos de las
/// 00:00 de ese día: un filtro que decía "del 1 al 21" traía un gasto del 22,
/// que es la hora exacta con la que se guarda un gasto anotado sin hora.
///
/// Un milisegundo antes lo deja fuera sin perder los de última hora del 21, que
/// es lo que se buscaba evitar al no cortar en 23:59:59.
DateTime finInclusivo(DateTime inicioDelSiguiente) =>
    inicioDelSiguiente.subtract(const Duration(milliseconds: 1));
