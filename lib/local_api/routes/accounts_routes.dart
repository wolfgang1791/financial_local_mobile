import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../data/api.dart' show ApiException;
import '../../local_db/row_mapping.dart';
import '../../local_engine/ledger.dart' show liquidAccountTypes, round2;
import '../../local_engine/user_clock.dart';
import '../current_user.dart';
import '../local_api_router.dart';

const _uuid = Uuid();
const _columnasBooleanas = {'isArchived', 'isHidden'};

/// Las que forman el patrimonio. Misma lista que el motor financiero.
const _tiposLiquidos = {'CHECKING', 'SAVINGS', 'CASH'};
const _columnasFecha = {'createdAt', 'updatedAt'};
const _adjustmentDetail = 'AJUSTE FUERA DE FINANCIAL';

/// Los mismos dos tipos que el backend excluye de este listado: una tarjeta
/// o un préstamo no son dinero disponible, son deuda — viven en `/debts`.

Map<String, dynamic> _accountJson(Map<String, Object?> fila) =>
    mapRow(fila, columnasBooleanas: _columnasBooleanas, columnasFecha: _columnasFecha);

/// Puerto de `openingEntry()`: la primera plata que se registra en una
/// cuenta entra como SALDO INICIAL, no como un movimiento — es el ancla
/// desde la que se reconstruye toda la serie de hitos.
Future<void> _crearAsientoInicial(
  Database db,
  String accountId,
  double amount,
  DateTime occurredAt,
) async {
  await db.insert('Transaction', {
    'id': _uuid.v4(),
    'accountId': accountId,
    'type': amount >= 0 ? 'INCOME' : 'EXPENSE',
    'kind': 'OPENING_BALANCE',
    'amount': amount.abs(),
    'detail': 'Saldo inicial',
    'occurredAt': occurredAt.millisecondsSinceEpoch,
    'createdAt': occurredAt.millisecondsSinceEpoch,
  });
}

