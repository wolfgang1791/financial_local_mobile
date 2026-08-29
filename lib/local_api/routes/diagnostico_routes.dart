import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../data/api.dart' show ApiException;
import '../../local_db/database.dart';
import '../../local_db/row_mapping.dart';
import '../../local_engine/user_clock.dart';
import '../current_user.dart';
import '../local_api_router.dart';

/// Las tablas que se pueden abrir, con las columnas que llevan fecha.
///
/// Lista blanca y no el nombre que llegue: la ruta arma el SQL con él, y
/// aceptar cualquiera sería dejar la puerta abierta a leer —o a romper— lo que
/// no toca. De paso ordena la exploración: son las tablas que explican algo
/// cuando una cifra no cuadra.
const _tablasAbribles = <String, ({Set<String> fechas, String orden})>{
  'Transaction': (fechas: {'occurredAt', 'createdAt'}, orden: 'occurredAt DESC'),
  'RecurringFlow': (
    fechas: {'startDate', 'endDate', 'nextDueDate', 'settledThrough'},
    orden: 'name ASC',
  ),
  'RecurringFlowMonth': (fechas: {'dueDate', 'paidAt'}, orden: 'month DESC'),
  'Account': (fechas: {'createdAt', 'updatedAt'}, orden: 'name ASC'),
  'Debt': (fechas: {'originationDate', 'createdAt'}, orden: 'rowid DESC'),
  'Category': (fechas: {}, orden: 'name ASC'),
  // Objetivos ya no está: esa tabla se fue con la capa de consejo. Lo que este
  // diagnóstico mira es el registro, que es lo único que queda de este lado.
};

