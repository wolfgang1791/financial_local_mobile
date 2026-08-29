import 'package:sqflite/sqflite.dart';

import '../data/api.dart' show ApiException;

/// El único usuario de esta base. En el backend conectado esto salía del
/// JWT en cada petición (`@CurrentUserId()`); acá no hay sesión que
/// verificar — la base sembrada trae un solo usuario, y es siempre él.
Future<String> currentUserId(Database db) async {
  final filas = await db.query('User', columns: ['id'], limit: 1);
  if (filas.isEmpty) {
    throw const ApiException('No hay ningún usuario en la base local todavía.', status: 404);
  }
  return filas.first['id'] as String;
}
