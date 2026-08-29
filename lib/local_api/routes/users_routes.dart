import '../../data/api.dart' show ApiException;
import '../../local_db/row_mapping.dart';
import '../current_user.dart';
import '../local_api_router.dart';

const _columnasFecha = {'createdAt', 'updatedAt'};

/// Lo que uno puede cambiar de sí mismo. Nada más: el resto de las columnas de
/// `User` las escribe la app, no el usuario, y aceptar el cuerpo entero deja
/// que un formulario con un campo de más reescriba lo que no le toca.
const _camposEditables = {'name', 'currency', 'timezone', 'goalStrategy'};

void registerUsersRoutes() {
  LocalApiRouter.registerGet('/users/me', (db, uri, body) async {
    final userId = await currentUserId(db);
    final filas = await db.query('User', where: 'id = ?', whereArgs: [userId], limit: 1);
    if (filas.isEmpty) throw ApiException('User $userId not found', status: 404);
    return mapRow(filas.first, columnasFecha: _columnasFecha);
  });

  // PATCH /users/me — nombre, moneda, zona y la estrategia de objetivos.
  //
  // Cambiar la zona no reescribe nada: los instantes guardados siguen siendo
  // los mismos, y lo que cambia es dónde caen las fronteras de día y de mes al
  // leerlos. Por eso mudarse de país no corrompe el historial, lo reinterpreta.
  LocalApiRouter.registerPatch('/users/me', (db, uri, body) async {
    final userId = await currentUserId(db);
    final datos = bodyAsMap(body);
    final cambios = <String, Object?>{
      for (final campo in _camposEditables)
        if (datos.containsKey(campo)) campo: datos[campo],
    };
    if (cambios.isNotEmpty) {
      await db.update('User', cambios, where: 'id = ?', whereArgs: [userId]);
    }
    final filas = await db.query('User', where: 'id = ?', whereArgs: [userId], limit: 1);
    return mapRow(filas.first, columnasFecha: _columnasFecha);
  });
}
