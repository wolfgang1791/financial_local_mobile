// El ojito de la tarjeta tapa la tarjeta. Nada más.
//
// Se reportó que prenderlo y apagarlo "afectaba los gastos fijos". Esto arma la
// pantalla de Movimientos entera y comprueba las dos formas en que podría
// tocarlos: que les tape las cifras, y que les borre lo que el usuario había
// elegido ahí —el mes que está mirando y los que descontó con su propio ojito—.

import 'dart:io';

import 'package:financial_strategist_local/data/models.dart';
import 'package:financial_strategist_local/design/theme.dart';
import 'package:financial_strategist_local/design/tokens.dart';
import 'package:financial_strategist_local/screens/movimientos_screen.dart';
import 'package:financial_strategist_local/state/providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_support.dart';

String _mesActual() {
  final hoy = DateTime.now();
  return '${hoy.year}-${hoy.month.toString().padLeft(2, '0')}';
}

Map<String, dynamic> _flujo(String id, String nombre, double monto) {
  final mes = _mesActual();
  return {
    'id': id,
    'name': nombre,
    'type': 'EXPENSE',
    'amount': monto,
    'frequency': 'MONTHLY',
    'nextDueDate': '$mes-28T12:00:00.000Z',
    'startDate': '$mes-01T12:00:00.000Z',
    'paidMonths': <String>[],
    'monthlyRecords': <dynamic>[],
    'missedMonths': <String>[],
    'months': {
      mes: {'amount': monto, 'dueDate': '$mes-28', 'paidAt': null},
    },
  };
}

void main() {
  late Directory tmp;

  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(inicializarMotorDePrueba);

  setUp(() async {
    tmp = await prepararDirectorioTemporal('ojo_fijos_test');
  });

  tearDown(() => tmp.delete(recursive: true));

  /// El test dibuja con la fuente de respaldo, no con la del producto: los
  /// textos salen más anchos y un par de filas se desbordan por unos píxeles.
  /// Es ruido del entorno, no del widget —en el dispositivo, con Jakarta, no
  /// pasa—, así que se ignora **solo** eso: cualquier otro error sigue
  /// rompiendo el test.
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
    // La pantalla es una lista perezosa: con la superficie de 800x600 por
    // defecto, los gastos fijos quedan fuera del viewport y ni se construyen.
    tester.view.physicalSize = const Size(390 * 3, 2600 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
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
          cashPositionProvider.overrideWith(
            (ref) async => CashPosition.fromJson({
              'total': 1182.42,
              'month': {'key': _mesActual(), 'income': 0, 'expenses': 1417.59, 'net': -1417.59},
              'accounts': <dynamic>[],
            }),
          ),
          recentTransactionsProvider.overrideWith((ref) async => <Transaction>[]),
          recurringFlowsProvider.overrideWith(
            (ref) async => [
              RecurringFlow.fromJson(_flujo('f1', 'Alquiler', 1700)),
              RecurringFlow.fromJson(_flujo('f2', 'Internet', 99)),
            ],
          ),
        ],
        child: AppTheme(
          colors: AppColors.light,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: MediaQuery(
              data: const MediaQueryData(size: Size(390, 1400)),
              child: const MovimientosScreen(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('tapar la tarjeta no tapa los gastos fijos', (tester) async {
    await montar(tester);

    expect(find.textContaining('1,700.00'), findsWidgets, reason: 'el gasto fijo se ve');

    await tester.tap(find.bySemanticsLabel('Tapar los montos'));
    await tester.pumpAndSettle();

    // La tarjeta sí se tapa...
    expect(find.text('S/ 1,182.42'), findsNothing);
    // ...y los gastos fijos no. Son dos preguntas distintas: tapar el
    // patrimonio es para que no se lea de reojo, y los fijos son una lista de
    // compromisos que uno mira igual.
    expect(find.textContaining('1,700.00'), findsWidgets);
  });

  testWidgets('prender y apagar no borra lo elegido en los gastos fijos', (tester) async {
    await montar(tester);

    // El usuario descuenta un gasto fijo con el ojito de esa fila.
    final ojosDeFila = find.bySemanticsLabel(RegExp('Descontar|Volver a contar'));
    expect(ojosDeFila, findsWidgets);
    await tester.tap(ojosDeFila.first);
    await tester.pumpAndSettle();
    final descontadoAntes = find.textContaining('descontado').evaluate().length;
    expect(descontadoAntes, greaterThan(0), reason: 'quedó uno descontado');

    // Y ahora toca el ojito de la tarjeta, dos veces.
    await tester.tap(find.bySemanticsLabel('Tapar los montos'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Mostrar los montos'));
    await tester.pumpAndSettle();

    // Lo que eligió en los gastos fijos sigue como lo dejó.
    expect(find.textContaining('descontado').evaluate().length, descontadoAntes);
  });
}
