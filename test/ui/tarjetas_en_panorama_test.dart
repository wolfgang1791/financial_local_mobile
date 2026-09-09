// Lo que debes en las tarjetas del día a día, en Panorama.
//
// Se lee contra el patrimonio y por eso vive pegado a él: "tengo 1,931" sin "y
// llevo 250 gastados con la tarjeta" contesta a medias la única pregunta de esta
// pantalla. No se resta del total —comprar con la tarjeta no te empobrece en el
// momento, te compromete— así que se dice aparte y con todas las letras.

import 'package:financial_strategist_local/data/models.dart';
import 'package:financial_strategist_local/design/theme.dart';
import 'package:financial_strategist_local/design/tokens.dart';
import 'package:financial_strategist_local/screens/panorama_screen.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  CashPositionAccount cuenta(String nombre, String tipo, double saldo) => CashPositionAccount(
    id: nombre,
    name: nombre,
    type: tipo,
    currentBalance: saldo,
    currency: 'PEN',
    isHidden: false,
  );

  Future<void> montar(WidgetTester tester, List<CashPositionAccount> cuentas) async {
    tester.view.physicalSize = const Size(390 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: AppTheme(
          colors: AppColors.light,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: MediaQuery(
              data: const MediaQueryData(size: Size(390, 900)),
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: TarjetaSaldoDePanorama(
                    posicion: CashPosition(
                      total: 1931.45,
                      income: 10,
                      expenses: 499.44,
                      currency: 'PEN',
                      accounts: cuentas,
                    ),
                    currency: 'PEN',
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  final banco = cuenta('Cuenta principal', 'CHECKING', 1931.45);

  testWidgets('dice cuánto debes en las tarjetas, sin restarlo del patrimonio', (tester) async {
    await montar(tester, [banco, cuenta('CMR', 'CREDIT_CARD', 250)]);

    expect(find.text('EN TUS TARJETAS'), findsOneWidget);
    expect(find.text('debes'), findsOneWidget);
    expect(find.text('S/ 250.00'), findsOneWidget);
    // El patrimonio sigue siendo el de las cuentas líquidas: lo de la tarjeta se
    // dice al lado, no se descuenta.
    expect(find.text('S/ 1,931.45'), findsOneWidget);
  });

  testWidgets('con más de una, cada tarjeta con lo suyo', (tester) async {
    await montar(tester, [
      banco,
      cuenta('CMR', 'CREDIT_CARD', 38.70),
      cuenta('Interbank', 'CREDIT_CARD', 61.30),
    ]);

    // El total, y debajo cuál es cuál: "debes 100" no dice cuál hay que pagar.
    expect(find.text('S/ 100.00'), findsOneWidget);
    expect(find.text('CMR'), findsOneWidget);
    expect(find.text('S/ 38.70'), findsOneWidget);
    expect(find.text('Interbank'), findsOneWidget);
    expect(find.text('S/ 61.30'), findsOneWidget);
  });

  testWidgets('una tarjeta a favor lo dice, no la llama deuda', (tester) async {
    await montar(tester, [banco, cuenta('CMR', 'CREDIT_CARD', -40)]);

    expect(find.text('a favor'), findsOneWidget);
    expect(find.text('debes'), findsNothing);
  });

  testWidgets('con las tarjetas en cero, la tira tranquiliza en vez de alarmar', (tester) async {
    await montar(tester, [banco, cuenta('CMR', 'CREDIT_CARD', 0)]);

    expect(find.text('Sin nada pendiente'), findsOneWidget);
    expect(find.text('debes'), findsNothing);
  });

  testWidgets('sin tarjetas no aparece la tira', (tester) async {
    await montar(tester, [banco]);

    expect(find.text('EN TUS TARJETAS'), findsNothing);
  });
}
