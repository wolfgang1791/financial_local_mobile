// El paquete que se lleva a la web.
//
// Lo que se prueba es que lleve lo que hay que llevar y no lo que no: el
// catálogo compartido se queda —mandarlo sería pedirle al otro lado que se
// reescriba a sí mismo— y todo viaja con su id, que es lo que permite que
// importar dos veces no duplique nada.

import 'dart:convert';
import 'dart:io';

import 'package:financial_strategist_local/data/bundle.dart';
import 'package:financial_strategist_local/local_db/database.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_support.dart';

void main() {
  late Directory tmp;

  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(inicializarMotorDePrueba);

  setUp(() async {
    tmp = await prepararDirectorioTemporal('paquete_test');
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<Map<String, dynamic>> paquete() async {
    final p = await construirPaquete(await LocalDatabase.open());
    return jsonDecode(utf8.decode(p.bytes)) as Map<String, dynamic>;
  }

  test('lleva las tablas del usuario y ninguna del catálogo compartido', () async {
    final p = await paquete();

    expect(p['formato'], formatoDelPaquete);
    expect(p['version'], versionDelPaquete);
    expect(p['userId'], isNotEmpty);

    final tablas = p['tablas'] as Map<String, dynamic>;
    expect(tablas.keys.toSet(), tablasDelPaquete.toSet());
    for (final prohibida in ['User', 'Currency', 'DebtKind', 'FinancialSnapshot']) {
      expect(tablas.containsKey(prohibida), isFalse, reason: '$prohibida es de las dos bases');
    }
  });

  test('cada fila viaja con su id: es lo que evita duplicar al importar', () async {
    final tablas = (await paquete())['tablas'] as Map<String, dynamic>;
    final movimientos = (tablas['Transaction'] as List).cast<Map<String, dynamic>>();

    expect(movimientos, isNotEmpty);
    expect(movimientos.every((t) => (t['id'] as String).isNotEmpty), isTrue);
    expect(
      movimientos.map((t) => t['id']).toSet().length,
      movimientos.length,
      reason: 'sin ids repetidos dentro del propio archivo',
    );
  });

  test('las fechas viajan en ISO y los booleanos como booleanos', () async {
    final tablas = (await paquete())['tablas'] as Map<String, dynamic>;
    final cuenta = (tablas['Account'] as List).cast<Map<String, dynamic>>().first;

    expect(cuenta['isHidden'], isA<bool>());
    expect(cuenta['createdAt'], isA<String>());
    expect(
      DateTime.parse(cuenta['createdAt'] as String).year,
      greaterThan(2000),
      reason: 'una fecha que viaje como número llegaría como 1970 al otro lado',
    );
  });

  test('las categorías del sistema no viajan: ya están en las dos bases', () async {
    final tablas = (await paquete())['tablas'] as Map<String, dynamic>;
    final categorias = (tablas['Category'] as List).cast<Map<String, dynamic>>();

    expect(categorias.every((c) => c['isSystem'] == false), isTrue);
  });

  test('un movimiento registrado en el teléfono entra en el paquete', () async {
    final db = await LocalDatabase.open();
    final antes = ((await paquete())['tablas'] as Map<String, dynamic>)['Transaction'] as List;

    final cuenta = (await db.query('Account', limit: 1)).first;
    await db.insert('Transaction', {
      'id': 'movimiento-del-telefono',
      'accountId': cuenta['id'],
      'type': 'EXPENSE',
      'kind': 'MOVEMENT',
      'amount': 12.5,
      'detail': 'Café en el teléfono',
      'occurredAt': DateTime.now().toUtc().millisecondsSinceEpoch,
      'createdAt': DateTime.now().toUtc().millisecondsSinceEpoch,
    });

    final despues = ((await paquete())['tablas'] as Map<String, dynamic>)['Transaction'] as List;
    expect(despues.length, antes.length + 1);
    expect(despues.any((t) => (t as Map)['id'] == 'movimiento-del-telefono'), isTrue);
  });

  test('el archivo se puede escribir para llevarlo', () async {
    final p = await construirPaquete(await LocalDatabase.open());
    expect(p.total, greaterThan(0));
    expect(p.filas['Transaction'], greaterThan(0));

    // Se deja una copia para poder probar la importación de verdad contra el
    // backend; el test no depende de ella.
    final destino = File('${Directory.systemTemp.path}/paquete-de-prueba.json');
    await destino.writeAsBytes(p.bytes);
    expect(await destino.length(), greaterThan(100));
  });
}
