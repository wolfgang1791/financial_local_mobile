import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../local_api/current_user.dart';

/// El paquete para llevarte a la web lo registrado en el teléfono.
///
/// **Por qué se puede hacer sin duplicar nada.** Las dos bases son la misma
/// base: el teléfono arranca de una copia del Postgres de la web y conserva los
/// ids tal cual. Lo que registras acá nace con un uuid nuevo, que no existe del
/// otro lado; lo que ya venía en la copia tiene el id que tiene allá. Así, "¿ya
/// lo tengo?" es una pregunta que se contesta por clave primaria y no
/// adivinando por monto y fecha — y por eso importar dos veces el mismo archivo
/// no puede duplicar nada.
///
/// **Lo que el archivo no puede saber.** Si el mismo gasto se tecleó a mano en
/// los dos lados, son dos movimientos distintos con dos ids distintos: ningún
/// id los delata. La web los marca como posible repetido al comparar cuenta,
/// monto, tipo y día, pero la decisión es de quien importa.
///
/// Se manda la fila entera, sin traducir a los modelos de pantalla: el otro lado
/// tiene el mismo esquema, y cualquier resumen intermedio es una ocasión de
/// perder un campo por el camino.
const formatoDelPaquete = 'financial-strategist/paquete';
const versionDelPaquete = 1;

/// En orden de dependencia: primero lo que otros apuntan.
///
/// `User`, `Currency` y `DebtKind` no viajan: son el catálogo que las dos bases
/// ya comparten, y mandarlos sería ofrecerle al otro lado que se reescriba a sí
/// mismo. `FinancialSnapshot` tampoco: es derivado, el motor lo rehace.
const tablasDelPaquete = [
  'Category',
  'Account',
  'RecurringFlow',
  'RecurringFlowMonth',
  'Debt',
  'DebtPayment',
  'Transaction',
  'ValueChange',
  'ExchangeRate',
];

class Paquete {
  const Paquete({required this.bytes, required this.filas});

  final Uint8List bytes;

  /// Cuántas filas lleva cada tabla, para poder decirlo antes de compartirlo.
  final Map<String, int> filas;

  int get total => filas.values.fold(0, (a, b) => a + b);
}

/// Cómo se guarda cada columna, según lo que declara el esquema.
///
/// Se pregunta a la base en vez de escribir la lista a mano: sqlite devuelve un
/// booleano como 0/1 y una fecha como milisegundos, y el otro lado espera
/// `true` e ISO-8601. Una lista escrita a mano envejece con la primera columna
/// nueva, y el síntoma sería una fecha que viaja como número sin que nadie lo
/// note hasta abrir el registro del año pasado.
Future<({Set<String> fechas, Set<String> booleanas})> _columnasDe(
  Database db,
  String tabla,
) async {
  final info = await db.rawQuery('PRAGMA table_info("$tabla")');
  final fechas = <String>{};
  final booleanas = <String>{};
  for (final columna in info) {
    final nombre = columna['name'] as String;
    final tipo = ((columna['type'] as String?) ?? '').toUpperCase();
    if (tipo.contains('DATETIME') || tipo.contains('DATE')) fechas.add(nombre);
    if (tipo.contains('BOOL')) booleanas.add(nombre);
  }
  return (fechas: fechas, booleanas: booleanas);
}

Future<Paquete> construirPaquete(Database db) async {
  final userId = await currentUserId(db);
  final tablas = <String, List<Map<String, Object?>>>{};

  for (final tabla in tablasDelPaquete) {
    final tipos = await _columnasDe(db, tabla);
    final columnas = (await db.rawQuery(
      'PRAGMA table_info("$tabla")',
    )).map((c) => c['name'] as String).toSet();

    // Solo lo del usuario. Las tablas que no llevan `userId` se acotan por su
    // padre: una fila que apunte a la cuenta de otro no tendría dónde entrar del
    // otro lado, y el error aparecería recién al importar.
    final filas = switch (tabla) {
      'Category' =>
        // Las del sistema ya están en las dos bases con el mismo id: mandarlas
        // sería pedirle al otro lado que se reescriba su propio catálogo.
        await db.rawQuery(
          'SELECT * FROM "Category" WHERE "userId" = ? AND "isSystem" = 0',
          [userId],
        ),
      'Account' => await db.rawQuery('SELECT * FROM "Account" WHERE "userId" = ?', [userId]),
      'RecurringFlow' => await db.rawQuery(
        'SELECT * FROM "RecurringFlow" WHERE "userId" = ?',
        [userId],
      ),
      'RecurringFlowMonth' => await db.rawQuery(
        'SELECT m.* FROM "RecurringFlowMonth" m '
        'JOIN "RecurringFlow" f ON f.id = m."recurringFlowId" WHERE f."userId" = ?',
        [userId],
      ),
      'Debt' => await db.rawQuery('SELECT * FROM "Debt" WHERE "userId" = ?', [userId]),
      'DebtPayment' => await db.rawQuery(
        'SELECT p.* FROM "DebtPayment" p '
        'JOIN "Debt" d ON d.id = p."debtId" WHERE d."userId" = ?',
        [userId],
      ),
      'Transaction' => await db.rawQuery(
        'SELECT t.* FROM "Transaction" t '
        'JOIN "Account" a ON a.id = t."accountId" WHERE a."userId" = ?',
        [userId],
      ),
      'ValueChange' => columnas.contains('userId')
          ? await db.rawQuery('SELECT * FROM "ValueChange" WHERE "userId" = ?', [userId])
          : await db.rawQuery('SELECT * FROM "ValueChange"'),
      _ => await db.rawQuery('SELECT * FROM "$tabla"'),
    };

    tablas[tabla] = [
      for (final fila in filas)
        {
          for (final entrada in fila.entries)
            entrada.key: _valor(entrada.value, entrada.key, tipos.fechas, tipos.booleanas),
        },
    ];
  }

  final cuerpo = {
    'formato': formatoDelPaquete,
    'version': versionDelPaquete,
    'generadoEl': DateTime.now().toUtc().toIso8601String(),
    // De quién es. El otro lado rechaza un paquete que no sea suyo: importar los
    // movimientos de otra persona en tu propia base no se deshace.
    'userId': userId,
    'tablas': tablas,
  };

  return Paquete(
    bytes: Uint8List.fromList(utf8.encode(jsonEncode(cuerpo))),
    filas: {for (final t in tablasDelPaquete) t: tablas[t]!.length},
  );
}

Object? _valor(Object? valor, String columna, Set<String> fechas, Set<String> booleanas) {
  if (valor == null) return null;
  if (booleanas.contains(columna) && valor is int) return valor == 1;
  if (fechas.contains(columna) && valor is int) {
    return DateTime.fromMillisecondsSinceEpoch(valor, isUtc: true).toIso8601String();
  }
  return valor;
}
