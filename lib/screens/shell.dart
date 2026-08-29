import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import '../state/providers.dart';
import '../ui/breakpoints.dart';
import '../ui/icons.dart';
import '../ui/modal.dart';
import '../ui/refreshable_screen.dart';
import 'decisiones_screen.dart';
import 'deudas_screen.dart';
import 'diagnostico_screen.dart';
import 'movimientos_screen.dart';
import 'objetivos_screen.dart';
import 'panorama_screen.dart';
import 'simulador_screen.dart';

typedef _Destino = ({String label, AppIconData icon, Widget screen});

/// Qué pestaña está abierta.
///
/// En un provider y no en el estado del armazón porque una pantalla puede
/// mandar a otra: Panorama enlaza a Deudas —"mira cómo viene bajando"— y ese
/// enlace tiene que cambiar la pestaña, no apilar una copia de Deudas encima con
/// su propio scroll y sin la barra marcando dónde estás.
/// Se abre en Panorama, no en la primera pestaña.
///
/// Lo primero que se ve al entrar tiene que responder algo: Panorama dice cómo
/// vas. Decisiones es por ahora un marcador —esa capa la va a hacer el agente— y
/// aterrizar en un "próximamente" es abrir la app y que no te diga nada.
final seccionProvider = StateProvider<int>((ref) => indiceDe('Panorama'));

/// El índice de una pestaña por su nombre, para no escribir números sueltos: si
/// mañana se agrega un destino en medio, "3" apuntaría a otra pantalla.
int indiceDe(String label) => _destinos.indexWhere((d) => d.label == label);

const _destinos = <_Destino>[
  (label: 'Decisiones', icon: AppIconData.compass, screen: DecisionesScreen()),
  (label: 'Panorama', icon: AppIconData.chart, screen: PanoramaScreen()),
  (label: 'Movimientos', icon: AppIconData.wallet, screen: MovimientosScreen()),
  (label: 'Deudas', icon: AppIconData.card, screen: DeudasScreen()),
  (label: 'Objetivos', icon: AppIconData.target, screen: ObjetivosScreen()),
  (label: 'Simulador', icon: AppIconData.calculator, screen: SimuladorScreen()),
];

/// El armazón: navegación más la pantalla activa.
///
/// **La barra es propia, no `BottomNavigationBar` ni `CupertinoTabBar`.** Las dos
/// traen su apariencia de plataforma —altura, tipografía, el rebote del ícono— y
/// la app se vería como dos apps distintas según el teléfono.
///
/// Y cambia de lado según el ancho: abajo en un teléfono, donde el pulgar llega;
/// al costado en una tablet, donde una barra inferior de 1000 puntos de ancho
/// deja los destinos lejísimos unos de otros y desperdicia el alto, que es lo que
/// escasea al leer listas.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  @override
  Widget build(BuildContext context) {
    final indice = ref.watch(seccionProvider);
    final ancho = MediaQuery.sizeOf(context).width;
    final lateral = !Breakpoints.isCompact(ancho);

    // `IndexedStack` y no un `switch`: cambiar de pestaña no debe reconstruir la
    // pantalla ni perder su scroll. Con un switch, volver a Decisiones la arma
    // de cero y aterriza arriba del todo.
    //
    // Los datos sí se vuelven a pedir, pero eso lo hace `RefreshableScreen` al
    // enterarse por `ScreenVisibility` de que volvió al frente: la pantalla
    // conserva dónde estabas y a la vez muestra lo último. Sin este aviso no se
    // enteraría nunca, porque dentro del `IndexedStack` sigue construida.
    final contenido = IndexedStack(
      index: indice,
      children: [
        for (var i = 0; i < _destinos.length; i++)
          ScreenVisibility(visible: i == indice, child: _destinos[i].screen),
      ],
    );

    if (lateral) {
      return SafeArea(
        child: Row(
          children: [
            _BarraLateral(
              indice: indice,
              onSelect: (i) => ref.read(seccionProvider.notifier).state = i,
            ),
            Expanded(child: contenido),
          ],
        ),
      );
    }

    return Column(
      children: [
        Expanded(child: SafeArea(bottom: false, child: contenido)),
        _BarraInferior(
          indice: indice,
          onSelect: (i) => ref.read(seccionProvider.notifier).state = i,
        ),
      ],
    );
  }
}

