// El campo de texto: que se pueda escribir y borrar sin que el foco se caiga.
//
// El bug que protege este test era invisible en el árbol de widgets y muy
// visible usando la app: cada formulario construía su `FocusNode()` dentro de
// `build`, y como todos llaman a `setState` en cada tecla —para habilitar el
// botón de guardar—, al primer carácter escrito o borrado el campo perdía el
// foco. El teclado se cerraba y el cursor desaparecía; un campo recién vaciado
// quedaba en blanco, sin nada que mirar.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:financial_strategist_local/design/theme.dart';
import 'package:financial_strategist_local/design/tokens.dart';
import 'package:financial_strategist_local/ui/fields.dart';

/// Un formulario como los de la app: redibuja entero en cada tecla.
class _FormularioQueSeRedibuja extends StatefulWidget {
  const _FormularioQueSeRedibuja({required this.controller, this.placeholder});

  final TextEditingController controller;
  final String? placeholder;

  @override
  State<_FormularioQueSeRedibuja> createState() => _FormularioQueSeRedibujaState();
}

class _FormularioQueSeRedibujaState extends State<_FormularioQueSeRedibuja> {
  int rebuilds = 0;

  @override
  Widget build(BuildContext context) {
    rebuilds++;
    return AppTextField(
      controller: widget.controller,
      placeholder: widget.placeholder,
      onChanged: (_) => setState(() {}),
    );
  }
}

void main() {
  Widget envuelto(Widget child) => AppTheme(
    colors: AppColors.light,
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: SizedBox(width: 300, child: child)),
    ),
  );

  testWidgets('escribir y borrar no le quitan el foco al campo', (tester) async {
    final controller = TextEditingController(text: '25.50');
    await tester.pumpWidget(envuelto(_FormularioQueSeRedibuja(controller: controller)));

    final campo = find.byType(EditableText);
    bool conFoco() => tester.widget<EditableText>(campo).focusNode.hasFocus;

    await tester.tap(campo);
    await tester.pump();
    expect(conFoco(), isTrue, reason: 'tocarlo lo enfoca');

    await tester.enterText(campo, '25.5');
    await tester.pump();
    expect(conFoco(), isTrue, reason: 'borrar un carácter no cierra el teclado');

    await tester.enterText(campo, '');
    await tester.pump();
    expect(conFoco(), isTrue, reason: 'vaciarlo tampoco');
    expect(controller.text, isEmpty);
  });

  testWidgets('la pista aparece al vaciarlo y se va al escribir', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(
      envuelto(_FormularioQueSeRedibuja(controller: controller, placeholder: '0.00')),
    );

    expect(find.text('0.00'), findsOneWidget, reason: 'vacío desde el arranque');

    await tester.enterText(find.byType(EditableText), '12');
    await tester.pump();
    expect(find.text('0.00'), findsNothing, reason: 'con texto no hay pista');

    await tester.enterText(find.byType(EditableText), '');
    await tester.pump();
    expect(find.text('0.00'), findsOneWidget, reason: 'al borrar vuelve');
  });

  testWidgets('la pista vuelve aunque el texto se borre desde afuera', (tester) async {
    // La "×" del buscador del historial limpia el controlador sin pasar por el
    // teclado: si el campo solo escuchara su propio `onChanged`, la pista no
    // reaparecería.
    final controller = TextEditingController(text: 'café');
    await tester.pumpWidget(
      envuelto(AppTextField(controller: controller, placeholder: 'Buscar por detalle')),
    );
    expect(find.text('Buscar por detalle'), findsNothing);

    controller.clear();
    await tester.pump();
    expect(find.text('Buscar por detalle'), findsOneWidget);
  });

  testWidgets('la selección se pinta con un color visible', (tester) async {
    // Sin `selectionColor`, `EditableText` no dibuja nada al seleccionar:
    // el doble toque marcaba la palabra de verdad pero en pantalla no se
    // notaba, y borrarla parecía no hacer nada.
    await tester.pumpWidget(
      envuelto(AppTextField(controller: TextEditingController(text: 'hola'))),
    );
    final campo = tester.widget<EditableText>(find.byType(EditableText));
    expect(campo.selectionColor, isNotNull);
    expect(campo.selectionColor!.a, greaterThan(0));
  });
}
