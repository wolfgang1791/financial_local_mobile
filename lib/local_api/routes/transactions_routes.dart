import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../data/api.dart' show ApiException;
import '../../local_db/row_mapping.dart';
import '../../local_engine/ledger.dart';
import '../../local_engine/user_clock.dart';
import '../current_user.dart';
import '../local_api_router.dart';
import 'categories_routes.dart';

const _uuid = Uuid();

const _columnasFecha = {'occurredAt', 'createdAt'};
const maxPageSize = 1000;

/// El id pedido, más los de sus subcategorías si las tiene — puerto de
/// `TransactionsService.categoryIdsForFilter`. Filtrar por una categoría con
/// hijas cuenta todo lo de abajo, no solo lo que se etiquetó directo con el
/// general.
Future<List<String>> categoryIdsForFilter(Database db, String categoryId) async {
  final hijas = await db.query(
    'Category',
    columns: ['id'],
    where: 'parentId = ?',
    whereArgs: [categoryId],
  );
  return [categoryId, ...hijas.map((f) => f['id'] as String)];
}

/// Arma el `WHERE ... args` de `findForUser`, como puerto directo — mismos
/// filtros, mismo orden de evaluación.
/// Lo escrito en el buscador leído como monto, o `null` si no es un número.
///
/// Acepta "250", "250.5", "250,50", "S/ 250" y "-250" — quien busca una cifra la
/// escribe como la ve en la fila, con su símbolo, con el signo del gasto y con
/// la coma decimal de acá.
///
/// Lo que **no** hace es sacarle los dígitos a una frase: "250 gramos" no es el
/// número 250, y tratarlo como tal escondería justo el almuerzo cuyo detalle
/// dice eso. Tiene que ser una cifra entera, no una frase que contenga una.
final _soloUnMonto = RegExp(r'^-?\s*(?:S/|\$|€)?\s*(\d+(?:[.,]\d{1,2})?)$');

double? montoBuscado(String? q) {
  final encaja = _soloUnMonto.firstMatch((q ?? '').trim());
  if (encaja == null) return null;
  // En valor absoluto: las filas guardan el monto sin signo —lo pone el tipo—
  // así que copiar "-250.00" de un gasto tiene que encontrar ese gasto.
  return double.tryParse(encaja.group(1)!.replaceAll(',', '.'));
}

