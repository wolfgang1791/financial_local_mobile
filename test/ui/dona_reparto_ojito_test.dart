// El ojito del anillo "Dónde terminó tu dinero".
//
// Acá significa otra cosa que en el anillo de categorías: allá es "¿cuánto
// habría gastado sin esto?" y acá es "sácalo de la cuenta para ver cuánto pesa
// el resto". Esto comprueba las tres cosas que eso implica: que la porción sale
// del total del centro, que los porcentajes se recalculan sobre lo que queda, y
// que la fila **no** desaparece —si lo hiciera, no habría forma de volver a
// contarla—.

import 'package:financial_strategist_local/design/theme.dart';
import 'package:financial_strategist_local/design/tokens.dart';
import 'package:financial_strategist_local/ui/donut_chart.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// El mismo armado que hace `_SeccionReparto`: el gráfico es controlado, así
/// que quien lo usa es el que pone a cero lo tapado y baja el total.
class _Reparto extends StatefulWidget {
  const _Reparto();

  @override
  State<_Reparto> createState() => _RepartoState();
}

class _RepartoState extends State<_Reparto> {
  static const _partes = [
    (id: 'deudas', label: 'Pago de deudas', monto: 3670.14),
    (id: 'fijos', label: 'Gastos fijos', monto: 2122.15),
    (id: 'otros', label: 'Gastos de la vida', monto: 3044.25),
    (id: 'ajustes', label: 'Ajustes y traspasos', monto: 5960.00),
  ];

  final _ocultas = <String>{};

  @override
  Widget build(BuildContext context) {
    final segmentos = [
      for (final p in _partes)
        DonutSegment(
          id: p.id,
          label: p.label,
          value: _ocultas.contains(p.id) ? 0 : p.monto,
          fullValue: p.monto,
        ),
    ];
    final contado = segmentos.fold<double>(0, (s, seg) => s + seg.value);

    return DonutChart(
      segments: segmentos,
      total: contado,
      centerLabel: 'Dinero del periodo',
      currency: 'PEN',
      hidden: _ocultas,
      onToggleHide: (id) => setState(() {
        if (!_ocultas.remove(id)) _ocultas.add(id);
      }),
    );
  }
}

void main() {
  Future<void> montar(WidgetTester tester) async {
    // El anillo y su tabla van uno debajo del otro en un teléfono: sin altura
    // suficiente las filas quedan fuera del viewport y ni se construyen.
    tester.view.physicalSize = const Size(390 * 3, 1400 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      AppTheme(
        colors: AppColors.light,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: MediaQueryData(size: Size(390, 1400)),
            child: _Reparto(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('tapar una porción la saca del total y recalcula el resto', (tester) async {
    await montar(tester);

    // 3670.14 + 2122.15 + 3044.25 + 5960 = 14796.54; las deudas son el 24.8%.
    expect(find.text('S/ 14,796.54'), findsOneWidget, reason: 'el centro suma las cuatro');
    expect(find.text('24.8%'), findsOneWidget);

    // Fuera los ajustes: quedan 8836.54, y las deudas pasan a pesar 41.5%.
    await tester.tap(find.bySemanticsLabel('Quitar Ajustes y traspasos de la cuenta'));
    await tester.pumpAndSettle();

    expect(find.text('S/ 8,836.54'), findsOneWidget, reason: 'el centro descuenta lo tapado');
    expect(find.text('41.5%'), findsOneWidget, reason: 'el resto se reparte el nuevo entero');

    // La fila sigue ahí, con su monto: si desapareciera no habría forma de
    // volver a contarla.
    expect(find.text('Ajustes y traspasos'), findsOneWidget);
    expect(find.text('S/ 5,960.00'), findsOneWidget);
    // Y sin porcentaje: el total ya no la incluye, así que cualquier cifra ahí
    // sería una fracción de un entero al que esta porción no pertenece.
    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('volver a tocarla la devuelve a la cuenta', (tester) async {
    await montar(tester);

    final ojo = find.bySemanticsLabel(RegExp('(Quitar|Volver a contar) Gastos fijos'));
    await tester.tap(ojo);
    await tester.pumpAndSettle();
    expect(find.text('S/ 12,674.39'), findsOneWidget);

    await tester.tap(ojo);
    await tester.pumpAndSettle();
    expect(find.text('S/ 14,796.54'), findsOneWidget);
  });
}
