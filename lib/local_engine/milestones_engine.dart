import 'package:sqflite/sqflite.dart';

import 'ledger.dart' show round2, signedAmount;
import 'user_clock.dart';

/// Puerto de lectura de `backend/src/milestones/milestones.service.ts` —
/// todo se reconstruye del ledger, nada se lee de una caché. La escritura
/// de `FinancialSnapshot` (`materialize()`) no se porta: es una vista
/// materializada para otros consumidores (recomendaciones con IA) que este
/// clon no tiene — la fuente de verdad sigue siendo el ledger, así que
/// omitirla no cambia ningún número que la app muestre.

class _LedgerEntry {
  const _LedgerEntry({
    required this.type,
    required this.amount,
    required this.occurredAt,
    required this.kind,
    this.accountId = '',
  });
  final String type;
  final double amount;
  final DateTime occurredAt;
  final String kind;

  /// De qué cuenta salió. Solo lo usa la curva diaria, que reparte el saldo por
  /// cuenta para que el gráfico pueda elegir cuáles dibuja.
  final String accountId;
}

class Milestone {
  const Milestone({
    required this.kind,
    required this.month,
    required this.date,
    required this.liquid,
    required this.movementsIncome,
    required this.movementsExpenses,
  });

  final String kind; // OPENING | CLOSE | IN_PROGRESS
  final String month;
  final DateTime date;
  final double liquid;
  final double movementsIncome;
  final double movementsExpenses;
}

class NetWorthPoint {
  const NetWorthPoint({
    required this.month,
    required this.liquid,
    required this.delta,
    required this.income,
    required this.expenses,
    required this.inProgress,
  });
  final String month;
  final double liquid;
  final double delta;
  final double income;
  final double expenses;
  final bool inProgress;
}

class DailyNetWorthPoint {
  const DailyNetWorthPoint({
    required this.date,
    required this.liquid,
    required this.moved,
    this.byAccount = const {},
  });
  final String date;
  final double liquid;
  final double moved;

  /// El saldo de cada cuenta ese día, por su id — incluidas las que están fuera
  /// del patrimonio.
  ///
  /// Es lo que permite que el gráfico deje elegir qué cuentas dibuja **sin
  /// tocar nada**: filtrar por `isHidden` sacaría esa cuenta de toda la app, y
  /// mirar un gráfico no debería cambiarle los totales a nadie. La suma de las
  /// que cuentan es exactamente `liquid`.
  final Map<String, double> byAccount;
}

const _liquidAccountTypes = {'CHECKING', 'SAVINGS', 'CASH'};
const _maxDailyPoints = 730;

String _dayKey(DateTime instant, UserClock clock) {
  final p = clock.parts(instant);
  return '${p.year}-${p.month.toString().padLeft(2, '0')}-${p.day.toString().padLeft(2, '0')}';
}

Future<List<Map<String, Object?>>> _accountsNoArchivadas(Database db, String userId) =>
    db.query('Account', where: 'userId = ? AND isArchived = 0', whereArgs: [userId]);

Future<List<_LedgerEntry>> _entradasDe(
  Database db,
  List<String> accountIds, {
  String orderBy = 'occurredAt ASC',
}) async {
  if (accountIds.isEmpty) return [];
  final placeholders = List.filled(accountIds.length, '?').join(',');
  final filas = await db.rawQuery(
    'SELECT type, amount, occurredAt, kind, accountId FROM "Transaction" '
    'WHERE accountId IN ($placeholders) ORDER BY $orderBy',
    accountIds,
  );
  return filas
      .map(
        (f) => _LedgerEntry(
          type: f['type'] as String,
          amount: (f['amount'] as num).toDouble(),
          occurredAt: DateTime.fromMillisecondsSinceEpoch(f['occurredAt'] as int, isUtc: true),
          kind: f['kind'] as String,
          accountId: f['accountId'] as String,
        ),
      )
      .toList();
}

({DateTime date, bool fromOpeningEntry}) _anchorDate(
  List<Map<String, Object?>> accounts,
  List<_LedgerEntry> entries,
  UserClock clock,
) {
  final apertura = entries.where((e) => e.kind == 'OPENING_BALANCE').firstOrNull;
  if (apertura != null) return (date: apertura.occurredAt, fromOpeningEntry: true);

  final candidatos = [
    ...accounts.map((a) => DateTime.fromMillisecondsSinceEpoch(a['createdAt'] as int, isUtc: true)),
    ...entries.map((e) => e.occurredAt),
  ];
  final primero = candidatos.reduce((min, d) => d.isBefore(min) ? d : min);
  return (date: clock.startOfDayOf(primero), fromOpeningEntry: false);
}