class _BarraInferior extends StatelessWidget {
  const _BarraInferior({required this.indice, required this.onSelect});

  final int indice;
  final void Function(int) onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final padding = MediaQuery.paddingOf(context);

    return Container(
      // El padding inferior del sistema se suma al propio: en un iPhone con
      // gesto de inicio, sin esto los destinos quedan debajo de la barra blanca.
      padding: EdgeInsets.only(
        top: Spacing.sm,
        bottom: Spacing.sm + padding.bottom,
        left: Spacing.sm,
        right: Spacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.96),
        border: Border(top: BorderSide(color: colors.surfaceBorder)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < _destinos.length; i++)
            Expanded(
              child: _DestinoTile(
                destino: _destinos[i],
                activo: i == indice,
                vertical: true,
                onTap: () => onSelect(i),
              ),
            ),
        ],
      ),
    );
  }
}

class _BarraLateral extends StatelessWidget {
  const _BarraLateral({required this.indice, required this.onSelect});

  final int indice;
  final void Function(int) onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Container(
      width: 92,
      padding: const EdgeInsets.symmetric(vertical: Spacing.lg),
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: colors.surfaceBorder)),
      ),
      child: Column(
        children: [
          for (var i = 0; i < _destinos.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.sm),
              child: _DestinoTile(
                destino: _destinos[i],
                activo: i == indice,
                vertical: true,
                onTap: () => onSelect(i),
              ),
            ),
        ],
      ),
    );
  }
}

class _DestinoTile extends StatelessWidget {
  const _DestinoTile({
    required this.destino,
    required this.activo,
    required this.vertical,
    required this.onTap,
  });

  final _Destino destino;
  final bool activo;
  final bool vertical;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final color = activo ? colors.sageInk : colors.oliveInk.withValues(alpha: 0.55);

    return Semantics(
      button: true,
      selected: activo,
      label: destino.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          // 56 de alto: el destino entero es tocable, no solo el ícono.
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(destino.icon, size: 22, color: color),
              const SizedBox(height: 4),
              Text(
                destino.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.tiny(
                  color,
                ).copyWith(fontWeight: activo ? FontWeight.w600 : FontWeight.w400),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// El encabezado de una pantalla: saludo, título y la acción de salir.
class ScreenHeader extends ConsumerWidget {
  const ScreenHeader({
    super.key,
    required this.kicker,
    required this.title,
    this.subtitle,
    this.action,
  });

  final String kicker;
  final String title;
  final String? subtitle;

  /// La acción propia de la pantalla —agregar una deuda, una meta—, si la hay.
  ///
  /// Va acá dentro y no al lado del encabezado, que es como estaba: puesta
  /// afuera quedaba *después* del avatar de la cuenta, y el avatar dejaba de
  /// estar pegado al borde derecho. Es el único elemento que aparece en las seis
  /// pantallas siempre en el mismo sitio; que se corriera 36 puntos hacia
  /// adentro en dos de ellas era justo lo que hacía ver el botón fuera de lugar.
  /// De paso el subtítulo recupera el ancho completo, que también se perdía al
  /// meter el encabezado en un `Expanded`.
  final Widget? action;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    kicker.toUpperCase(),
                    style: AppText.kicker(colors.sageInk.withValues(alpha: 0.8)),
                  ),
                  const SizedBox(height: 4),
                  Text(title, style: AppText.display(colors.foreground).copyWith(fontSize: 26)),
                ],
              ),
            ),
            if (action != null) ...[action!, const SizedBox(width: Spacing.sm)],
            const _CuentaMenu(),
          ],
        ),
        if (subtitle != null) ...[
          const SizedBox(height: Spacing.sm),
          Text(subtitle!, style: AppText.body(colors.oliveInk.withValues(alpha: 0.8))),
        ],
      ],
    );
  }
}

