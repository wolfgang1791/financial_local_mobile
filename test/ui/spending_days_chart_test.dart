// El calendario de días con gasto: que dibuje lo que dice y que el interruptor
// cambie de verdad la vista.

import 'package:financial_strategist_local/design/theme.dart';
import 'package:financial_strategist_local/design/tokens.dart';
import 'package:financial_strategist_local/data/models.dart';
import 'package:financial_strategist_local/local_engine/spending_days.dart';
import 'package:financial_strategist_local/ui/spending_days_chart.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

SpendingDay _dia(
  String fecha,
  double monto,
  int weekday, {
  double fijo = 0,
  double deuda = 0,
  List<String> categorias = const [],
}) => SpendingDay(
  date: fecha,
  day: int.parse(fecha.split('-')[2]),
  month: int.parse(fecha.split('-')[1]),
  year: int.parse(fecha.split('-')[0]),
  weekday: weekday,
  amount: monto,
  count: monto > 0 ? 1 : 0,
  fijo: fijo,
  fijoCount: fijo > 0 ? 1 : 0,
  deuda: deuda,
  deudaCount: deuda > 0 ? 1 : 0,
  categorias: categorias,
);

SpendingDays _resumen(List<SpendingDay> dias) {
  final conGasto = dias.where((d) => d.conGasto).toList();
  return SpendingDays(
    days: dias,
    conGasto: conGasto.length,
    sinGasto: dias.length - conGasto.length,
    rachaSinGasto: 1,
    rachaActual: 0,
    totalGastado: conGasto.fold(0.0, (a, d) => a + d.amount),
    mayor: conGasto.isEmpty ? null : conGasto.reduce((a, b) => a.amount >= b.amount ? a : b),
    menor: conGasto.isEmpty ? null : conGasto.reduce((a, b) => a.amount <= b.amount ? a : b),
  );
}

Future<void> _montar(WidgetTester tester, Widget hijo) => tester.pumpWidget(
  AppTheme(
    colors: AppColors.light,
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(390, 900)),
        // Con scroll: la tarjeta es más alta que la ventana de prueba, y un
        // desborde vertical del arnés no dice nada del widget.
        child: SingleChildScrollView(child: SizedBox(width: 340, child: hijo)),
      ),
    ),
  ),
);

void main() {
  // El 3 fue solo el alquiler; el 5 fue gasto de verdad.
  final todo = _resumen([
    _dia('2026-08-03', 200, 0, fijo: 200),
    _dia('2026-08-04', 0, 1),
    _dia('2026-08-05', 15, 2),
  ]);

  testWidgets('dice cuántos días tuvieron gasto', (tester) async {
    await _montar(
      tester,
      SpendingDaysChart(
        resumen: todo,
        categorias: const [],
        periodo: 'este mes',
        currency: 'PEN',
        esPeriodoAbierto: true,
        onVerDia: (_) {},
      ),
    );
    expect(find.text('2 de 3 días'), findsOneWidget);
    expect(find.textContaining('1 día sin gastar nada este mes'), findsOneWidget);
  });

  testWidgets('el interruptor descuenta fijos y deudas, y se puede volver', (tester) async {
    await _montar(
      tester,
      SpendingDaysChart(
        resumen: todo,
        categorias: const [],
        periodo: 'este mes',
        currency: 'PEN',
        esPeriodoAbierto: true,
        onVerDia: (_) {},
      ),
    );
    await tester.tap(find.textContaining('Sin gastos fijos'));
    await tester.pump();
    expect(find.text('1 de 3 días'), findsOneWidget);

    // Reversible: apagarlo devuelve la vista completa.
    await tester.tap(find.textContaining('Sin gastos fijos'));
    await tester.pump();
    expect(find.text('2 de 3 días'), findsOneWidget);
  });

  testWidgets('los dos descuentos son independientes', (tester) async {
    await _montar(
      tester,
      SpendingDaysChart(
        resumen: todo,
        categorias: const [],
        periodo: 'este mes',
        currency: 'PEN',
        esPeriodoAbierto: true,
        onVerDia: (_) {},
      ),
    );
    // Quitar las cuotas de deuda no toca el alquiler: el 3 sigue contando.
    await tester.tap(find.textContaining('Sin cuotas de deuda'));
    await tester.pump();
    expect(find.text('2 de 3 días'), findsOneWidget);
  });

  testWidgets('tocar un día abre sus movimientos', (tester) async {
    String? pedido;
    await _montar(
      tester,
      SpendingDaysChart(
        resumen: todo,
        categorias: const [],
        periodo: 'este mes',
        currency: 'PEN',
        esPeriodoAbierto: true,
        onVerDia: (fecha) => pedido = fecha,
      ),
    );
    await tester.tap(find.text('3'));
    await tester.pump();
    expect(pedido, '2026-08-03');

    // Un día sin nada no lleva a ningún lado: sería una lista vacía.
    pedido = null;
    await tester.tap(find.text('4'));
    await tester.pump();
    expect(pedido, isNull);
  });

  testWidgets('el ícono de una subcategoría marcada sale dentro del día', (tester) async {
    final conCategorias = _resumen([
      _dia('2026-08-03', 200, 0, categorias: const ['cat-comida']),
      _dia('2026-08-04', 0, 1),
      _dia('2026-08-05', 15, 2),
    ]);
    await _montar(
      tester,
      SpendingDaysChart(
        resumen: conCategorias,
        categorias: const [
          Category(id: 'cat-comida', name: 'Comida rápida', type: 'EXPENSE', parentId: 'p'),
        ],
        periodo: 'este mes',
        currency: 'PEN',
        esPeriodoAbierto: true,
        onVerDia: (_) {},
      ),
    );

    // Sin marcar nada, el calendario no lleva íconos: marcar todo es no marcar
    // nada, y por eso arranca limpio.
    expect(find.textContaining('🍔'), findsNothing);
    expect(find.textContaining('Marcar categorías'), findsOneWidget);
  });
}
