import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../local_engine/user_clock.dart';

/// Abre la base local, copiándola del asset sembrado la primera vez.
///
/// El asset (`assets/seed/app.db`) es de solo lectura dentro del paquete de
/// la app — no se puede escribir ahí. Por eso al primer arranque se copia
/// entero al directorio de datos de la app (donde sqflite sí puede
/// escribir) y de ahí en más se abre esa copia. Arranques siguientes la
/// encuentran ya copiada y no la vuelven a tocar: lo que el usuario
/// registre en esta app vive en esa copia, no en el asset original.
abstract final class LocalDatabase {
  static const _nombreArchivo = 'financial_strategist_local.db';
  static Database? _abierta;

  /// La apertura **en curso**, no la base ya abierta.
  ///
  /// Sin esto, dos llamadas a `open()` antes de que la primera termine hacen el
  /// trabajo entero dos veces: dos conexiones a la vez y, sobre todo, `_alDia`
  /// corriendo por duplicado. Mientras las migraciones eran "agrega la columna
  /// si falta" no se notaba; la primera que inserta filas reventó con un
  /// UNIQUE, porque las dos pasaban la comprobación de "¿ya está?" antes de que
  /// ninguna hubiera escrito. Y en un teléfono no habría reventado: habría
  /// duplicado el movimiento.
  ///
  /// Se memoriza el `Future`, no la instancia: es la diferencia entre "ya está
  /// abierta" y "alguien la está abriendo", y solo la segunda evita la carrera.
  static Future<Database>? _abriendo;

  /// Dónde vive la base de este dispositivo.
  ///
  /// Se expone para el diagnóstico: repetir el nombre del archivo en otro sitio
  /// es garantizar que un día dejen de coincidir y que la pantalla informe
  /// sobre un archivo que no es el que la app abre.
  static Future<String> rutaDelArchivo() async =>
      p.join((await getApplicationDocumentsDirectory()).path, _nombreArchivo);

  static Future<Database> open() => _abriendo ??= _abrir();

  static Future<Database> _abrir() async {
    final ya = _abierta;
    if (ya != null) return ya;

    final directorio = await getApplicationDocumentsDirectory();
    final ruta = p.join(directorio.path, _nombreArchivo);

    if (!await File(ruta).exists()) {
      await Directory(p.dirname(ruta)).create(recursive: true);
      final bytes = await rootBundle.load('assets/seed/app.db');
      await File(ruta).writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        flush: true,
      );
    }

