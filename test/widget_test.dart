// Humo: que la app levante sin tirar una excepción en el primer cuadro.
//
// Acá no hay servidor que simular ni token que inyectar: la sesión se
// resuelve leyendo la base sembrada (una copia de prueba, no la real), así
// que lo que se prueba es que abrir la base, leer el usuario y armar la
// pantalla de inicio no revienta.

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:financial_strategist_local/app.dart';
import 'package:financial_strategist_local/local_db/database.dart';

import 'test_support.dart';

void main() {
  late Directory tmp;

  setUpAll(inicializarMotorDePrueba);

  setUp(() async {
    tmp = await prepararDirectorioTemporal('financial_strategist_local_widget_test');
  });

  tearDown(() async {
    await LocalDatabase.resetForTests();
    await tmp.delete(recursive: true);
  });

  testWidgets('la app arranca y llega a una pantalla', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: FinancialStrategistApp()));
    await tester.pumpAndSettle();

    // No se afirma sobre un texto específico de una pantalla en particular
    // —Decisiones, Objetivos, lo que sea que muestre el usuario sembrado—
    // porque eso cambia con cada fase portada. Lo que este test protege es
    // que copiar la base y armar el árbol de widgets no explota.
    expect(tester.takeException(), isNull);
  });
}