(double income, double expenses) _monthMovements(
  List<_LedgerEntry> entries,
  DateTime monthStart,
  UserClock clock,
) {
  final from = clock.startOfMonth(monthStart);
  final to = clock.endOfMonth(from);
  final enElMes = entries.where(
    (e) => e.kind == 'MOVEMENT' && !e.occurredAt.isBefore(from) && !e.occurredAt.isAfter(to),
  );
  double sumaDe(String type) =>
      round2(enElMes.where((e) => e.type == type).fold<double>(0, (acc, e) => acc + e.amount));
  return (sumaDe('INCOME'), sumaDe('EXPENSE'));
}

class MilestoneSeries {
  const MilestoneSeries({required this.opening, required this.milestones});
  final Milestone? opening;
  final List<Milestone> milestones;
}

Future<MilestoneSeries> getSeries(Database db, String userId) async {
  final clock = await UserClock.forUser(db, userId);
  final cuentas = await _accountsNoArchivadas(db, userId);
  final cuentasLiquidas = cuentas
      .where((a) => _liquidAccountTypes.contains(a['type']) && (a['isHidden'] as int) == 0)
      .toList();

  if (cuentasLiquidas.isEmpty) return const MilestoneSeries(opening: null, milestones: []);

  final currentLiquid = round2(
    cuentasLiquidas.fold<double>(0, (acc, a) => acc + (a['currentBalance'] as num).toDouble()),
  );

  final entries = await _entradasDe(db, cuentasLiquidas.map((a) => a['id'] as String).toList());

  double balanceAt(DateTime instant, {bool before = false}) {
    final movidoDespues = entries
        .where((e) => before ? !e.occurredAt.isBefore(instant) : e.occurredAt.isAfter(instant))
        .fold<double>(0, (acc, e) => acc + signedAmount(e.type, e.amount));
    return round2(currentLiquid - movidoDespues);
  }

  final now = clock.now();
  final ancla = _anchorDate(cuentasLiquidas, entries, clock);

  final opening = Milestone(
    kind: 'OPENING',
    month: clock.monthKey(ancla.date),
    date: ancla.date,
    liquid: balanceAt(ancla.date, before: !ancla.fromOpeningEntry),
    movementsIncome: 0,
    movementsExpenses: 0,
  );

  final closes = <Milestone>[];
  var cursor = clock.startOfMonth(ancla.date);
  final currentMonthStart = clock.startOfMonth(now);
  while (cursor.isBefore(currentMonthStart)) {
    final date = clock.endOfMonth(cursor);
    final (income, expenses) = _monthMovements(entries, cursor, clock);
    closes.add(
      Milestone(
        kind: 'CLOSE',
        month: clock.monthKey(cursor),
        date: date,
        liquid: balanceAt(date),
        movementsIncome: income,
        movementsExpenses: expenses,
      ),
    );
    cursor = clock.addMonths(cursor, 1);
  }

  final (incomeActual, expensesActual) = _monthMovements(entries, currentMonthStart, clock);
  final current = Milestone(
    kind: 'IN_PROGRESS',
    month: clock.monthKey(now),
    date: now,
    liquid: currentLiquid,
    movementsIncome: incomeActual,
    movementsExpenses: expensesActual,
  );

  return MilestoneSeries(opening: opening, milestones: [opening, ...closes, current]);
}

/// Un mes de gasto, partido en las tres cosas que lo componen.
class SpendingPoint {
  const SpendingPoint({
    required this.month,
    required this.total,
    required this.fixed,
    required this.debt,
    required this.life,
    required this.count,
    required this.inProgress,
  });

  final String month;

  /// Todo el gasto corriente del mes: la suma de los tres de abajo.
  final double total;

  /// Lo que se fue en pagos de un gasto fijo.
  final double fixed;

  /// Lo que se fue en cuotas de deuda.
  final double debt;

  /// El resto: lo que decidiste tú.
  final double life;

  final int count;

  /// El mes en curso todavía no terminó: compararlo con los cerrados sin avisar
  /// hace pensar que vas mucho mejor cuando lo que pasa es que aún no acaba.
  final bool inProgress;

  Map<String, dynamic> toJson() => {
    'month': month,
    'total': total,
    'fixed': fixed,
    'debt': debt,
    'life': life,
    'count': count,
    'inProgress': inProgress,
  };
}

