import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../data/api.dart' show ApiException;
import '../../local_db/row_mapping.dart';
import '../current_user.dart';
import '../local_api_router.dart';

const _columnasBooleanas = {'isSystem', 'isEssential'};

const _uuid = Uuid();

/// Una fila de `Category`, con su `parent` anidado — igual que el backend,
/// que la trae con `include: { parent: true }` para que el frontend pueda
/// agrupar una hoja bajo el nombre de su padre sin una segunda consulta.
Future<Map<String, dynamic>> categoryJson(Database db, Map<String, Object?> fila) async {
  final base = mapRow(fila, columnasBooleanas: _columnasBooleanas);
  final parentId = fila['parentId'] as String?;
  if (parentId == null) return {...base, 'parent': null};

  final padre = await db.query('Category', where: 'id = ?', whereArgs: [parentId], limit: 1);
  return {
    ...base,
    'parent': padre.isEmpty ? null : {'id': padre.first['id'], 'name': padre.first['name']},
  };
}

void registerCategoriesRoutes() {
  // GET /categories?type=EXPENSE — el catálogo completo (sistema + propias),
  // no solo las usadas: al registrar un gasto lo más común es estrenar una
  // categoría.
  LocalApiRouter.registerGet('/categories', (db, uri, body) async {
    final userId = await currentUserId(db);
    final tipo = uri.queryParameters['type'];
    final filas = await db.query(
      'Category',
      where: tipo != null
          ? '(userId = ? OR isSystem = 1) AND type = ?'
          : '(userId = ? OR isSystem = 1)',
      whereArgs: tipo != null ? [userId, tipo] : [userId],
    );
    final resultado = await Future.wait(filas.map((f) => categoryJson(db, f)));
    // Mismo orden que el backend: por nombre del padre y, dentro de él, por
    // nombre propio — para que la lista salga agrupable sin reordenar acá.
    resultado.sort((a, b) {
      final grupoA = (a['parent'] as Map?)?['name'] as String? ?? a['name'] as String;
      final grupoB = (b['parent'] as Map?)?['name'] as String? ?? b['name'] as String;
      final cmp = grupoA.compareTo(grupoB);
      return cmp != 0 ? cmp : (a['name'] as String).compareTo(b['name'] as String);
    });
    return resultado;
  });

  // GET /categories/in-use — solo las que aparecen en algún movimiento, más
  // el "general" de cada una que lo tenga — el filtro del historial.
  LocalApiRouter.registerGet('/categories/in-use', (db, uri, body) async {
    final userId = await currentUserId(db);
    final idsUsados = await db.rawQuery(
      '''
      SELECT DISTINCT t.categoryId AS id
      FROM "Transaction" t
      JOIN Account a ON a.id = t.accountId
      WHERE a.userId = ? AND t.categoryId IS NOT NULL
      ''',
      [userId],
    );
    final ids = idsUsados.map((f) => f['id'] as String).toList();
    if (ids.isEmpty) return <Map<String, dynamic>>[];

    final placeholders = List.filled(ids.length, '?').join(',');
    final hojas = await db.query('Category', where: 'id IN ($placeholders)', whereArgs: ids);

    // El "general" de una hoja en uso entra también, aunque nunca haya un
    // movimiento etiquetado directo con el padre — filtrar por él suma
    // todas sus hojas (ver `categoryIdsForFilter` en transactions_routes).
    final parentIds = {
      for (final h in hojas)
        if (h['parentId'] != null && !ids.contains(h['parentId'])) h['parentId'] as String,
    }.toList();
    final padres = parentIds.isEmpty
        ? <Map<String, Object?>>[]
        : await db.query(
            'Category',
            where: 'id IN (${List.filled(parentIds.length, '?').join(',')})',
            whereArgs: parentIds,
          );

    final todas = [...hojas, ...padres];
    final resultado = await Future.wait(todas.map((f) => categoryJson(db, f)));
    resultado.sort((a, b) {
      final grupoA = (a['parent'] as Map?)?['name'] as String? ?? a['name'] as String;
      final grupoB = (b['parent'] as Map?)?['name'] as String? ?? b['name'] as String;
      final cmp = grupoA.compareTo(grupoB);
      return cmp != 0 ? cmp : (a['name'] as String).compareTo(b['name'] as String);
    });
    return resultado;
  });

  // POST /categories — una categoría propia.
  //
  // El dueño sale de la sesión y no del cuerpo: una categoría que llega
  // diciendo de quién es, es una categoría que se puede meter en la lista de
  // otro.
  LocalApiRouter.registerPost('/categories', (db, uri, body) async {
    final userId = await currentUserId(db);
    final datos = bodyAsMap(body);
    final nombre = (datos['name'] as String?)?.trim() ?? '';
    if (nombre.isEmpty) throw const ApiException('Ponle un nombre.');
    final tipo = datos['type'] as String?;
    if (tipo != 'EXPENSE' && tipo != 'INCOME') {
      throw const ApiException('El tipo tiene que ser EXPENSE o INCOME.');
    }

    final id = _uuid.v4();
    await db.insert('Category', {
      'id': id,
      'userId': userId,
      'name': nombre,
      'type': tipo,
      'icon': datos['icon'],
      'parentId': datos['parentId'],
      'isSystem': 0,
    });
    final fila = await db.query('Category', where: 'id = ?', whereArgs: [id], limit: 1);
    return categoryJson(db, fila.first);
  });

  // PATCH /categories/:id/essential — qué es irrenunciable, lo decide el
  // usuario.
  //
  // Vale tanto para las suyas como para las del sistema: la taxonomía es de
  // todos, pero qué parte de ella no se puede recortar es de cada uno — el auto
  // es esencial para quien vive lejos del trabajo y prescindible para quien no.
  LocalApiRouter.registerPatch('/categories/:id/essential', (db, uri, body) async {
    final userId = await currentUserId(db);
    final id = uri.queryParameters['id']!;
    final datos = bodyAsMap(body);

    final filas = await db.query(
      'Category',
      where: 'id = ? AND (userId = ? OR isSystem = 1 OR userId IS NULL)',
      whereArgs: [id, userId],
      limit: 1,
    );
    if (filas.isEmpty) throw ApiException('Category $id not found', status: 404);

    await db.update(
      'Category',
      {'isEssential': (datos['isEssential'] as bool? ?? false) ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
    final actualizada = await db.query('Category', where: 'id = ?', whereArgs: [id], limit: 1);
    return categoryJson(db, actualizada.first);
  });

  // GET /categories/revision-esenciales — las de gasto que este usuario usa de
  // verdad, para poder marcarlas una por una.
  //
  // Del catálogo entero no sirve: son cien, y noventa no le pasan por delante
  // nunca. Cuentan las que aparecen en un movimiento y las que tiene enganchada
  // un gasto fijo activo.
  LocalApiRouter.registerGet('/categories/revision-esenciales', (db, uri, body) async {
    final userId = await currentUserId(db);
    final deMovimientos = await db.rawQuery(
      '''
      SELECT DISTINCT t.categoryId AS id
      FROM "Transaction" t
      JOIN Account a ON a.id = t.accountId
      WHERE a.userId = ? AND t.categoryId IS NOT NULL
      ''',
      [userId],
    );
    final deFlujos = await db.rawQuery(
      'SELECT DISTINCT categoryId AS id FROM RecurringFlow '
      'WHERE userId = ? AND isActive = 1 AND categoryId IS NOT NULL',
      [userId],
    );
    final ids = {
      for (final f in [...deMovimientos, ...deFlujos]) f['id'] as String,
    }.toList();
    if (ids.isEmpty) return <Map<String, dynamic>>[];

    final filas = await db.query(
      'Category',
      where: 'id IN (${List.filled(ids.length, '?').join(',')}) AND type = ?',
      whereArgs: [...ids, 'EXPENSE'],
      orderBy: 'name ASC',
    );
    return Future.wait(filas.map((f) => categoryJson(db, f)));
  });

  // DELETE /categories/:id — solo las propias, y solo si no cuelga nada de
  // ellas.
  //
  // Los movimientos que la usaban **no se borran**: se quedan sin categoría.
  // Borrar la etiqueta no borra la plata que se gastó, y una categoría que se
  // lleva puestos veinte movimientos por delante es una trampa.
  LocalApiRouter.registerDelete('/categories/:id', (db, uri, body) async {
    final userId = await currentUserId(db);
    final id = uri.queryParameters['id']!;

    final filas = await db.query('Category', where: 'id = ?', whereArgs: [id], limit: 1);
    if (filas.isEmpty) throw ApiException('Category $id not found', status: 404);
    final categoria = filas.first;

    if ((categoria['isSystem'] as int? ?? 0) == 1 || categoria['userId'] == null) {
      throw const ApiException('Las categorías del sistema no se pueden borrar.', status: 403);
    }
    if (categoria['userId'] != userId) {
      throw const ApiException('Esa categoría es de otro usuario.', status: 403);
    }
    final hijas = await db.query('Category', where: 'parentId = ?', whereArgs: [id]);
    if (hijas.isNotEmpty) {
      throw ApiException(
        '"${categoria['name']}" tiene ${hijas.length} subcategoría(s). '
        'Borra o mueve esas primero.',
      );
    }

    final movimientos = await db.update(
      '"Transaction"',
      {'categoryId': null},
      where: 'categoryId = ?',
      whereArgs: [id],
    );
    final flujos = await db.update(
      'RecurringFlow',
      {'categoryId': null},
      where: 'categoryId = ?',
      whereArgs: [id],
    );
    await db.delete('Category', where: 'id = ?', whereArgs: [id]);

    return {
      'id': id,
      'name': categoria['name'],
      'unlinkedTransactions': movimientos,
      'unlinkedFlows': flujos,
    };
  });
}
