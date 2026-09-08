// Las columnas del resumen de cuentas: las pastillas de estado y las cifras.
//
// Cada fila tiene un nombre de largo distinto, así que todo lo que va después de
// él se corre con el nombre: las pastillas caían en cinco sitios distintos y la
// columna se leía como una escalera. Lo que se prueba acá es que **no** dependan
// del nombre — que es justo lo que un ancho fijo garantiza y lo que un `Row`
// suelto no.

import 'dart:io';

import 'package:financial_strategist_local/data/models.dart';
import 'package:financial_strategist_local/design/theme.dart';
import 'package:financial_strategist_local/design/tokens.dart';
import 'package:financial_strategist_local/screens/movimientos_screen.dart';
import 'package:financial_strategist_local/state/providers.dart';
import 'package:financial_strategist_local/ui/surface.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_support.dart';

void main() {
  late Directory tmp;

  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(inicializarMotorDePrueba);

  setUp(() async {
    tmp = await prepararDirectorioTemporal('columnas_cuentas_test');
  });

  tearDown(() => tmp.delete(recursive: true));

  /// El test dibuja con la fuente de respaldo, no con la del producto: los
  /// textos salen más anchos y alguna fila se desborda por unos píxeles. Es
  /// ruido del entorno, no del widget.
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
    tester.view.physicalSize = const Size(390 * 3, 3000 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

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
                data: MediaQueryData(size: Size(390, 3000)),
                child: MovimientosScreen(),
              ),
            ),
          ),
        ),
      );
      // Se espera a que las cuentas lleguen, no un rato fijo: con la suite
      // entera corriendo en paralelo sqflite tarda más que sola, y un `delayed`
      // a ojo hace que el test pase o falle según lo cargada que esté la
      // máquina.
      for (var intento = 0; intento < 60; intento++) {
        await tester.pump();
        if (find.text('EN EL BANCO').evaluate().isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await tester.pump();
    });
    await tester.pump();
  }

  testWidgets('las pastillas de visible caen todas en la misma vertical', (tester) async {
    await montar(tester);

    final pastillas = [...find.text('visible').evaluate(), ...find.text('no visible').evaluate()];
    expect(pastillas.length, greaterThanOrEqualTo(2), reason: 'hacen falta varias filas');

    // La derecha de cada pastilla, que es su borde alineado: el ancho del texto
    // cambia entre "visible" y "no visible", el sitio donde termina no.
    final derechas = pastillas.map((e) {
      final caja = e.findRenderObject()! as RenderBox;
      return caja.localToGlobal(Offset(caja.size.width, 0)).dx;
    }).toList();

    for (final x in derechas) {
      expect(x, closeTo(derechas.first, 1), reason: 'todas terminan donde la primera');
    }
  });

  testWidgets('las cifras de las cuentas terminan todas en la misma vertical', (tester) async {
    await montar(tester);

    // Solo la tarjeta del patrimonio: más abajo hay otra lista con cifras, y su
    // columna es la suya —no tiene por qué compartir vertical con esta—.
    final tarjeta = find
        .ancestor(of: find.text('PATRIMONIO DISPONIBLE'), matching: find.byType(AppCard))
        .first;
    final montos = find
        .descendant(
          of: tarjeta,
          matching: find.byWidgetPredicate((w) => w is Text && (w.data ?? '').startsWith('S/ ')),
        )
        .evaluate()
        .where((e) {
          final caja = e.findRenderObject()! as RenderBox;
          // El patrimonio de la cabecera es mucho más alto que las filas.
          return caja.size.height < 24;
        })
        .toList();
    expect(montos.length, greaterThanOrEqualTo(3));

    final derechas = montos.map((e) {
      final caja = e.findRenderObject()! as RenderBox;
      return caja.localToGlobal(Offset(caja.size.width, 0)).dx;
    }).toSet();

    // Una sola vertical: las filas y los subtotales de cada grupo. Antes el
    // subtotal iba pegado al borde de la tarjeta y las filas se paraban antes,
    // así que el total de un grupo no caía sobre la columna que resume.
    expect(derechas.length, 1, reason: 'derechas distintas: $derechas');
  });
}
