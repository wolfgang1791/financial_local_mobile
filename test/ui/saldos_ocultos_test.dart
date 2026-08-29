// Tapar las cifras de la tarjeta, y que se quede así.
//
// Es privacidad de vitrina: alguien se asoma a la pantalla. Lo que se prueba
// acá es que el interruptor se guarda —encontrarlo destapado mañana lo volvería
// inútil— y que arranca a la vista, no al revés.

import 'dart:io';

import 'package:financial_strategist_local/data/preferencias.dart';
import 'package:financial_strategist_local/state/providers.dart';
import 'package:financial_strategist_local/ui/format.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_support.dart';

void main() {
  late Directory tmp;

  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(inicializarMotorDePrueba);

  setUp(() async {
    tmp = await prepararDirectorioTemporal('saldos_ocultos_test');
    Preferencias.olvidarParaTests();
  });

  tearDown(() => tmp.delete(recursive: true));

  test('tapar una cifra deja puntos, no un cero', () {
    // Un "S/ 0.00" es una cifra que se puede leer mal y da un susto.
    expect(tapar('S/ 1,234.56', true), cifraTapada);
    expect(tapar('S/ 1,234.56', false), 'S/ 1,234.56');
    expect(cifraTapada.contains('0'), isFalse);
  });

  test('el interruptor arranca a la vista y se guarda al alternarlo', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(saldosOcultosProvider), isFalse, reason: 'nadie pidió taparlo todavía');

    await container.read(saldosOcultosProvider.notifier).alternar();
    expect(container.read(saldosOcultosProvider), isTrue);

    final prefs = await Preferencias.abrir();
    expect(prefs.bandera(claveSaldosOcultos), isTrue);
  });

  test('lo tapado sigue tapado en el próximo arranque', () async {
    final prefs = await Preferencias.abrir();
    await prefs.guardarBandera(claveSaldosOcultos, true);

    // Como si la app se hubiera cerrado y vuelto a abrir.
    Preferencias.olvidarParaTests();
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // El primer fotograma va a la vista y se corrige al leer el archivo:
    // mostrar de más por un instante es preferible a tapar lo que nadie pidió.
    expect(container.read(saldosOcultosProvider), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(container.read(saldosOcultosProvider), isTrue);
  });

  test('destaparlo también se guarda', () async {
    final prefs = await Preferencias.abrir();
    await prefs.guardarBandera(claveSaldosOcultos, true);
    Preferencias.olvidarParaTests();

    final container = ProviderContainer();
    addTearDown(container.dispose);
    // La primera lectura es la que construye el provider —y con él arranca la
    // lectura del archivo—, así que sin ella no habría nada esperando.
    container.read(saldosOcultosProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(container.read(saldosOcultosProvider), isTrue);

    await container.read(saldosOcultosProvider.notifier).alternar();
    expect((await Preferencias.abrir()).bandera(claveSaldosOcultos), isFalse);
  });

  test('tapar cubre todas las cifras de la tarjeta, no solo el total', () {
    // Se reportó que las pastillas con el saldo de cada cuenta seguían a la
    // vista con el ojito cerrado. Tapar el patrimonio y dejar el saldo de cada
    // cuenta visible deja el interruptor a medias, que es como no tenerlo.
    const total = 'S/ 1,182.42';
    const deUnaCuenta = 'S/ 207.20';
    for (final cifra in [total, deUnaCuenta]) {
      expect(tapar(cifra, true), cifraTapada);
      expect(tapar(cifra, false), cifra);
    }
  });
}
