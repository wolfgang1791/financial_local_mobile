import 'package:flutter/widgets.dart';

import '../design/theme.dart';
import '../design/tokens.dart';

enum AppButtonVariant { primary, secondary, destructive }

/// El botón de la app.
///
/// Propio y no `ElevatedButton`/`CupertinoButton` por la misma razón que los
/// modales: esos traen la apariencia de su plataforma, y el mismo botón se
/// vería distinto en Android y en iOS. Acá el producto se ve igual en los dos y
/// el estado presionado es una opacidad, no un `ripple` de Material.
class AppButton extends StatefulWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = AppButtonVariant.primary,
    this.busy = false,
    this.icon,
  });

  final String label;

  /// `null` deshabilita. Un botón deshabilitado se queda a la vista, apagado:
  /// esconderlo haría desaparecer la acción sin explicar por qué.
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final bool busy;
  final IconData? icon;

  @override
  State<AppButton> createState() => _AppButtonState();
}

class _AppButtonState extends State<AppButton> {
  bool _presionado = false;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final habilitado = widget.onPressed != null && !widget.busy;

    final (fondo, texto, borde) = switch (widget.variant) {
      AppButtonVariant.primary => (colors.sageDark, const Color(0xFFFFFFFF), null),
      AppButtonVariant.secondary => (
        const Color(0x00000000),
        colors.foreground,
        colors.surfaceBorder,
      ),
      AppButtonVariant.destructive => (colors.danger, const Color(0xFFFFFFFF), null),
    };

    return Semantics(
      button: true,
      enabled: habilitado,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: habilitado ? (_) => setState(() => _presionado = true) : null,
        onTapUp: habilitado ? (_) => setState(() => _presionado = false) : null,
        onTapCancel: habilitado ? () => setState(() => _presionado = false) : null,
        onTap: habilitado ? widget.onPressed : null,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: !habilitado ? 0.45 : (_presionado ? 0.7 : 1),
          child: Container(
            // 48 de alto: por encima del mínimo táctil y cómodo con el pulgar.
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: Spacing.xl),
            decoration: BoxDecoration(
              color: fondo,
              borderRadius: BorderRadius.circular(Radii.pill),
              border: borde == null ? null : Border.all(color: borde),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, size: 18, color: texto),
                  const SizedBox(width: Spacing.sm),
                ],
                Flexible(
                  child: Text(
                    widget.busy ? 'Un momento…' : widget.label,
                    textAlign: TextAlign.center,
                    style: AppText.bodyMedium(texto),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
