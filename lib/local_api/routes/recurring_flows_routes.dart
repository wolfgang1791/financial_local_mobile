import 'package:sqflite/sqflite.dart' show Database;
import 'package:uuid/uuid.dart';

import '../../data/api.dart' show ApiException;
import '../../local_db/row_mapping.dart';
import '../../local_engine/ledger.dart' show signedAmount;
import '../../local_engine/months_util.dart';
import '../../local_engine/recurring_flows_engine.dart';
import '../../local_engine/user_clock.dart';
import '../current_user.dart';
import '../local_api_router.dart';
import 'categories_routes.dart';

const _uuid = Uuid();

const _columnasBooleanas = {'isActive', 'isSubscription'};
const _columnasFecha = {'startDate', 'endDate', 'nextDueDate', 'settledThrough'};

DateTime? _fecha(Object? ms) =>
    ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms as int, isUtc: true);

void registerRecurringFlowsRoutes() {
  // GET /recurring-flows — "pagado/pendiente este mes" derivado, nunca
  // guardado como bandera: la deuda es la expectativa, la transacción el
  // recibo.
  LocalApiRouter.registerGet('/recurring-flows', (db, uri, body) async {
    final userId = await currentUserId(db);
    final clock = await UserClock.forUser(db, userId);
    final now = clock.now();

    final flujos = await db.query(
      'RecurringFlow',
      where: 'userId = ? AND isActive = 1',
      whereArgs: [userId],
      orderBy: 'nextDueDate ASC, name ASC',
    );
    if (flujos.isEmpty) return <Map<String, dynamic>>[];

    final ids = flujos.map((f) => f['id'] as String).toList();
    final placeholders = List.filled(ids.length, '?').join(',');
    final pagos = await db.rawQuery(
      'SELECT id, recurringFlowId, occurredAt, amount FROM "Transaction" '
      'WHERE recurringFlowId IN ($placeholders) AND kind = \'MOVEMENT\'',
      ids,
    );

    final mesesPorFlujo = <String, Set<String>>{};
    // Qué se registró en cada mes: monto y movimiento. El `amount` del flujo es
    // la expectativa; lo que pasó cada mes puede diferir —la luz nunca es la
    // misma— y la pantalla tiene que mostrar el del mes que se está mirando, no
    // el declarado. Sin esto, cambiar el monto del flujo reescribía el pasado a
    // la vista.
    final registrosPorFlujo = <String, Map<String, Map<String, Object?>>>{};
    for (final pago in pagos) {
      final id = pago['recurringFlowId'] as String;
      final ocurrio = DateTime.fromMillisecondsSinceEpoch(pago['occurredAt'] as int, isUtc: true);
      final mes = clock.monthKey(ocurrio);
      (mesesPorFlujo[id] ??= {}).add(mes);
      (registrosPorFlujo[id] ??= {})[mes] = {
        'month': mes,
        'amount': (pago['amount'] as num).toDouble(),
        'transactionId': pago['id'],
        'occurredAt': ocurrio.toIso8601String(),
      };
    }

    final resultado = <Map<String, dynamic>>[];
    for (final flujo in flujos) {
      final id = flujo['id'] as String;
      // Los meses que falten se crean al leer: así el 1 de septiembre la fila de
      // septiembre existe sin que nadie haya tocado la pantalla.
      //
      // Cada mes nuevo nace copiando al anterior —monto y día— y desde ahí vive
      // su vida. Solo del anterior: heredar del siguiente haría que escribir
      // agosto cambiara julio.
      //
      // Va antes de lo derivado porque de estas fichas sale qué meses están
      // registrados, y de ahí salen los meses que faltan y el estado del mes.
      final mesesCompletos = await _completarMeses(db, flujo, clock, now);
      final registrados = mesesRegistrados(mesesCompletos, mesesPorFlujo[id] ?? const {});

      final derivado = decorateRecurringFlow(
        frequency: flujo['frequency'] as String,
        startDate: _fecha(flujo['startDate'])!,
        storedNextDueDate: _fecha(flujo['nextDueDate'])!,
        endDate: _fecha(flujo['endDate']),
        settledThrough: _fecha(flujo['settledThrough']),
        paidMonths: registrados,
        clock: clock,
        now: now,
      );

      final categoryId = flujo['categoryId'] as String?;
      Map<String, dynamic>? categoria;
      if (categoryId != null) {
        final fila = await db.query('Category', where: 'id = ?', whereArgs: [categoryId], limit: 1);
        if (fila.isNotEmpty) categoria = await categoryJson(db, fila.first);
      }

      resultado.add({
        ...mapRow(flujo, columnasBooleanas: _columnasBooleanas, columnasFecha: _columnasFecha),
        'nextDueDate': derivado.nextDueDate.toIso8601String(),
        'statusThisMonth': derivado.statusThisMonth,
        'lastPaidMonth': derivado.lastPaidMonth,
        // Todos los meses con algún registro, para que la pantalla pueda
        // mostrar el estado de *cualquier* mes y no solo el de hoy.
        'paidMonths': mesesRegistrados(mesesCompletos, mesesPorFlujo[id] ?? const {}).toList()
          ..sort(),
        // Las filas de cada mes, ya completas: si septiembre no existía, acaba
        // de nacer copiando a agosto. Con su monto, su caducidad y su marca de
        // pago, para que la pantalla resuelva cualquier mes —incluido uno sin
        // pagar— sin volver a preguntar.
        'months': {
          for (final f in mesesCompletos)
            f['month'] as String: {
              'amount': (f['amount'] as num).toDouble(),
              'dueDate': DateTime.fromMillisecondsSinceEpoch(
                f['dueDate'] as int,
                isUtc: true,
              ).toIso8601String().substring(0, 10),
              'paidAt': f['paidAt'] == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(
                      f['paidAt'] as int,
                      isUtc: true,
                    ).toIso8601String(),
            },
        },
        // Lo registrado en cada mes, con su monto: una fila puede mostrar lo
        // que de verdad pasó ese mes en vez de lo declarado en el flujo.
        'monthlyRecords': ((registrosPorFlujo[id] ?? const {}).values.toList()
          ..sort((a, b) => (a['month'] as String).compareTo(b['month'] as String))),
        'missedMonths': derivado.missedMonths,
        'category': categoria,
      });
    }

    // Por monto, de mayor a menor; el nombre desempata para que la lista no
    // se reacomode sola cuando dos montos coinciden.
    resultado.sort((a, b) {
      final cmp = (b['amount'] as num).toDouble().compareTo((a['amount'] as num).toDouble());
      return cmp != 0 ? cmp : (a['name'] as String).compareTo(b['name'] as String);
    });
    return resultado;
  });

  // POST /recurring-flows
  LocalApiRouter.registerPost('/recurring-flows', (db, uri, body) async {
    final userId = await currentUserId(db);
    final datos = bodyAsMap(body);
    final clock = await UserClock.forUser(db, userId);
    final id = _uuid.v4();
    _validarMonto(datos['amount']);

    final desde = campoObligatorio(datos, 'startDate');
    final proxima = campoObligatorio(datos, 'nextDueDate');

    await db.insert('RecurringFlow', {
      'id': id,
      'userId': userId,
      'accountId': datos['accountId'],
      'categoryId': datos['categoryId'],
      'type': datos['type'],
      'name': datos['name'],
      'amount': (datos['amount'] as num).toDouble(),
      'frequency': datos['frequency'],
      'startDate': clock.toInstantValue(desde).millisecondsSinceEpoch,
      'endDate': datos['endDate'] != null
          ? clock.toInstantValue(datos['endDate'] as String).millisecondsSinceEpoch
          : null,
      'nextDueDate': clock.toInstantValue(proxima).millisecondsSinceEpoch,
      'isSubscription': (datos['isSubscription'] as bool?) ?? false ? 1 : 0,
      'isActive': 1,
    });

    final fila = (await db.query('RecurringFlow', where: 'id = ?', whereArgs: [id])).first;
    return mapRow(fila, columnasBooleanas: _columnasBooleanas, columnasFecha: _columnasFecha);
  });

  // PATCH /recurring-flows/:id — edita la expectativa nada más: los pagos ya
  // registrados se quedan con el monto por el que de verdad se hicieron.
  LocalApiRouter.registerPatch('/recurring-flows/:id', (db, uri, body) async {
    final userId = await currentUserId(db);
    final id = uri.queryParameters['id']!;
    final datos = bodyAsMap(body);

    final existente = await db.query(
      'RecurringFlow',
      where: 'id = ? AND userId = ?',
      whereArgs: [id, userId],
    );
    if (existente.isEmpty) throw ApiException('RecurringFlow $id not found', status: 404);
    _validarMonto(datos['amount']);
    final clock = await UserClock.forUser(db, userId);

    final cambios = <String, Object?>{};
    for (final campo in [
      'accountId',
      'categoryId',
      'type',
      'name',
      'amount',
      'frequency',
      'isSubscription',
    ]) {
      if (datos.containsKey(campo)) {
        final valor = datos[campo];
        cambios[campo] = valor is bool ? (valor ? 1 : 0) : valor;
      }
    }
    for (final campo in ['startDate', 'endDate', 'nextDueDate']) {
      if (datos.containsKey(campo) && datos[campo] != null) {
        cambios[campo] = clock.toInstantValue(datos[campo] as String).millisecondsSinceEpoch;
      }
    }
    if (cambios.isNotEmpty) {
      await db.update('RecurringFlow', cambios, where: 'id = ?', whereArgs: [id]);
    }

    final fila = (await db.query('RecurringFlow', where: 'id = ?', whereArgs: [id])).first;
    return mapRow(fila, columnasBooleanas: _columnasBooleanas, columnasFecha: _columnasFecha);
  });

  // DELETE /recurring-flows/:id — un flujo con historia se desactiva, no se
  // borra: la plata que se pagó de verdad no puede quedar sin flujo que la
  // explique. Solo el que nunca tuvo un pago se borra de verdad.
  LocalApiRouter.registerDelete('/recurring-flows/:id', (db, uri, body) async {
    final userId = await currentUserId(db);
    final id = uri.queryParameters['id']!;

    final existente = await db.query(
      'RecurringFlow',
      where: 'id = ? AND userId = ?',
      whereArgs: [id, userId],
    );
    if (existente.isEmpty) throw ApiException('RecurringFlow $id not found', status: 404);

    final pagosFila = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM "Transaction" WHERE recurringFlowId = ?',
      [id],
    );
    final pagos = (pagosFila.first['n'] as num).toInt();

    if (pagos > 0) {
      await db.update('RecurringFlow', {'isActive': 0}, where: 'id = ?', whereArgs: [id]);
    } else {
      await db.delete('RecurringFlow', where: 'id = ?', whereArgs: [id]);
    }
    return {'id': id, 'archived': pagos > 0};
  });

  // POST /recurring-flows/:id/pay — registra el pago de un mes Y corre
  // `settledThrough`, en la misma operación: son las dos mitades de "marcar
  // pagado", no dos gestos aparte.
  //
  // El mes se puede elegir (`month`, como "2026-03") y por defecto es el
  // actual: un pago se anota tarde —pagaste el alquiler de marzo y te
  // acordaste en agosto— y marcarlo en el mes de hoy dejaría marzo reclamado
  // para siempre y agosto pagado dos veces.
  LocalApiRouter.registerPost('/recurring-flows/:id/pay', (db, uri, body) async {
    final userId = await currentUserId(db);
    final id = uri.queryParameters['id']!;
    final datos = bodyAsMap(body);

    final filas = await db.query(
      'RecurringFlow',
      where: 'id = ? AND userId = ?',
      whereArgs: [id, userId],
    );
    if (filas.isEmpty) throw ApiException('RecurringFlow $id not found', status: 404);
    final flujo = filas.first;
    final clock = await UserClock.forUser(db, userId);

    final accountId = (datos['accountId'] as String?) ?? flujo['accountId'] as String?;
    if (accountId == null) {
      throw ApiException(
        '"${flujo['name']}" no tiene cuenta asociada: elige una para registrar el pago.',
      );
    }
    final cuenta = await db.query(
      'Account',
      where: 'id = ? AND userId = ?',
      whereArgs: [accountId, userId],
    );
    if (cuenta.isEmpty) throw ApiException('Account $accountId not found', status: 404);

    // Lo que toca ese mes: el pedido, o el que ya tenía escrito el mes —que a su
    // vez hereda del anterior—. El monto del flujo es solo la semilla.
    final mesDelPago = (datos['month'] as String?) ?? clock.monthKey();
    final filaMes = (await db.query(
      'RecurringFlowMonth',
      where: 'recurringFlowId = ? AND month = ?',
      whereArgs: [id, mesDelPago],
      limit: 1,
    )).firstOrNull;
    final amount =
        (datos['amount'] as num?)?.toDouble() ??
        (filaMes?['amount'] as num?)?.toDouble() ??
        (flujo['amount'] as num).toDouble();
    // Cuándo ocurrió el pago: **cuando lo marcaste**.
    //
    // El vencimiento es una referencia —"esto toca el 5"— y no la fecha del
    // hecho. Fecharlo ahí daba movimientos en el futuro: la ficha de agosto de
    // "Luz" vencía el 1 de septiembre, y marcarla hoy registraba una salida de
    // plata que todavía no ha pasado.
    //
    // La excepción es marcar un mes que ya cerró: ahí "ahora" cae fuera de ese
    // mes, y un pago de julio fechado en agosto le cambiaría el gasto a los dos
    // meses. Se usa su vencimiento si cae dentro, y su último día si no —que es
    // lo más tarde que ese mes pudo pagarse.
    final vencimientoDelMes = filaMes?['dueDate'] != null
        ? DateTime.fromMillisecondsSinceEpoch(filaMes!['dueDate'] as int, isUtc: true)
        : clock.toInstantValue('$mesDelPago-${_diaDeVencimiento(flujo, mesDelPago)}T12:00:00');
    final cuando = mesDelPago == clock.monthKey()
        ? clock.now()
        : (clock.monthKey(vencimientoDelMes) == mesDelPago
              ? vencimientoDelMes
              : clock.toInstantValue(
                  '$mesDelPago-${_ultimoDiaDe(mesDelPago).toString().padLeft(2, '0')}T12:00:00',
                ));
    // El inicio del mes **que se marca**, no el del mes en que cae la fecha del
    // movimiento: es lo que apaga el aviso de los meses anteriores, y con un
    // vencimiento fuera de su mes se adelantaba uno de más.
    final inicioDeMes = clock.startOfMonth(clock.toInstantValue('$mesDelPago-15T12:00:00'));

    // Qué meses se van a dejar de reclamar, calculado ANTES de escribir —
    // para poder decirle al usuario qué acaba de pasar.
    final pagos = await db.query(
      'Transaction',
      columns: ['occurredAt'],
      where: 'recurringFlowId = ?',
      whereArgs: [id],
    );
    final fichas = await db.query(
      'RecurringFlowMonth',
      columns: ['month', 'paidAt'],
      where: 'recurringFlowId = ?',
      whereArgs: [id],
    );
    final mesesPagados = mesesRegistrados(
      fichas,
      pagos.map(
        (p) => clock.monthKey(
          DateTime.fromMillisecondsSinceEpoch(p['occurredAt'] as int, isUtc: true),
        ),
      ),
    );
    final settledThrough = flujo['settledThrough'] as int?;
    final startDate = flujo['startDate'] as int;
    final desde = settledThrough != null && settledThrough > startDate
        ? DateTime.fromMillisecondsSinceEpoch(settledThrough, isUtc: true)
        : DateTime.fromMillisecondsSinceEpoch(startDate, isUtc: true);
    // Un mes ya registrado no se marca dos veces: sin esto, tocar "pagado"
    // sobre un mes que ya lo estaba duplicaría el movimiento y el saldo.
    // A qué mes pertenece este pago lo dice la pastilla, no la fecha del
    // movimiento. Desde que un vencimiento puede caer fuera de su mes —una
    // tarjeta que cierra el 28 se paga el 5 del siguiente—, deducir el mes de
    // la fecha marcaba el mes equivocado: marcar agosto escribía septiembre, y
    // al volver a intentarlo agosto seguía sin registro mientras el API
    // contestaba que "ya tiene un registro en ese mes".
    if (mesesPagados.contains(mesDelPago)) {
      throw ApiException('"${flujo['name']}" ya tiene un registro en ese mes.');
    }
    final saldados = monthlyOrTighter.contains(flujo['frequency'])
        ? missedMonthsSince(desde, mesesPagados, clock.now(), clock)
        : <String>[];

    final type = flujo['type'] as String;
    final transaccionId = _uuid.v4();
    final ahora = clock.now();

    // Marcar un mes que ya pasó no mueve el saldo de hoy.
    //
    // La plata de julio ya entró o salió en julio, y el saldo que tienes hoy ya
    // la contiene: registrarla ahora la contaría dos veces.
    //
    // Pero tampoco basta con no tocar el saldo: el patrimonio se reconstruye
    // sumando el ledger hacia atrás desde el saldo de hoy, así que un
    // movimiento sin contrapartida deja esa reconstrucción torcida y la curva
    // empieza a mentir desde ese mes. Por eso se escribe también un asiento de
    // ajuste que lo cancela dentro del mismo mes: el mes queda registrado, los
    // totales de julio lo cuentan —un ajuste no suma como ingreso ni como
    // gasto— y ni el saldo ni la curva se mueven.
    //
    // El mes en curso sí mueve el saldo: ahí la plata está saliendo ahora.
    //
    // Y los **ingresos** de meses pasados también, aunque el mes ya haya
    // cerrado: un sueldo que corresponde a agosto y te entra hoy pertenece a
    // agosto, pero llegó hoy — tu saldo no lo incluye, y neutralizarlo dejaba el
    // patrimonio corto sin forma de arreglarlo. Un gasto viejo es al revés: el
    // alquiler de julio ya salió de la cuenta en julio, y volver a descontarlo
    // al marcarlo lo contaría dos veces.
    //
    // La regla vale porque los dos casos se dan en direcciones distintas: un
    // ingreso se cobra tarde, un alquiler no se paga tarde.
    final yaEstabaEnElSaldo = mesDelPago != clock.monthKey() && type == 'EXPENSE';
    // Ocurre en el mes elegido; se registró ahora. Son dos fechas distintas y
    // el historial las usa para cosas distintas.

    await db.insert('Transaction', {
      'id': transaccionId,
      'accountId': accountId,
      'recurringFlowId': id,
      'categoryId': (datos['categoryId'] as String?) ?? flujo['categoryId'],
      'type': type,
      'kind': 'MOVEMENT',
      'amount': amount,
      'description': '${type == 'EXPENSE' ? 'Pago' : 'Cobro'} de ${flujo['name']}',
      'occurredAt': cuando.millisecondsSinceEpoch,
      'createdAt': ahora.millisecondsSinceEpoch,
    });
    if (yaEstabaEnElSaldo) {
      // Monto cero no necesita contrapartida: no movió nada.
      if (amount != 0) {
        await db.insert('Transaction', {
          'id': _uuid.v4(),
          'accountId': accountId,
          'type': type == 'INCOME' ? 'EXPENSE' : 'INCOME',
          'kind': 'ADJUSTMENT',
          'amount': amount,
          'description': 'Ya estaba reflejado en tu saldo',
          'occurredAt': cuando.millisecondsSinceEpoch,
          'createdAt': ahora.millisecondsSinceEpoch,
        });
      }
    } else {
      await db.rawUpdate('UPDATE Account SET currentBalance = currentBalance + ? WHERE id = ?', [
        signedAmount(type, amount),
        accountId,
      ]);
    }
    // La fila del mes queda con lo que se pagó y con la marca de cuándo.
    //
    // `paidAt` es lo que distingue "este mes vale 55.90" de "este mes ya se
    // pagó": el monto puede existir sin pago, y la marca se anota en el mes que
    // se marcó — marcar julio en agosto anota julio, no hoy.
    final mesMarcado = mesDelPago;
    if (filaMes == null) {
      await db.insert('RecurringFlowMonth', {
        'id': _uuid.v4(),
        'recurringFlowId': id,
        'month': mesMarcado,
        'amount': amount,
        'dueDate': caducidadDe(mesMarcado, cuando.day).millisecondsSinceEpoch,
        'paidAt': cuando.millisecondsSinceEpoch,
      });
    } else {
      await db.update(
        'RecurringFlowMonth',
        {'amount': amount, 'paidAt': cuando.millisecondsSinceEpoch},
        where: 'recurringFlowId = ? AND month = ?',
        whereArgs: [id, mesMarcado],
      );
    }

    // `settledThrough` solo avanza, nunca retrocede: marcar marzo tarde no
    // puede volver a reclamar abril y mayo, que ya se habían dado por saldados.
    final avance = settledThrough != null && settledThrough > inicioDeMes.millisecondsSinceEpoch
        ? settledThrough
        : inicioDeMes.millisecondsSinceEpoch;
    await db.update('RecurringFlow', {'settledThrough': avance}, where: 'id = ?', whereArgs: [id]);

    return {'transactionId': transaccionId, 'saldados': saldados, 'mes': mesDelPago};
  });

  // PATCH /recurring-flows/:id/month — cambiar el monto de un mes ya registrado.
  //
  // En un paso y no "revertir y volver a marcar": son dos escrituras de plata
  // para corregir una cifra, y entre una y otra el mes queda sin registro.
  //
  // Acá vive la única regla delicada del asunto: un mes pasado se guardó junto
  // con su ajuste compensatorio —el par que hace que no mueva el patrimonio— y
  // los dos tienen que cambiar a la vez. Si solo cambiara el movimiento, la
  // diferencia se le escaparía al saldo por la puerta de atrás.
  LocalApiRouter.registerPatch('/recurring-flows/:id/month', (db, uri, body) async {
    final userId = await currentUserId(db);
    final id = uri.queryParameters['id']!;
    final datos = bodyAsMap(body);
    final mes = campoObligatorio(datos, 'month');

    final filas = await db.query(
      'RecurringFlow',
      where: 'id = ? AND userId = ?',
      whereArgs: [id, userId],
    );
    if (filas.isEmpty) throw ApiException('RecurringFlow $id not found', status: 404);

    final clock = await UserClock.forUser(db, userId);
    final guardada = (await db.query(
      'RecurringFlowMonth',
      where: 'recurringFlowId = ? AND month = ?',
      whereArgs: [id, mes],
      limit: 1,
    )).firstOrNull;

    // Se puede cambiar el monto, la caducidad o los dos: son dos campos de la
    // misma fila y no dos gestos distintos. Lo que no se manda, se queda.
    final monto =
        (datos['amount'] as num?)?.toDouble() ??
        (guardada?['amount'] as num?)?.toDouble() ??
        (filas.first['amount'] as num).toDouble();
    if (monto < 0) throw const ApiException('El monto no puede ser negativo.');

    // La caducidad la pone el usuario y no se le discute, aunque caiga fuera del
    // mes: una tarjeta con cierre el 28 se paga el 5 del siguiente, y un recibo
    // de diciembre vence en enero. Antes se descartaba en silencio cualquier
    // fecha que no empezara por el mes de la fila, que es la peor forma de decir
    // que no — el usuario elegía una fecha, guardaba, y salía otra.
    //
    // La fila **sigue perteneciendo a su mes**: `month` es lo que la ubica, no
    // su vencimiento.
    final pedida = datos['dueDate'] as String?;
    final caducidad = pedida != null
        ? DateTime.parse('${pedida}T12:00:00Z')
        : (guardada?['dueDate'] != null
              ? DateTime.fromMillisecondsSinceEpoch(guardada!['dueDate'] as int, isUtc: true)
              : caducidadDe(
                  mes,
                  DateTime.fromMillisecondsSinceEpoch(
                    filas.first['nextDueDate'] as int,
                    isUtc: true,
                  ).day,
                ));

    final desdeMes = clock.startOfMonth(clock.toInstantValue('$mes-15T12:00:00'));
    final hastaMes = clock.addMonths(desdeMes, 1);

    // Cuándo se marcó, si se cambia. Se ancla al día en la zona del usuario,
    // igual que cualquier otra fecha que llega sin hora.
    final pedidaMarca = datos['paidAt'] as String?;
    final nuevaMarca = pedidaMarca == null ? null : clock.toInstantValue('${pedidaMarca}T12:00:00');

    // El movimiento se busca **antes** de escribir la ficha: el enlace es la
    // marca guardada, y sobrescribirla primero lo perdería. Por el rango del
    // mes solo cuando no hay marca — los pagos anteriores a que existiera.
    final marcaGuardada = guardada?['paidAt'] as int?;
    final movimientos = await db.rawQuery(
      'SELECT id, accountId, type, amount, occurredAt FROM "Transaction" '
      'WHERE recurringFlowId = ? AND kind = ? '
      '${marcaGuardada != null ? 'AND occurredAt = ?' : 'AND occurredAt >= ? AND occurredAt < ?'}',
      [
        id,
        'MOVEMENT',
        if (marcaGuardada != null)
          marcaGuardada
        else ...[
          desdeMes.millisecondsSinceEpoch,
          hastaMes.millisecondsSinceEpoch,
        ],
      ],
    );

    // La fila se guarda siempre, esté pagada o no. Es lo que permite decir
    // "julio son 500" antes de haberlo pagado, y lo que el mes siguiente hereda.
    //
    // La marca solo se mueve si hay un pago que mover: sin él, una fecha de
    // marcado sería decir que se pagó sin que exista el asiento.
    final marca = movimientos.isNotEmpty && nuevaMarca != null
        ? nuevaMarca.millisecondsSinceEpoch
        : marcaGuardada;
    if (guardada == null) {
      await db.insert('RecurringFlowMonth', {
        'id': _uuid.v4(),
        'recurringFlowId': id,
        'month': mes,
        'amount': monto,
        'dueDate': caducidad.millisecondsSinceEpoch,
        'paidAt': marca,
      });
    } else {
      await db.update(
        'RecurringFlowMonth',
        {'amount': monto, 'dueDate': caducidad.millisecondsSinceEpoch, 'paidAt': marca},
        where: 'recurringFlowId = ? AND month = ?',
        whereArgs: [id, mes],
      );
    }
    // Sin pago no hay más que hacer: se cambió lo que ese mes vale, y no hay
    // plata que mover porque nunca se movió.
    if (movimientos.isEmpty) return {'month': mes, 'amount': monto};
    final movimiento = movimientos.first;
    final anterior = (movimiento['amount'] as num).toDouble();

    // Su ajuste compensatorio, si el mes entró como pasado.
    final compensaciones = await db.rawQuery(
      'SELECT id FROM "Transaction" WHERE kind = ? AND description = ? '
      'AND accountId = ? AND amount = ? AND occurredAt = ?',
      [
        'ADJUSTMENT',
        'Ya estaba reflejado en tu saldo',
        movimiento['accountId'],
        anterior,
        movimiento['occurredAt'],
      ],
    );

    // Cambiar la fecha del marcado mueve el asiento con ella: el saldo no se
    // entera —la plata ya se movió y sigue siendo la misma— pero el día en que
    // se cuenta sí cambia, que es justo lo que se está corrigiendo.
    await db.update(
      'Transaction',
      {'amount': monto, if (nuevaMarca != null) 'occurredAt': nuevaMarca.millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [movimiento['id']],
    );

    if (compensaciones.isNotEmpty) {
      // Mes pasado: los dos suben o bajan juntos y el patrimonio no se entera.
      // Y viajan juntos: un ajuste que se queda atrás deja de cancelar a su
      // movimiento y el saldo empieza a mentir desde ese día.
      await db.update(
        'Transaction',
        {'amount': monto, if (nuevaMarca != null) 'occurredAt': nuevaMarca.millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [compensaciones.first['id']],
      );
    } else {
      // Mes en curso: la plata se movió de verdad, así que el saldo sigue la
      // diferencia — ni el monto viejo entero ni el nuevo entero.
      await db.rawUpdate('UPDATE Account SET currentBalance = currentBalance + ? WHERE id = ?', [
        signedAmount(movimiento['type'] as String, monto - anterior),
        movimiento['accountId'],
      ]);
    }

    return {'month': mes, 'amount': monto};
  });

  // POST /recurring-flows/:id/revert-payment — "marqué pagado por error":
  // borra los pagos de ese mes, devuelve la plata y vuelve a deber los meses
  // que el pago había saldado.
  //
  // Toma un mes, igual que pagar: desde que se puede marcar marzo estando en
  // agosto, deshacerlo tiene que poder apuntar al mismo mes que se marcó.
  LocalApiRouter.registerPost('/recurring-flows/:id/revert-payment', (db, uri, body) async {
    final userId = await currentUserId(db);
    final id = uri.queryParameters['id']!;
    final datos = bodyAsMap(body);

    final filas = await db.query(
      'RecurringFlow',
      where: 'id = ? AND userId = ?',
      whereArgs: [id, userId],
    );
    if (filas.isEmpty) throw ApiException('RecurringFlow $id not found', status: 404);
    final clock = await UserClock.forUser(db, userId);

    final mesPedido = datos['month'] as String?;
    final mesARevertir = mesPedido ?? clock.monthKey();
    final cuando = clock.toInstantValue('$mesARevertir-15T12:00:00');
    final desdeMes = clock.startOfMonth(cuando);
    final hastaMes = clock.addMonths(desdeMes, 1);

    // Cuándo se marcó ese mes. Es el enlace exacto entre la ficha y su
    // movimiento —al marcar se guarda en `paidAt` el mismo instante que lleva
    // el asiento—, y hace falta porque la fecha ya no dice a qué mes pertenece
    // un pago: con un vencimiento fuera de su mes, el de agosto puede estar
    // fechado en septiembre.
    final marca =
        (await db.query(
              'RecurringFlowMonth',
              columns: ['paidAt'],
              where: 'recurringFlowId = ? AND month = ?',
              whereArgs: [id, mesARevertir],
              limit: 1,
            )).firstOrNull?['paidAt']
            as int?;

    // Acotado por arriba también: sin el tope, revertir marzo se llevaba por
    // delante todos los pagos posteriores.
    final pagos = await db.rawQuery(
      'SELECT id, accountId, type, amount FROM "Transaction" '
      'WHERE recurringFlowId = ? AND ${marca != null ? 'occurredAt = ?' : 'occurredAt >= ? AND occurredAt < ?'}',
      [
        id,
        if (marca != null)
          marca
        else ...[
          desdeMes.millisecondsSinceEpoch,
          hastaMes.millisecondsSinceEpoch,
        ],
      ],
    );

    // El ajuste que compensó un mes pasado se va con su movimiento: es el par
    // que escribió el pago —mismo día, mismo monto, sentido contrario—. Si el
    // movimiento se borrara solo, el ajuste quedaría huérfano restando plata
    // que ya no tiene contrapartida, y el saldo bajaría al revertir algo que
    // nunca lo había subido.
    final compensaciones = await db.rawQuery(
      'SELECT id, accountId, type, amount FROM "Transaction" '
      'WHERE kind = ? AND description = ? '
      '${marca != null ? 'AND occurredAt = ?' : 'AND occurredAt >= ? AND occurredAt < ?'}',
      [
        'ADJUSTMENT',
        'Ya estaba reflejado en tu saldo',
        if (marca != null)
          marca
        else ...[
          desdeMes.millisecondsSinceEpoch,
          hastaMes.millisecondsSinceEpoch,
        ],
      ],
    );
    final montosDelMes = pagos.map((p) => (p['amount'] as num).toDouble()).toSet();
    final aBorrar = [
      ...pagos,
      ...compensaciones.where((c) => montosDelMes.contains((c['amount'] as num).toDouble())),
    ];

    // Solo se devuelve al saldo lo que de verdad lo movió: un mes pasado entró
    // compensado y su neto sobre el saldo fue cero.
    final netos = <String, double>{};
    for (final t in aBorrar) {
      final id = t['accountId'] as String;
      netos[id] =
          (netos[id] ?? 0) + signedAmount(t['type'] as String, (t['amount'] as num).toDouble());
    }
    for (final entrada in netos.entries) {
      if (entrada.value == 0) continue;
      await db.rawUpdate('UPDATE Account SET currentBalance = currentBalance - ? WHERE id = ?', [
        entrada.value,
        entrada.key,
      ]);
    }
    final ids = aBorrar.map((p) => p['id'] as String).toList();
    if (ids.isNotEmpty) {
      await db.delete(
        'Transaction',
        where: 'id IN (${List.filled(ids.length, '?').join(',')})',
        whereArgs: ids,
      );
    }
    // La fila del mes deja de estar marcada. El monto se queda: revertir es "no
    // lo pagué", no "no sé cuánto era".
    await db.update(
      'RecurringFlowMonth',
      {'paidAt': null},
      where: 'recurringFlowId = ? AND month = ?',
      whereArgs: [id, mesARevertir],
    );

    await db.update('RecurringFlow', {'settledThrough': null}, where: 'id = ?', whereArgs: [id]);

    return {'reverted': pagos.length};
  });
}

/// Qué meses de un flujo ya están registrados.
///
/// Sale de las **fichas** —cada una sabe si se marcó y cuándo— y no de la fecha
/// de sus movimientos. Desde que un vencimiento puede caer fuera de su mes, la
/// fecha de un pago dejó de decir a qué mes pertenece: el pago de agosto de una
/// tarjeta que cierra el 28 ocurre el 5 de septiembre y sigue siendo de agosto.
///
/// Los movimientos solo cuentan para los meses **anteriores a la primera
/// ficha**: son los que se marcaron antes de que las fichas existieran, y ahí
/// la fecha es lo único que hay. Acotarlo importa — un pago fechado después
/// haría figurar como registrado un mes que nadie marcó.
Set<String> mesesRegistrados(List<Map<String, Object?>> fichas, Iterable<String> mesesDePagos) {
  final conFicha = fichas.map((f) => f['month'] as String).toList()..sort();
  final primera = conFicha.isEmpty ? null : conFicha.first;
  return {
    for (final f in fichas)
      if (f['paidAt'] != null) f['month'] as String,
    for (final m in mesesDePagos)
      if (primera == null || m.compareTo(primera) < 0) m,
  };
}

/// El último día de un mes.
int _ultimoDiaDe(String mes) {
  final p = mes.split('-');
  return DateTime(int.parse(p[0]), int.parse(p[1]) + 1, 0).day;
}

/// La caducidad de un mes, con el día que toque, acotada a su largo: un
/// vencimiento el 31 cae el 28 en febrero. Y siempre dentro de su propio mes —
/// una fila de agosto con fecha de septiembre ya se coló una vez.
DateTime caducidadDe(String mes, int dia) {
  final p = mes.split('-');
  final d = dia < 1 ? 1 : (dia > _ultimoDiaDe(mes) ? _ultimoDiaDe(mes) : dia);
  return DateTime.utc(int.parse(p[0]), int.parse(p[1]), d, 12);
}

String _mesSiguiente(String mes) {
  final p = mes.split('-');
  final d = DateTime(int.parse(p[0]), int.parse(p[1]) + 1, 1);
  return '${d.year}-${d.month.toString().padLeft(2, '0')}';
}

/// Cero o más, nunca negativo.
///
/// Cero vale a propósito: un flujo puede estar en pausa —un alquiler que este
/// año no se cobra— y obligar a borrarlo para registrar eso pierde su historia
/// y su categoría. Un negativo, en cambio, invertiría el sentido del flujo por
/// la puerta de atrás: si algo entra o sale lo dice `type`, no el signo.
///
/// Se valida acá y no solo en el formulario: la interfaz no es la que decide.
void _validarMonto(Object? valor) {
  if (valor == null) return;
  final monto = (valor as num).toDouble();
  if (monto < 0) {
    throw const ApiException('El monto no puede ser negativo.');
  }
}

/// El día en que un flujo vence dentro de un mes concreto, en dos dígitos.
///
/// Sale del ancla del propio flujo —`nextDueDate` guarda qué día del mes toca—
/// y se acota al largo del mes pedido: un vencimiento el 31 cae el 28 en
/// febrero, como en cualquier banco. Sin ancla, el 15: el único día que existe
/// en todos los meses y que no arrastra ninguna intención.
String _diaDeVencimiento(Map<String, Object?> flujo, String mes) {
  final ancla = flujo['nextDueDate'] as int?;
  if (ancla == null) return '15';
  final dia = DateTime.fromMillisecondsSinceEpoch(ancla, isUtc: true).day;
  final partes = mes.split('-');
  final ultimo = DateTime(int.parse(partes[0]), int.parse(partes[1]) + 1, 0).day;
  return (dia > ultimo ? ultimo : dia).toString().padLeft(2, '0');
}

/// Crea las filas de mes que falten y devuelve todas, en orden.
///
/// Cada mes nuevo nace copiando al anterior: su monto y su día. Solo hacia
/// atrás — heredar del mes siguiente haría que escribir agosto cambiara julio,
/// que es justo lo que este modelo vino a impedir. Sin ningún mes anterior del
/// que copiar, cae en el monto del flujo, que es la semilla.
Future<List<Map<String, Object?>>> _completarMeses(
  Database db,
  Map<String, Object?> flujo,
  UserClock clock,
  DateTime now,
) async {
  final id = flujo['id'] as String;
  final existentes = await db.query(
    'RecurringFlowMonth',
    where: 'recurringFlowId = ?',
    whereArgs: [id],
    orderBy: 'month ASC',
  );
  final porMes = {for (final f in existentes) f['month'] as String: f};

  final mesActual = clock.monthKey(now);
  var cursor = existentes.isEmpty
      ? clock.monthKey(_fecha(flujo['startDate'])!)
      : existentes.first['month'] as String;
  Map<String, Object?>? referencia = existentes.isEmpty ? null : existentes.first;

  // Tope de 24 vueltas: más atrás no es un selector, es un historial.
  for (var i = 0; cursor.compareTo(mesActual) <= 0 && i < 24; i++) {
    final existente = porMes[cursor];
    if (existente != null) {
      referencia = existente;
    } else {
      final dia = referencia == null
          ? DateTime.fromMillisecondsSinceEpoch(flujo['nextDueDate'] as int, isUtc: true).day
          : DateTime.fromMillisecondsSinceEpoch(referencia['dueDate'] as int, isUtc: true).day;
      final fila = <String, Object?>{
        'id': _uuid.v4(),
        'recurringFlowId': id,
        'month': cursor,
        'amount': referencia == null
            ? (flujo['amount'] as num).toDouble()
            : (referencia['amount'] as num).toDouble(),
        'dueDate': caducidadDe(cursor, dia).millisecondsSinceEpoch,
        'paidAt': null,
      };
      await db.insert('RecurringFlowMonth', fila);
      porMes[cursor] = fila;
      referencia = fila;
    }
    cursor = _mesSiguiente(cursor);
  }

  final claves = porMes.keys.toList()..sort();
  return [for (final k in claves) porMes[k]!];
}
