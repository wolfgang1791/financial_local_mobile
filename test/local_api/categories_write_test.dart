// Categorías y perfil, en el clon local.
//
// Las tres pantallas que dependían de esto —gestión de categorías, la revisión
// de esenciales y el onboarding— quedaban en error porque el router local
// contestaba 501. Esto fija lo que ahora tiene que funcionar.

import 'dart:io';

import 'package:financial_strategist_local/data/api.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_support.dart';

void main() {
  late Directory tmp;
  late ApiClient api;

  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(inicializarMotorDePrueba);

  setUp(() async {
    tmp = await prepararDirectorioTemporal('categories_write_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<List<Map<String, dynamic>>> todas() async =>
      (await api.get('/categories') as List).cast<Map<String, dynamic>>();

  test('una categoría propia se crea y aparece en el catálogo', () async {
    final creada =
        await api.post('/categories', {'name': 'Clases de piano', 'type': 'EXPENSE'})
            as Map<String, dynamic>;

    expect(creada['name'], 'Clases de piano');
    expect(creada['isSystem'], isFalse);
    expect((await todas()).any((c) => c['id'] == creada['id']), isTrue);
  });

  test('sin nombre o con un tipo raro no se crea', () async {
    await expectLater(
      api.post('/categories', {'name': '   ', 'type': 'EXPENSE'}),
      throwsA(isA<ApiException>()),
    );
    await expectLater(
      api.post('/categories', {'name': 'Algo', 'type': 'RARO'}),
      throwsA(isA<ApiException>()),
    );
  });

  test('borrar una categoría propia deja sus movimientos sin categoría', () async {
    final creada =
        await api.post('/categories', {'name': 'Temporal', 'type': 'EXPENSE'})
            as Map<String, dynamic>;
    final cuentas = await api.get('/accounts') as List;
    await api.post('/transactions', {
      'accountId': (cuentas.first as Map)['id'],
      'categoryId': creada['id'],
      'type': 'EXPENSE',
      'amount': 12.5,
      'detail': 'una prueba',
      'occurredAt': '2026-08-10',
    });

    final resultado = await api.delete('/categories/${creada['id']}') as Map<String, dynamic>;
    // Borrar la etiqueta no borra la plata que se gastó.
    expect(resultado['unlinkedTransactions'], 1);
    expect((await todas()).any((c) => c['id'] == creada['id']), isFalse);

    // Con `take` corto el movimiento de prueba —fechado en agosto— se quedaba
    // fuera de la página: la base tiene más filas nuevas que antes y la lista
    // viene del más nuevo al más viejo.
    final movimientos = (await api.get('/transactions?take=500') as Map)['items'] as List;
    final huerfano = movimientos.cast<Map<String, dynamic>>().firstWhere(
      (t) => t['detail'] == 'una prueba',
    );
    expect(huerfano['categoryId'], isNull, reason: 'el movimiento sigue vivo');
  });

  test('las del sistema no se borran', () async {
    final delSistema = (await todas()).firstWhere((c) => c['isSystem'] == true);
    await expectLater(api.delete('/categories/${delSistema['id']}'), throwsA(isA<ApiException>()));
  });

  test('una categoría con hijas no se borra hasta mover las hijas', () async {
    final madre =
        await api.post('/categories', {'name': 'Ocio propio', 'type': 'EXPENSE'})
            as Map<String, dynamic>;
    await api.post('/categories', {'name': 'Cine', 'type': 'EXPENSE', 'parentId': madre['id']});

    await expectLater(api.delete('/categories/${madre['id']}'), throwsA(isA<ApiException>()));
  });

  test('marcar esencial vale también para las del sistema', () async {
    final revision = (await api.get('/categories/revision-esenciales') as List)
        .cast<Map<String, dynamic>>();
    // Solo las de gasto que este usuario usa de verdad: del catálogo entero,
    // noventa no le pasan por delante nunca.
    expect(revision, isNotEmpty);
    expect(revision.every((c) => c['type'] == 'EXPENSE'), isTrue);

    final una = revision.first;
    final marcada =
        await api.patch('/categories/${una['id']}/essential', {'isEssential': true})
            as Map<String, dynamic>;
    expect(marcada['isEssential'], isTrue);

    final desmarcada =
        await api.patch('/categories/${una['id']}/essential', {'isEssential': false})
            as Map<String, dynamic>;
    expect(desmarcada['isEssential'], isFalse);
  });

  test('el perfil se puede cambiar y se lee de vuelta', () async {
    final antes = await api.get('/users/me') as Map<String, dynamic>;
    expect(antes['id'], isNotNull);

    final despues =
        await api.patch('/users/me', {'currency': 'USD', 'goalStrategy': 'CONSERVATIVE'})
            as Map<String, dynamic>;
    expect(despues['currency'], 'USD');
    expect(despues['goalStrategy'], 'CONSERVATIVE');

    // Lo que no se manda no se toca: un formulario con un campo suelto no puede
    // reescribir el resto del perfil.
    expect(despues['email'], antes['email']);
    expect(despues['timezone'], antes['timezone']);
  });
}
