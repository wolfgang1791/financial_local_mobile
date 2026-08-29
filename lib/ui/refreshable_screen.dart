import 'dart:async';

import 'package:flutter/widgets.dart';

import '../design/tokens.dart';
import 'breakpoints.dart';

/// Si la pantalla que hay debajo es la que se está mirando.
///
/// El armazón mantiene las seis pantallas vivas dentro de un `IndexedStack`
/// —para no perder el scroll ni volver a construirlas al cambiar de pestaña—, y
/// por eso ninguna se entera sola de que volvió al frente: su `initState` corrió
/// una sola vez, al arrancar la app. Esto es lo que se lo cuenta.
class ScreenVisibility extends InheritedWidget {
  const ScreenVisibility({super.key, required this.visible, required super.child});

  final bool visible;

  /// Sin armazón alrededor —una pantalla empujada como ruta, como el
  /// historial— la respuesta es que sí: si está construida, está al frente.
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ScreenVisibility>()?.visible ?? true;

  @override
  bool updateShouldNotify(ScreenVisibility old) => old.visible != visible;
}

/// El armazón de scroll de una pantalla, con el refresco de entrada.
///
/// Cada vez que la pantalla vuelve al frente se vuelven a pedir sus datos y el
/// contenido entra con un fundido corto. Las dos mitades son una sola cosa: sin
/// el fundido, un refresco que devuelve lo mismo no se ve —la pantalla parece
/// congelada y uno duda de si se actualizó—; sin el refresco, el fundido sería
/// una animación que miente.
///
/// La primera vez que una pantalla aparece no se invalida nada: sus providers
/// acaban de cargar al construirse, y pedirlo de nuevo sería el mismo viaje a la
/// base dos veces seguidas. La animación sí corre, porque ahí también se está
/// entrando.
class RefreshableScreen extends StatefulWidget {
  const RefreshableScreen({super.key, required this.children, required this.onRefresh});

  final List<Widget> children;
  final Future<void> Function() onRefresh;

  @override
  State<RefreshableScreen> createState() => _RefreshableScreenState();
}

class _RefreshableScreenState extends State<RefreshableScreen> with SingleTickerProviderStateMixin {
  // Arranca en 1 —sin animación pendiente— porque una pantalla que todavía no
  // entró no debe quedar invisible esperando un fotograma.
  late final AnimationController _entrada = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    value: 1,
  );

  /// Lo último que dijo `ScreenVisibility`. `didChangeDependencies` también
  /// corre por un cambio de tema o de tamaño de pantalla, y sin comparar contra
  /// esto cada uno de esos dispararía un refresco que nadie pidió.
  bool _alFrente = false;

  /// Si esta es la primera vez que se resuelven las dependencias. Distingue
  /// "apareció al arrancar" de "volviste a ella", que es lo que decide si hay
  /// que pedir los datos de nuevo o no.
  bool _primeraVez = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final alFrente = ScreenVisibility.of(context);
    final entrando = alFrente && !_alFrente;
    final primera = _primeraVez;
    _alFrente = alFrente;
    _primeraVez = false;

    if (!entrando) return;
    // `ignore` y no `await`: el refresco es del contenido, no de la animación —
    // esperarlo dejaría la pantalla en negro hasta que la base conteste. Cada
    // `onRefresh` maneja su propio error; lo que no se puede es dejar el futuro
    // suelto y que un fallo tumbe la zona.
    if (!primera) widget.onRefresh().ignore();
    _entrada.forward(from: 0);
  }

  @override
  void dispose() {
    _entrada.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) => Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: Breakpoints.contentWidth(c.maxWidth)),
          child: AnimatedBuilder(
            animation: _entrada,
            // El contenido se construye una vez y la animación solo lo envuelve:
            // sin esto, cada fotograma reconstruiría la lista entera.
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    Spacing.xl,
                    Spacing.xxl,
                    Spacing.xl,
                    Spacing.section,
                  ),
                  sliver: SliverList.list(children: widget.children),
                ),
              ],
            ),
            builder: (context, child) {
              // En reposo no se paga ni la capa de opacidad ni la traslación:
              // `Opacity` fuerza una capa de composición y el scroll es lo que
              // más se toca de la app.
              if (_entrada.value == 1) return child!;
              final t = Curves.easeOut.transform(_entrada.value);
              return Opacity(
                // No arranca de cero: un parpadeo a blanco se lee como un error
                // de dibujo, y el gesto que se quiere es "esto se acaba de
                // volver a poner", no "esto desapareció y volvió".
                opacity: 0.2 + 0.8 * t,
                child: Transform.translate(offset: Offset(0, 12 * (1 - t)), child: child),
              );
            },
          ),
        ),
      ),
    );
  }
}
