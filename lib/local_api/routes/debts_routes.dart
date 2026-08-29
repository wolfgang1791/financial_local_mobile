import 'package:uuid/uuid.dart';

import '../../data/api.dart' show ApiException;
import '../../local_db/row_mapping.dart';
import '../../local_engine/amortization.dart';
import '../../local_engine/currency_convert.dart';
import '../../local_engine/debts_engine.dart';
import '../../local_engine/ledger.dart' show liquidAccountTypes, round2;
import '../../local_engine/user_clock.dart';
import '../current_user.dart';
import '../local_api_router.dart';

const _uuid = Uuid();

/// El interés que corre este mes sobre una deuda **sin cronograma**.
///
/// Una tarjeta o una línea revolvente no tienen cuotas proyectadas, y hasta
/// ahora eso se traducía en "interés = 0": cada sol que pagabas bajaba el
/// capital. Sobre una tarjeta al 66% TEA con S/ 8,116 de saldo son S/ 350 al
/// mes que la app daba por amortizados y el banco no — el saldo de la app baja
/// más rápido que el del estado de cuenta, y la diferencia se acumula todos los
/// meses.
///
/// Es una **estimación**: el interés real depende de la fecha de cada consumo y
/// del corte. Por eso el desglose declarado manda sobre esto en cuanto el
/// usuario tiene el estado de cuenta delante.
///
/// La tasa mensual sale de la anual efectiva con la raíz doceava, no dividiendo
/// entre 12: la TEA ya incluye la capitalización, y dividir cobraría de menos.
double _interesDelMesSinCronograma(Map<String, Object?> deuda) {
  final saldo = (deuda['currentBalance'] as num?)?.toDouble() ?? 0;
  if (saldo <= 0) return 0;
  final tea = (deuda['interestRateAnnual'] as num?)?.toDouble() ?? 0;
  return round2(saldo * monthlyRateFromEffectiveAnnual(tea));
}

const _columnasBooleanasDebtKind = {'hasRates', 'hasTerm', 'hasDueDay', 'isActive'};
const _columnasBooleanasAccount = {'isArchived', 'isHidden'};
const _columnasFechaAccount = {'createdAt', 'updatedAt'};
const _columnasBooleanasDebt = {'isActive'};
const _columnasFechaDebt = {'originationDate', 'dueDate'};

Map<String, dynamic> _debtKindJson(Map<String, Object?> fila) =>
    mapRow(fila, columnasBooleanas: _columnasBooleanasDebtKind);

Map<String, dynamic> _accountJson(Map<String, Object?> fila) => mapRow(
  fila,
  columnasBooleanas: _columnasBooleanasAccount,
  columnasFecha: _columnasFechaAccount,
);