    // Las llaves foráneas no se validan solas en SQLite: hay que pedirlo
    // por conexión. Sin esto, borrar una cuenta con movimientos no avisa —
    // simplemente deja filas huérfanas.
    final db = await openDatabase(
      ruta,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
    );
    await _alDia(db);
    _abierta = db;
    return db;
  }

  /// Las columnas que se agregaron después de que alguien ya tenía la app.
  ///
  /// La base se copia del asset una sola vez, así que quien instaló ayer sigue
  /// con el esquema de ayer: sin esto, una columna nueva existe para los
  /// instalados de hoy y no para los de antes, y la app revienta en la primera
  /// consulta que la mencione.
  ///
  /// Se comprueba y se agrega, sin número de versión: son columnas opcionales y
  /// añadirlas es idempotente si primero se mira si están.
  static Future<void> _alDia(Database db) async {
    final columnas = await db.rawQuery('PRAGMA table_info(RecurringFlow)');
    if (!columnas.any((c) => c['name'] == 'monthlyAmounts')) {
      await db.execute('ALTER TABLE RecurringFlow ADD COLUMN monthlyAmounts TEXT');
    }

    // La tabla de meses: una fila por flujo y mes, con su monto, su caducidad y
    // cuándo se marcó. El padre guarda lo que no cambia —nombre, periodicidad,
    // categoría— y cada mes vive acá.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS "RecurringFlowMonth" (
        "id" TEXT NOT NULL PRIMARY KEY,
        "recurringFlowId" TEXT NOT NULL,
        "month" TEXT NOT NULL,
        "amount" DECIMAL NOT NULL,
        "dueDate" DATETIME NOT NULL,
        "paidAt" DATETIME,
        CONSTRAINT "RecurringFlowMonth_recurringFlowId_fkey"
          FOREIGN KEY ("recurringFlowId") REFERENCES "RecurringFlow" ("id")
          ON DELETE CASCADE ON UPDATE CASCADE
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS "RecurringFlowMonth_recurringFlowId_month_key"
        ON "RecurringFlowMonth"("recurringFlowId", "month")
    ''');

    await _mudarMesesDelJson(db);
    await _marcarMesesYaPagados(db);
    await _reubicarPagosEnElFuturo(db);
    await _asegurarElColchonDeJulio(db);
    await _igualarConLaWeb(db);
    await _soloLosRegistros(db);
  }

  /// Se van las tablas de la capa de consejo.
  ///
  /// Objetivos, propuestas, escenarios, presupuestos, recomendaciones, informes
  /// de cierre y el hilo de chat. Ese trabajo lo va a hacer el agente, y
  /// mantener en paralelo una versión anterior de lo mismo solo garantizaba dos
  /// opiniones distintas sobre las mismas cifras.
  ///
  /// Va acá y no editando el `.db` semilla a mano: así se limpian por igual la
  /// base que trae la app y la que ya tenga instalada quien viene de una versión
  /// anterior. Es la misma migración que corrió del lado del servidor — la base
  /// del teléfono sigue el esquema de la web, que es lo que permite compararlas
  /// fila a fila.
  ///
  /// El orden importa: primero lo que apunta a otras tablas.
  static Future<void> _soloLosRegistros(Database db) async {
    for (final tabla in const [
      'GoalAnalysis',
      'Goal',
      'Scenario',
      'Budget',
      'Recommendation',
      'SpendingReport',
      'ChatTurn',
    ]) {
      await db.execute('DROP TABLE IF EXISTS "$tabla"');
    }
  }

  /// Traer la base de este teléfono a lo que dice la web.
  ///
  /// Las dos apps no se sincronizan: cada una escribe en su propia base, y al
  /// compararlas el 26 de agosto de 2026 habían divergido en trece filas. Nada
  /// grave —los saldos de las dos coincidían, porque **todas** las diferencias
  /// eran neutras para el saldo— pero sí lo suficiente para que julio se leyera
  /// distinto en cada pantalla: 2,760 menos de ingresos y 55.90 menos de gastos
  /// fijos en el teléfono.
  ///
  /// La web manda. Esto aplica la diferencia en tres tandas:
  ///
  ///  1. **Textos**: el mismo movimiento escrito distinto en cada app
  ///     ("Maas retención" / "Mass retención", "cdv" / "CDV"...).
  ///  2. **Fechas**: dos cobros de "Apoyo de coneja" que en el teléfono se
  ///     marcaron otro día. Se mueve el movimiento, su contrapartida y la marca
  ///     de la ficha a la vez: son la misma cosa vista desde dos tablas, y
  ///     dejarlas distintas rompe el enlace que usa "revertir".
  ///  3. **Lo que faltaba**: dos pagos marcados en la web que acá nunca se
  ///     registraron, cada uno con su contrapartida. Los dos pares son neutros
  ///     —entra y sale lo mismo el mismo día—, así que ni tocan
  ///     `currentBalance` ni mueven la curva de patrimonio.
  ///
  /// Todo se busca por su contenido exacto y se escribe una sola vez: correrlo
  /// de nuevo, o sobre una base que ya está bien, no hace nada.
  static Future<void> _igualarConLaWeb(Database db) async {
    // ── 1. Textos
    const textos = <(String, String)>[
      ('Maas retención', 'Mass retención'),
      ('iu Test', 'UI Test'),
      ('cdv', 'CDV'),
      ('taller pizza mesario', 'Taller pizza mesario'),
      ('sanguchon campesino', 'Sanguchon campesino'),
      ('Viajecito de Alem', 'Préstamo coneja por el viajecito de alem'),
    ];
    for (final (viejo, nuevo) in textos) {
      // En las dos columnas: un movimiento escrito a mano guarda su texto en
      // `detail` y uno que escribe la app en `description`. Buscar solo en una
      // dejaba justo estos seis sin tocar, que son todos de los escritos a
      // mano. `=` compara byte a byte, así que 'cdv' no pisa a 'CDV'.
      await db.update(
        '"Transaction"',
        {'description': nuevo},
        where: 'description = ?',
        whereArgs: [viejo],
      );
      await db.update('"Transaction"', {'detail': nuevo}, where: 'detail = ?', whereArgs: [viejo]);
    }

    // El flujo se renombró en la web y acá se quedó con el nombre viejo.
    await db.update('RecurringFlow', {
      'name': 'MAXIMO',
    }, where: "name = 'Mass' AND type = 'INCOME'");

    // ── 2. Fechas
    Future<void> mover(int desde, int hasta) async {
      // El movimiento y su contrapartida comparten el instante exacto: mover
      // por `occurredAt` los lleva a los dos.
      await db.update(
        '"Transaction"',
        {'occurredAt': hasta},
        where: 'occurredAt = ?',
        whereArgs: [desde],
      );
      await db.update(
        'RecurringFlowMonth',
        {'paidAt': hasta},
        where: 'paidAt = ?',
        whereArgs: [desde],
      );
    }

    // "Apoyo de coneja": julio se marcó el 5 y en la web el 15; agosto el 5 y
    // en la web el 21.
    await mover(1783252800000, 1784134800000);
    await mover(1785931200000, 1787292073313);

    // ── 3. Los dos pagos que faltaban
    final cuenta = await db.rawQuery('''
      SELECT t.accountId AS id
      FROM "Transaction" t
      JOIN Account a ON a.id = t.accountId
      WHERE a.type IN ('CHECKING','SAVINGS','CASH')
      GROUP BY t.accountId
      ORDER BY count(*) DESC
      LIMIT 1
    ''');
    if (cuenta.isEmpty) return;
    final cuentaId = cuenta.first['id'] as String;

    Future<String?> idDe(String tabla, String nombre) async {
      final f = await db.query(tabla, columns: ['id'], where: 'name = ?', whereArgs: [nombre]);
      return f.isEmpty ? null : f.first['id'] as String;
    }

    /// Un pago marcado, tal como lo escribe `payThisMonth` para un mes pasado:
    /// el movimiento y la contrapartida que evita que el saldo se mueva dos
    /// veces, con el mismo instante — que es además el enlace con su ficha.
    Future<void> pagoMarcado({
      required String id,
      required String flujo,
      required String categoria,
      required String texto,
      required String tipo,
      required double monto,
      required int cuando,
      required String mes,
      // Si la web tiene ficha de ese mes. Con Netflix la tiene —55.90, marcada
      // el 27— y acá hay que dejarla igual; con MAXIMO no: ese mes lo da por
      // pagado deduciéndolo del movimiento, que es lo que hace
      // `mesesRegistrados` con los meses anteriores a la primera ficha. Crear
      // una que la web no tiene sería justo lo contrario de unificar.
      required bool conFicha,
    }) async {
      final flujoId = await idDe('RecurringFlow', flujo);
      if (flujoId == null) return;
      final yaEsta = await db.query(
        '"Transaction"',
        columns: ['id'],
        where: 'recurringFlowId = ? AND occurredAt = ?',
        whereArgs: [flujoId, cuando],
      );
      if (yaEsta.isNotEmpty) return;

      await db.insert('"Transaction"', conflictAlgorithm: ConflictAlgorithm.ignore, {
        'id': id,
        'accountId': cuentaId,
        'recurringFlowId': flujoId,
        'categoryId': await idDe('Category', categoria),
        'type': tipo,
        'kind': 'MOVEMENT',
        'amount': monto,
        'description': texto,
        'occurredAt': cuando,
        'createdAt': cuando,
      });
      await db.insert('"Transaction"', conflictAlgorithm: ConflictAlgorithm.ignore, {
        'id': '$id-contrapartida',
        'accountId': cuentaId,
        'type': tipo == 'INCOME' ? 'EXPENSE' : 'INCOME',
        'kind': 'ADJUSTMENT',
        'amount': monto,
        'description': 'Ya estaba reflejado en tu saldo',
        'occurredAt': cuando,
        'createdAt': cuando,
      });
      // La ficha del mes queda marcada en el mismo instante que el pago.
      final ficha = await db.query(
        'RecurringFlowMonth',
        columns: ['id'],
        where: 'recurringFlowId = ? AND month = ?',
        whereArgs: [flujoId, mes],
      );
      if (ficha.isNotEmpty) {
        await db.update(
          'RecurringFlowMonth',
          {'amount': monto, 'paidAt': cuando},
          where: 'id = ?',
          whereArgs: [ficha.first['id']],
        );
      } else if (conFicha) {
        await db.insert('RecurringFlowMonth', {
          'id': '$id-ficha',
          'recurringFlowId': flujoId,
          'month': mes,
          'amount': monto,
          'dueDate': cuando,
          'paidAt': cuando,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    }

    await pagoMarcado(
      id: 'web-maximo-2026-07',
      flujo: 'MAXIMO',
      categoria: 'Salario',
      texto: 'Cobro de MAXIMO',
      tipo: 'INCOME',
      monto: 2760,
      cuando: 1783357200000, // 2026-07-06 12:00 en Lima
      mes: '2026-07',
      conFicha: false,
    );
    await pagoMarcado(
      id: 'web-netflix-2026-07',
      flujo: 'Netflix',
      categoria: 'Streaming',
      texto: 'Pago de Netflix',
      tipo: 'EXPENSE',
      monto: 55.90,
      cuando: 1785171600000, // 2026-07-27 12:00 en Lima
      mes: '2026-07',
      conFicha: true,
    );

    // El monto del mes de Google en julio: la web dice 7.50 y acá quedó en 8.52,
    // que es lo que valía el mes anterior. La ficha guarda "cuánto vale este
    // mes" y se puede editar; las dos apps la editaron distinto.
    final google = await idDe('RecurringFlow', 'Google');
    if (google != null) {
      await db.update(
        'RecurringFlowMonth',
        {'amount': 7.50},
        where: "recurringFlowId = ? AND month = '2026-07' AND amount = 8.52",
        whereArgs: [google],
      );
    }

    // ── 4. Las dos tarjetas, y los nombres de las cuentas
    //
    // Ninguna de las dos tiene cuotas detrás —los pagos programados son del
    // préstamo y de la mudanza—, así que su saldo es una cifra suelta y se
    // puede traer tal cual. La cuenta y la deuda se escriben juntas: son el
    // mismo número visto desde dos tablas.
    const tarjetas = <(String, String, double)>[
      ('DEUDA EN DOLARES SUPERVIAJE', 'DEUDA EN DOLARES', 3546.02),
      ('DEUDA EN SOLES SUPERVIAJE', 'DEUDA EN SOLES', 8116.57),
    ];
    for (final (viejo, nuevo, saldo) in tarjetas) {
      final cuentas = await db.query(
        'Account',
        columns: ['id'],
        where: 'name = ? OR name = ?',
        whereArgs: [viejo, nuevo],
      );
      if (cuentas.isEmpty) continue;
      final id = cuentas.first['id'] as String;
      await db.update(
        'Account',
        {'name': nuevo, 'currentBalance': saldo},
        where: 'id = ?',
        whereArgs: [id],
      );
      await db.update(
        'Debt',
        {'originalPrincipal': saldo, 'currentBalance': saldo},
        where: 'accountId = ?',
        whereArgs: [id],
      );
    }
    await db.update('Account', {'name': 'prestamo gigante'}, where: "name = 'Prestamo gigante'");

    // Y los términos de la deuda, no solo su saldo: la cuota y el desgravamen
    // de la tarjeta en soles se editaron en la web y acá quedaron los viejos.
    // Importan porque de ellos sale la proyección: con 580.48 sin seguro salían
    // 22 meses, y con los datos buenos —545.58 con 25 de desgravamen— son 27.
    final enSoles = await db.query('Account', columns: ['id'], where: "name = 'DEUDA EN SOLES'");
    if (enSoles.isNotEmpty) {
      await db.update(
        'Debt',
        {'minimumPayment': 545.58, 'monthlyInsurance': 25.0},
        where: 'accountId = ? AND minimumPayment = 580.48',
        whereArgs: [enSoles.first['id']],
      );
    }
  }

  /// El dinero con el que se empezó julio, que la app nunca supo.
  ///
  /// La curva de patrimonio se deduce **hacia atrás** desde el saldo de hoy, así
  /// que los días viejos salen de restarle todo lo que pasó después. Como el
  /// primer registro es del 2 de julio y antes de esa fecha ya había plata en la
  /// mano que nadie anotó, la curva arrancaba por debajo de cero y se quedaba
  /// ahí veintitantos días —el peor, el 29 de julio, en -2,710.10—.
  ///
  /// Son **dos** asientos y no uno. Uno solo el 2 de julio no levanta nada: sin
  /// tocar el saldo de hoy, subir el principio baja el arranque en la misma
  /// cantidad y la curva queda igual. La pareja —entra el 2, sale el 30, el
  /// primer día que ya estaba en positivo— levanta exactamente el tramo hundido
  /// y devuelve la curva a su sitio justo donde dejaba de hacer falta.
  ///
  /// Van como `ADJUSTMENT`: no suman como ingreso ni como gasto en ningún total,
  /// ni tocan `currentBalance`. Se ven en el historial —para eso están— pero no
  /// mueven una sola cifra de las que ya estaban.
  ///
  /// Los `id` son fijos: correr esto dos veces no duplica nada.
  static Future<void> _asegurarElColchonDeJulio(Database db) async {
    // La cuenta donde de verdad vive el día a día: la líquida con más
    // movimientos. Buscarla y no fijarla evita escribir en una cuenta que en
    // este teléfono podría ni existir.
    final cuenta = await db.rawQuery(
      'SELECT t.accountId AS id FROM "Transaction" t '
      'JOIN Account a ON a.id = t.accountId '
      "WHERE a.type IN ('CHECKING','SAVINGS','CASH') "
      'GROUP BY t.accountId ORDER BY count(*) DESC LIMIT 1',
    );
    if (cuenta.isEmpty) return;
    final cuentaId = cuenta.first['id'] as String;

    Future<void> poner(String id, String tipo, DateTime cuando, String texto) async {
      final ms = cuando.millisecondsSinceEpoch;
      await db.rawInsert(
        'INSERT OR IGNORE INTO "Transaction" '
        '(id, accountId, type, kind, amount, occurredAt, createdAt, description) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [id, cuentaId, tipo, 'ADJUSTMENT', 2750, ms, ms, texto],
      );
    }

    await poner(
      'colchon-inicial-2026-07-02',
      'INCOME',
      DateTime.utc(2026, 7, 2, 17),
      'Efectivo que ya tenías al empezar',
    );
    await poner(
      'colchon-cierre-2026-07-30',
      'EXPENSE',
      DateTime.utc(2026, 7, 30, 17),
      'Cierre del efectivo inicial',
    );
  }

  /// Los pagos que quedaron fechados en el futuro vuelven al día en que se
  /// marcaron.
  ///
  /// Antes, marcar un gasto fijo fechaba su movimiento en el **vencimiento** de
  /// ese mes. Con un vencimiento que aún no llega —Claude y Movistar vencen el
  /// 31— el asiento nacía en el futuro: el saldo ya lo había descontado, pero
  /// el movimiento no aparecía ni en el calendario del día ni en la lista del
  /// mes hasta que llegara esa fecha. La regla nueva es que el pago ocurre
  /// cuando lo marcas; esto arrastra a esa regla los que se marcaron antes.
  ///
  /// `createdAt` es lo que guarda el instante real del marcado, así que de ahí
  /// sale la fecha. Se corre una sola vez de hecho: al terminar ya no queda
  /// ningún pago por delante del reloj.
  static Future<void> _reubicarPagosEnElFuturo(Database db) async {
    final ahora = DateTime.now().toUtc().millisecondsSinceEpoch;
    final futuros = await db.query(
      '"Transaction"',
      columns: ['id', 'recurringFlowId', 'occurredAt', 'createdAt'],
      where: 'recurringFlowId IS NOT NULL AND occurredAt > ?',
      whereArgs: [ahora],
    );
    for (final t in futuros) {
      final cuandoSeMarco = t['createdAt'] as int;
      await db.update(
        '"Transaction"',
        {'occurredAt': cuandoSeMarco},
        where: 'id = ?',
        whereArgs: [t['id']],
      );
      // Y la marca de la ficha se alinea con su movimiento: son la misma cosa
      // vista desde dos tablas, y dejarlas distintas rompe el enlace que usa
      // revertir para encontrar el pago.
      await db.update(
        'RecurringFlowMonth',
        {'paidAt': cuandoSeMarco},
        where: 'recurringFlowId = ? AND paidAt = ?',
        whereArgs: [t['recurringFlowId'], t['occurredAt']],
      );
    }
  }

  /// La marca de pago de los meses que se marcaron antes de que existiera.
  ///
  /// `paidAt` nació con esta tabla, y la mudanza del JSON no tenía de dónde
  /// sacarlo: los meses ya marcados quedaron con su movimiento en el ledger y la
  /// marca en null. La pantalla los daba por pendientes, ofrecía marcarlos otra
  /// vez y el API contestaba que ese mes ya estaba registrado — un error sin
  /// explicación en una fila que se veía normal.
  ///
  /// El movimiento es la evidencia dura de que la plata se movió, así que de ahí
  /// sale la fecha. El mes se compara con el reloj del usuario y no en UTC: un
  /// cobro del 31 a las 20:00 en Lima se guarda como el 1 del mes siguiente, y
  /// agrupar por UTC lo mandaría al mes equivocado.
  static Future<void> _marcarMesesYaPagados(Database db) async {
    final filas = await db.rawQuery('''
      SELECT m.id AS mesId, m.month AS mes, t.occurredAt AS cuando, f.userId AS userId
      FROM RecurringFlowMonth m
      JOIN "Transaction" t
        ON t.recurringFlowId = m.recurringFlowId AND t.kind = 'MOVEMENT'
      JOIN RecurringFlow f ON f.id = m.recurringFlowId
      WHERE m.paidAt IS NULL
    ''');
    final relojes = <String, UserClock>{};
    for (final fila in filas) {
      final userId = fila['userId'] as String;
      var reloj = relojes[userId];
      if (reloj == null) {
        reloj = await UserClock.forUser(db, userId);
        relojes[userId] = reloj;
      }
      final cuando = fila['cuando'] as int;
      final mes = reloj.monthKey(DateTime.fromMillisecondsSinceEpoch(cuando, isUtc: true));
      if (mes != fila['mes']) continue;
      await db.update(
        'RecurringFlowMonth',
        {'paidAt': cuando},
        where: 'id = ?',
        whereArgs: [fila['mesId']],
      );
    }
  }

  /// Los meses que vivían en la columna JSON se mudan a filas.
  ///
  /// Sin esto la migración perdería lo que ya se había corregido mes a mes. Se
  /// corre una sola vez: al terminar deja la columna vacía, y con ella vacía no
  /// hay nada que mudar la próxima.
  static Future<void> _mudarMesesDelJson(Database db) async {
    final pendientes = await db.query(
      'RecurringFlow',
      columns: ['id', 'monthlyAmounts'],
      where: 'monthlyAmounts IS NOT NULL AND monthlyAmounts != ?',
      whereArgs: [''],
    );
    for (final fila in pendientes) {
      final crudo = jsonDecode(fila['monthlyAmounts'] as String);
      if (crudo is! Map) continue;
      for (final e in crudo.entries) {
        final v = e.value;
        if (v is! Map || v['amount'] is! num) continue;
        final mes = e.key as String;
        final dia = (v['dueDate'] as String?) ?? '$mes-01';
        await db.insert('RecurringFlowMonth', {
          'id': '${fila['id']}-$mes',
          'recurringFlowId': fila['id'],
          'month': mes,
          'amount': (v['amount'] as num).toDouble(),
          'dueDate': DateTime.parse('${dia}T12:00:00Z').millisecondsSinceEpoch,
          'paidAt': null,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await db.update(
        'RecurringFlow',
        {'monthlyAmounts': null},
        where: 'id = ?',
        whereArgs: [fila['id']],
      );
    }
  }

  /// Solo para tests: fuerza a que el próximo [open] vuelva a copiar y abrir
  /// desde cero, en vez de reusar la conexión del test anterior.
  static Future<void> resetForTests() async {
    await _abierta?.close();
    _abierta = null;
    _abriendo = null;
  }
}