void registerAccountsRoutes() {
  // GET /accounts — mismo criterio que `AccountsService.findAllForUser`: las que
  // no son el espejo de una deuda, no archivadas, más viejas primero.
  //
  // Se excluye **por la relación y no por el tipo**. Antes se tomaba "es tarjeta
  // de crédito" como sinónimo de "pertenece a una deuda", y no lo es: una
  // tarjeta de uso diario, que pagas entera cada mes, es una cuenta de lo que
  // debes y no un préstamo con tasa, cuota mínima y plazo. Con el filtro por
  // tipo no había forma de tenerla — no aparecía en ningún selector.
  LocalApiRouter.registerGet('/accounts', (db, uri, body) async {
    final userId = await currentUserId(db);
    final filas = await db.rawQuery(
      'SELECT a.* FROM Account a '
      'WHERE a.userId = ? AND a.isArchived = 0 '
      '  AND NOT EXISTS (SELECT 1 FROM Debt d WHERE d.accountId = a.id) '
      'ORDER BY a.createdAt ASC',
      [userId],
    );
    return filas.map(_accountJson).toList();
  });

  // POST /accounts — una cuenta líquida que arranca con plata ("hoy tengo
  // S/4,320") necesita esa plata en el ledger como SALDO INICIAL, o parte
  // del saldo queda sin explicación.
  LocalApiRouter.registerPost('/accounts', (db, uri, body) async {
    final userId = await currentUserId(db);
    final datos = bodyAsMap(body);
    final clock = await UserClock.forUser(db, userId);
    final id = _uuid.v4();
    final ahora = DateTime.now().toUtc();

    await db.insert('Account', {
      'id': id,
      'userId': userId,
      'name': datos['name'],
      'type': datos['type'],
      'institution': datos['institution'],
      'currentBalance': (datos['currentBalance'] as num).toDouble(),
      'creditLimit': (datos['creditLimit'] as num?)?.toDouble(),
      'currency': (datos['currency'] as String?) ?? 'PEN',
      'isArchived': 0,
      'isHidden': 0,
      'createdAt': ahora.millisecondsSinceEpoch,
      'updatedAt': ahora.millisecondsSinceEpoch,
    });

    final type = campoObligatorio(datos, 'type');
    final balance = (datos['currentBalance'] as num).toDouble();
    if (liquidAccountTypes.contains(type) && balance != 0) {
      final openedAt = datos['openedAt'] != null
          ? clock.toInstantValue(datos['openedAt'] as String)
          : clock.now();
      await _crearAsientoInicial(db, id, balance, openedAt);
    }

    final fila = (await db.query('Account', where: 'id = ?', whereArgs: [id])).first;
    return _accountJson(fila);
  });

  // PATCH /accounts/:id — nunca el saldo: eso solo se mueve por el ledger
  // (un movimiento, o /balance más abajo).
  LocalApiRouter.registerPatch('/accounts/:id', (db, uri, body) async {
    final userId = await currentUserId(db);
    final id = uri.queryParameters['id']!;
    final datos = bodyAsMap(body);

    final existente = await db.query(
      'Account',
      where: 'id = ? AND userId = ?',
      whereArgs: [id, userId],
    );
    if (existente.isEmpty) throw ApiException('Account $id not found', status: 404);

    final cambios = <String, Object?>{'updatedAt': DateTime.now().toUtc().millisecondsSinceEpoch};
    for (final campo in ['name', 'type', 'institution', 'currency', 'creditLimit']) {
      if (datos.containsKey(campo)) cambios[campo] = datos[campo];
    }
    if (datos.containsKey('isHidden')) {
      final ocultar = datos['isHidden'] as bool;
      // No se puede ocultar la última cuenta que cuenta.
      //
      // Quedarse sin patrimonio no es un estado que nadie elija a propósito, y
      // la app entera se apaga con él: el patrimonio queda en cero, los hitos no
      // tienen de dónde salir, y **los movimientos desaparecen de todas las
      // listas** —el historial filtra por cuentas que cuentan— así que Panorama
      // contesta "sin registros todavía" con todo guardado. Pasó de verdad, y
      // desde la app no había forma de entender por qué.
      //
      // El candado va acá y no solo en la pantalla: es la única forma de que
      // valga igual venga de donde venga la llamada.
      if (ocultar && (existente.first['isHidden'] as int? ?? 0) == 0) {
        final marcas = List.filled(_tiposLiquidos.length, '?').join(',');
        final quedan = await db.rawQuery(
          'SELECT COUNT(*) AS n FROM Account '
          'WHERE userId = ? AND isArchived = 0 AND isHidden = 0 AND type IN ($marcas)',
          [userId, ..._tiposLiquidos],
        );
        if ((quedan.first['n'] as num).toInt() <= 1) {
          throw const ApiException(
            'Es la única cuenta que cuenta en tu patrimonio. Si la ocultas no queda '
            'ninguna, y todos tus movimientos dejarían de verse.',
          );
        }
      }
      cambios['isHidden'] = ocultar ? 1 : 0;
    }

    await db.update('Account', cambios, where: 'id = ?', whereArgs: [id]);
    final fila = (await db.query('Account', where: 'id = ?', whereArgs: [id])).first;
    return _accountJson(fila);
  });

  // POST /accounts/:id/balance — "en realidad tengo X": la diferencia queda
  // en el ledger como un ajuste, nunca se pisa el número en silencio.
  LocalApiRouter.registerPost('/accounts/:id/balance', (db, uri, body) async {
    final userId = await currentUserId(db);
    final id = uri.queryParameters['id']!;
    final datos = bodyAsMap(body);

    final filas = await db.query(
      'Account',
      where: 'id = ? AND userId = ?',
      whereArgs: [id, userId],
    );
    if (filas.isEmpty) throw ApiException('Account $id not found', status: 404);
    final cuenta = filas.first;
    final clock = await UserClock.forUser(db, userId);

    final actual = (cuenta['currentBalance'] as num).toDouble();
    final nuevo = (datos['balance'] as num).toDouble();
    final esperado = (datos['expectedBalance'] as num?)?.toDouble();
    // La verificación va antes de escribir nada: dos ediciones a la vez no
    // pueden pisarse una a la otra sin que ninguna lo note.
    if (esperado != null && round2(esperado) != round2(actual)) {
      throw ApiException(
        'El saldo cambió mientras confirmabas: ahora es ${actual.toStringAsFixed(2)} y no ${esperado.toStringAsFixed(2)}. Vuelve a revisar antes de ajustar.',
      );
    }

    final delta = round2(nuevo - actual);
    if (delta == 0) return _accountJson(cuenta);

    final occurredAt = datos['occurredAt'] != null
        ? clock.toInstantValue(datos['occurredAt'] as String)
        : clock.now();
    final entryCountFila = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM "Transaction" WHERE accountId = ?',
      [id],
    );
    final entryCount = (entryCountFila.first['n'] as num).toInt();

    if (entryCount == 0) {
      await _crearAsientoInicial(db, id, delta, occurredAt);
    } else {
      await db.insert('Transaction', {
        'id': _uuid.v4(),
        'accountId': id,
        'type': delta > 0 ? 'INCOME' : 'EXPENSE',
        'kind': 'ADJUSTMENT',
        'amount': delta.abs(),
        'detail': _adjustmentDetail,
        'occurredAt': occurredAt.millisecondsSinceEpoch,
        'createdAt': occurredAt.millisecondsSinceEpoch,
      });
    }

    await db.update(
      'Account',
      {'currentBalance': nuevo, 'updatedAt': DateTime.now().toUtc().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
    final fila = (await db.query('Account', where: 'id = ?', whereArgs: [id])).first;
    return _accountJson(fila);
  });

  // GET /accounts/:id/deletion-impact — qué se lleva borrarla, para poder
  // advertirlo antes de preguntar.
  LocalApiRouter.registerGet('/accounts/:id/deletion-impact', (db, uri, body) async {
    final userId = await currentUserId(db);
    final id = uri.queryParameters['id']!;

    final filas = await db.query(
      'Account',
      where: 'id = ? AND userId = ?',
      whereArgs: [id, userId],
    );
    if (filas.isEmpty) throw ApiException('Account $id not found', status: 404);
    final cuenta = filas.first;

    final movimientos =
        (await db.rawQuery('SELECT COUNT(*) AS n FROM "Transaction" WHERE accountId = ?', [
              id,
            ])).first['n']
            as int;
    final pagosDeuda =
        (await db.rawQuery(
              'SELECT COUNT(*) AS n FROM "Transaction" WHERE accountId = ? AND debtId IS NOT NULL',
              [id],
            )).first['n']
            as int;
    final flujos =
        (await db.rawQuery('SELECT COUNT(*) AS n FROM RecurringFlow WHERE accountId = ?', [
              id,
            ])).first['n']
            as int;

    final esEspejoDeDeuda =
        ((await db.rawQuery('SELECT COUNT(*) AS n FROM Debt WHERE accountId = ?', [id])).first['n']
                as num)
            .toInt() >
        0;

    return {
      'name': cuenta['name'],
      'balance': (cuenta['currentBalance'] as num).toDouble(),
      'movements': movimientos,
      'recurringFlows': flujos,
      // Por la relación y no por el tipo: lo que no se puede borrar por acá es
      // el espejo de una deuda —se iría con ella—, no cualquier tarjeta.
      'blockedBy': esEspejoDeDeuda ? 'DEBT_ACCOUNT' : (pagosDeuda > 0 ? 'DEBT_PAYMENTS' : null),
      'debtPayments': pagosDeuda,
    };
  });

  // DELETE /accounts/:id — archiva (reversible): la cuenta deja de contar
  // pero sigue existiendo, para poder mostrarla de nuevo.
  LocalApiRouter.registerDelete('/accounts/:id', (db, uri, body) async {
    final userId = await currentUserId(db);
    final id = uri.queryParameters['id']!;
    final existente = await db.query(
      'Account',
      where: 'id = ? AND userId = ?',
      whereArgs: [id, userId],
    );
    if (existente.isEmpty) throw ApiException('Account $id not found', status: 404);

    await db.update(
      'Account',
      {'isArchived': 1, 'updatedAt': DateTime.now().toUtc().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
    final fila = (await db.query('Account', where: 'id = ?', whereArgs: [id])).first;
    return _accountJson(fila);
  });

  // DELETE /accounts/:id/permanently — borrado de verdad, con sus
  // movimientos. Antes de la ruta con menos segmentos para que el router no
  // la confunda: acá no hace falta, cada patrón tiene su propio largo.
  LocalApiRouter.registerDelete('/accounts/:id/permanently', (db, uri, body) async {
    final userId = await currentUserId(db);
    final id = uri.queryParameters['id']!;

    final filas = await db.query(
      'Account',
      where: 'id = ? AND userId = ?',
      whereArgs: [id, userId],
    );
    if (filas.isEmpty) throw ApiException('Account $id not found', status: 404);

    // Por la relación y no por el tipo, igual que arriba.
    final tieneDeuda =
        ((await db.rawQuery('SELECT COUNT(*) AS n FROM Debt WHERE accountId = ?', [id])).first['n']
                as num)
            .toInt() >
        0;
    if (tieneDeuda) {
      throw ApiException('Account $id belongs to a debt. Delete the debt instead.');
    }

    final pagosDeuda =
        (await db.rawQuery(
              'SELECT COUNT(*) AS n FROM "Transaction" WHERE accountId = ? AND debtId IS NOT NULL',
              [id],
            )).first['n']
            as int;
    if (pagosDeuda > 0) {
      throw ApiException(
        'Account $id has $pagosDeuda debt payment(s) and cannot be deleted, because deleting them would '
        'leave those debts amortized by movements that no longer exist. Hide the account instead.',
      );
    }

    await db.update('RecurringFlow', {'accountId': null}, where: 'accountId = ?', whereArgs: [id]);
    await db.update(
      'Goal',
      {'linkedAccountId': null},
      where: 'linkedAccountId = ?',
      whereArgs: [id],
    );
    await db.delete('Transaction', where: 'accountId = ?', whereArgs: [id]);
    await db.delete('Account', where: 'id = ?', whereArgs: [id]);

    return {'id': id, 'deleted': true};
  });
}