void registerDebtsRoutes() {
  // GET /debts/kinds — antes de la ruta con :id para que no se la coma.
  LocalApiRouter.registerGet('/debts/kinds', (db, uri, body) async {
    final filas = await db.query('DebtKind', where: 'isActive = 1', orderBy: 'sortOrder ASC');
    return filas.map(_debtKindJson).toList();
  });

  // GET /debts/history — la deuda mes a mes: cuánto se pagó, en qué se fue y
  // con cuánto saldo cerró cada mes. Puerto de `monthlyHistory` del backend.
  //
  // Se declara antes que `/debts/:id` porque el router hace calzar por patrón y
  // "history" entraría como un id.
  LocalApiRouter.registerGet('/debts/history', (db, uri, body) async {
    final userId = await currentUserId(db);
    final clock = await UserClock.forUser(db, userId);
    const meses = 12;

    // Solo las que cuentan. Una cancelada está fuera de todos los totales de la
    // app, y dejarla acá hacía que el saldo del último mes no cuadrara con el de
    // la pantalla de Deudas — dos vistas diciendo cifras distintas sobre lo
    // mismo, que es peor que perder el rastro de sus pagos.
    final deudas = await db.query(
      'Debt',
      where: 'userId = ? AND isActive = 1',
      whereArgs: [userId],
    );
    if (deudas.isEmpty) return <Map<String, dynamic>>[];

    final ids = deudas.map((d) => d['id'] as String).toList();
    final pagos = await db.rawQuery('''
      SELECT debtId, occurredAt, amount, debtAmountApplied, debtPrincipalApplied,
             debtInterestApplied, debtInsuranceApplied, debtFeesApplied
      FROM "Transaction" WHERE debtId IN (${List.filled(ids.length, '?').join(',')})
      ''', ids);

    // La rejilla es fija —los últimos doce meses— y no "los meses con datos":
    // un mes sin pagos tiene que verse como el hueco que es, no desaparecer y
    // dejar dos meses no consecutivos pegados uno al lado del otro.
    final claves = [
      for (var i = meses - 1; i >= 0; i--) clock.monthKey(clock.addMonths(clock.now(), -i)),
    ];

    final porMoneda = <String, Map<String, Map<String, double>>>{};
    final monedaDeCuenta = <String, String>{};
    for (final cuenta in await db.query('Account', where: 'userId = ?', whereArgs: [userId])) {
      monedaDeCuenta[cuenta['id'] as String] = (cuenta['currency'] as String?) ?? 'PEN';
    }

    final pagosPorDeuda = <String, List<Map<String, Object?>>>{};
    for (final p in pagos) {
      (pagosPorDeuda[p['debtId'] as String] ??= []).add(p);
    }

    double num0(Object? v) => (v as num?)?.toDouble() ?? 0;

    for (final deuda in deudas) {
      final moneda = monedaDeCuenta[deuda['accountId'] as String] ?? 'PEN';
      final serie = porMoneda.putIfAbsent(
        moneda,
        () => {
          for (final k in claves)
            k: {'paid': 0.0, 'principal': 0.0, 'interest': 0.0, 'other': 0.0, 'balance': 0.0},
        },
      );
      final propios = pagosPorDeuda[deuda['id'] as String] ?? const [];
      final mesOrigen = clock.monthKey(
        DateTime.fromMillisecondsSinceEpoch(deuda['originationDate'] as int, isUtc: true),
      );

      String mesDe(Map<String, Object?> p) =>
          clock.monthKey(DateTime.fromMillisecondsSinceEpoch(p['occurredAt'] as int, isUtc: true));

      for (final p in propios) {
        final punto = serie[mesDe(p)];
        if (punto == null) continue;
        final pagado = p['debtAmountApplied'] == null
            ? num0(p['amount'])
            : num0(p['debtAmountApplied']);
        final capital = num0(p['debtPrincipalApplied']);
        final extra = num0(p['debtInsuranceApplied']) + num0(p['debtFeesApplied']);
        // El interés se deriva y no se lee de la columna, salvo que venga
        // declarado: solo se guarda cuando el usuario tenía el estado de cuenta
        // delante. Lo que siempre se sabe es cuánto se pagó y cuánto de eso bajó
        // el capital — el resto se lo llevó el préstamo. Es la misma cuenta que
        // ya hacen el estado del mes y el revertir.
        final interes = p['debtInterestApplied'] == null
            ? (pagado - capital - extra).clamp(0.0, double.infinity)
            : num0(p['debtInterestApplied']);
        punto['principal'] = punto['principal']! + capital;
        punto['interest'] = punto['interest']! + interes;
        punto['other'] = punto['other']! + extra;
        punto['paid'] = punto['paid']! + pagado;
      }

      // El saldo de cierre se reconstruye hacia atrás desde el de hoy, que es el
      // único que se sabe cierto: se le devuelve el capital amortizado después
      // de ese mes. Antes de su mes de origen la deuda no suma nada — sin ese
      // corte, una deuda de junio aparecería debiéndose desde enero.
      var saldo = num0(deuda['currentBalance']);
      for (var i = claves.length - 1; i >= 0; i--) {
        final clave = claves[i];
        if (clave.compareTo(mesOrigen) >= 0) {
          serie[clave]!['balance'] = serie[clave]!['balance']! + saldo;
        }
        saldo += propios
            .where((p) => mesDe(p) == clave)
            .fold<double>(0, (a, p) => a + num0(p['debtPrincipalApplied']));
      }
    }

    return [
      for (final entrada in porMoneda.entries)
        {
          'currency': entrada.key,
          // Se recorta el vacío del principio: si la deuda es de julio, los
          // meses anteriores son ceros que aplastan el gráfico contra el borde
          // derecho y no cuentan nada. Solo el de adelante — un hueco *entre*
          // dos meses con datos sí informa (ese mes no se pagó) y se queda.
          'months': [
            for (final k in _desdeElPrimeroConDatos(claves, entrada.value))
              {
                'month': k,
                'paid': round2(entrada.value[k]!['paid']!),
                'principal': round2(entrada.value[k]!['principal']!),
                'interest': round2(entrada.value[k]!['interest']!),
                'other': round2(entrada.value[k]!['other']!),
                'balance': round2(entrada.value[k]!['balance']!),
              },
          ],
        },
    ];
  });

  // GET /debts — "estado: pagada/pendiente/parcial este mes", igual que en
  // los flujos recurrentes: se deriva de si ya hay una transacción de esta
  // deuda en el mes, nunca se guarda como bandera.
  // PATCH /debts/:id/payments/:paymentId — corregir el reparto de un pago.
  //
  // Lo que pagaste no se toca: sigue siendo el mismo dinero que salió de tu
  // cuenta el mismo día. Lo que se corrige es **en qué se fue** —cuánto bajó la
  // deuda y cuánto se lo llevó el préstamo—, que es lo que la app estima al
  // pagar y tu estado de cuenta dice exacto.
  //
  // Las cuatro partes suman siempre lo pagado, y la que no declaras absorbe el
  // resto: si corriges el interés, el capital se recalcula solo, y si corriges
  // el capital, es el interés el que cede.
  //
  // Mover capital mueve el saldo de la deuda —y el de su cuenta espejo— por la
  // diferencia, no por el monto entero: es una corrección del reparto, no un
  // pago nuevo.
  LocalApiRouter.registerPatch('/debts/:id/payments/:paymentId', (db, uri, body) async {
    final userId = await currentUserId(db);
    final id = uri.queryParameters['id']!;
    final paymentId = uri.queryParameters['paymentId']!;
    final datos = (body as Map?)?.cast<String, dynamic>() ?? const {};

    final deudas = await db.query(
      'Debt',
      where: 'id = ? AND userId = ?',
      whereArgs: [id, userId],
      limit: 1,
    );
    if (deudas.isEmpty) throw ApiException('Debt $id not found', status: 404);
    final deuda = deudas.first;

    final pagos = await db.rawQuery(
      '''
      SELECT t.* FROM "Transaction" t JOIN Account a ON a.id = t.accountId
      WHERE t.id = ? AND t.debtId = ? AND a.userId = ?
      ''',
      [paymentId, id, userId],
    );
    if (pagos.isEmpty) throw ApiException('Payment $paymentId not found', status: 404);
    final pago = pagos.first;

    final pagado = round2(
      (pago['debtAmountApplied'] as num?)?.toDouble() ?? (pago['amount'] as num).toDouble(),
    );
    final capitalAntes = (pago['debtPrincipalApplied'] as num?)?.toDouble() ?? 0;

    double positivo(double v) => v < 0 ? 0 : v;
    final seguro = round2(
      positivo(
        (datos['insurance'] as num?)?.toDouble() ??
            (pago['debtInsuranceApplied'] as num?)?.toDouble() ??
            0,
      ),
    );
    final portes = round2(
      positivo(
        (datos['fees'] as num?)?.toDouble() ??
            (pago['debtFeesApplied'] as num?)?.toDouble() ??
            0,
      ),
    );

    final double interes;
    final double capital;
    if (datos.containsKey('principal') && datos['principal'] != null) {
      // El capital manda y el interés absorbe el resto, salvo que también venga
      // declarado — ahí mandan los dos y se comprueba que cuadren.
      final pedido = (datos['principal'] as num).toDouble();
      capital = round2(positivo(pedido < pagado ? pedido : pagado));
      interes = datos['interest'] != null
          ? round2(positivo((datos['interest'] as num).toDouble()))
          : round2(positivo(pagado - capital - seguro - portes));
    } else {
      interes = round2(
        positivo(
          (datos['interest'] as num?)?.toDouble() ??
              (pago['debtInterestApplied'] as num?)?.toDouble() ??
              0,
        ),
      );
      capital = round2(positivo(pagado - interes - seguro - portes));
    }

    if (capital + interes + seguro + portes > pagado + 0.01) {
      throw ApiException(
        'Las partes suman más de lo que pagaste ($pagado). Revisa el desglose.',
      );
    }

    // Amortizar más de lo que se debe dejaría la deuda en negativo. El tope es
    // lo que este pago ya tenía acreditado más lo que queda por deber.
    final tope = round2(capitalAntes + (deuda['currentBalance'] as num).toDouble());
    if (capital > tope) {
      throw ApiException(
        'No puedes acreditar $capital a capital: contando este pago, la deuda solo tiene $tope pendiente.',
      );
    }

    await db.update(
      '"Transaction"',
      {
        'debtPrincipalApplied': capital,
        'debtInterestApplied': interes,
        'debtInsuranceApplied': seguro > 0 ? seguro : null,
        'debtFeesApplied': portes > 0 ? portes : null,
      },
      where: 'id = ?',
      whereArgs: [paymentId],
    );

    final delta = round2(capital - capitalAntes);
    if (delta != 0) {
      // La deuda y su cuenta espejo se mueven juntas: son el mismo número visto
      // desde dos tablas, y separarlas deja la sección Deudas y el patrimonio
      // diciendo cifras distintas sobre lo mismo.
      await db.rawUpdate('UPDATE Debt SET currentBalance = currentBalance - ? WHERE id = ?', [
        delta,
        id,
      ]);
      await db.rawUpdate('UPDATE Account SET currentBalance = currentBalance - ? WHERE id = ?', [
        delta,
        deuda['accountId'],
      ]);
    }

    return {
      'id': paymentId,
      'paid': pagado,
      'principal': capital,
      'interest': interes,
      'insurance': seguro,
      'fees': portes,
    };
  });

  // GET /debts/:id/payments — todos los pagos de una deuda, con qué hizo cada
  // uno.
  //
  // La pregunta que contesta no es "cuánto he pagado" —eso ya está en el
  // historial de movimientos— sino **"de todo lo que pagué, cuánto bajó la
  // deuda"**, que sobre un crédito caro son dos cifras muy distintas: de
  // S/ 1,694 de una cuota, S/ 677 bajaron el capital y S/ 1,017 se los llevó el
  // préstamo.
  //
  // El saldo de cada fila se reconstruye hacia atrás desde el actual, no hacia
  // adelante desde el principal: misma regla que el saldo corrido del historial
  // de movimientos, y la que garantiza que la última fila termine exactamente
  // en el saldo que muestra la tarjeta.
  LocalApiRouter.registerGet('/debts/:id/payments', (db, uri, body) async {
    final userId = await currentUserId(db);
    final id = uri.queryParameters['id']!;
    final clock = await UserClock.forUser(db, userId);

    final deudas = await db.query(
      'Debt',
      where: 'id = ? AND userId = ?',
      whereArgs: [id, userId],
      limit: 1,
    );
    if (deudas.isEmpty) throw ApiException('Debt $id not found', status: 404);
    final deuda = deudas.first;

    final cuentaDeuda = (await db.query(
      'Account',
      where: 'id = ?',
      whereArgs: [deuda['accountId']],
      limit: 1,
    )).first;
    final moneda = cuentaDeuda['currency'] as String;

    final pagos = await db.rawQuery(
      '''
      SELECT t.*, a.name AS cuentaNombre, a.currency AS cuentaMoneda
      FROM "Transaction" t JOIN Account a ON a.id = t.accountId
      WHERE t.debtId = ?
      ORDER BY t.occurredAt DESC, t.createdAt DESC
      ''',
      [id],
    );

    var saldo = (deuda['currentBalance'] as num).toDouble();
    final filas = <Map<String, dynamic>>[];
    for (final p in pagos) {
      final aplicado =
          (p['debtAmountApplied'] as num?)?.toDouble() ?? (p['amount'] as num).toDouble();
      final capital = (p['debtPrincipalApplied'] as num?)?.toDouble() ?? 0;
      final seguro = (p['debtInsuranceApplied'] as num?)?.toDouble() ?? 0;
      final portes = (p['debtFeesApplied'] as num?)?.toDouble() ?? 0;
      // El interés declarado si lo hay; si no, lo que quedó después de capital,
      // seguro y portes. Los pagos viejos no lo guardaban.
      final interes =
          (p['debtInterestApplied'] as num?)?.toDouble() ??
          round2((aplicado - capital - seguro - portes).clamp(0, double.infinity));
      final cuando = DateTime.fromMillisecondsSinceEpoch(p['occurredAt'] as int, isUtc: true);

      filas.add({
        'id': p['id'],
        'occurredAt': cuando.toIso8601String(),
        'month': clock.monthKey(cuando),
        'paid': round2(aplicado),
        'principal': round2(capital),
        'interest': interes,
        'insurance': round2(seguro),
        'fees': round2(portes),
        // Lo que salió de la cuenta, en **su** moneda: con una deuda en dólares
        // pagada en soles son dos cifras distintas y las dos importan.
        'charged': round2((p['amount'] as num).toDouble()),
        'chargedCurrency': p['cuentaMoneda'],
        'chargedFrom': p['cuentaNombre'],
        'description': p['description'],
        'balanceAfter': round2(saldo),
        'balanceBefore': round2(saldo + capital),
      });
      saldo = round2(saldo + capital);
    }

    double total(String campo) =>
        round2(filas.fold<double>(0, (s, f) => s + (f[campo] as num).toDouble()));

    return {
      'currency': moneda,
      'payments': filas,
      'totals': {
        'paid': total('paid'),
        'principal': total('principal'),
        // Todo lo que no bajó la deuda, junto y separado: es el costo de
        // haberla tenido.
        'interest': total('interest'),
        'insurance': total('insurance'),
        'fees': total('fees'),
        'cost': round2(total('interest') + total('insurance') + total('fees')),
      },
    };
  });

  LocalApiRouter.registerGet('/debts', (db, uri, body) async {
    final userId = await currentUserId(db);
    final clock = await UserClock.forUser(db, userId);

    // Sin filtrar por isActive: las canceladas también viajan, con su bandera
    // puesta, para que la pantalla pueda mostrarlas como histórico. Es el único
    // sitio que las ve — el motor de recomendaciones filtra por su cuenta, y
    // por eso cancelar una deuda la saca de los cálculos sin tocarlo.
    final deudas = await db.query('Debt', where: 'userId = ?', whereArgs: [userId]);
    if (deudas.isEmpty) return <Map<String, dynamic>>[];
    final ids = deudas.map((d) => d['id'] as String).toList();
    final placeholders = List.filled(ids.length, '?').join(',');

    final inicioMes = clock.startOfMonth();
    final pagosEsteMes = await db.rawQuery(
      '''
      SELECT debtId, debtAmountApplied, debtPrincipalApplied, amount
      FROM "Transaction" WHERE debtId IN ($placeholders) AND occurredAt >= ?
      ''',
      [...ids, inicioMes.millisecondsSinceEpoch],
    );
    final todosLosPagos = await db.rawQuery(
      'SELECT debtId, occurredAt FROM "Transaction" WHERE debtId IN ($placeholders)',
      ids,
    );
    final proximasCuotas = await db.rawQuery('''
      SELECT dp.* FROM DebtPayment dp
      WHERE dp.debtId IN ($placeholders) AND dp.status = 'SCHEDULED'
        AND dp.dueDate = (
          SELECT MIN(dp2.dueDate) FROM DebtPayment dp2
          WHERE dp2.debtId = dp.debtId AND dp2.status = 'SCHEDULED'
        )
      ''', ids);

    final pagadoPorDeuda = <String, double>{};
    final interesPagadoPorDeuda = <String, double>{};
    for (final pago in pagosEsteMes) {
      final id = pago['debtId'] as String;
      final aplicado =
          (pago['debtAmountApplied'] as num?)?.toDouble() ?? (pago['amount'] as num).toDouble();
      pagadoPorDeuda[id] = (pagadoPorDeuda[id] ?? 0) + aplicado;
      interesPagadoPorDeuda[id] =
          (interesPagadoPorDeuda[id] ?? 0) +
          (aplicado - ((pago['debtPrincipalApplied'] as num?)?.toDouble() ?? 0));
    }

    final mesesPorDeuda = <String, Set<String>>{};
    for (final pago in todosLosPagos) {
      final id = pago['debtId'] as String;
      final ocurrio = DateTime.fromMillisecondsSinceEpoch(pago['occurredAt'] as int, isUtc: true);
      (mesesPorDeuda[id] ??= {}).add(clock.monthKey(ocurrio));
    }

    final proximaPorDeuda = {for (final c in proximasCuotas) c['debtId'] as String: c};

    final resultado = <Map<String, dynamic>>[];
    for (final deuda in deudas) {
      final id = deuda['id'] as String;
      final proxima = proximaPorDeuda[id];
      final derivado = decorateDebt(
        currentBalance: (deuda['currentBalance'] as num).toDouble(),
        minimumPayment: (deuda['minimumPayment'] as num).toDouble(),
        originationDate: DateTime.fromMillisecondsSinceEpoch(
          deuda['originationDate'] as int,
          isUtc: true,
        ),
        termMonths: (deuda['termMonths'] as num?)?.toInt(),
        paidThisMonth: round2(pagadoPorDeuda[id] ?? 0),
        interestPaidThisMonth: interesPagadoPorDeuda[id] ?? 0,
        paidMonths: mesesPorDeuda[id] ?? {},
        nextScheduledAmount: (proxima?['scheduledAmount'] as num?)?.toDouble(),
        // Sin cronograma se estima sobre el saldo: una tarjeta no tiene cuotas
        // proyectadas, pero sí cobra interés todos los meses.
        nextInterestPortion:
            (proxima?['interestPortion'] as num?)?.toDouble() ??
            _interesDelMesSinCronograma(deuda),
        hasScheduledPayment: proxima != null,
        clock: clock,
        isActive: (deuda['isActive'] as int? ?? 1) == 1,
      );

      final cuentaFila = await db.query(
        'Account',
        where: 'id = ?',
        whereArgs: [deuda['accountId']],
        limit: 1,
      );
      final tipoFila = await db.query(
        'DebtKind',
        where: 'code = ?',
        whereArgs: [deuda['debtTypeCode']],
        limit: 1,
      );

      resultado.add({
        ...mapRow(
          deuda,
          columnasBooleanas: _columnasBooleanasDebt,
          columnasFecha: _columnasFechaDebt,
        ),
        'account': cuentaFila.isEmpty ? null : _accountJson(cuentaFila.first),
        'debtKind': tipoFila.isEmpty ? null : _debtKindJson(tipoFila.first),
        'statusThisMonth': derivado.statusThisMonth,
        'lastPaidMonth': derivado.lastPaidMonth,
        'missedMonths': derivado.missedMonths,
        'paidThisMonth': derivado.paidThisMonth,
        'pendingThisMonth': derivado.pendingThisMonth,
        'installmentInterest': derivado.installmentInterest,
        'interestPendingThisMonth': derivado.interestPendingThisMonth,
        'installmentAmount': derivado.installmentAmount,
        'scheduledInstallment': derivado.scheduledInstallment,
        // Cuánto falta hasta terminarla, simulado desde el saldo de hoy.
        'projection': proyectarDeuda(
          currentBalance: (deuda['currentBalance'] as num).toDouble(),
          installment: derivado.installmentAmount,
          interestRateAnnual: (deuda['interestRateAnnual'] as num?)?.toDouble() ?? 0,
          costRateAnnual: (deuda['costRateAnnual'] as num?)?.toDouble(),
          monthlyInsurance: (deuda['monthlyInsurance'] as num?)?.toDouble() ?? 0,
          termMonths: (deuda['termMonths'] as num?)?.toInt(),
        ).toJson(),
        'remainingInstallments': derivado.remainingInstallments,
      });
    }

    // Mismo orden que el backend: saldo de mayor a menor.
    resultado.sort(
      (a, b) => (b['currentBalance'] as num).toDouble().compareTo(
        (a['currentBalance'] as num).toDouble(),
      ),
    );
    return resultado;
  });

  // POST /debts — crea la cuenta espejo y la deuda, y —cuando hay plazo—
  // el cronograma proyectado, para que "¿cuándo termino de pagar?" sea una
  // lectura y no un cálculo cada vez.
  LocalApiRouter.registerPost('/debts', (db, uri, body) async {
    final userId = await currentUserId(db);
    final datos = bodyAsMap(body);

    final tipoFila = await db.query(
      'DebtKind',
      where: 'code = ?',
      whereArgs: [datos['debtTypeCode']],
    );
    if (tipoFila.isEmpty) {
      throw ApiException('Tipo de deuda ${datos['debtTypeCode']} no existe', status: 404);
    }
    final tipo = tipoFila.first;

    final clock = await UserClock.forUser(db, userId);
    final originationDate = clock.toInstantValue(campoObligatorio(datos, 'originationDate'));
    final interestRateAnnual = (datos['interestRateAnnual'] as num?)?.toDouble() ?? 0;
    // El cronograma se arma con la TCEA cuando existe: es lo que de verdad
    // se paga cada mes, incluidos seguro y portes que la TEA deja fuera.
    final scheduleRate = (datos['costRateAnnual'] as num?)?.toDouble() ?? interestRateAnnual;
    final currentBalance = (datos['currentBalance'] as num).toDouble();

    final accountId = _uuid.v4();
    final ahora = DateTime.now().toUtc().millisecondsSinceEpoch;
    await db.insert('Account', {
      'id': accountId,
      'userId': userId,
      'name': datos['name'],
      'type': tipo['accountType'],
      'institution': datos['institution'],
      'currentBalance': currentBalance,
      'currency': (datos['currency'] as String?) ?? 'PEN',
      'isArchived': 0,
      'isHidden': 0,
      'createdAt': ahora,
      'updatedAt': ahora,
    });

    final debtId = _uuid.v4();
    final termMonths = (datos['termMonths'] as num?)?.toInt();
    await db.insert('Debt', {
      'id': debtId,
      'userId': userId,
      'accountId': accountId,
      'debtTypeCode': tipo['code'],
      'originalPrincipal': (datos['originalPrincipal'] as num).toDouble(),
      'currentBalance': currentBalance,
      'interestRateAnnual': interestRateAnnual,
      'costRateAnnual': (datos['costRateAnnual'] as num?)?.toDouble(),
      'minimumPayment': (datos['minimumPayment'] as num?)?.toDouble() ?? 0,
      'monthlyInsurance': (datos['monthlyInsurance'] as num?)?.toDouble(),
      'termMonths': termMonths,
      'originationDate': originationDate.millisecondsSinceEpoch,
      // Sin día de pago pactado, el del desembolso es la referencia menos
      // arbitraria.
      'dueDay': (datos['dueDay'] as num?)?.toInt() ?? clock.parts(originationDate).day,
      'dueDate': datos['dueDate'] != null
          ? clock.toInstantValue(datos['dueDate'] as String).millisecondsSinceEpoch
          : null,
      'isActive': 1,
    });

    if (termMonths != null) {
      final resultado = amortizeInstallmentLoan(
        principal: currentBalance,
        annualRate: scheduleRate,
        termMonths: termMonths,
        startDate: originationDate,
      );
      for (final cuota in resultado.schedule) {
        await db.insert('DebtPayment', {
          'id': _uuid.v4(),
          'debtId': debtId,
          'dueDate': cuota.dueDate.millisecondsSinceEpoch,
          'scheduledAmount': cuota.payment,
          'principalPortion': cuota.principalPortion,
          'interestPortion': cuota.interestPortion,
          'status': 'SCHEDULED',
        });
      }
    }

    final fila = (await db.query('Debt', where: 'id = ?', whereArgs: [debtId])).first;
    return mapRow(
      fila,
      columnasBooleanas: _columnasBooleanasDebt,
      columnasFecha: _columnasFechaDebt,
    );
  });

  // PATCH /debts/:id — corrige la deuda, su cuenta espejo, y el cronograma
  // si algo de lo que lo determina cambió. Si nada cambió, no se toca:
  // volver a generarlo borraría cuotas ya marcadas como pagadas.
  LocalApiRouter.registerPatch('/debts/:id', (db, uri, body) async {
    final userId = await currentUserId(db);
    final id = uri.queryParameters['id']!;
    final datos = bodyAsMap(body);

    final filas = await db.query('Debt', where: 'id = ? AND userId = ?', whereArgs: [id, userId]);
    if (filas.isEmpty) throw ApiException('Debt $id not found', status: 404);
    final existente = filas.first;
    final clock = await UserClock.forUser(db, userId);

    final currentBalance =
        (datos['currentBalance'] as num?)?.toDouble() ??
        (existente['currentBalance'] as num).toDouble();
    final interestRateAnnual =
        (datos['interestRateAnnual'] as num?)?.toDouble() ??
        (existente['interestRateAnnual'] as num).toDouble();
    final costRateAnnual =
        (datos['costRateAnnual'] as num?)?.toDouble() ??
        (existente['costRateAnnual'] as num?)?.toDouble();
    final termMonths =
        (datos['termMonths'] as num?)?.toInt() ?? (existente['termMonths'] as num?)?.toInt();
    final originationDate = datos['originationDate'] != null
        ? clock.toInstantValue(datos['originationDate'] as String)
        : DateTime.fromMillisecondsSinceEpoch(existente['originationDate'] as int, isUtc: true);

    final cambioCronograma =
        currentBalance != (existente['currentBalance'] as num).toDouble() ||
        (costRateAnnual ?? interestRateAnnual) !=
            ((existente['costRateAnnual'] as num?)?.toDouble() ??
                (existente['interestRateAnnual'] as num).toDouble()) ||
        termMonths != (existente['termMonths'] as num?)?.toInt() ||
        originationDate.millisecondsSinceEpoch != existente['originationDate'];

    final cambiosDeuda = <String, Object?>{};
    for (final campo in [
      'originalPrincipal',
      'currentBalance',
      'interestRateAnnual',
      'costRateAnnual',
      'minimumPayment',
      'monthlyInsurance',
      'termMonths',
      'dueDay',
    ]) {
      if (datos.containsKey(campo)) cambiosDeuda[campo] = datos[campo];
    }
    if (datos['originationDate'] != null) {
      cambiosDeuda['originationDate'] = originationDate.millisecondsSinceEpoch;
    }
    if (datos['dueDate'] != null) {
      cambiosDeuda['dueDate'] = clock
          .toInstantValue(datos['dueDate'] as String)
          .millisecondsSinceEpoch;
    }
    if (cambiosDeuda.isNotEmpty) {
      await db.update('Debt', cambiosDeuda, where: 'id = ?', whereArgs: [id]);
    }

    final cambiosCuenta = <String, Object?>{};
    for (final campo in ['name', 'institution', 'currentBalance', 'currency']) {
      if (datos.containsKey(campo)) cambiosCuenta[campo] = datos[campo];
    }
    if (cambiosCuenta.isNotEmpty) {
      await db.update(
        'Account',
        cambiosCuenta,
        where: 'id = ?',
        whereArgs: [existente['accountId']],
      );
    }

    if (cambioCronograma && termMonths != null) {
      // Solo las cuotas todavía no pagadas: un pago ya registrado es un
      // hecho, no una proyección que se pueda reescribir.
      await db.delete(
        'DebtPayment',
        where: 'debtId = ? AND status = ?',
        whereArgs: [id, 'SCHEDULED'],
      );
      final resultado = amortizeInstallmentLoan(
        principal: currentBalance,
        annualRate: costRateAnnual ?? interestRateAnnual,
        termMonths: termMonths,
        startDate: originationDate,
      );
      for (final cuota in resultado.schedule) {
        await db.insert('DebtPayment', {
          'id': _uuid.v4(),
          'debtId': id,
          'dueDate': cuota.dueDate.millisecondsSinceEpoch,
          'scheduledAmount': cuota.payment,
          'principalPortion': cuota.principalPortion,
          'interestPortion': cuota.interestPortion,
          'status': 'SCHEDULED',
        });
      }
    }

    final fila = (await db.query('Debt', where: 'id = ?', whereArgs: [id])).first;
    return mapRow(
      fila,
      columnasBooleanas: _columnasBooleanasDebt,
      columnasFecha: _columnasFechaDebt,
    );
  });

  // POST /debts/:id/pay — el corazón de la Fase 5. El interés del período
  // se cobra una sola vez pero puede quedar a medias entre pagos parciales
  // del mismo mes; recién cuando está cubierto, el resto baja capital.
  LocalApiRouter.registerPost('/debts/:id/pay', (db, uri, body) async {
    final userId = await currentUserId(db);
    final id = uri.queryParameters['id']!;
    final datos = bodyAsMap(body);

    final filas = await db.query('Debt', where: 'id = ? AND userId = ?', whereArgs: [id, userId]);
    if (filas.isEmpty) throw ApiException('Debt $id not found', status: 404);
    final deuda = filas.first;
    final cuentaDeudaFila = await db.query(
      'Account',
      where: 'id = ?',
      whereArgs: [deuda['accountId']],
    );
    final cuentaDeuda = cuentaDeudaFila.first;

    final payingAccountId = campoObligatorio(datos, 'accountId');
    final cuentaPagoFila = await db.query(
      'Account',
      where: 'id = ? AND userId = ?',
      whereArgs: [payingAccountId, userId],
    );
    if (cuentaPagoFila.isEmpty) {
      throw ApiException('Account $payingAccountId not found', status: 404);
    }
    final cuentaPago = cuentaPagoFila.first;
    if (!liquidAccountTypes.contains(cuentaPago['type'])) {
      throw const ApiException(
        'Una cuota se paga desde una cuenta con dinero, no desde otra deuda.',
      );
    }

    final proximaFila = await db.query(
      'DebtPayment',
      where: 'debtId = ? AND status = ?',
      whereArgs: [id, 'SCHEDULED'],
      orderBy: 'dueDate ASC',
      limit: 1,
    );
    final proxima = proximaFila.isEmpty ? null : proximaFila.first;

    final clock = await UserClock.forUser(db, userId);
    final inicioMes = clock.startOfMonth();
    final pagosDelMes = await db.query(
      'Transaction',
      columns: ['debtAmountApplied', 'debtPrincipalApplied', 'amount'],
      where: 'debtId = ? AND occurredAt >= ?',
      whereArgs: [id, inicioMes.millisecondsSinceEpoch],
    );
    double aplicadoDe(Map<String, Object?> p) =>
        (p['debtAmountApplied'] as num?)?.toDouble() ?? (p['amount'] as num).toDouble();
    final paidSoFar = round2(pagosDelMes.fold<double>(0, (acc, p) => acc + aplicadoDe(p)));
    final interestPaidSoFar = round2(
      pagosDelMes.fold<double>(
        0,
        (acc, p) => acc + (aplicadoDe(p) - ((p['debtPrincipalApplied'] as num?)?.toDouble() ?? 0)),
      ),
    );

    final declared = (deuda['minimumPayment'] as num).toDouble();
    final installment = round2(
      declared > 0 ? declared : ((proxima?['scheduledAmount'] as num?)?.toDouble() ?? 0),
    );
    // Por defecto se paga lo que falta de la cuota, no la cuota entera: si
    // ya se abonó una parte este mes, no se puede volver a cobrar todo.
    final amount = round2(
      (datos['amount'] as num?)?.toDouble() ?? (installment - paidSoFar).clamp(0, double.infinity),
    );
    if (amount <= 0) {
      throw const ApiException(
        'Indica cuánto estás pagando: esta deuda no tiene cuota pendiente este mes.',
      );
    }

    // El interés del mes se cobra una sola vez; si el primer abono no
    // alcanzó a cubrirlo, el siguiente paga el resto antes de tocar
    // capital. Recién cuando está cubierto, todo lo demás baja la deuda.
    //
    // Sin cronograma —una tarjeta, una línea revolvente— el interés no es cero:
    // se estima sobre el saldo. Darlo por cero era acreditar al capital lo que
    // el banco cobra como interés: sobre una tarjeta al 66% TEA con S/ 8,116 de
    // saldo son S/ 350 al mes que la app daba por amortizados y el banco no.
    final monthInterest =
        (proxima?['interestPortion'] as num?)?.toDouble() ??
        _interesDelMesSinCronograma(deuda);
    final interestDue = (monthInterest - interestPaidSoFar).clamp(0, double.infinity);
    // Lo declarado manda sobre lo estimado: con el estado de cuenta delante, esa
    // es la verdad. Antes se guardaba lo declarado pero se repartía con lo
    // estimado, así que la fila decía "capital 170" mientras el saldo bajaba 200.
    final interest =
        (datos['interest'] as num?)?.toDouble() ?? (amount < interestDue ? amount : interestDue);

    // El desgravamen sale de la cuota antes que el capital.
    //
    // Es lo que hace cualquier estado de cuenta: de S/ 1,694.80, S/ 110.75 son
    // seguro y no bajan un céntimo de la deuda. Sin descontarlo, esos 110 se
    // acreditaban al capital y el saldo de la app bajaba más rápido que el del
    // banco — un desvío que se acumula todos los meses.
    //
    // Se cobra una vez por mes: si ya se pagó una parte de la cuota, el seguro
    // ya salió en ese pago.
    final seguroDelMes = (deuda['monthlyInsurance'] as num?)?.toDouble() ?? 0;
    final seguro =
        (datos['insurance'] as num?)?.toDouble() ??
        (interestPaidSoFar > 0
            ? 0.0
            : ((amount - interest).clamp(0, double.infinity) < seguroDelMes
                  ? (amount - interest).clamp(0, double.infinity).toDouble()
                  : seguroDelMes));

    // Los portes también salen antes que el capital. Se guardaban en la fila
    // pero no se restaban, así que declararlos inflaba lo amortizado.
    final portes = (datos['fees'] as num?)?.toDouble() ?? 0;

    // Acotado al saldo aunque venga declarado: amortizar más de lo que se debe
    // dejaría la deuda en negativo, y "me sobró capital" no es una deuda.
    final principal = round2(
      ((datos['principal'] as num?)?.toDouble() ?? (amount - interest - seguro - portes)).clamp(
        0,
        (deuda['currentBalance'] as num).toDouble(),
      ),
    );

    final categoriaFila = await db.query(
      'Category',
      where: 'name = ? AND isSystem = 1 AND parentId IS NULL',
      whereArgs: ['Deudas'],
    );
    final categoriaId = categoriaFila.isEmpty ? null : categoriaFila.first['id'] as String;

    final occurredAt = datos['occurredAt'] != null
        ? clock.toInstantValue(datos['occurredAt'] as String)
        : clock.now();
    final convertido = await convert(
      db,
      amount,
      cuentaDeuda['currency'] as String,
      cuentaPago['currency'] as String,
      purpose: ConversionPurpose.debt,
      date: occurredAt,
    );

    final transaccionId = _uuid.v4();
    await db.insert('Transaction', {
      'id': transaccionId,
      'accountId': payingAccountId,
      'categoryId': categoriaId,
      'debtId': id,
      'debtPaymentId': proxima?['id'],
      // El desglose declarado manda sobre el estimado: si el usuario tiene
      // el estado de cuenta delante, esa es la verdad.
      'debtPrincipalApplied': principal,
      // El interés siempre, declarado o estimado: sin esto la columna solo se
      // llenaba cuando venía del estado de cuenta, y el historial tenía que
      // deducirlo restando —metiendo el seguro y los portes dentro del interés—.
      'debtInterestApplied': interest,
      'debtInsuranceApplied': seguro > 0 ? seguro : null,
      'debtFeesApplied': portes > 0 ? portes : null,
      'debtAmountApplied': amount,
      'type': 'EXPENSE',
      'amount': convertido.amount,
      'description': convertido.rate == 1
          ? 'Cuota de ${cuentaDeuda['name']}'
          : 'Cuota de ${cuentaDeuda['name']} · $amount ${cuentaDeuda['currency']} a ${convertido.rate}',
      'occurredAt': occurredAt.millisecondsSinceEpoch,
      'createdAt': occurredAt.millisecondsSinceEpoch,
    });

    // El patrimonio baja por lo que realmente salió de la cuenta.
    await db.rawUpdate('UPDATE Account SET currentBalance = currentBalance - ? WHERE id = ?', [
      convertido.amount,
      payingAccountId,
    ]);
    // La deuda y su cuenta espejo bajan por el capital, en su propia
    // moneda.
    await db.rawUpdate('UPDATE Debt SET currentBalance = currentBalance - ? WHERE id = ?', [
      principal,
      id,
    ]);
    await db.rawUpdate('UPDATE Account SET currentBalance = currentBalance - ? WHERE id = ?', [
      principal,
      deuda['accountId'],
    ]);

    // La cuota del cronograma se marca pagada solo cuando el mes quedó
    // cubierto — un pago parcial sigue pendiente.
    final coveredNow = round2(paidSoFar + amount);
    final covered = coveredNow + 0.005 >= installment;
    if (proxima != null && covered) {
      await db.update(
        'DebtPayment',
        {
          'status': 'PAID',
          'actualAmount': coveredNow,
          'paidDate': occurredAt.millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [proxima['id']],
      );
    }

    return {
      'paid': amount,
      'currency': cuentaDeuda['currency'],
      'principal': principal,
      // Las tres partes, separadas: antes el interés se calculaba como "todo lo
      // que no fue capital" y se tragaba el seguro adentro.
      'interest': round2(interest.toDouble()),
      'insurance': round2(seguro),
      'paidThisMonth': coveredNow,
      'installment': installment,
      'covered': covered,
      'chargedToAccount': convertido.amount,
      'accountCurrency': cuentaPago['currency'],
      'rate': convertido.rate,
    };
  });

  // POST /debts/:id/revert-payment — "pagué la cuota por error": devuelve
  // la plata, sube la deuda por el capital que había bajado y vuelve la
  // cuota del cronograma a pendiente.
  LocalApiRouter.registerPost('/debts/:id/revert-payment', (db, uri, body) async {
    final userId = await currentUserId(db);
    final id = uri.queryParameters['id']!;

    final filas = await db.query('Debt', where: 'id = ? AND userId = ?', whereArgs: [id, userId]);
    if (filas.isEmpty) throw ApiException('Debt $id not found', status: 404);
    final deuda = filas.first;
    final clock = await UserClock.forUser(db, userId);

    final pagos = await db.query(
      'Transaction',
      where: 'debtId = ? AND occurredAt >= ?',
      whereArgs: [id, clock.startOfMonth().millisecondsSinceEpoch],
    );

    for (final pago in pagos) {
      await db.rawUpdate('UPDATE Account SET currentBalance = currentBalance + ? WHERE id = ?', [
        pago['amount'],
        pago['accountId'],
      ]);
      final principal = (pago['debtPrincipalApplied'] as num?)?.toDouble() ?? 0;
      await db.rawUpdate('UPDATE Debt SET currentBalance = currentBalance + ? WHERE id = ?', [
        principal,
        id,
      ]);
      await db.rawUpdate('UPDATE Account SET currentBalance = currentBalance + ? WHERE id = ?', [
        principal,
        deuda['accountId'],
      ]);
      if (pago['debtPaymentId'] != null) {
        await db.update(
          'DebtPayment',
          {'status': 'SCHEDULED', 'actualAmount': null, 'paidDate': null},
          where: 'id = ?',
          whereArgs: [pago['debtPaymentId']],
        );
      }
    }

    final ids = pagos.map((p) => p['id'] as String).toList();
    if (ids.isNotEmpty) {
      await db.delete(
        'Transaction',
        where: 'id IN (${List.filled(ids.length, '?').join(',')})',
        whereArgs: ids,
      );
    }

    return {'reverted': pagos.length};
  });

  // POST /debts/:id/cancel y /reactivate — apagar y encender una deuda.
  //
  // Cancelar no es eliminar: la deuda deja de contar en todos lados pero se
  // queda a la vista. Sirve para la que ya no aplica y que igual pasó —te la
  // condonaron, la refinanciaste, resultó que no era tuya—, donde borrar se
  // llevaría una historia que explica movimientos reales.
  //
  // La bandera es la misma que ya usaba el borrado para archivar: no hay estado
  // nuevo que mantener.
  for (final (ruta, activa) in [('/debts/:id/cancel', 0), ('/debts/:id/reactivate', 1)]) {
    LocalApiRouter.registerPost(ruta, (db, uri, body) async {
      final userId = await currentUserId(db);
      final id = uri.queryParameters['id']!;

      final filas = await db.query('Debt', where: 'id = ? AND userId = ?', whereArgs: [id, userId]);
      if (filas.isEmpty) throw ApiException('Debt $id not found', status: 404);

      await db.update('Debt', {'isActive': activa}, where: 'id = ?', whereArgs: [id]);
      // La cuenta espejo sigue a la deuda: archivada mientras esté cancelada, de
      // vuelta al reactivarla. Si se quedara archivada, la deuda volvería a
      // contar con una cuenta que no aparece en ningún lado.
      await db.update(
        'Account',
        {'isArchived': activa == 1 ? 0 : 1},
        where: 'id = ?',
        whereArgs: [filas.first['accountId']],
      );
      return {'id': id, 'isActive': activa == 1};
    });
  }

  // DELETE /debts/:id — igual que con los gastos fijos: si por su cuenta
  // pasó dinero de verdad, se archiva; solo la que nunca movió nada se
  // borra de verdad, junto con su cronograma proyectado.
  LocalApiRouter.registerDelete('/debts/:id', (db, uri, body) async {
    final userId = await currentUserId(db);
    final id = uri.queryParameters['id']!;

    final filas = await db.query('Debt', where: 'id = ? AND userId = ?', whereArgs: [id, userId]);
    if (filas.isEmpty) throw ApiException('Debt $id not found', status: 404);
    final deuda = filas.first;

    final movimientosFila = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM "Transaction" WHERE accountId = ?',
      [deuda['accountId']],
    );
    final movimientos = (movimientosFila.first['n'] as num).toInt();

    if (movimientos > 0) {
      await db.update('Debt', {'isActive': 0}, where: 'id = ?', whereArgs: [id]);
      await db.update(
        'Account',
        {'isArchived': 1},
        where: 'id = ?',
        whereArgs: [deuda['accountId']],
      );
      return {'id': id, 'archived': true, 'movements': movimientos};
    }

    await db.delete('DebtPayment', where: 'debtId = ?', whereArgs: [id]);
    await db.delete('Debt', where: 'id = ?', whereArgs: [id]);
    await db.delete('Account', where: 'id = ?', whereArgs: [deuda['accountId']]);
    return {'id': id, 'archived': false, 'movements': 0};
  });
}

/// Las claves de mes desde la primera con algo que contar.
List<String> _desdeElPrimeroConDatos(List<String> claves, Map<String, Map<String, double>> serie) {
  final primero = claves.indexWhere((k) => serie[k]!['paid']! > 0 || serie[k]!['balance']! > 0);
  return primero <= 0 ? claves : claves.sublist(primero);
}