/// El gasto mes a mes, partido en fijos, cuotas y vida.
///
/// Las tres piezas y no solo la vida: quien mira la curva decide qué contar
/// —con lo comprometido o sin ello— y ese interruptor vive en la pantalla. Si
/// el motor devolviera únicamente el resto, apagarlo obligaría a pedir la serie
/// otra vez, y a que dos llamadas distintas se pusieran de acuerdo.
///
/// "De la vida" es el complemento de lo comprometido: ni cuotas de deuda ni
/// pagos de un gasto fijo. Es lo que decidiste tú, y por eso es la única pieza
/// sobre la que tiene sentido preguntarse si va subiendo — el alquiler no sube
/// porque hayas salido más.
///
/// Solo `MOVEMENT`: una corrección de saldo hacia abajo no es plata que
/// gastaste, y contarla haría que arreglar la contabilidad pareciera un mes malo.
///
/// La rejilla de meses es fija —no "los meses con datos"— pero cortada por la
/// izquierda en el primer registro: un mes sin gasto suelto es un dato, y diez
/// meses en cero antes de que la app existiera no lo son.
Future<List<SpendingPoint>> getSpendingHistory(
  Database db,
  String userId, {
  int months = 12,
}) async {
  final clock = await UserClock.forUser(db, userId);
  final cuentas = await db.query(
    'Account',
    columns: ['id'],
    where: 'userId = ? AND isHidden = 0',
    whereArgs: [userId],
  );
  if (cuentas.isEmpty) return [];
  final ids = cuentas.map((c) => c['id'] as String).toList();
  final marcas = List.filled(ids.length, '?').join(',');

  final ahora = clock.now();
  final claves = <String>[
    for (var i = months - 1; i >= 0; i--) clock.monthKey(clock.addMonths(ahora, -i)),
  ];
  final desde = clock.startOfMonth(clock.addMonths(ahora, -(months - 1)));

  // Todo el gasto corriente, sin descartar lo comprometido: se parte acá abajo.
  final gastos = await db.rawQuery(
    'SELECT amount, occurredAt, recurringFlowId, debtId FROM "Transaction" '
    'WHERE accountId IN ($marcas) '
    "AND type = 'EXPENSE' AND kind = 'MOVEMENT' "
    'AND occurredAt >= ?',
    [...ids, desde.millisecondsSinceEpoch],
  );

  final porMes = {
    for (final k in claves)
      k: <String, double>{'total': 0, 'fijos': 0, 'cuotas': 0, 'vida': 0, 'cuantos': 0},
  };
  for (final g in gastos) {
    final cuando = DateTime.fromMillisecondsSinceEpoch(g['occurredAt'] as int, isUtc: true);
    final punto = porMes[clock.monthKey(cuando)];
    if (punto == null) continue;
    final monto = (g['amount'] as num).toDouble();
    punto['total'] = punto['total']! + monto;
    punto['cuantos'] = punto['cuantos']! + 1;
    // Una cuota primero: un pago de deuda que además cuelgue de un flujo
    // recurrente es una cuota, y contarlo en los dos sitios haría que las tres
    // piezas sumaran más que el total.
    if (g['debtId'] != null) {
      punto['cuotas'] = punto['cuotas']! + monto;
    } else if (g['recurringFlowId'] != null) {
      punto['fijos'] = punto['fijos']! + monto;
    } else {
      punto['vida'] = punto['vida']! + monto;
    }
  }

  // Se corta por la izquierda en el primer registro. Sin esto, alguien con dos
  // meses de historia ve diez meses en cero y la línea dice que gastaba nada en
  // enero — no gastaba nada, es que la app no existía.
  final primeras = await db.rawQuery(
    'SELECT MIN(occurredAt) AS primero FROM "Transaction" WHERE accountId IN ($marcas)',
    ids,
  );
  final primeroMs = primeras.first['primero'] as int?;
  final desdeElPrimero = primeroMs == null
      ? claves.first
      : clock.monthKey(DateTime.fromMillisecondsSinceEpoch(primeroMs, isUtc: true));

  final mesActual = clock.monthKey(ahora);
  return [
    for (final k in claves.where((k) => k.compareTo(desdeElPrimero) >= 0))
      SpendingPoint(
        month: k,
        total: round2(porMes[k]!['total']!),
        fixed: round2(porMes[k]!['fijos']!),
        debt: round2(porMes[k]!['cuotas']!),
        life: round2(porMes[k]!['vida']!),
        count: porMes[k]!['cuantos']!.toInt(),
        inProgress: k == mesActual,
      ),
  ];
}

