import 'package:flutter/widgets.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import 'breakpoints.dart';
import 'buttons.dart';
import 'icons.dart';

/// El único canal de feedback de la app.
///
/// **No hay SnackBar, ni AlertDialog, ni CupertinoAlertDialog en ninguna parte.**
/// Es un requisito del producto y también una decisión defendible: los diálogos
/// del sistema se ven distintos en Android y en iOS, no respetan la paleta, y
/// un SnackBar aparece abajo justo donde está la barra de navegación —tapando
/// el control que el usuario acaba de tocar— y se va solo antes de que alcance a
/// leerlo si estaba mirando otra parte de la pantalla.
///
/// Se construye sobre `PopupRoute` y no sobre `showDialog`. `PopupRoute` es una
/// primitiva de navegación, no un widget con apariencia: da gratis el botón
/// atrás de Android, el gesto de retroceso, y el manejo de foco; todo lo que se
/// ve lo pinta este archivo.
///
/// **Responsive por forma, no por tamaño.** En un teléfono entra desde abajo
/// como hoja —el pulgar llega al borde inferior, no al centro—; en una tablet
/// aparece centrado, porque una hoja de ancho completo en 1000 puntos es una
/// franja absurda. No es la misma caja escalada: son dos gestos distintos.
Future<T?> showAppModal<T>(
  BuildContext context, {
  required String title,
  String? subtitle,
  required WidgetBuilder builder,
  bool dismissible = true,
}) {
  return Navigator.of(context, rootNavigator: true).push<T>(
    _ModalRoute<T>(title: title, subtitle: subtitle, builder: builder, dismissible: dismissible),
  );
}

/// El tono de un mensaje. Decide el color del acento y el ícono, nunca el texto.
enum FeedbackTone { exito, error, aviso }

/// Un mensaje de resultado: "se guardó", "no se pudo", "esto va a borrar algo".
///
/// Sustituye al SnackBar y al diálogo de alerta a la vez. Devuelve `true` si el
/// usuario confirmó, `false`/`null` si cerró — así el mismo componente sirve
/// para avisar y para preguntar, y no hay dos estilos de mensaje en la app.
Future<bool?> showFeedback(
  BuildContext context, {
  required String title,
  String? message,
  FeedbackTone tone = FeedbackTone.exito,
  String confirmLabel = 'Entendido',
  String? cancelLabel,
  bool destructive = false,
}) {
  return showAppModal<bool>(
    context,
    title: title,
    builder: (context) {
      final colors = AppTheme.of(context);
      final accent = switch (tone) {
        FeedbackTone.exito => colors.sage,
        FeedbackTone.error => colors.danger,
        FeedbackTone.aviso => colors.chart[3],
      };

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // El punto de color acompaña al texto, nunca lo sustituye: el tono
              // tiene que entenderse sin distinguir colores.
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(top: 7, right: Spacing.md),
                decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
              ),
              Expanded(
                child: Text(
                  message ?? '',
                  style: AppText.body(colors.foreground.withValues(alpha: 0.8)),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.xl),
          if (cancelLabel == null)
            AppButton(label: confirmLabel, onPressed: () => Navigator.of(context).pop(true))
          else
            Row(
              children: [
                Expanded(
                  child: AppButton(
                    label: cancelLabel,
                    variant: AppButtonVariant.secondary,
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                ),
                const SizedBox(width: Spacing.md),
                Expanded(
                  child: AppButton(
                    label: confirmLabel,
                    variant: destructive ? AppButtonVariant.destructive : AppButtonVariant.primary,
                    onPressed: () => Navigator.of(context).pop(true),
                  ),
                ),
              ],
            ),
        ],
      );
    },
  );
}

class _ModalRoute<T> extends PopupRoute<T> {
  _ModalRoute({
    required this.title,
    required this.subtitle,
    required this.builder,
    required this.dismissible,
  });

  final String title;
  final String? subtitle;
  final WidgetBuilder builder;
  final bool dismissible;

  @override
  Color? get barrierColor => const Color(0x8C0B1620);

  @override
  bool get barrierDismissible => dismissible;

  @override
  String? get barrierLabel => 'Cerrar';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 260);

  @override
  Widget buildPage(BuildContext context, Animation<double> a, Animation<double> b) {
    return _ModalShell(
      title: title,
      subtitle: subtitle,
      dismissible: dismissible,
      child: Builder(builder: builder),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondary,
    Widget child,
  ) {
    final eased = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final ancho = MediaQuery.sizeOf(context).width;

    // En hoja entra desde abajo; centrado, crece un pelo. El mismo contenido con
    // dos entradas distintas porque son dos objetos distintos.
    if (Breakpoints.isCompact(ancho)) {
      return SlideTransition(
        position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(eased),
        child: child,
      );
    }
    return FadeTransition(
      opacity: eased,
      child: ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(eased), child: child),
    );
  }
}

class _ModalShell extends StatelessWidget {
  const _ModalShell({
    required this.title,
    required this.subtitle,
    required this.dismissible,
    required this.child,
  });

  final String title;
  final String? subtitle;
  final bool dismissible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final media = MediaQuery.of(context);
    final compacto = Breakpoints.isCompact(media.size.width);

    final panel = Container(
      decoration: BoxDecoration(
        color: colors.surface,
        // En hoja solo se redondean las esquinas de arriba: las de abajo salen
        // de la pantalla y redondearlas deja dos muescas donde no hay nada.
        borderRadius: compacto
            ? const BorderRadius.vertical(top: Radius.circular(Radii.xl))
            : BorderRadius.circular(Radii.xl),
        border: Border.all(color: colors.surfaceBorder),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (compacto)
            // El asidero. Es la señal de que esto se arrastra hacia abajo, y sin
            // él la hoja parece una pantalla que solo se cierra por el botón.
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(top: Spacing.md),
                decoration: BoxDecoration(
                  color: colors.foreground.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(Radii.pill),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Spacing.xl, Spacing.lg, Spacing.sm, Spacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: AppText.title(colors.foreground)),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: AppText.small(colors.oliveInk.withValues(alpha: 0.75)),
                        ),
                      ],
                    ],
                  ),
                ),
                if (dismissible)
                  IconTapTarget(
                    semanticLabel: 'Cerrar',
                    onTap: () => Navigator.of(context).maybePop(),
                    child: AppIcon(
                      AppIconData.close,
                      size: 20,
                      color: colors.foreground.withValues(alpha: 0.55),
                    ),
                  ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                Spacing.xl,
                0,
                Spacing.xl,
                // El teclado y la zona segura de abajo se suman: sin esto el
                // último campo queda debajo del teclado y no hay forma de verlo.
                Spacing.xl + media.viewInsets.bottom + (compacto ? media.padding.bottom : 0),
              ),
              child: child,
            ),
          ),
        ],
      ),
    );

    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      label: title,
      child: compacto
          ? Align(alignment: Alignment.bottomCenter, child: panel)
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(Spacing.xxl),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: panel,
                ),
              ),
            ),
    );
  }
}
