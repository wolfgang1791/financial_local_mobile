import '../../data/api.dart' show ApiException;
import '../../local_db/row_mapping.dart';
import '../../local_engine/user_clock.dart';
import '../current_user.dart';
import '../local_api_router.dart';

/// De dónde salió una cotización. La que puso el usuario a mano se puede
/// quitar; la que vino cargada es el registro de lo que costaba ese día.
const _fuenteManual = 'manual';

void registerCurrenciesRoutes() {
  // GET /currencies — el catálogo, para los selectores.
  LocalApiRouter.registerGet('/currencies', (db, uri, body) async {
    final filas = await db.query('Currency', where: 'isActive = 1', orderBy: 'sortOrder ASC');
    return filas.map((f) => mapRow(f, columnasBooleanas: {'isActive'})).toList();
  });

  // GET /currencies/rates?date=... — la cotización vigente por par, la más
  // reciente que no sea posterior a la fecha pedida (hoy si no se manda
  // ninguna). Mismo `distinct: ['baseCode','quoteCode']` del backend, hecho
  // a mano: SQLite no tiene `DISTINCT ON`, así que se pide la fecha máxima
  // por par y se filtra contra ella.
  LocalApiRouter.registerGet('/currencies/rates', (db, uri, body) async {
    final fecha = uri.queryParameters['date'] != null
        ? DateTime.parse(uri.queryParameters['date']!)
        : DateTime.now();
    final limiteMs = fecha.toUtc().millisecondsSinceEpoch;

    final filas = await db.rawQuery(
      '''
      SELECT e1.* FROM ExchangeRate e1
      WHERE e1.date <= ?
        AND e1.date = (
          SELECT MAX(e2.date) FROM ExchangeRate e2
          WHERE e2.baseCode = e1.baseCode AND e2.quoteCode = e1.quoteCode AND e2.date <= ?
        )
      ORDER BY e1.date DESC
      ''',
      [limiteMs, limiteMs],
    );
    return filas.map((f) => mapRow(f, columnasFecha: {'date'})).toList();
  });

  // PUT /currencies/rates — el tipo de cambio que pone el usuario.
  //
  // No reemplaza al que había: se guarda como una fila más, con su fecha, y la
  // búsqueda de siempre —la más reciente que no sea posterior— hace que mande
  // de esa fecha en adelante y que lo anterior siga usando el que le tocaba.
  // Eso es lo que deja al cargado como respaldo sin marcarlo como tal en
  // ningún sitio: un pago que registres con fecha de junio se sigue
  // convirtiendo con la cotización de junio.
  LocalApiRouter.registerPut('/currencies/rates', (db, uri, body) async {
    final datos = (body as Map?)?.cast<String, dynamic>() ?? const {};
    final base = (datos['baseCode'] as String?)?.toUpperCase();
    final quote = (datos['quoteCode'] as String?)?.toUpperCase();
    if (base == null || quote == null || base == quote) {
      throw const ApiException('Hacen falta dos monedas distintas para un tipo de cambio.');
    }

    double cifra(String campo, String nombre) {
      final v = (datos[campo] as num?)?.toDouble();
      // Cero o negativo no es una cotización, y con un cero de por medio una
      // deuda en dólares valdría cero soles.
      if (v == null || v <= 0) {
        throw ApiException('La $nombre tiene que ser mayor que 0.');
      }
      return v;
    }

    final compra = cifra('buy', 'compra');
    final venta = cifra('sell', 'venta');

    // La fecha se ancla al calendario del usuario. `DateTime.now()` a las diez
    // de la noche en Lima es mañana en UTC, y la fila guarda el día: el tipo de
    // cambio de hoy habría quedado fechado mañana y no lo habría usado ningún
    // pago de hoy.
    // `now()` es el instante en UTC: leerle el día directo daba el de mañana a
    // partir de las 19:00 en Lima. `parts()` es el que lo pasa por la zona del
    // usuario, que es el calendario en el que se piensa una cotización.
    final clock = await UserClock.forUser(db, await currentUserId(db));
    final hoy = clock.parts();
    String dd(int n) => n.toString().padLeft(2, '0');
    final dia = (datos['date'] as String?) ?? '${hoy.year}-${dd(hoy.month)}-${dd(hoy.day)}';
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(dia)) {
      throw const ApiException('La fecha va como "2026-08-25".');
    }
    final ms = DateTime.parse('${dia}T00:00:00.000Z').millisecondsSinceEpoch;

    final existente = await db.query(
      'ExchangeRate',
      where: 'baseCode = ? AND quoteCode = ? AND date = ?',
      whereArgs: [base, quote, ms],
      limit: 1,
    );
    if (existente.isEmpty) {
      await db.insert('ExchangeRate', {
        'id': '$base-$quote-$dia',
        'baseCode': base,
        'quoteCode': quote,
        'date': ms,
        'buy': compra,
        'sell': venta,
        'source': _fuenteManual,
      });
    } else {
      await db.update(
        'ExchangeRate',
        {'buy': compra, 'sell': venta, 'source': _fuenteManual},
        where: 'id = ?',
        whereArgs: [existente.first['id']],
      );
    }

    final guardada = await db.query(
      'ExchangeRate',
      where: 'baseCode = ? AND quoteCode = ? AND date = ?',
      whereArgs: [base, quote, ms],
      limit: 1,
    );
    return mapRow(guardada.first, columnasFecha: {'date'});
  });

  // DELETE /currencies/rates?base&quote&date — quitar el propio para volver al
  // que había. Solo borra los manuales: los que vinieron cargados son el
  // registro de lo que costaba ese día y no son de nadie para borrarlos.
  LocalApiRouter.registerDelete('/currencies/rates', (db, uri, body) async {
    final base = (uri.queryParameters['base'] ?? '').toUpperCase();
    final quote = (uri.queryParameters['quote'] ?? '').toUpperCase();
    final dia = uri.queryParameters['date'] ?? '';
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(dia)) {
      throw const ApiException('La fecha va como "2026-08-25".');
    }
    final borradas = await db.delete(
      'ExchangeRate',
      where: 'baseCode = ? AND quoteCode = ? AND date = ? AND source = ?',
      whereArgs: [base, quote, DateTime.parse('${dia}T00:00:00.000Z').millisecondsSinceEpoch, _fuenteManual],
    );
    if (borradas == 0) {
      throw ApiException(
        'No hay un tipo de cambio tuyo de $base a $quote el $dia.',
        status: 404,
      );
    }
    return {'borrado': true};
  });
}
