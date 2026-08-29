import 'package:sqflite/sqflite.dart';

import '../local_api/local_api_router.dart';
import '../local_db/database.dart';

/// Un error que sí se le puede contar al usuario.
///
/// Se mantiene el mismo tipo que en la app conectada: cada pantalla ya sabe
/// atrapar `ApiException` y mostrar `e.message` — cambiar de tipo habría
/// significado tocar un `catch` en cada formulario del app para nada.
class ApiException implements Exception {
  const ApiException(this.message, {this.status});

  final String message;
  final int? status;

  @override
  String toString() => message;
}

/// El mismo contrato que `ApiClient` tenía contra el backend por HTTP
/// (`get/post/patch/delete(path, body)` devolviendo el mismo `Map`/`List`
/// que mandaba Nest), pero resuelto acá mismo, en el proceso, contra SQLite.
/// Es la costura que permite que `providers.dart` y casi todas las
/// pantallas se copien sin tocar una línea: no les importa si la respuesta
/// vino de un socket o de una consulta local, solo que tenga la forma de
/// siempre.
class ApiClient {
  ApiClient({Database? db}) : _dbFuture = db != null ? Future.value(db) : LocalDatabase.open();

  final Future<Database> _dbFuture;

  Future<dynamic> get(String path) async => LocalApiRouter.dispatch(await _dbFuture, 'GET', path);

  Future<dynamic> post(String path, [Object? body]) async =>
      LocalApiRouter.dispatch(await _dbFuture, 'POST', path, body);

  Future<dynamic> patch(String path, Object body) async =>
      LocalApiRouter.dispatch(await _dbFuture, 'PATCH', path, body);

  Future<dynamic> put(String path, Object body) async =>
      LocalApiRouter.dispatch(await _dbFuture, 'PUT', path, body);

  Future<dynamic> delete(String path) async =>
      LocalApiRouter.dispatch(await _dbFuture, 'DELETE', path);

  // ── Sesión ────────────────────────────────────
  //
  // Sin login: la base ya viene con un único usuario real sembrado. "Entrar"
  // acá es simplemente leer esa fila — no hay token, ni otra cuenta a la que
  // cambiarse, ni servidor que pueda decir que la sesión venció.
  Future<Map<String, dynamic>?> currentUser() async {
    final db = await _dbFuture;
    final filas = await db.query('User', limit: 1);
    if (filas.isEmpty) return null;

    final usuario = filas.first;
    // Mismo criterio que `AuthService.needsOnboarding` en el backend: falta
    // el arranque si no hay ninguna cuenta líquida con la que medir nada.
    final cuentas = Sqflite.firstIntValue(
      await db.rawQuery(
        '''
      SELECT COUNT(*) FROM Account
      WHERE userId = ? AND isArchived = 0 AND type IN ('CHECKING', 'SAVINGS', 'CASH')
      ''',
        [usuario['id']],
      ),
    );

    return {'user': usuario, 'needsOnboarding': (cuentas ?? 0) == 0};
  }
}
