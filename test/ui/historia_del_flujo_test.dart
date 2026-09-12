// Cómo ha cambiado un gasto fijo, mes a mes.
//
// La serie sale del monto que guarda cada mes —exista o no el pago— así que un
// mes sin marcar también cuenta. Lo que se prueba acá es que diga la verdad
// sobre el cambio: cuánto fue cada mes, cuánto varió respecto al anterior, y el
// salto desde el primero, que es la pregunta de fondo ("¿esto viene subiendo?").

import 'package:financial_strategist_local/data/models.dart';
import 'package:financial_strategist_local/design/theme.dart';
import 'package:financial_strategist_local/design/tokens.dart';
import 'package:financial_strategist_local/ui/historia_del_flujo.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  FlowMonth mes(double monto) => FlowMonth(amount: monto, dueDate: DateTime.utc(2026, 7, 31));

  Future<void> montar(WidgetTester tester, Map<String, FlowMonth> meses, {String? elegido}) async {
    tester.view.physicalSize = const Size(390 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      AppTheme(
        colors: AppColors.light,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(390, 900)),
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: HistoriaDelFlujo(meses: meses, mesElegido: elegido, currency: 'PEN'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  // La luz de verdad: julio 34.90, agosto 35.50.
  final laLuz = {'2026-07': mes(34.90), '2026-08': mes(35.50), '2026-09': mes(41.20)};

  testWidgets('muestra lo que costó cada mes', (tester) async {
    await montar(tester, laLuz);

    expect(find.text('S/ 34.90'), findsOneWidget);
    expect(find.text('S/ 35.50'), findsOneWidget);
    expect(find.text('S/ 41.20'), findsOneWidget);
    expect(find.text('jul 26'), findsOneWidget);
    expect(find.text('sep 26'), findsOneWidget);
  });

  testWidgets('dice cuánto varió cada mes respecto al anterior', (tester) async {
    await montar(tester, laLuz);

    // El primero no tiene contra qué compararse: su celda va vacía en vez de
    // inventar un cero que se leería como "no cambió".
    expect(find.text('+0.60'), findsOneWidget, reason: '34.90 → 35.50');
    expect(find.text('+5.70'), findsOneWidget, reason: '35.50 → 41.20');
  });

  testWidgets('resume el salto desde el primer mes', (tester) async {
    await montar(tester, laLuz);

    expect(find.textContaining('Subió'), findsOneWidget);
    expect(find.textContaining('S/ 6.30'), findsOneWidget);
    expect(find.textContaining('julio'), findsOneWidget);
    expect(find.textContaining('18%'), findsOneWidget);
  });

  testWidgets('cuando bajó, lo dice al revés', (tester) async {
    await montar(tester, {'2026-07': mes(100), '2026-08': mes(80)});

    expect(find.textContaining('Bajó'), findsOneWidget);
    expect(find.text('−20.00'), findsOneWidget);
  });

  testWidgets('un flujo estrenado este mes no finge historia', (tester) async {
    await montar(tester, {'2026-09': mes(41.20)});

    expect(
      find.textContaining('primer mes registrado'),
      findsOneWidget,
      reason: 'con un solo mes no hay con qué comparar',
    );
    expect(find.textContaining('Subió'), findsNothing);
  });

  testWidgets('sin meses no pinta nada', (tester) async {
    await montar(tester, const {});

    expect(find.textContaining('CÓMO HA CAMBIADO'), findsNothing);
  });

  testWidgets('el mes que estás editando se distingue de los demás', (tester) async {
    await montar(tester, laLuz, elegido: '2026-08');

    final elegido = tester.widget<Text>(find.text('ago 26'));
    final otro = tester.widget<Text>(find.text('jul 26'));
    expect(elegido.style!.fontWeight, FontWeight.w600);
    expect(otro.style!.fontWeight, isNot(FontWeight.w600));
  });

  testWidgets('con años de historia muestra los últimos ocho meses', (tester) async {
    final muchos = {
      for (var i = 1; i <= 14; i++) '2026-${i.toString().padLeft(2, '0')}': mes(10.0 + i),
    };
    await montar(tester, muchos);

    // Los ocho últimos: del 07 al 14 (los meses 13 y 14 no existen en el
    // calendario, pero la serie ordena por clave y eso es lo que se prueba).
    expect(find.text('S/ 24.00'), findsOneWidget, reason: 'el último');
    expect(find.text('S/ 11.00'), findsNothing, reason: 'el primero ya no cabe');
  });
}
