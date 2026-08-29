// Qué encuentra el buscador del historial.
//
// Las dos búsquedas más naturales de un historial son "todo lo de Uber" y "el
// gasto de 250". Que exista un filtro de categoría aparte no arregla la primera:
// quien escribe en un buscador espera que busque.

import 'dart:io';

import 'package:financial_strategist_local/data/api.dart';
import 'package:financial_strategist_local/local_api/routes/transactions_routes.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_support.dart';

void main() {
  late Directory tmp;
  late ApiClient api;

  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(inicializarMotorDePrueba);

  setUp(() async {
    tmp = await prepararDirectorioTemporal('buscador_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<List<Map<String, dynamic>>> buscar(String q) async =>
      ((await api.get('/transactions?take=200&q=${Uri.encodeQueryComponent(q)}') as Map)['items']
              as List)
          .cast<Map<String, dynamic>>();

  group('montoBuscado', () {
    test('lee una cifra como la ve el usuario en la fila', () {
      expect(montoBuscado('250'), 250);
      expect(montoBuscado('250.5'), 250.5);
      // La coma decimal es la de acá: quien copia "1250,50" de la pantalla
      // espera que funcione igual que con punto.
      expect(montoBuscado('250,50'), 250.5);
      expect(montoBuscado('S/ 250'), 250);
      // Las filas guardan el monto sin signo —lo pone el tipo— así que copiar
      // "-250" de un gasto tiene que encontrar ese gasto.
      expect(montoBuscado('-250'), 250);
    });

    test('un texto no es un monto', () {
      for (final q in ['uber', 'café 2', '2 cafés', '', '   ', '250 gramos', '.', ',']) {
        expect(montoBuscado(q), isNull, reason: '"$q" no es una cifra');
      }
      expect(montoBuscado(null), isNull);
    });
  });

  test('encuentra por el nombre de la categoría', () async {
    // Se toma una categoría que de verdad tenga movimientos y se comprueba que
    // buscarla por su nombre los trae. Sin esto, "todo lo de Comida" obligaba a
    // saber que el control correcto estaba en otro sitio.
    final todos = ((await api.get('/transactions?take=500') as Map)['items'] as List)
        .cast<Map<String, dynamic>>();
    final conCategoria = todos.firstWhere((t) => t['category'] != null);
    final nombre = (conCategoria['category'] as Map)['name'] as String;

    final encontrados = await buscar(nombre);
    expect(encontrados.map((t) => t['id']), contains(conCategoria['id']));
  });

  test('encuentra por el monto exacto', () async {
    final todos = ((await api.get('/transactions?take=500') as Map)['items'] as List)
        .cast<Map<String, dynamic>>();
    final uno = todos.first;
    final monto = (uno['amount'] as num).toDouble();

    final encontrados = await buscar(monto.toString());
    expect(encontrados.map((t) => t['id']), contains(uno['id']));
    // Y todos los que vuelven por esa vía son de ese monto o traen el texto:
    // buscar una cifra no puede devolver media base.
    for (final t in encontrados) {
      final texto = '${t['detail'] ?? ''} ${t['description'] ?? ''}';
      expect((t['amount'] as num).toDouble() == monto || texto.contains(monto.toString()), isTrue);
    }
  });
}
