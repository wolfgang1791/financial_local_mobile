import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/allocation.dart';
import '../data/api.dart';
import '../data/preferencias.dart';
import '../data/models.dart';

final apiProvider = Provider<ApiClient>((ref) => ApiClient());

/// Si a quien está dentro todavía le falta el arranque (moneda + saldo
/// inicial). Vive aparte de [sessionProvider] y no como un campo de
/// [AppUser] porque no es un dato del usuario: es un paso pendiente, y
/// `_Root` necesita poder cambiarlo sin tener que reconstruir la sesión
/// entera cuando el onboarding termina.
final needsOnboardingProvider = StateProvider<bool>((ref) => false);

/// Tapar las cifras de la tarjeta.
///
/// Es para mirar el teléfono con alguien al lado: el patrimonio, lo que entró,
/// lo que salió y el saldo de cada cuenta son justo lo que uno no quiere que se
/// lea de reojo. No es seguridad —quien tenga el teléfono lo destapa con un
/// toque— es privacidad de vitrina, que es un problema distinto y mucho más
/// frecuente.
///
/// Un provider y no estado de pantalla porque lo comparten todas las tarjetas
/// de la app: tapar en Panorama y que Movimientos siga mostrando todo sería
/// peor que no tener el interruptor. Y se guarda, porque dejarlo tapado y
/// encontrarlo destapado mañana lo volvería inútil.
class SaldosOcultos extends Notifier<bool> {
  /// Si el usuario ya decidió en esta sesión.
  ///
  /// Lo guardado se lee del archivo, que es lento, y en ese rato el usuario
  /// puede haber tocado el ojito: sin esta bandera la lectura llegaba tarde y
  /// **pisaba** su decisión — tapabas la tarjeta y se destapaba sola medio
  /// segundo después.
  bool _decidido = false;

  /// Si el provider sigue vivo. La lectura del archivo puede terminar después
  /// de que se descarte —pasa en los tests, donde cada caso arma el suyo— y
  /// escribir el estado de un notifier muerto revienta.
  bool _vivo = true;

  @override
  bool build() {
    ref.onDispose(() => _vivo = false);
    // Arranca a la vista y se corrige al leer el archivo: es un fotograma
    // destapado, no un parpadeo al revés — mostrar de más por un instante es
    // preferible a tapar lo que el usuario nunca pidió tapar.
    _cargar();
    return false;
  }

  Future<void> _cargar() async {
    final prefs = await Preferencias.abrir();
    if (!_vivo || _decidido) return;
    final guardado = prefs.bandera(claveSaldosOcultos);
    if (guardado != state) state = guardado;
  }

  Future<void> alternar() async {
    _decidido = true;
    state = !state;
    final prefs = await Preferencias.abrir();
    await prefs.guardarBandera(claveSaldosOcultos, state);
  }
}

final saldosOcultosProvider = NotifierProvider<SaldosOcultos, bool>(SaldosOcultos.new);

/// Si la tarjeta de "te falta pagar este mes" está desplegada.
///
/// Es la más alta de Panorama —cinco filas— y hay meses en que ya sabes lo que
/// dice y solo estorba para llegar a lo de abajo. Se recuerda entre visitas: una
/// preferencia que se olvida al abrir la app no es una preferencia, y el usuario
/// deja de tocarla.
///
/// Arranca desplegada y se corrige al leer el archivo, igual que el ojo: mostrar
/// de más por un fotograma es preferible a plegar lo que nadie pidió plegar.
class PendienteAbierto extends Notifier<bool> {
  bool _decidido = false;
  bool _vivo = true;

  @override
  bool build() {
    ref.onDispose(() => _vivo = false);
    _cargar();
    return true;
  }

  Future<void> _cargar() async {
    final prefs = await Preferencias.abrir();
    if (!_vivo || _decidido) return;
    final guardado = prefs.banderaOpcional(clavePendienteAbierto);
    if (guardado != null && guardado != state) state = guardado;
  }

  Future<void> alternar() async {
    _decidido = true;
    state = !state;
    final prefs = await Preferencias.abrir();
    await prefs.guardarBandera(clavePendienteAbierto, state);
  }
}

final pendienteAbiertoProvider = NotifierProvider<PendienteAbierto, bool>(PendienteAbierto.new);