Future<(String, List<Object?>)> _whereYArgs(Database db, String userId, Uri uri) async {
  final condiciones = <String>['a.userId = ?', 'a.isHidden = 0'];
  final args = <Object?>[userId];

  final desde = uri.queryParameters['from'];
  final hasta = uri.queryParameters['to'];
  if (desde != null || hasta != null) {
    if (desde != null) {
      condiciones.add('t.occurredAt >= ?');
      args.add(DateTime.parse(desde).toUtc().millisecondsSinceEpoch);
    }
    if (hasta != null) {
      condiciones.add('t.occurredAt <= ?');
      args.add(DateTime.parse(hasta).toUtc().millisecondsSinceEpoch);
    }
  }

  // De dónde viene lo que salió, cuando se filtra por eso en vez de por
  // categoría: 'fijos' son los pagos de un gasto recurrente, 'deudas' las
  // cuotas, 'otros' el gasto suelto de la vida y 'ajustes' lo que movió el
  // saldo sin ser un gasto. No son categorías —un pago de Internet **tiene** la
  // categoría Internet— sino otra pregunta sobre el mismo movimiento: "¿esto lo
  // decidí este mes o ya estaba comprometido?".
  //
  // Los cuatro son de gasto y no se solapan: entre los cuatro reparten todo lo
  // que bajó el saldo en el periodo. Es lo que permite que cada porción del
  // anillo de Panorama enlace a la lista de lo que la compone y las dos cifras
  // coincidan.
  //
  // El tipo importa: un sueldo también es un flujo recurrente, y sin acotarlo
  // "Gastos fijos" devolvía el cobro del sueldo entre los gastos.
  final origen = uri.queryParameters['origen'];
  if (origen == 'fijos' || origen == 'deudas' || origen == 'otros') {
    condiciones.add("t.type = 'EXPENSE'");
  }
  // Los tres de gasto piden `MOVEMENT`: la contrapartida que la app escribe al
  // marcar pagado un mes pasado lleva el mismo `recurringFlowId` que el pago, y
  // sin esto caía a la vez en "gastos fijos" y en "ajustes" — dos porciones del
  // anillo contando la misma fila.
  if (origen == 'fijos') {
    condiciones.add("t.recurringFlowId IS NOT NULL AND t.kind = 'MOVEMENT'");
  }
  if (origen == 'deudas') condiciones.add("t.debtId IS NOT NULL AND t.kind = 'MOVEMENT'");
  if (origen == 'otros') {
    condiciones.add("t.recurringFlowId IS NULL AND t.debtId IS NULL AND t.kind = 'MOVEMENT'");
  }
  // Los ajustes son el cuarto cajón, y el único que no se acota a los gastos:
  // van sus dos direcciones, porque casi siempre vienen en pareja —al marcar
  // pagado un mes pasado, la app escribe el pago y su contrapartida— y mostrar
  // una sola pata daría una cifra que no movió nada. La lista tiene que ser la
  // de las filas que hay detrás del neto que muestra el anillo.
  if (origen == 'ajustes') condiciones.add("t.kind <> 'MOVEMENT'");

  final categoryId = uri.queryParameters['categoryId'];
  if (categoryId != null && categoryId.isNotEmpty) {
    final ids = await categoryIdsForFilter(db, categoryId);
    condiciones.add('t.categoryId IN (${List.filled(ids.length, '?').join(',')})');
    args.addAll(ids);
  }

  final kind = uri.queryParameters['kind'];
  if (kind != null) {
    condiciones.add('t.kind = ?');
    args.add(kind);
  }

  // Buscar es buscar en todo lo que se ve de una fila: su texto, su categoría y
  // su monto.
  //
  // Antes solo miraba `detail` y `description`, y las dos búsquedas más
  // naturales de un historial —"todo lo de Uber", "el gasto de 250"— no
  // devolvían nada. Que exista un filtro de categoría aparte no arregla la
  // primera: quien escribe en un buscador espera que busque, no que le explique
  // dónde estaba el control correcto.
  //
  // La categoría por subconsulta y no por JOIN: la consulta de la lista no
  // trae Category, y sumarle un JOIN solo para el buscador cambiaría el plan de
  // todas las demás llamadas.
  final q = uri.queryParameters['q']?.trim();
  if (q != null && q.isNotEmpty) {
    final monto = montoBuscado(q);
    condiciones.add(
      '(t.detail LIKE ? OR t.description LIKE ? '
      'OR t.categoryId IN (SELECT id FROM Category WHERE name LIKE ?)'
      '${monto != null ? ' OR t.amount = ?' : ''})',
    );
    args.addAll(['%$q%', '%$q%', '%$q%', if (monto != null) monto]);
  }

  final recurringFlowId = uri.queryParameters['recurringFlowId'];
  if (recurringFlowId != null && recurringFlowId.isNotEmpty) {
    condiciones.add('t.recurringFlowId = ?');
    args.add(recurringFlowId);
  }

  return (condiciones.join(' AND '), args);
}

Future<Map<String, dynamic>> _transactionJson(Database db, Map<String, Object?> fila) async {
  final base = mapRow(fila, columnasFecha: _columnasFecha);

  // El nombre de la cuenta viaja con el movimiento.
  //
  // Antes solo iba el `accountId`, así que ninguna lista podía decir a dónde
  // fue la plata: se elegía la cuenta al registrar y después no había forma de
  // comprobarlo sin abrir el editor. Con dos cuentas eso es justo lo que uno
  // quiere verificar de un vistazo.
  final cuentas = await db.query(
    'Account',
    columns: ['id', 'name'],
    where: 'id = ?',
    whereArgs: [fila['accountId']],
    limit: 1,
  );
  final cuenta = cuentas.isEmpty
      ? null
      : {'id': cuentas.first['id'], 'name': cuentas.first['name']};

  final categoryId = fila['categoryId'] as String?;
  if (categoryId == null) return {...base, 'account': cuenta, 'category': null};
  final categoria = await db.query('Category', where: 'id = ?', whereArgs: [categoryId], limit: 1);
  return {
    ...base,
    'account': cuenta,
    'category': categoria.isEmpty ? null : await categoryJson(db, categoria.first),
  };
}

