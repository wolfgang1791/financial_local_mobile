// Las preferencias de vista sobreviven a cerrar la app.
//
// El caso que fija: elegir tres subcategorías para marcarlas en el calendario
// es una decisión, y volver a tomarla en cada arranque la convierte en un
// trámite.

import 'dart:convert';
import 'dart:io';

import 'package:financial_strategist_local/data/preferencias.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_support.dart';

void main() {
  late Directory tmp;

  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(inicializarMotorDePrueba);

  setUp(() async {
    tmp = await prepararDirectorioTemporal('preferencias_test');
    Preferencias.olvidarParaTests();
  });

  tearDown(() => tmp.delete(recursive: true));

  test('lo guardado se lee de vuelta al abrir de nuevo', () async {
    final prefs = await Preferencias.abrir();
    expect(prefs.listaDeTextos(claveMarcasDelCalendario), isEmpty);

    await prefs.guardarLista(claveMarcasDelCalendario, ['cat-1', 'cat-2']);

    // Como si la app se hubiera cerrado y vuelto a abrir.
    Preferencias.olvidarParaTests();
    final otraVez = await Preferencias.abrir();
    expect(otraVez.listaDeTextos(claveMarcasDelCalendario), ['cat-1', 'cat-2']);
  });

  test('guardar una clave no pisa las otras', () async {
    final prefs = await Preferencias.abrir();
    await prefs.guardarLista('otra', ['x']);
    await prefs.guardarLista(claveMarcasDelCalendario, ['cat-1']);

    Preferencias.olvidarParaTests();
    final otraVez = await Preferencias.abrir();
    expect(otraVez.listaDeTextos('otra'), ['x']);
    expect(otraVez.listaDeTextos(claveMarcasDelCalendario), ['cat-1']);
  });

  test('un archivo ilegible arranca en blanco en vez de reventar', () async {
    await File('${tmp.path}/preferencias.json').writeAsString('esto no es json {{{');
    Preferencias.olvidarParaTests();

    final prefs = await Preferencias.abrir();
    // Perder una preferencia de vista no es perder nada; no abrir la app sí.
    expect(prefs.listaDeTextos(claveMarcasDelCalendario), isEmpty);
    await prefs.guardarLista(claveMarcasDelCalendario, ['cat-1']);
    expect(jsonDecode(await File('${tmp.path}/preferencias.json').readAsString()), {
      'panorama.marcasDelCalendario': ['cat-1'],
    });
  });

  test('dos lecturas a la vez comparten el mismo archivo', () async {
    // La carrera que costó un test intermitente: con la instancia memorizada en
    // vez del futuro, dos llamadas simultáneas abrían el archivo cada una y
    // creaban dos mapas distintos. El último en asignarse ganaba y la escritura
    // del otro se perdía en silencio.
    final dos = await Future.wait([Preferencias.abrir(), Preferencias.abrir()]);
    expect(identical(dos[0], dos[1]), isTrue);

    await dos[0].guardarBandera('a', true);
    await dos[1].guardarLista('b', ['x']);

    Preferencias.olvidarParaTests();
    final releida = await Preferencias.abrir();
    expect(releida.bandera('a'), isTrue);
    expect(releida.listaDeTextos('b'), ['x']);
  });
}