/// El tema: `null` sigue al sistema, `true` oscuro, `false` claro.
///
/// Arranca siguiendo al teléfono —el usuario ya eligió una vez en sus ajustes y
/// volver a preguntárselo es duplicar una decisión— pero en cuanto toca el
/// interruptor manda él: hay quien tiene el sistema en oscuro y quiere esta app
/// en claro, y decirle que su elección vale menos que la del sistema es una
/// discusión que la app no puede ganar.
class TemaOscuro extends Notifier<bool?> {
  bool _decidido = false;
  bool _vivo = true;

  @override
  bool? build() {
    ref.onDispose(() => _vivo = false);
    _cargar();
    return null;
  }

  Future<void> _cargar() async {
    final prefs = await Preferencias.abrir();
    if (!_vivo || _decidido) return;
    final guardado = prefs.banderaOpcional(claveTemaOscuro);
    if (guardado != state) state = guardado;
  }

  /// Fija el tema, o lo devuelve al del sistema con `null`.
  Future<void> fijar(bool? oscuro) async {
    _decidido = true;
    state = oscuro;
    final prefs = await Preferencias.abrir();
    await prefs.guardarBanderaOpcional(claveTemaOscuro, oscuro);
  }
}

final temaOscuroProvider = NotifierProvider<TemaOscuro, bool?>(TemaOscuro.new);

/// Quién está dentro. `null` solo si la base local no trae ningún usuario
/// sembrado — no debería pasar con el seed de fábrica, pero `_Root` sabe
/// mandar a onboarding si algún día se arranca desde una base vacía.
///
/// Sigue siendo un `AsyncNotifier` (no un valor plano) porque abrir la base
/// y leer la fila es async, y el primer cuadro necesita un estado de
/// "todavía cargando" antes de tener datos — no porque haya login que
/// esperar: acá no hay red, ni token, ni otra cuenta a la que entrar.
class SessionNotifier extends AsyncNotifier<AppUser?> {
  @override
  Future<AppUser?> build() async {
    final r = await ref.read(apiProvider).currentUser();
    if (r == null) return null;
    ref.read(needsOnboardingProvider.notifier).state = (r['needsOnboarding'] as bool?) ?? false;
    return AppUser.fromJson(r['user'] as Map<String, dynamic>);
  }

  /// Sin sesión que cerrar de verdad: solo relee la misma fila. Se mantiene
  /// el método porque el menú de cuenta del shell lo llama, y no tiene
  /// sentido tocar esa pantalla por algo que acá no cambia nada.
  Future<void> signOut() async {
    ref.invalidateSelf();
    await future;
  }
}

final sessionProvider = AsyncNotifierProvider<SessionNotifier, AppUser?>(SessionNotifier.new);

/// El usuario, ya resuelto. Solo se usa dentro del shell, donde por definición
/// hay sesión — de ahí el `!`.
final userProvider = Provider<AppUser>((ref) => ref.watch(sessionProvider).requireValue!);

// ── Datos de pantalla ─────────────────────────
//
// Cada uno es un `FutureProvider` independiente y no un objeto gordo con todo:
// así Movimientos no espera a que cargue Panorama, y refrescar una cosa no
// vuelve a pedir las otras cuatro.
//
// Los de recomendaciones, informes de cierre, chat, objetivos y "cuánto puedo
// gastar hoy" se fueron con su backend: esa capa la va a hacer el agente. Un
// provider que apunta a una ruta que ya no existe no es inofensivo — el clon
// local responde 501 y la pantalla lo traga con un `orElse`, así que la sección
// desaparece sin decir nada.

final cashPositionProvider = FutureProvider<CashPosition>((ref) async {
  final r = await ref.watch(apiProvider).get('/financial-engine/cash-position');
  return CashPosition.fromJson(r as Map<String, dynamic>);
});

/// El periodo que se está mirando en Panorama.
///
/// Vive fuera de la pantalla para que cambiarlo no se pierda al ir a Decisiones
/// y volver — el `IndexedStack` conserva el widget, pero un estado local se
/// perdería si algún día la pantalla se reconstruye.
final periodoProvider = StateProvider<PeriodoElegido>(
  (ref) => const PeriodoElegido.relativo(Periodo.mes),
);