/// Qué hay de verdad en la base de este teléfono.
///
/// La base sembrada del repositorio y la que usa la app **no son la misma**: la
/// primera es la copia de fábrica y la segunda vive en el directorio de
/// documentos, con todo lo que se registró desde que se instaló. Mirar la
/// primera para explicar algo que pasa en la segunda es mirar el sitio
/// equivocado, y eso ya costó una vuelta entera.
///
/// Devuelve conteos, rangos y —lo que de verdad sirve— **avisos**: las
/// incoherencias concretas que han causado errores antes, dichas en una frase.
void registerDiagnosticoRoutes() {
  LocalApiRouter.registerGet('/diagnostico', (db, uri, body) async {
    final userId = await currentUserId(db);
    final clock = await UserClock.forUser(db, userId);
    final ahora = clock.now();
    final mesActual = clock.monthKey(ahora);

    Future<int> contar(String tabla) async =>
        Sqflite.firstIntValue(await db.rawQuery('SELECT count(*) FROM "$tabla"')) ?? 0;

    Future<int> contarDonde(String tabla, String donde, [List<Object?> args = const []]) async =>
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT count(*) FROM "$tabla" WHERE $donde', args),
        ) ??
        0;

    String? fecha(Object? ms) => ms == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(ms as int, isUtc: true).toIso8601String();

    // ── La base
    final archivo = File(await LocalDatabase.rutaDelArchivo());
    final existe = await archivo.exists();

    // ── Movimientos
    final rango = (await db.rawQuery(
      'SELECT min(occurredAt) AS primero, max(occurredAt) AS ultimo FROM "Transaction"',
    )).first;
    final enElFuturo = await contarDonde('Transaction', 'occurredAt > ?', [
      ahora.millisecondsSinceEpoch,
    ]);
    final pagosEnElFuturo = await contarDonde(
      'Transaction',
      'recurringFlowId IS NOT NULL AND occurredAt > ?',
      [ahora.millisecondsSinceEpoch],
    );

    // ── Fichas de mes
    final meses =
        (await db.rawQuery(
              'SELECT month, count(*) AS cuantas, sum(paidAt IS NOT NULL) AS marcadas '
              'FROM RecurringFlowMonth GROUP BY month ORDER BY month',
            ))
            .map(
              (f) => {
                'mes': f['month'],
                'fichas': f['cuantas'],
                'marcadas': (f['marcadas'] as num?)?.toInt() ?? 0,
              },
            )
            .toList();
    final mesesAdelantados = meses
        .where((m) => (m['mes'] as String).compareTo(mesActual) > 0)
        .map((m) => m['mes'] as String)
        .toList();

    // Una ficha marcada sin su movimiento —o al revés— es el enlace roto que
    // deja "revertir" sin nada que borrar.
    final marcadasSinMovimiento =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT count(*) FROM RecurringFlowMonth m WHERE m.paidAt IS NOT NULL '
            'AND NOT EXISTS (SELECT 1 FROM "Transaction" t '
            'WHERE t.recurringFlowId = m.recurringFlowId AND t.occurredAt = m.paidAt)',
          ),
        ) ??
        0;

    final avisos = <Map<String, String>>[
      if (!existe)
        {
          'que': 'No encuentro el archivo de la base donde debería estar.',
          'porque': 'La app la copia del asset al arrancar; si falta, algo la borró.',
        },
      if (pagosEnElFuturo > 0)
        {
          'que': '$pagosEnElFuturo pago(s) de gasto fijo con fecha por delante del reloj.',
          'porque':
              'Se marcaron cuando el pago se fechaba en su vencimiento. No salen en el '
              'calendario ni en la lista del mes hasta que llegue esa fecha. Se reparan '
              'solos al abrir la app.',
        },
      if (enElFuturo > pagosEnElFuturo)
        {
          'que': '${enElFuturo - pagosEnElFuturo} movimiento(s) sueltos con fecha futura.',
          'porque': 'Se registraron con una fecha que todavía no llega.',
        },
      if (mesesAdelantados.isNotEmpty)
        {
          'que': 'Hay fichas de meses que aún no empiezan: ${mesesAdelantados.join(", ")}.',
          'porque':
              'Las fichas nacen al llegar su mes. Una adelantada la creó un pago fechado '
              'en el futuro.',
        },
      if (marcadasSinMovimiento > 0)
        {
          'que': '$marcadasSinMovimiento ficha(s) marcadas sin el movimiento que les corresponde.',
          'porque':
              'La marca y su asiento se escriben juntos; si no coinciden, revertir no '
              'encuentra qué borrar.',
        },
    ];

    return {
      'generado': ahora.toIso8601String(),
      'zona': clock.timeZone,
      'mesActual': mesActual,
      'base': {
        'ruta': archivo.path,
        'existe': existe,
        'kb': existe ? (await archivo.length() / 1024).round() : 0,
      },
      'tablas': {
        'Account': await contar('Account'),
        'Transaction': await contar('Transaction'),
        'RecurringFlow': await contar('RecurringFlow'),
        'RecurringFlowMonth': await contar('RecurringFlowMonth'),
        'Debt': await contar('Debt'),
        'Category': await contar('Category'),
      },
      'movimientos': {
        'primero': fecha(rango['primero']),
        'ultimo': fecha(rango['ultimo']),
        'enElFuturo': enElFuturo,
        'deGastosFijosEnElFuturo': pagosEnElFuturo,
      },
      'meses': meses,
      'avisos': avisos,
    };
  });

  // GET /diagnostico/dump — una copia consistente de la base, para mandarla.
  //
  // No se comparte el archivo que la app tiene abierto: SQLite guarda parte de
  // lo escrito en su diario hasta que hace checkpoint, así que copiar el
  // archivo tal cual puede entregar una base a la que le faltan los últimos
  // cambios —justo los que uno quiere que el otro vea—. `VACUUM INTO` escribe
  // una base nueva, completa y ya compactada, sin tocar la original.
  //
  // Va a un temporal y no al directorio de documentos: es una copia de usar y
  // tirar, y dejarla al lado de la buena es pedir que un día se abra la que no
  // era.
  LocalApiRouter.registerGet('/diagnostico/dump', (db, uri, body) async {
    final clock = await UserClock.forUser(db, await currentUserId(db));
    final ahora = clock.now();
    String dosCifras(int n) => n.toString().padLeft(2, '0');
    final sello =
        '${ahora.year}${dosCifras(ahora.month)}${dosCifras(ahora.day)}'
        '-${dosCifras(ahora.hour)}${dosCifras(ahora.minute)}';
    final nombre = 'financial-local-$sello.db';

    final destino = p.join(Directory.systemTemp.path, nombre);
    // Si quedó una copia de un intento anterior con el mismo minuto, VACUUM
    // INTO se niega a escribir encima. Se borra: es una copia, no un dato.
    final archivo = File(destino);
    if (await archivo.exists()) await archivo.delete();

    await db.execute("VACUUM INTO ?", [destino]);

    return {'ruta': destino, 'nombre': nombre, 'kb': (await archivo.length() / 1024).round()};
  });

  // GET /diagnostico/tabla?nombre=Transaction&take=50&skip=0
  //
  // Las filas tal cual están, con las fechas ya legibles: un diagnóstico que
  // muestra 1756093200000 obliga a hacer la conversión a mano, que es
  // exactamente el trabajo que uno viene a evitar.
  LocalApiRouter.registerGet('/diagnostico/tabla', (db, uri, body) async {
    final nombre = uri.queryParameters['nombre'] ?? '';
    final tabla = _tablasAbribles[nombre];
    if (tabla == null) {
      throw ApiException(
        'No sé abrir la tabla "$nombre". Se pueden: ${_tablasAbribles.keys.join(", ")}.',
        status: 404,
      );
    }

    final take = int.tryParse(uri.queryParameters['take'] ?? '')?.clamp(1, 200) ?? 50;
    final skip = int.tryParse(uri.queryParameters['skip'] ?? '') ?? 0;

    final total = Sqflite.firstIntValue(await db.rawQuery('SELECT count(*) FROM "$nombre"')) ?? 0;
    final filas = await db.rawQuery(
      'SELECT * FROM "$nombre" ORDER BY ${tabla.orden} LIMIT ? OFFSET ?',
      [take, skip],
    );

    return {
      'tabla': nombre,
      'total': total,
      'take': take,
      'skip': skip,
      'filas': [for (final f in filas) mapRow(f, columnasFecha: tabla.fechas)],
    };
  });
}