Future<List<NetWorthPoint>> getNetWorthHistory(Database db, String userId) async {
  final serie = await getSeries(db, userId);
  if (serie.opening == null) return [];

  var previous = serie.opening!.liquid;
  final puntos = <NetWorthPoint>[];
  for (final m in serie.milestones.where((m) => m.kind != 'OPENING')) {
    puntos.add(
      NetWorthPoint(
        month: m.month,
        liquid: m.liquid,
        delta: round2(m.liquid - previous),
        income: m.movementsIncome,
        expenses: m.movementsExpenses,
        inProgress: m.kind == 'IN_PROGRESS',
      ),
    );
    previous = m.liquid;
  }
  return puntos;
}

Future<List<DailyNetWorthPoint>> getDailyNetWorth(
  Database db,
  String userId, {
  int maxDays = _maxDailyPoints,
}) async {
  final clock = await UserClock.forUser(db, userId);
  final placeholdersTipo = List.filled(_liquidAccountTypes.length, '?').join(',');
  // Dos conjuntos, a propósito. `contadas` son las que forman el patrimonio —de
  // ellas sale `liquid`—; `todas` incluye además las apagadas, cuyo saldo viaja
  // en el desglose para que el gráfico pueda ofrecerlas como filtro de la vista
  // sin volver a contarlas en ningún total.
  final todas = await db.query(
    'Account',
    where: 'userId = ? AND isArchived = 0 AND type IN ($placeholdersTipo)',
    whereArgs: [userId, ..._liquidAccountTypes],
  );
  if (todas.isEmpty) return [];
  final cuentas = todas.where((a) => (a['isHidden'] as int? ?? 0) == 0).toList();

  final entries = await _entradasDe(db, todas.map((a) => a['id'] as String).toList());
  if (entries.isEmpty) return [];

  final contadas = cuentas.map((a) => a['id'] as String).toSet();
  final movidoPorDia = <String, double>{};
  final movidoPorDiaYCuenta = <String, Map<String, double>>{};
  for (final e in entries) {
    final key = _dayKey(e.occurredAt, clock);
    final firmado = signedAmount(e.type, e.amount);
    // El total solo cuenta las del patrimonio: si una apagada entrara acá, la
    // curva dejaría de terminar en la cifra de la tarjeta.
    if (contadas.contains(e.accountId)) {
      movidoPorDia[key] = (movidoPorDia[key] ?? 0) + firmado;
    }
    final delDia = movidoPorDiaYCuenta[key] ??= {};
    delDia[e.accountId] = (delDia[e.accountId] ?? 0) + firmado;
  }

  final today = clock.startOfDayOf(clock.now());
  var cursor = clock.startOfDayOf(entries.first.occurredAt);

  final currentLiquid = round2(
    cuentas.fold<double>(0, (acc, a) => acc + (a['currentBalance'] as num).toDouble()),
  );
  final movidoDesdeInicio = movidoPorDia.values.fold<double>(0, (a, b) => a + b);
  var running = round2(currentLiquid - movidoDesdeInicio);

  // El mismo cálculo, cuenta por cuenta: cada una arranca en su saldo de hoy
  // menos todo lo suyo que pasó desde el principio.
  final porCuenta = <String, double>{};
  for (final a in todas) {
    final id = a['id'] as String;
    var movidoSuyo = 0.0;
    for (final delDia in movidoPorDiaYCuenta.values) {
      movidoSuyo += delDia[id] ?? 0;
    }
    porCuenta[id] = round2((a['currentBalance'] as num).toDouble() - movidoSuyo);
  }

  final puntos = <DailyNetWorthPoint>[];
  while (!cursor.isAfter(today) && puntos.length < maxDays) {
    final key = _dayKey(cursor, clock);
    final moved = round2(movidoPorDia[key] ?? 0);
    running = round2(running + moved);
    final delDia = movidoPorDiaYCuenta[key];
    if (delDia != null) {
      for (final entrada in delDia.entries) {
        porCuenta[entrada.key] = round2((porCuenta[entrada.key] ?? 0) + entrada.value);
      }
    }
    puntos.add(
      DailyNetWorthPoint(
        date: key,
        liquid: running,
        moved: moved,
        byAccount: Map<String, double>.from(porCuenta),
      ),
    );
    cursor = clock.startOfDayOf(cursor.add(const Duration(days: 1)));
  }

  return puntos.length < maxDays ? puntos : puntos.sublist(puntos.length - maxDays);
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
