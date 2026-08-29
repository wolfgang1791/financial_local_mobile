import 'package:flutter/services.dart' show TextInputAction, TextInputFormatter, TextInputType;
import 'package:flutter/widgets.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import 'icons.dart';

/// Los cuatro bloques de un formulario, compartidos por todas las pantallas
/// que piden datos: registrar un movimiento, transferir, una deuda, una meta,
/// un flujo recurrente, una categoría.
///
/// Vivían como widgets privados de `nuevo_movimiento.dart` cuando era el único
/// formulario de la app. Con la paridad de la web, dejaron de ser un detalle
/// de esa pantalla y pasaron a ser el vocabulario de formulario de la app.

/// La etiqueta en versalitas sobre un campo.
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.texto, {super.key});

  final String texto;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        texto.toUpperCase(),
        style: AppText.kicker(colors.oliveInk.withValues(alpha: 0.6)).copyWith(fontSize: 10),
      ),
    );
  }
}

/// La caja con borde que envuelve un campo o un selector.
class FieldBox extends StatelessWidget {
  const FieldBox({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.lg, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: colors.surfaceBorder),
      ),
      child: child,
    );
  }
}

/// El campo de texto de la app: lo que va dentro de un [FieldBox].
///
/// Envuelve `EditableText` en vez de usar `TextField`, por lo mismo que el
/// resto de la app no usa Material: `TextField` trae su borde, su etiqueta
/// flotante y su color de foco, y con él la app se vería como dos apps según
/// el teléfono. Lo que sí hace falta de un campo de verdad está acá:
///
///  * **El `FocusNode` lo dueña este widget.** Antes cada pantalla escribía
///    `focusNode: FocusNode()` dentro de su `build`, y como los formularios
///    llaman a `setState` en cada tecla —para habilitar el botón de guardar—,
///    cada carácter escrito o borrado creaba un nodo nuevo: el campo perdía el
///    foco, el teclado se cerraba y el cursor desaparecía. Borrar dejaba una
///    caja vacía sin nada a la vista. Construido acá, el nodo sobrevive a los
///    rebuilds del formulario y además se libera al desmontarse.
///  * **`selectionColor`.** Sin él, `EditableText` no pinta nada al
///    seleccionar: un doble toque marcaba la palabra de verdad —y la siguiente
///    tecla la reemplazaba— pero en la pantalla no se veía ninguna diferencia.
///  * **El texto de ayuda cuando está vacío**, para que un campo recién
///    borrado siga diciendo qué se espera en él en vez de quedar en blanco.
class AppTextField extends StatefulWidget {
  const AppTextField({
    super.key,
    required this.controller,
    this.placeholder,
    this.style,
    this.autofocus = false,
    this.keyboardType,
    this.inputFormatters,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;

  /// Lo que se muestra mientras no hay nada escrito. En gris y detrás del
  /// cursor: es una pista, no un valor.
  final String? placeholder;

  /// El estilo del texto escrito. Por defecto el del cuerpo; los campos de
  /// monto pasan el suyo, más grande y tabular.
  final TextStyle? style;
  final bool autofocus;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final TextInputAction? textInputAction;
  final void Function(String)? onChanged;
  final void Function(String)? onSubmitted;

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  final _foco = FocusNode();
  late bool _vacio = widget.controller.text.isEmpty;

  @override
  void initState() {
    super.initState();
    // Se escucha al controlador y no al `onChanged` del campo: el texto también
    // cambia desde afuera —la "×" que limpia la búsqueda, un formulario que se
    // rellena solo— y el placeholder tiene que aparecer también en esos casos.
    widget.controller.addListener(_alCambiarElTexto);
  }

  @override
  void didUpdateWidget(AppTextField viejo) {
    super.didUpdateWidget(viejo);
    if (viejo.controller != widget.controller) {
      viejo.controller.removeListener(_alCambiarElTexto);
      widget.controller.addListener(_alCambiarElTexto);
      _vacio = widget.controller.text.isEmpty;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_alCambiarElTexto);
    _foco.dispose();
    super.dispose();
  }

  void _alCambiarElTexto() {
    // Solo cuando cruza el umbral de vacío a con texto: el listener corre en
    // cada tecla y redibujar en todas sería trabajo tirado.
    final vacio = widget.controller.text.isEmpty;
    if (vacio != _vacio) setState(() => _vacio = vacio);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final estilo = widget.style ?? AppText.body(colors.foreground);

    return Stack(
      children: [
        EditableText(
          controller: widget.controller,
          focusNode: _foco,
          autofocus: widget.autofocus,
          style: estilo,
          cursorColor: colors.sageDark,
          backgroundCursorColor: colors.olive,
          selectionColor: colors.sage.withValues(alpha: 0.32),
          keyboardType: widget.keyboardType,
          inputFormatters: widget.inputFormatters,
          textInputAction: widget.textInputAction,
          onChanged: widget.onChanged,
          onSubmitted: widget.onSubmitted,
          maxLines: 1,
        ),
        // Detrás en el orden de toque —`IgnorePointer`— para que tocar sobre la
        // pista ponga el cursor donde se tocó, como si no estuviera.
        if (_vacio && widget.placeholder != null)
          Positioned.fill(
            child: IgnorePointer(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  widget.placeholder!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: estilo.copyWith(color: colors.oliveInk.withValues(alpha: 0.4)),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Un campo que no se edita escribiendo: abre otra cosa al tocarlo (un
/// buscador, un calendario, una lista de opciones).
class FieldSelector extends StatelessWidget {
  const FieldSelector({super.key, required this.texto, required this.onTap, this.icon});

  final String texto;
  final VoidCallback onTap;
  final AppIconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: FieldBox(
        child: Row(
          children: [
            if (icon != null) ...[
              AppIcon(icon!, size: 16, color: colors.oliveInk.withValues(alpha: 0.6)),
              const SizedBox(width: Spacing.sm),
            ],
            Expanded(
              child: Text(
                texto,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.body(colors.foreground),
              ),
            ),
            AppIcon(
              AppIconData.chevronDown,
              size: 16,
              color: colors.oliveInk.withValues(alpha: 0.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// Una fila de opción dentro de una lista elegible (categoría, cuenta, tipo…).
class FieldOption extends StatelessWidget {
  const FieldOption({
    super.key,
    required this.titulo,
    this.detalle,
    this.subtitulo,
    required this.onTap,
    this.seleccionado = false,
  });

  final String titulo;
  final String? detalle;
  final String? subtitulo;
  final VoidCallback onTap;
  final bool seleccionado;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    titulo,
                    style: AppText.body(
                      colors.foreground,
                    ).copyWith(fontWeight: seleccionado ? FontWeight.w600 : FontWeight.w400),
                  ),
                  if (subtitulo != null)
                    Text(subtitulo!, style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.6))),
                ],
              ),
            ),
            if (detalle != null)
              Text(
                detalle!,
                style: AppText.money(colors.oliveInk.withValues(alpha: 0.6), size: 12.5),
              ),
            if (seleccionado) ...[
              const SizedBox(width: Spacing.sm),
              AppIcon(AppIconData.check, size: 16, color: colors.sageInk),
            ],
          ],
        ),
      ),
    );
  }
}

/// El conmutador de dos o tres opciones (Gasto/Ingreso, Gasto/Ingreso/
/// Transferencia). Genérico sobre `T` para servir a los dos casos sin
/// duplicar el widget.
class FieldSwitch<T> extends StatelessWidget {
  const FieldSwitch({
    super.key,
    required this.opciones,
    required this.valor,
    required this.onChange,
  });

  final List<(String, T)> opciones;
  final T valor;
  final void Function(T) onChange;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: colors.foreground.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(
        children: [
          for (final (etiqueta, v) in opciones)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChange(v),
                child: Container(
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  decoration: BoxDecoration(
                    color: valor == v ? colors.surface : null,
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                  child: Text(
                    etiqueta,
                    textAlign: TextAlign.center,
                    style: AppText.bodyMedium(
                      valor == v ? colors.foreground : colors.oliveInk.withValues(alpha: 0.6),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