void registerTransactionsRoutes() {
  // GET /transactions?take&skip&categoryId&q&kind&from&to&recurringFlowId
  LocalApiRouter.registerGet('/transactions', (db, uri, body) async {
    final userId = await currentUserId(db);
    final (whereSql, args) = await _whereYArgs(db, userId, uri);

    // Cómo se ordena. Por fecha es lo natural —un historial es una línea de
    // tiempo— pero "¿en qué se me fue la plata?" se contesta mucho más rápido
    // con los montos de mayor a menor.
    //
    // Se ordena acá y no en la pantalla: con 50 filas de 3,000, un orden hecho
    // sobre la página que se está mirando haría que "el más grande" fuera el
    // más grande **de esa página**.
    //
    // La fecha desempata siempre: dos gastos del mismo monto en orden
    // arbitrario hacen que pasar de página los baraje. Y la lista de valores es
    // cerrada: el texto entra en el SQL, y aceptar cualquiera sería dejar la
    // puerta abierta.
    final orden = switch (uri.queryParameters['orden']) {
      'monto' => 't.amount DESC, t.occurredAt DESC',
      'monto-asc' => 't.amount ASC, t.occurredAt DESC',
      _ => 't.occurredAt DESC, t.createdAt DESC',
    };

    final take = (int.tryParse(uri.queryParameters['take'] ?? '') ?? 20).clamp(0, maxPageSize);
    final skip = int.tryParse(uri.queryParameters['skip'] ?? '') ?? 0;

    final filas = await db.rawQuery(
      '''
      SELECT t.* FROM "Transaction" t
      JOIN Account a ON a.id = t.accountId
      WHERE $whereSql
      ORDER BY $orden
      LIMIT ? OFFSET ?
      ''',
      [...args, take, skip],
    );

    final totalFila = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM "Transaction" t JOIN Account a ON a.id = t.accountId WHERE $whereSql',
      args,
    );
    final total = (totalFila.first['n'] as num).toInt();

    // Agrupadas también por `kind`, para separar dos cosas que no son la misma:
    // "cuánto gastaste" es plata que salió de verdad, y un ajuste de saldo o
    // una transferencia entre cuentas tuyas no lo es. Antes se forzaba
    // MOVEMENT y los ajustes no se contaban en ningún lado: una lista con un
    // ajuste de 5,960 encabezada por un "Gastado: 3,044" no daba forma de
    // saber a dónde se había ido la diferencia.
    final sumas = await db.rawQuery('''
      SELECT t.type AS type, t.kind AS kind, SUM(t.amount) AS total FROM "Transaction" t
      JOIN Account a ON a.id = t.accountId
      WHERE $whereSql
      GROUP BY t.type, t.kind
      ''', args);
    var income = 0.0, expense = 0.0, ajusteIn = 0.0, ajusteOut = 0.0;
    for (final fila in sumas) {
      final monto = (fila['total'] as num?)?.toDouble() ?? 0;
      final esMovimiento = fila['kind'] == 'MOVEMENT';
      if (fila['type'] == 'INCOME') {
        if (esMovimiento) {
          income += monto;
        } else {
          ajusteIn += monto;
        }
      }
      if (fila['type'] == 'EXPENSE') {
        if (esMovimiento) {
          expense += monto;
        } else {
          ajusteOut += monto;
        }
      }
    }
    income = round2(income);
    expense = round2(expense);

    final balances = await balancesBefore(db, userId);
    final items = await Future.wait(
      filas.map((f) async {
        final json = await _transactionJson(db, f);
        return {...json, 'balanceBefore': balances[json['id']]};
      }),
    );

    return {
      'items': items,
      'total': total,
      'totals': {
        'income': income,
        'expense': expense,
        // Lo que movió el saldo sin ser gasto ni ingreso: correcciones y
        // traspasos. Aparte de los otros dos a propósito — sumarlos daría un
        // "gastaste" que incluye plata que nunca se gastó.
        'adjustments': {'income': round2(ajusteIn), 'expense': round2(ajusteOut)},
      },
    };
  });

  // POST /transactions — crea el movimiento y ajusta el saldo de la cuenta
  // en la misma operación, para que nunca queden desincronizados.
  LocalApiRouter.registerPost('/transactions', (db, uri, body) async {
    final userId = await currentUserId(db);
    final datos = bodyAsMap(body);
    final accountId = campoObligatorio(datos, 'accountId');

    final cuenta = await db.query(
      'Account',
      where: 'id = ? AND userId = ?',
      whereArgs: [accountId, userId],
    );
    if (cuenta.isEmpty) throw ApiException('Account $accountId not found', status: 404);

    final clock = await UserClock.forUser(db, userId);
    // "2026-07-31" sin hora se ancla al día del usuario — interpretarla con
    // la zona del dispositivo corría el movimiento un día si no coincidían.
    final occurredAt = clock.toInstantValue(campoObligatorio(datos, 'occurredAt'));
    final type = campoObligatorio(datos, 'type');
    final amount = (datos['amount'] as num).toDouble();
    final id = _uuid.v4();

    await db.insert('Transaction', {
      'id': id,
      'accountId': accountId,
      'categoryId': datos['categoryId'],
      'recurringFlowId': datos['recurringFlowId'],
      'type': type,
      'kind': 'MOVEMENT',
      'amount': amount,
      'paymentMethod': datos['paymentMethod'],
      'detail': datos['detail'],
      'description': datos['description'],
      'occurredAt': occurredAt.millisecondsSinceEpoch,
      'createdAt': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
    // Con la regla de la cuenta: en una tarjeta un cargo **sube** lo que debes.
    await db.rawUpdate('UPDATE Account SET currentBalance = currentBalance + ? WHERE id = ?', [
      balanceDelta(cuenta.first['type'] as String, type, amount),
      accountId,
    ]);

    final fila = (await db.query('Transaction', where: 'id = ?', whereArgs: [id])).first;
    return _transactionJson(db, fila);
  });

  // POST /transactions/transfer — dos asientos, uno por cuenta, con el mismo
  // transferId: son las dos patas de un solo movimiento de plata propia, y
  // se muestran y se borran como una unidad.
  LocalApiRouter.registerPost('/transactions/transfer', (db, uri, body) async {
    final userId = await currentUserId(db);
    final datos = bodyAsMap(body);
    final fromId = campoObligatorio(datos, 'fromAccountId');
    final toId = campoObligatorio(datos, 'toAccountId');

    if (fromId == toId) {
      throw const ApiException('El origen y el destino no pueden ser la misma cuenta.');
    }

    final cuentas = await db.query(
      'Account',
      where: 'id IN (?, ?) AND userId = ?',
      whereArgs: [fromId, toId, userId],
    );
    Map<String, Object?>? origen, destino;
    for (final c in cuentas) {
      if (c['id'] == fromId) origen = c;
      if (c['id'] == toId) destino = c;
    }
    if (origen == null) throw ApiException('Account $fromId not found', status: 404);
    if (destino == null) throw ApiException('Account $toId not found', status: 404);
    if (origen['currency'] != destino['currency']) {
      throw ApiException(
        'No se puede transferir entre cuentas de distinta moneda (${origen['currency']} → ${destino['currency']}).',
      );
    }

    final clock = await UserClock.forUser(db, userId);
    final occurredAt = clock.toInstantValue(campoObligatorio(datos, 'occurredAt'));
    final transferId = _uuid.v4();
    final detalleCrudo = (datos['detail'] as String?)?.trim();
    final detalle = (detalleCrudo == null || detalleCrudo.isEmpty) ? null : detalleCrudo;
    final amount = (datos['amount'] as num).toDouble();
    final ahora = DateTime.now().toUtc().millisecondsSinceEpoch;

    await db.insert('Transaction', {
      'id': _uuid.v4(),
      'accountId': fromId,
      'type': 'EXPENSE',
      'kind': 'TRANSFER',
      'amount': amount,
      'occurredAt': occurredAt.millisecondsSinceEpoch,
      'transferId': transferId,
      'detail': detalle,
      'description': 'Transferencia a ${destino['name']}',
      'createdAt': ahora,
    });
    await db.insert('Transaction', {
      'id': _uuid.v4(),
      'accountId': toId,
      'type': 'INCOME',
      'kind': 'TRANSFER',
      'amount': amount,
      'occurredAt': occurredAt.millisecondsSinceEpoch,
      'transferId': transferId,
      'detail': detalle,
      'description': 'Transferencia desde ${origen['name']}',
      'createdAt': ahora,
    });
    // Cada cuenta con su regla, y por eso no es un simple resta/suma.
    //
    // Pagar la tarjeta es una transferencia de la corriente a la tarjeta: baja el
    // efectivo **y baja lo que debes**. Con la suma de siempre, pagar la tarjeta
    // la subía — el saldo de una cuenta de crédito es deuda, no dinero.
    await db.rawUpdate('UPDATE Account SET currentBalance = currentBalance + ? WHERE id = ?', [
      balanceDelta(origen['type'] as String, 'EXPENSE', amount),
      fromId,
    ]);
    await db.rawUpdate('UPDATE Account SET currentBalance = currentBalance + ? WHERE id = ?', [
      balanceDelta(destino['type'] as String, 'INCOME', amount),
      toId,
    ]);

    return {'transferId': transferId};
  });

  // PATCH /transactions/:id
  LocalApiRouter.registerPatch('/transactions/:id', (db, uri, body) async {
    final userId = await currentUserId(db);
    final id = uri.queryParameters['id']!;
    final datos = bodyAsMap(body);

    final filas = await db.rawQuery(
      'SELECT t.* FROM "Transaction" t JOIN Account a ON a.id = t.accountId WHERE t.id = ? AND a.userId = ?',
      [id, userId],
    );
    if (filas.isEmpty) throw ApiException('Transaction $id not found', status: 404);
    final existente = filas.first;

    // El saldo inicial es de solo lectura: es el ancla de toda la serie de
    // hitos. Se corrige con un ajuste, que es una fila nueva.
    if (existente['kind'] == 'OPENING_BALANCE') {
      throw const ApiException(
        'Transaction is an opening balance and cannot be edited. Record a balance adjustment instead.',
      );
    }
    // Un ajuste solo acepta monto, sentido y fecha — no tiene categoría ni
    // medio de pago, no es un gasto ni un ingreso.
    if (existente['kind'] == 'ADJUSTMENT') {
      final noEditables = [
        'categoryId',
        'paymentMethod',
        'detail',
        'description',
        'accountId',
      ].where((campo) => datos.containsKey(campo)).toList();
      if (noEditables.isNotEmpty) {
        throw ApiException(
          'An adjustment only accepts amount, type and occurredAt. Remove: ${noEditables.join(', ')}.',
        );
      }
    }

    final clock = await UserClock.forUser(db, userId);
    final newType = (datos['type'] as String?) ?? existente['type'] as String;
    final newAmount =
        (datos['amount'] as num?)?.toDouble() ?? (existente['amount'] as num).toDouble();
    final newAccountId = (datos['accountId'] as String?) ?? existente['accountId'] as String;

    // Cada cuenta con su regla: mover un cargo de la tarjeta a la corriente baja
    // lo que debes en una y el saldo en la otra. Con una sola regla, moverlo
    // entre cuentas de distinta naturaleza dejaba las dos mal.
    final tipos = <String, String>{
      for (final c in await db.query(
        'Account',
        columns: ['id', 'type'],
        where: 'id IN (?, ?)',
        whereArgs: [existente['accountId'], newAccountId],
      ))
        c['id'] as String: c['type'] as String,
    };
    final oldSigned = balanceDelta(
      tipos[existente['accountId']]!,
      existente['type'] as String,
      (existente['amount'] as num).toDouble(),
    );
    final newSigned = balanceDelta(tipos[newAccountId]!, newType, newAmount);

    final cambios = <String, Object?>{};
    for (final campo in [
      'categoryId',
      'type',
      'amount',
      'paymentMethod',
      'detail',
      'description',
      'accountId',
    ]) {
      if (datos.containsKey(campo)) cambios[campo] = datos[campo];
    }
    if (datos.containsKey('occurredAt')) {
      cambios['occurredAt'] = clock
          .toInstantValue(datos['occurredAt'] as String)
          .millisecondsSinceEpoch;
    }
    if (cambios.isNotEmpty) {
      await db.update('Transaction', cambios, where: 'id = ?', whereArgs: [id]);
    }

    // Misma cuenta: los dos efectos se netean en un solo delta. Cuenta
    // distinta: se deshace el viejo en la de antes y se aplica el nuevo en
    // la de ahora.
    if (existente['accountId'] == newAccountId) {
      await db.rawUpdate('UPDATE Account SET currentBalance = currentBalance + ? WHERE id = ?', [
        newSigned - oldSigned,
        newAccountId,
      ]);
    } else {
      await db.rawUpdate('UPDATE Account SET currentBalance = currentBalance - ? WHERE id = ?', [
        oldSigned,
        existente['accountId'],
      ]);
      await db.rawUpdate('UPDATE Account SET currentBalance = currentBalance + ? WHERE id = ?', [
        newSigned,
        newAccountId,
      ]);
    }

    final actualizada = (await db.query('Transaction', where: 'id = ?', whereArgs: [id])).first;
    return _transactionJson(db, actualizada);
  });

  // DELETE /transactions/:id — se va la fila y se deshace lo que le hizo al
  // saldo. Las dos patas de una transferencia se van juntas.
  LocalApiRouter.registerDelete('/transactions/:id', (db, uri, body) async {
    final userId = await currentUserId(db);
    final id = uri.queryParameters['id']!;

    final filas = await db.rawQuery(
      'SELECT t.* FROM "Transaction" t JOIN Account a ON a.id = t.accountId WHERE t.id = ? AND a.userId = ?',
      [id, userId],
    );
    if (filas.isEmpty) throw ApiException('Transaction $id not found', status: 404);
    final entrada = filas.first;

    if (entrada['kind'] == 'OPENING_BALANCE') {
      throw const ApiException(
        'Transaction is an opening balance and cannot be deleted. Record a balance adjustment instead.',
      );
    }
    if (entrada['debtId'] != null) {
      throw const ApiException(
        "Transaction is a debt payment. Use the debt's revert-payment action instead.",
      );
    }

    final transferId = entrada['transferId'] as String?;
    final patas = transferId != null
        ? await db.query('Transaction', where: 'transferId = ?', whereArgs: [transferId])
        : [entrada];

    for (final pata in patas) {
      // Se deshace con la misma regla con la que se aplicó: en una tarjeta el
      // cargo subió lo que debes, así que borrarlo lo baja.
      final tipoDeSuCuenta =
          (await db.query(
                'Account',
                columns: ['type'],
                where: 'id = ?',
                whereArgs: [pata['accountId']],
                limit: 1,
              )).first['type']
              as String;
      final firmado = balanceDelta(
        tipoDeSuCuenta,
        pata['type'] as String,
        (pata['amount'] as num).toDouble(),
      );
      await db.rawUpdate('UPDATE Account SET currentBalance = currentBalance - ? WHERE id = ?', [
        firmado,
        pata['accountId'],
      ]);
    }
    final ids = patas.map((p) => p['id'] as String).toList();
    await db.delete(
      'Transaction',
      where: 'id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: ids,
    );

    return {'id': id, 'deleted': patas.length};
  });
}
