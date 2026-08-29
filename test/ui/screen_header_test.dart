// El encabezado: que el avatar de la cuenta sea siempre lo último a la derecha.
//
// Es el único elemento que aparece en las seis pantallas en el mismo sitio, y la
// acción propia de una pantalla —agregar una deuda, una meta— se colaba después
// de él y lo corría 36 puntos hacia adentro. A ojo se ve como un botón fuera de
// lugar; en el árbol de widgets no se nota nada.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:financial_strategist_local/data/models.dart';
import 'package:financial_strategist_local/design/theme.dart';
import 'package:financial_strategist_local/design/tokens.dart';
import 'package:financial_strategist_local/screens/shell.dart';
import 'package:financial_strategist_local/state/providers.dart';

void main() {
  // Con el usuario servido de una vez y sin base de por medio: lo que se mide es
  // dónde cae cada cosa en la fila, no de dónde salió el nombre. `userProvider`
  // se sobreescribe directamente porque leerlo del `sessionProvider` obligaría a
  // esperar un `Future` que acá no aporta nada.
  const usuario = AppUser(
    id: 'u1',
    // El avatar dibuja la inicial del nombre, y por esa inicial se lo ubica: el
    // widget es privado y la 'B' es lo único suyo que se puede buscar sin
    // encender el árbol de semántica.
    name: 'Betsy Vies',
    email: 'betsy@example.com',
    currency: 'PEN',
    timezone: 'America/Lima',
  );

  Widget envuelto(Widget child) => ProviderScope(
    overrides: [userProvider.overrideWithValue(usuario)],
    child: AppTheme(
      colors: AppColors.light,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(390, 800)),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 390, child: child),
          ),
        ),
      ),
    ),
  );

  testWidgets('la acción de la pantalla va antes del avatar, no después', (tester) async {
    await tester.pumpWidget(
      envuelto(
        const ScreenHeader(
          kicker: 'Gestión de dinero',
          title: 'Deudas',
          action: SizedBox(
            key: _llaveAccion,
            width: 36,
            height: 36,
            child: Center(child: Text('+')),
          ),
        ),
      ),
    );

    final accion = tester.getRect(find.byKey(_llaveAccion));
    final avatar = tester.getRect(_avatar);

    expect(accion.right, lessThanOrEqualTo(avatar.left), reason: 'la acción queda a la izquierda');
    expect(avatar.right, closeTo(390, 1), reason: 'el avatar sigue pegado al borde');
  });

  testWidgets('sin acción, el avatar queda en el mismo sitio', (tester) async {
    await tester.pumpWidget(
      envuelto(const ScreenHeader(kicker: 'Gestión de dinero', title: 'Panorama')),
    );

    expect(tester.getRect(_avatar).right, closeTo(390, 1));
  });

  testWidgets('la acción y el avatar arrancan a la misma altura', (tester) async {
    // Los dos son círculos de 36: dos puntos de diferencia —los que tenía el
    // botón de margen— se leen como un botón torcido.
    await tester.pumpWidget(
      envuelto(
        const ScreenHeader(
          kicker: 'A dónde vas',
          title: 'Objetivos',
          action: SizedBox(
            key: _llaveAccion,
            width: 36,
            height: 36,
            child: Center(child: Text('+')),
          ),
        ),
      ),
    );

    final accion = tester.getRect(find.byKey(_llaveAccion));
    final avatar = tester.getRect(_avatar);
    expect(accion.center.dy, closeTo(avatar.center.dy, 0.5));
  });
}

const _llaveAccion = ValueKey('accion');

/// El círculo del avatar: el primer `Container` que envuelve a la inicial.
final _avatar = find.ancestor(of: find.text('B'), matching: find.byType(Container)).first;
