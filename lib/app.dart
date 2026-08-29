import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'design/theme.dart';
import 'design/tokens.dart';
import 'local_api/routes.dart';
import 'local_engine/timezone_util.dart' show inicializarZonas;
import 'screens/onboarding_screen.dart';
import 'screens/shell.dart';
import 'state/providers.dart';
import 'ui/surface.dart';

/// La raíz.
///
/// `WidgetsApp` y no `MaterialApp`: lo único que hace falta de un "App" es el
/// Navigator, la localización y el manejo del teclado. `MaterialApp` además
/// instala el tema de Material, y con él a mano cualquier `showDialog` que
/// alguien agregue mañana se vería nativo y funcionaría — el requisito de que
/// todo feedback sea nuestro se rompería solo, sin que nadie lo note.
class FinancialStrategistApp extends ConsumerWidget {
  const FinancialStrategistApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // El tema sigue al sistema **hasta que el usuario diga otra cosa**. Que
    // arranque siguiéndolo evita preguntar algo que ya está contestado; que se
    // pueda cambiar reconoce que hay quien quiere el teléfono en oscuro y esta
    // app en claro, o al revés.
    final elegido = ref.watch(temaOscuroProvider);
    final oscuro = elegido ?? MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final colors = oscuro ? AppColors.dark : AppColors.light;

    return AppTheme(
      colors: colors,
      child: WidgetsApp(
        title: 'Financial Strategist',
        color: colors.sageDark,
        locale: const Locale('es', 'PE'),
        supportedLocales: const [Locale('es', 'PE'), Locale('es')],
        // El texto por defecto de toda la app. Sin esto, cualquier `Text` sin
        // estilo sale con el subrayado amarillo de depuración de Flutter.
        textStyle: AppText.body(colors.foreground),
        pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) => PageRouteBuilder<T>(
          settings: settings,
          pageBuilder: (context, a, b) => builder(context),
          transitionsBuilder: (context, a, b, child) => FadeTransition(
            opacity: CurvedAnimation(parent: a, curve: Curves.easeOut),
            child: child,
          ),
        ),
        builder: (context, child) => AppBackground(child: child ?? const SizedBox()),
        home: const _Root(),
      ),
    );
  }
}

class _Root extends ConsumerWidget {
  const _Root();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sesion = ref.watch(sessionProvider);
    final faltaOnboarding = ref.watch(needsOnboardingProvider);

    return sesion.when(
      loading: () => const _Splash(),
      // Sin servidor no hay "reintentar la conexión": si algo falló leyendo
      // la base local, la única salida con sentido es la misma que si
      // nunca hubiera habido usuario — el arranque, no una pantalla de
      // error contra la que no hay nada que hacer.
      error: (_, __) => const OnboardingScreen(),
      data: (user) => user == null || faltaOnboarding ? const OnboardingScreen() : const AppShell(),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Center(
      child: Text(
        'Financial Strategist',
        style: AppText.kicker(colors.sageInk.withValues(alpha: 0.7)),
      ),
    );
  }
}

Future<void> bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Los nombres de mes en español salen de acá. Sin esta carga, `DateFormat`
  // con locale 'es' lanza en tiempo de ejecución — y lo hace en la primera
  // pantalla que muestre una fecha, no al arrancar.
  await initializeDateFormatting('es');
  // La base de zonas IANA para `local_engine/timezone_util.dart`. Sin esto,
  // `getLocation` no encuentra ninguna zona y cada cálculo de "inicio del
  // mes" revienta en la primera pantalla que lo pida.
  inicializarZonas();
  // El router local: sin esto, `ApiClient` no tiene a quién despacharle
  // ninguna ruta.
  registerAllRoutes();
}
