// El refresco de entrada: quién lo dispara y quién no.
//
// Es la clase de regla que se rompe sola al tocar el armazón —basta que una
// pantalla deje de estar envuelta en `ScreenVisibility`, o que un cambio de tema
// vuelva a disparar `didChangeDependencies`, para que la app empiece a recargar
// de más o de menos— y que a ojo no se ve: un refresco que sobra devuelve lo
// mismo que ya estaba.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:financial_strategist_local/ui/refreshable_screen.dart';

void main() {
  /// Arma una pantalla envuelta en la visibilidad que se le pase, y cuenta los
  /// refrescos.
  Widget pantalla({required bool visible, required VoidCallback onRefresh}) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ScreenVisibility(
        visible: visible,
        child: RefreshableScreen(
          onRefresh: () async => onRefresh(),
          children: const [Text('contenido')],
        ),
      ),
    );
  }

  testWidgets('aparecer por primera vez no pide los datos de nuevo', (tester) async {
    var refrescos = 0;
    await tester.pumpWidget(pantalla(visible: true, onRefresh: () => refrescos++));
    await tester.pumpAndSettle();

    // Los providers acaban de cargar al construirse la pantalla: invalidarlos
    // acá sería el mismo viaje a la base dos veces seguidas.
    expect(refrescos, 0);
  });

  testWidgets('volver al frente pide los datos de nuevo, una sola vez', (tester) async {
    var refrescos = 0;
    Future<void> construir(bool visible) =>
        tester.pumpWidget(pantalla(visible: visible, onRefresh: () => refrescos++));

    await construir(false);
    await tester.pumpAndSettle();
    expect(refrescos, 0, reason: 'nunca estuvo al frente');

    await construir(true);
    await tester.pumpAndSettle();
    expect(refrescos, 1);

    // Un rebuild con la misma visibilidad —un cambio de tema, una rotación— no
    // es entrar a la pantalla.
    await construir(true);
    await tester.pumpAndSettle();
    expect(refrescos, 1);

    await construir(false);
    await construir(true);
    await tester.pumpAndSettle();
    expect(refrescos, 2);
  });

  testWidgets('el contenido entra con el fundido y termina opaco', (tester) async {
    await tester.pumpWidget(pantalla(visible: false, onRefresh: () {}));
    await tester.pump();
    await tester.pumpWidget(pantalla(visible: true, onRefresh: () {}));

    // A mitad de la animación el contenido está a medio camino; si el fundido
    // no corriera, no habría ninguna capa de opacidad en el árbol.
    await tester.pump(const Duration(milliseconds: 100));
    final enCurso = tester.widget<Opacity>(find.byType(Opacity));
    expect(enCurso.opacity, greaterThan(0));
    expect(enCurso.opacity, lessThan(1));

    // Y en reposo la capa desaparece: `Opacity` fuerza una capa de composición
    // y el scroll es lo que más se toca de la app.
    await tester.pumpAndSettle();
    expect(find.byType(Opacity), findsNothing);
    expect(find.text('contenido'), findsOneWidget);
  });
}
