import 'package:sqflite/sqflite.dart';

import 'timezone_util.dart';

/// El reloj del usuario: qué día y qué mes son *para él* — puerto directo
/// de `backend/src/common/user-clock.service.ts`. Todo lo que necesita una
/// frontera de tiempo (flujos recurrentes, deudas, ledger) pasa por acá en
/// vez de calcularla por su cuenta, para que "este mes" signifique lo mismo
/// en toda la app.
class UserClock {
  const UserClock(this.timeZone);

  final String timeZone;

  static Future<UserClock> forUser(Database db, String userId) async {
    final filas = await db.query(
      'User',
      columns: ['timezone'],
      where: 'id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    return UserClock(filas.isEmpty ? 'UTC' : (filas.first['timezone'] as String? ?? 'UTC'));
  }

  DateTime now() => DateTime.now().toUtc();

  DateTime toInstantValue(String value) => toInstant(value, timeZone);

  DateTime startOfDay(String date) => startOfDayInZone(date, timeZone);

  DateTime startOfMonth([DateTime? instant]) => startOfMonthInZone(instant ?? now(), timeZone);

  DateTime endOfMonth([DateTime? instant]) => endOfMonthInZone(instant ?? now(), timeZone);

  DateTime addMonths(DateTime instant, int count) => addMonthsInZone(instant, count, timeZone);

  String monthKey([DateTime? instant]) => monthKeyInZone(instant ?? now(), timeZone);

  ZonedParts parts([DateTime? instant]) => zonedParts(instant ?? now(), timeZone);

  /// El inicio del día en que cae ese instante, para el usuario.
  DateTime startOfDayOf(DateTime instant) {
    final p = parts(instant);
    return startOfDay(
      '${p.year}-${p.month.toString().padLeft(2, '0')}-${p.day.toString().padLeft(2, '0')}',
    );
  }
}
