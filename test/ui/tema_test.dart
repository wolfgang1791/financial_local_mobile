// El modo oscuro, prendido a mano.
//
// Arranca siguiendo al teléfono —el usuario ya eligió una vez en sus ajustes—
// pero en cuanto toca el interruptor manda él: hay quien tiene el sistema en
// oscuro y quiere esta app en claro.

import 'dart:io';

import 'package:financial_strategist_local/data/preferencias.dart';
import 'package:financial_strategist_local/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_support.dart';

void main() {
  late Directory tmp;

  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(inicializarMotorDePrueba);

  setUp(() async {
    tmp = await prepararDirectorioTemporal('tema_test');
    Preferencias.olvidarParaTests();
  });

  tearDown(() => tmp.delete(recursive: true));

  test('sin decidir nada, sigue al sistema', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // `null` es "lo que diga el teléfono": la pantalla lo resuelve con el
    // brillo de la plataforma.
    expect(container.read(temaOscuroProvider), isNull);
  });

  test('lo elegido se guarda y vuelve en el próximo arranque', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(temaOscuroProvider.notifier).fijar(true);
    expect(container.read(temaOscuroProvider), isTrue);

    Preferencias.olvidarParaTests();
    final otro = ProviderContainer();
    addTearDown(otro.dispose);
    otro.read(temaOscuroProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(otro.read(temaOscuroProvider), isTrue);
  });

  test('elegir claro con el sistema en oscuro también se respeta', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // Lo que se guarda es `false`, no "sin decidir": son cosas distintas y
    // confundirlas devolvería al usuario al tema del sistema.
    await container.read(temaOscuroProvider.notifier).fijar(false);

    final prefs = await Preferencias.abrir();
    expect(prefs.banderaOpcional(claveTemaOscuro), isFalse);
    expect(container.read(temaOscuroProvider), isFalse);
  });

  test('el tema y las cifras tapadas son dos decisiones distintas', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(temaOscuroProvider.notifier).fijar(true);
    expect(container.read(saldosOcultosProvider), isFalse, reason: 'el ojito no se movió');

    await container.read(saldosOcultosProvider.notifier).alternar();
    expect(container.read(temaOscuroProvider), isTrue, reason: 'y el tema tampoco');

    // Y las dos sobreviven juntas en el archivo.
    final prefs = await Preferencias.abrir();
    expect(prefs.banderaOpcional(claveTemaOscuro), isTrue);
    expect(prefs.bandera(claveSaldosOcultos), isTrue);
  });
}
