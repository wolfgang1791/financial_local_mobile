import '../../local_engine/ledger.dart' show round2;
import '../../local_engine/milestones_engine.dart' as milestones;
import '../../local_engine/user_clock.dart';
import '../current_user.dart';
import '../local_api_router.dart';

const _liquidAccountTypes = {'CHECKING', 'SAVINGS', 'CASH'};

void registerFinancialEngineRoutes() {
  // GET /financial-engine/safe-to-spend — cuánto puedo gastar hoy sin
  // afectar mi presupuesto: liquidez disponible tras los gastos fijos
  // comprometidos hasta el próximo ingreso, repartida en los días que
  // faltan.
  LocalApiRouter.registerGet('/financial-engine/safe-to-spend', (db, uri, body) async {
    final userId = await currentUserId(db);
    final placeholdersTipo = List.filled(_liquidAccountTypes.length, '?').join(',');
    final cuentas = await db.query(
      'Account',
      where: 'userId = ? AND isArchived = 0 AND isHidden = 0 AND type IN ($placeholdersTipo)',
      whereArgs: [userId, ..._liquidAccountTypes],
    );
    final liquidAssets = cuentas.fold<double>(
      0,
      (acc, a) => acc + (a['currentBalance'] as num).toDouble(),
    );

    final flujos = await db.query(
      'RecurringFlow',
      where: 'userId = ? AND isActive = 1',
      whereArgs: [userId],
    );
    final hoy = DateTime.now().toUtc();

    final ingresos = flujos.where((f) => f['type'] == 'INCOME').toList()
      ..sort((a, b) => (a['nextDueDate'] as int).compareTo(b['nextDueDate'] as int));
    final proximoIngreso = ingresos.isEmpty ? null : ingresos.first;

    final horizonte = proximoIngreso != null
        ? DateTime.fromMillisecondsSinceEpoch(proximoIngreso['nextDueDate'] as int, isUtc: true)
        : hoy.add(const Duration(days: 30));
    final diasHastaHorizonte =
        ((horizonte.millisecondsSinceEpoch - hoy.millisecondsSinceEpoch) / (24 * 60 * 60 * 1000))
            .ceil();
    final dias = diasHastaHorizonte < 1 ? 1 : diasHastaHorizonte;

    final gastosPorVenir = flujos
        .where(
          (f) =>
              f['type'] == 'EXPENSE' &&
              (f['nextDueDate'] as int) <= horizonte.millisecondsSinceEpoch,
        )
        .fold<double>(0, (acc, f) => acc + (f['amount'] as num).toDouble());

    final disponible = (liquidAssets - gastosPorVenir).clamp(0, double.infinity);
    final safeToSpendToday = round2(disponible / dias);

    return {
      'liquidAssets': liquidAssets,
      'upcomingExpenses': gastosPorVenir,
      'daysUntilHorizon': dias,
      'horizon': horizonte.toIso8601String(),
      'safeToSpendToday': safeToSpendToday,
    };
  });

  // GET /financial-engine/cash-position — lo que lee la tarjeta de
  // patrimonio: cuánta plata líquida hay ahora mismo, por cuenta, más cómo
  // llegó ahí el mes en curso (movimientos reales, no proyectados).
  LocalApiRouter.registerGet('/financial-engine/cash-position', (db, uri, body) async {
    final userId = await currentUserId(db);
    final clock = await UserClock.forUser(db, userId);
    final monthStart = clock.startOfMonth();
    final monthEnd = clock.endOfMonth();

    // Las líquidas más las tarjetas de uso diario —las de crédito **sin** deuda
    // asociada—: lo que debes ahí es plata que vas a pagar, y no verla en ningún
    // sitio es peor que verla. No suman al total, igual que las ocultas.
    //
    // El espejo de un préstamo no entra: eso vive en Deudas con su cronograma, y
    // repetirlo acá sería contarlo dos veces en dos idiomas.
    final placeholdersTipo = List.filled(_liquidAccountTypes.length, '?').join(',');
    final cuentas = await db.rawQuery(
      'SELECT a.* FROM Account a '
      'WHERE a.userId = ? AND a.isArchived = 0 AND ('
      '  a.type IN ($placeholdersTipo)'
      "  OR (a.type = 'CREDIT_CARD' AND NOT EXISTS ("
      '    SELECT 1 FROM Debt d WHERE d.accountId = a.id))'
      ') ORDER BY a.createdAt ASC',
      [userId, ..._liquidAccountTypes],
    );

    final transacciones = await db.rawQuery(
      '''
      SELECT t.type AS type, t.amount AS amount FROM "Transaction" t
      JOIN Account a ON a.id = t.accountId
      WHERE a.userId = ? AND a.isHidden = 0 AND t.occurredAt >= ? AND t.occurredAt <= ? AND t.kind = 'MOVEMENT'
      ''',
      [userId, monthStart.millisecondsSinceEpoch, monthEnd.millisecondsSinceEpoch],
    );

    final income = transacciones
        .where((t) => t['type'] == 'INCOME')
        .fold<double>(0, (acc, t) => acc + (t['amount'] as num).toDouble());
    final expenses = transacciones
        .where((t) => t['type'] == 'EXPENSE')
        .fold<double>(0, (acc, t) => acc + (t['amount'] as num).toDouble());

    // Una tarjeta nunca entra al total: su saldo es lo que debes, no lo que
    // tienes. Sumarla haría que comprar con crédito subiera tu patrimonio.
    final total = round2(
      cuentas
          .where(
            (a) => (a['isHidden'] as int) == 0 && _liquidAccountTypes.contains(a['type'] as String),
          )
          .fold<double>(0, (acc, a) => acc + (a['currentBalance'] as num).toDouble()),
    );

    return {
      'total': total,
      'accounts': cuentas
          .map(
            (a) => {
              'id': a['id'],
              'name': a['name'],
              'type': a['type'],
              'currentBalance': (a['currentBalance'] as num).toDouble(),
              'currency': a['currency'],
              'isHidden': (a['isHidden'] as int) == 1,
              // El cupo, para decir cuánto queda y no solo cuánto se debe.
              'creditLimit': (a['creditLimit'] as num?)?.toDouble(),
            },
          )
          .toList(),
      'month': {
        'key': clock.monthKey(),
        'income': round2(income),
        'expenses': round2(expenses),
        'net': round2(income - expenses),
      },
    };
  });

  // GET /financial-engine/net-worth-history — un punto por mes calendario,
  // el mes en curso marcado aparte para que su cifra (que todavía se mueve)
  // no se lea como una caída.
  LocalApiRouter.registerGet('/financial-engine/net-worth-history', (db, uri, body) async {
    final userId = await currentUserId(db);
    final puntos = await milestones.getNetWorthHistory(db, userId);
    return puntos
        .map(
          (p) => {
            'month': p.month,
            'liquid': p.liquid,
            'delta': p.delta,
            'income': p.income,
            'expenses': p.expenses,
            'inProgress': p.inProgress,
          },
        )
        .toList();
  });

  // GET /financial-engine/spending-history — el gasto mes a mes, partido en
  // fijos, cuotas y vida. Las tres piezas viajan juntas para que apagar lo
  // comprometido sea una resta en la pantalla y no otra llamada.
  LocalApiRouter.registerGet('/financial-engine/spending-history', (db, uri, body) async {
    final userId = await currentUserId(db);
    final puntos = await milestones.getSpendingHistory(db, userId);
    return puntos.map((p) => p.toJson()).toList();
  });

  // GET /financial-engine/net-worth-daily — la curva acumulada, un punto
  // por día desde que hay registros.
  LocalApiRouter.registerGet('/financial-engine/net-worth-daily', (db, uri, body) async {
    final userId = await currentUserId(db);
    final puntos = await milestones.getDailyNetWorth(db, userId);
    return puntos
        .map(
          (p) => {'date': p.date, 'liquid': p.liquid, 'moved': p.moved, 'byAccount': p.byAccount},
        )
        .toList();
  });
}
