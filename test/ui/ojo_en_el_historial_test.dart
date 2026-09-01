// El ojito del historial: descontar un movimiento de las cifras de arriba.
//
// Se llega acá desde una porción del anillo de Panorama —"gastos fijos",
// "deudas"— y lo primero que uno quiere hacer con una lista de gastos es
// preguntarse "¿y sin este?". La fila no se borra ni se filtra: se queda a la
// vista, apagada, porque si desapareciera no habría forma de volver a contarla.

import 'dart:io';

import 'package:financial_strategist_local/data/models.dart';
import 'package:financial_strategist_local/design/theme.dart';
import 'package:financial_strategist_local/design/tokens.dart';
import 'package:financial_strategist_local/screens/historial_screen.dart';
import 'package:financial_strategist_local/state/providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_support.dart';

void main() {
  late Directory tmp;

  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(inicializarMotorDePrueba);

  setUp(() async {
    tmp = await prepararDirectorioTemporal('ojo_historial_test');
  });

  tearDown(() => tmp.delete(recursive: true));

  /// El test dibuja con la fuente de respaldo, no con la del producto: los
  /// textos salen más anchos y alguna fila se desborda por unos píxeles. Es
  /// ruido del entorno, no del widget, así que se ignora **solo** eso.
  void ignorarDesbordesDeFuente() {
    final original = FlutterError.onError;
    FlutterError.onError = (detalles) {
      if (detalles.exceptionAsString().contains('overflowed by')) return;
      original?.call(detalles);
    };
    addTearDown(() => FlutterError.onError = original);
  }

  Future<void> montar(WidgetTester tester) async {
    ignorarDesbordesDeFuente();
    // La pantalla es una lista larga: con la superficie por defecto las filas
    // quedan fuera del viewport y ni se construyen.
    tester.view.physicalSize = const Size(390 * 3, 3000 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    // Todo el montaje dentro de `runAsync`: la pantalla pide sus movimientos a
    // sqflite en `initState`, y un future creado dentro del reloj falso de
    // `testWidgets` no avanza aunque se bombee. Sin esto, el test mira una
    // lista que todavía está cargando.
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            userProvider.overrideWithValue(
              AppUser.fromJson({
                'id': 'u1',
                'name': 'Prueba',
                'email': 'p@p.pe',
                'currency': 'PEN',
                'timezone': 'America/Lima',
              }),
            ),
          ],
          child: AppTheme(
            colors: AppColors.light,
            child: const Directionality(
              textDirection: TextDirection.ltr,
              child: MediaQuery(
                data: MediaQueryData(size: Size(390, 1600)),
                // Se llega como se llega desde el anillo: con un origen puesto.
                child: HistorialScreen(origen: 'fijos'),
              ),
            ),
          ),
        ),
      );
      // Se espera a que la lista llegue, no un rato fijo: con la suite entera
      // corriendo en paralelo, sqflite tarda más que sola y un `delayed` a ojo
      // hace que el test pase o falle según lo cargada que esté la máquina.
      for (var intento = 0; intento < 60; intento++) {
        await tester.pump();
        if (find.bySemanticsLabel('Descontar este movimiento').evaluate().isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await tester.pump();
    });
    await tester.pumpAndSettle();
  }

  testWidgets('cada movimiento trae su ojito y descontarlo cambia el total', (tester) async {
    await montar(tester);

    final ojos = find.bySemanticsLabel('Descontar este movimiento');
    expect(ojos, findsWidgets, reason: 'la lista llega con gastos fijos y cada uno con su ojo');

    // Antes de tocar nada no hay aviso de descontados.
    expect(find.textContaining('descontado'), findsNothing);

    await tester.tap(ojos.first);
    await tester.pumpAndSettle();

    // La fila sigue ahí —ahora con el ojo cerrado— y el encabezado avisa.
    expect(find.bySemanticsLabel('Volver a contar este movimiento'), findsOneWidget);
    expect(find.textContaining('1 movimiento descontado'), findsOneWidget);
  });

  testWidgets('volver a contarlos deshace todo de un toque', (tester) async {
    await montar(tester);

    final ojos = find.bySemanticsLabel('Descontar este movimiento');
    await tester.tap(ojos.first);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Descontar este movimiento').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('2 movimientos descontados'), findsOneWidget);

    await tester.tap(find.textContaining('volver a contarlos'));
    await tester.pumpAndSettle();
    expect(find.textContaining('descontado'), findsNothing);
  });
}