/// Los periodos que se ofrecen: los relativos que aportan algo, más los meses
/// cerrados que existen en la historia.
final periodosProvider = Provider<List<PeriodoElegido>>((ref) {
  final meses = ref.watch(netWorthMonthlyProvider).valueOrNull ?? const [];
  return periodosOfrecidos(
    ref.watch(primerRegistroProvider),
    DateTime.now(),
    mesesCerrados: meses.where((p) => !p.enCurso).map((p) => p.etiqueta).toList(),
  );
});

/// Todos los movimientos del periodo: los dos tipos y las cuatro naturalezas.
///
/// Uno solo y no dos consultas. El anillo de categorías quiere solo los gastos
/// corrientes y el reparto quiere absolutamente todo, pero pedirlos por separado
/// serían dos viajes por el mismo rango — y, peor, dos conjuntos que pueden
/// diferir si algo se registra entre una llamada y la otra.
final periodTransactionsProvider = FutureProvider<List<Transaction>>((ref) async {
  final periodo = ref.watch(periodoProvider);
  final (desde, hasta) = periodo.rango(DateTime.now());
  final r = await ref.watch(apiProvider).get('/transactions?take=1000');
  final items = (r is Map ? r['items'] : r) as List;
  return items.map((e) => Transaction.fromJson(e as Map<String, dynamic>)).where((t) {
    final cuando = t.occurredAt.toLocal();
    // El extremo derecho es exclusivo: un mes cerrado va del día 1 al 1 del
    // siguiente sin incluirlo, o el último movimiento del mes caería en dos.
    return !cuando.isBefore(desde) && cuando.isBefore(hasta);
  }).toList();
});

/// Solo el gasto corriente del periodo, para el anillo de categorías.
///
/// Derivado del anterior, no pedido aparte: así el anillo y el reparto hablan
/// exactamente del mismo conjunto de movimientos.
final periodExpensesProvider = Provider<AsyncValue<List<Transaction>>>((ref) {
  return ref
      .watch(periodTransactionsProvider)
      .whenData((todos) => todos.where((t) => t.isExpense && t.kind == 'MOVEMENT').toList());
});

/// El gasto mes a mes, con sus tres piezas. Como la curva de patrimonio, no lo
/// recorta el periodo elegido: su gracia es ver los meses juntos.
final spendingHistoryProvider = FutureProvider<List<SpendingPoint>>((ref) async {
  final r = await ref.watch(apiProvider).get('/financial-engine/spending-history') as List;
  return r.map((e) => SpendingPoint.fromJson((e as Map).cast<String, dynamic>())).toList();
});

final netWorthMonthlyProvider = FutureProvider<List<NetWorthPoint>>((ref) async {
  final r = await ref.watch(apiProvider).get('/financial-engine/net-worth-history') as List;
  return r.map((e) => NetWorthPoint.mensual(e as Map<String, dynamic>)).toList();
});

/// La deuda mes a mes. Como la curva de patrimonio, no la recorta el periodo
/// elegido: su gracia es ver los meses juntos.
final debtHistoryProvider = FutureProvider<List<DebtHistorySeries>>((ref) async {
  final r = await ref.watch(apiProvider).get('/debts/history') as List;
  return r.map((e) => DebtHistorySeries.fromJson(e as Map<String, dynamic>)).toList();
});

/// Desde cuándo hay historia.
///
/// Decide qué pastillas de periodo tiene sentido ofrecer: con un mes de datos,
/// "1 año" y "5 años" muestran lo mismo que "6 meses". Sale de la serie diaria
/// —su primer punto es el primer día con registro— en vez de una consulta
/// aparte, porque esa serie ya se pide para el gráfico.
final primerRegistroProvider = Provider<DateTime?>((ref) {
  final serie = ref.watch(netWorthDailyProvider).valueOrNull;
  if (serie == null || serie.isEmpty) return null;
  return DateTime.tryParse(serie.first.etiqueta);
});

final netWorthDailyProvider = FutureProvider<List<NetWorthPoint>>((ref) async {
  final r = await ref.watch(apiProvider).get('/financial-engine/net-worth-daily') as List;
  return r.map((e) => NetWorthPoint.diario(e as Map<String, dynamic>)).toList();
});

