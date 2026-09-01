// Lo que necesita cualquier test que abra la base local: el motor FFI de
// sqflite (el real habla con Keystore/Keychain vía canal de plataforma, que
// no existe en un test) y un directorio de documentos falso apuntando a un
// temporal — igual que `widget_test.dart`, factorizado para no repetirlo en
// cada archivo de test nuevo.

import 'dart:io';

import 'package:financial_strategist_local/local_api/current_user.dart';
import 'package:financial_strategist_local/local_api/routes.dart';
import 'package:financial_strategist_local/local_db/database.dart';
import 'package:financial_strategist_local/local_engine/timezone_util.dart';
import 'package:financial_strategist_local/local_engine/user_clock.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class DirectorioDePrueba extends PathProviderPlatform with MockPlatformInterfaceMixin {
  DirectorioDePrueba(this.ruta);
  final String ruta;

  @override
  Future<String?> getApplicationDocumentsPath() async => ruta;
}

Future<void> inicializarMotorDePrueba() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  inicializarZonas();
  registerAllRoutes();
  // Lo mismo que hace `app.dart` al arrancar. Sin esto, cualquier widget que
  // formatee una fecha en español revienta con `LocaleDataException` y el test
  // no prueba lo que cree probar: la fila entera se cambia por un cuadro de
  // error y las aserciones no encuentran nada.
  await initializeDateFormatting('es');
}

Future<Directory> prepararDirectorioTemporal(String prefijo) async {
  final tmp = await Directory.systemTemp.createTemp(prefijo);
  PathProviderPlatform.instance = DirectorioDePrueba(tmp.path);
  await LocalDatabase.resetForTests();
  return tmp;
}

/// El día de hoy en la zona del usuario, como "2026-09-01".
///
/// Vive acá y no en cada golden porque los dos lo necesitan por la misma razón:
/// un valor de oro que menciona el mes en curso caduca solo. Escribir "2026-08"
/// a mano ya rompió estos tests una vez, sin que nada se hubiera roto de verdad.
Future<String> hoyDelUsuario() async {
  final db = await LocalDatabase.open();
  final clock = UserClock(
    (await db.query(
          'User',
          columns: ['timezone'],
          where: 'id = ?',
          whereArgs: [await currentUserId(db)],
          limit: 1,
        )).first['timezone']
        as String,
  );
  final p = clock.parts();
  return '${p.year}-${p.month.toString().padLeft(2, '0')}-${p.day.toString().padLeft(2, '0')}';
}