/// El avatar con la salida. Vive en cada `ScreenHeader` y no en una barra
/// fija: la app no tiene barra superior propia, y duplicar el botón en cinco
/// pantallas es más simple que inventar un armazón nuevo solo para esto.
class _CuentaMenu extends ConsumerWidget {
  const _CuentaMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppTheme.of(context);
    final user = ref.watch(userProvider);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        final accion = await showAppModal<String>(
          context,
          title: user.name.isEmpty ? user.email : user.name,
          subtitle: user.email,
          builder: (context) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // El tema, acá y no en una pantalla de ajustes que no existe:
              // este menú ya es "lo tuyo", y es el único sitio de la app que
              // habla de ti y no de tu plata.
              const _InterruptorDeTema(),
              const SizedBox(height: Spacing.sm),
              // Debajo del tema y encima de salir: es lo que se busca cuando
              // algo no cuadra, y no se toca ningún otro día.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).pop('diagnostico'),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 48),
                  alignment: Alignment.centerLeft,
                  child: Text('Diagnóstico', style: AppText.body(colors.foreground)),
                ),
              ),
              const SizedBox(height: Spacing.sm),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).pop('salir'),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 48),
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Cerrar sesión',
                    style: AppText.body(colors.danger).copyWith(fontWeight: FontWeight.w500),
                  ),
                ),
              ),
            ],
          ),
        );
        if (accion == 'salir') {
          await ref.read(sessionProvider.notifier).signOut();
        } else if (accion == 'diagnostico' && context.mounted) {
          await Navigator.of(
            context,
          ).push(PageRouteBuilder<void>(pageBuilder: (context, a, b) => const DiagnosticoScreen()));
        }
      },
      child: Semantics(
        button: true,
        label: 'Tu cuenta',
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colors.sage.withValues(alpha: 0.16),
            shape: BoxShape.circle,
          ),
          child: Text(
            (user.name.isNotEmpty ? user.name : user.email).characters.first.toUpperCase(),
            style: AppText.bodyMedium(colors.sageInk),
          ),
        ),
      ),
    );
  }
}

/// Prender y apagar el modo oscuro, dentro del menú de la cuenta.
///
/// Es un `ConsumerWidget` aparte y no parte del menú para que al tocarlo se
/// redibuje **él** y no todo el modal: el cambio de tema se ve al instante
/// detrás del modal, que es justo la confirmación de que hizo algo.
class _InterruptorDeTema extends ConsumerWidget {
  const _InterruptorDeTema();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppTheme.of(context);
    final elegido = ref.watch(temaOscuroProvider);
    final delSistema = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final oscuro = elegido ?? delSistema;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => ref.read(temaOscuroProvider.notifier).fijar(!oscuro),
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(
          children: [
            AppIcon(
              oscuro ? AppIconData.moon : AppIconData.sun,
              size: 18,
              color: colors.foreground,
            ),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Modo oscuro', style: AppText.body(colors.foreground)),
                  // Se dice de dónde sale mientras nadie lo haya tocado: un
                  // interruptor que ya está prendido sin que lo prendieras se
                  // lee como un error hasta que se explica.
                  if (elegido == null)
                    Text(
                      'Siguiendo a tu teléfono',
                      style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.7)),
                    ),
                ],
              ),
            ),
            _Palanca(encendida: oscuro),
          ],
        ),
      ),
    );
  }
}

/// La palanca del interruptor. Dibujada a mano como el resto: la de Material
/// traería su propio tema y su propia animación, que es justo lo que el resto
/// de la app evita.
class _Palanca extends StatelessWidget {
  const _Palanca({required this.encendida});

  final bool encendida;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      width: 44,
      height: 26,
      padding: const EdgeInsets.all(3),
      alignment: encendida ? Alignment.centerRight : Alignment.centerLeft,
      decoration: BoxDecoration(
        color: encendida ? colors.sage : colors.foreground.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Container(
        width: 20,
        height: 20,
        decoration: const BoxDecoration(color: Color(0xFFFFFFFF), shape: BoxShape.circle),
      ),
    );
  }
}