final recurringFlowsProvider = FutureProvider<List<RecurringFlow>>((ref) async {
  final r = await ref.watch(apiProvider).get('/recurring-flows') as List;
  return r.map((e) => RecurringFlow.fromJson(e as Map<String, dynamic>)).toList();
});

final debtsProvider = FutureProvider<List<Debt>>((ref) async {
  final r = await ref.watch(apiProvider).get('/debts') as List;
  return r.map((e) => Debt.fromJson(e as Map<String, dynamic>)).toList();
});

/// Las categorías de gasto que este usuario usa, para revisar cuáles
/// sobreviven a un corte de ingresos.
final categoriesForEssentialReviewProvider = FutureProvider<List<Category>>((ref) async {
  final r = await ref.watch(apiProvider).get('/categories/revision-esenciales') as List;
  return r.map((e) => Category.fromJson(e as Map<String, dynamic>)).toList();
});

/// Los movimientos recientes, sin recortar por periodo.
///
/// Es la lista de "qué pasó últimamente" de la pantalla de Movimientos, distinta
/// de la de Panorama: aquella responde "en qué se fue el mes" y esta "qué
/// registré". Por eso no comparten proveedor aunque salgan del mismo endpoint.
final recentTransactionsProvider = FutureProvider<List<Transaction>>((ref) async {
  final r = await ref.watch(apiProvider).get('/transactions?take=40');
  final items = (r is Map ? r['items'] : r) as List;
  return items.map((e) => Transaction.fromJson(e as Map<String, dynamic>)).toList();
});

/// Las cuentas donde se puede registrar un movimiento.
///
/// Las ocultas quedan fuera: el usuario decidió que esa plata no cuenta, y
/// ofrecerlas para registrar un gasto contradice esa decisión — el movimiento
/// entraría en una cuenta que después no suma en ningún total.
/// Todas las cuentas del usuario, **incluidas las que no cuentan**.
///
/// Se listaban solo las visibles, y eso convertía "no la sumes a mi patrimonio"
/// en "no existe": no se podía registrar un movimiento en ella, ni recibir ahí
/// un ingreso fijo, ni transferirle plata. La cuenta seguía teniendo saldo y
/// moviéndose en el banco de verdad; lo único que el usuario pidió fue no
/// contarla.
///
/// Y se llevaba por delante cosas que no tienen que ver: con una sola cuenta
/// visible desaparecía la pastilla de "Transferir" —hacen falta dos— aunque
/// hubiera tres cuentas.
///
/// Las pantallas ya saben decirlo: cada selector muestra "no cuenta en tu
/// patrimonio" debajo del nombre, así que se ofrece sin sorpresa.
final accountsProvider = FutureProvider<List<Account>>((ref) async {
  final r = await ref.watch(apiProvider).get('/accounts') as List;
  return r.map((e) => Account.fromJson(e as Map<String, dynamic>)).toList();
});

/// El catálogo completo de categorías.
///
/// Todas, no solo las usadas: al registrar un gasto lo más común es estrenar
/// una categoría, y ofrecer solo las que ya tienen movimientos deja fuera
/// justamente la que hace falta. Es el mismo arreglo que se hizo en la web.
final categoriesProvider = FutureProvider<List<Category>>((ref) async {
  final r = await ref.watch(apiProvider).get('/categories') as List;
  return r.map((e) => Category.fromJson(e as Map<String, dynamic>)).toList();
});

/// Las monedas que el backend conoce, para el selector del onboarding y de
/// las deudas.
final currenciesProvider = FutureProvider<List<Currency>>((ref) async {
  final r = await ref.watch(apiProvider).get('/currencies') as List;
  return r.map((e) => Currency.fromJson(e as Map<String, dynamic>)).toList();
});

/// Las cotizaciones del día, para convertir deudas en otra moneda.
final exchangeRatesProvider = FutureProvider<List<ExchangeRate>>((ref) async {
  final r = await ref.watch(apiProvider).get('/currencies/rates') as List;
  return r.map((e) => ExchangeRate.fromJson(e as Map<String, dynamic>)).toList();
});

/// Los tipos de deuda: qué campos tiene sentido pedir para cada uno.
final debtKindsProvider = FutureProvider<List<DebtKind>>((ref) async {
  final r = await ref.watch(apiProvider).get('/debts/kinds') as List;
  return r.map((e) => DebtKind.fromJson(e as Map<String, dynamic>)).toList();
});
