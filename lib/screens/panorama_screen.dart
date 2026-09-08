import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../data/allocation.dart';
import '../data/export.dart';
import '../data/models.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../state/providers.dart';
import 'historial_screen.dart';
import '../local_engine/ledger.dart' show round2;
import '../local_engine/pendiente_del_mes.dart';
import '../local_engine/spending_days.dart';
import '../ui/donut_chart.dart';
import '../ui/expense_rows.dart';
import '../ui/fields.dart';
import '../ui/format.dart';
import '../ui/icons.dart';
import '../ui/modal.dart';
import '../ui/spending_days_chart.dart';
import '../ui/net_worth_chart.dart';
import '../ui/refreshable_screen.dart';
import '../ui/todo_oculto.dart';
import '../ui/surface.dart';
import 'shell.dart';

/// Panorama: la misma lectura que la web, en el orden de la web.
///
///   1. El periodo que se está mirando.
///   2. El patrimonio de hoy.
///   3. En qué se fue, por categoría (el anillo con el ojito).
///   4. Los gastos más grandes.
///   5. Dónde terminó el dinero (el reparto, que cierra contra el patrimonio).
///   6. La evolución en el tiempo.
///
/// El orden no es decorativo: se responde "cuánto tengo", después "en qué se
/// fue", después "de dónde salió todo", y al final "cómo vengo". Cada una se
/// apoya en la anterior.
class PanoramaScreen extends ConsumerStatefulWidget {
  const PanoramaScreen({super.key});

  @override
  ConsumerState<PanoramaScreen> createState() => _PanoramaScreenState();
}

class _PanoramaScreenState extends ConsumerState<PanoramaScreen> {
  /// Los movimientos sacados de la cuenta con el ojito, por id.
  ///
  /// Por movimiento y no por categoría, igual que en la web: es lo que hace que
  /// el anillo, la lista y el total no puedan discrepar, porque los tres suman
  /// el mismo conjunto.
  final _ocultos = <String>{};

  /// La curva: por día o por mes.
  bool _porDia = true;

  /// En qué categoría se entró, por su id de grupo.
  ///
  /// Faltaba: tocar una porción solo la resaltaba, y en la web además **entra**
  /// en ella — el anillo pasa a dibujar sus subcategorías y la lista de abajo se
  /// recorta a esa categoría. Sin eso, el anillo de la app era una imagen y no
  /// algo que se recorre.
  String? _dentroDe;

  /// La porción señalada dentro del nivel actual — una hoja si ya se entró
  /// en una categoría, o una categoría de una sola hoja en la raíz (esa no
  /// tiene a dónde entrar, así que señalarla es lo único que puede hacer).
  /// Es lo que recorta "Gastos más grandes" a un solo grupo en vez de al
  /// nivel entero, igual que `pinned` en la web.
  String? _pinnedId;
  String? _pinnedLabel;

  void _entrar(String id) {
    setState(() {
      _dentroDe = id;
      _pinnedId = null;
      _pinnedLabel = null;
    });
  }

  void _salir() {
    setState(() {
      _dentroDe = null;
      _pinnedId = null;
      _pinnedLabel = null;
    });
  }

  void _pinear(String? id, String? label) {
    setState(() {
      // Tocar la misma porción otra vez la despina — un interruptor, no un
      // camino de una sola dirección.
      if (_pinnedId == id) {
        _pinnedId = null;
        _pinnedLabel = null;
      } else {
        _pinnedId = id;
        _pinnedLabel = label;
      }
    });
  }

  void _alternar(List<String> ids) {
    setState(() {
      final todosFuera = ids.every(_ocultos.contains);
      for (final id in ids) {
        if (todosFuera) {
          _ocultos.remove(id);
        } else {
          _ocultos.add(id);
        }
      }
    });
  }

  /// Los gastos que le tocan a "Gastos más grandes", según cuánto se haya
  /// recorrido el anillo: todo el periodo, solo la categoría en la que se
  /// entró, o solo la porción señalada dentro de ese nivel.
  /// Descontar del anillo lo que ya estaba comprometido.
  ///
  /// Separados en dos y no en uno solo: un gasto fijo y una cuota son dos cosas
  /// distintas —una la puedes renegociar, la otra la firmaste— y quien mira el
  /// anillo quiere poder verlas por separado o juntas. Son los mismos dos
  /// interruptores que ya tiene el calendario de días.
  /// Qué cuentas dibuja la curva de patrimonio.
  ///
  /// **Solo del gráfico**: no escribe nada, se pierde al salir y ninguna otra
  /// pantalla se entera. Mirar un gráfico no debería cambiarle los totales a
  /// nadie — para sacar una cuenta del patrimonio de verdad está su interruptor
  /// en Movimientos, que sí es una decisión guardada.
  ///
  /// `null` hasta que se toca la primera vez: significa "las del patrimonio",
  /// que es lo que se ve al entrar. Guardar el conjunto desde el arranque
  /// obligaría a saber las cuentas antes de que carguen.
  Set<String>? _cuentasDeLaCurva;

  bool _sinFijos = false;
  bool _sinDeudas = false;

  /// Se filtra en el origen y no en cada consumidor: el anillo, la leyenda y la
  /// lista de "más grandes" salen de la misma lista, y filtrar en tres sitios
  /// es garantizar que un día digan cosas distintas.
  /// La curva del subconjunto elegido: sumar los saldos de esas cuentas ese
  /// día. La suma de las que cuentan es exactamente `liquid`, así que sin filtro
  /// esto devuelve la misma serie.
  List<NetWorthPoint> _curvaDe(List<NetWorthPoint> puntos, Set<String> elegidas) => [
    for (final p in puntos)
      NetWorthPoint(
        etiqueta: p.etiqueta,
        liquid: round2(elegidas.fold<double>(0, (suma, id) => suma + (p.byAccount[id] ?? 0))),
        enCurso: p.enCurso,
        byAccount: p.byAccount,
      ),
  ];

  /// El cierre de cada mes a partir de la serie diaria: el último día de cada
  /// mes que aparezca.
  ///
  /// Es como se arma la mensual sin filtro del otro lado, así que filtrada tiene
  /// que armarse igual — de lo contrario los mismos meses saldrían de dos
  /// caminos distintos y un día dirían cifras distintas.
  List<NetWorthPoint> _mesesDe(List<NetWorthPoint> diaria) {
    final cierre = <String, double>{};
    for (final p in diaria) {
      // "2026-08-14" → "2026-08". Recorridos en orden, el último gana.
      cierre[p.etiqueta.substring(0, 7)] = p.liquid;
    }
    final claves = cierre.keys.toList()..sort();
    return [
      for (final (i, mes) in claves.indexed)
        NetWorthPoint(
          etiqueta: mes,
          liquid: cierre[mes]!,
          // El último mes de la serie es el que está corriendo: su cierre es el
          // saldo de hoy, no el del día 31.
          enCurso: i == claves.length - 1,
        ),
    ];
  }

  List<Transaction> _contando(List<Transaction> gastos) => gastos
      .where((t) => !(_sinFijos && t.recurringFlowId != null))
      .where((t) => !(_sinDeudas && t.debtId != null))
      .toList();

  List<Transaction> _gastosDelNivel(List<Transaction> gastos) {
    final delNivel = _dentroDe == null
        ? gastos
        : (agruparPorCategoria(gastos).where((g) => g.id == _dentroDe).firstOrNull?.items ??
              const []);
    if (_pinnedId == null) return delNivel;
    final grupo = _dentroDe == null ? agruparPorCategoria(delNivel) : agruparPorHoja(delNivel);
    return grupo.where((g) => g.id == _pinnedId).firstOrNull?.items ?? const [];
  }

  /// El patrimonio con el que cerró el periodo que se está mirando.
  ///
  /// Un rango relativo termina ahora, así que su cierre es el saldo de hoy. Un
  /// **mes cerrado** terminó cuando terminó: mirarlo tiene que decir cuánto
  /// había al cerrarlo, no cuánto hay hoy. Estaba pasando el saldo de hoy
  /// siempre, así que julio mostraba como "Disponible" el patrimonio de agosto
  /// —y el saldo de apertura se deducía hacia atrás desde el número equivocado,
  /// que es lo que descuadraba el anillo entero—.
  ///
  /// Si la serie de hitos todavía no llegó, el saldo de hoy es la mejor
  /// respuesta disponible: es la que se venía dando, y es exacta para el único
  /// periodo que se puede mirar sin esa serie.
  double _cierreDe(PeriodoElegido periodo, double saldoDeHoy) {
    if (!periodo.esMesCerrado) return saldoDeHoy;
    final puntos = ref.watch(netWorthMonthlyProvider).valueOrNull;
    final punto = puntos?.where((p) => p.etiqueta == periodo.mes).firstOrNull;
    return punto?.liquid ?? saldoDeHoy;
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(userProvider);
    final periodo = ref.watch(periodoProvider);
    final gastos = ref.watch(periodExpensesProvider);
    final todos = ref.watch(periodTransactionsProvider);
    final posicion = ref.watch(cashPositionProvider);
    final curva = ref.watch(_porDia ? netWorthDailyProvider : netWorthMonthlyProvider);

    return RefreshableScreen(
      onRefresh: () async {
        ref
          ..invalidate(periodTransactionsProvider)
          ..invalidate(cashPositionProvider)
          ..invalidate(netWorthDailyProvider)
          ..invalidate(netWorthMonthlyProvider);
      },
      children: [
        const ScreenHeader(
          kicker: 'Gestión de dinero',
          title: 'Panorama',
          subtitle: 'Resumen de tu situación financiera.',
        ),
        const SizedBox(height: Spacing.lg),
        _SelectorPeriodo(
          opciones: ref.watch(periodosProvider),
          seleccionado: periodo,
          // Cambiar de periodo sale de la categoría: los movimientos son otros,
          // y quedarse dentro de una categoría que quizá ya no existe en el
          // periodo nuevo deja la pantalla vacía sin explicar por qué.
          onSelect: (p) {
            setState(() {
              _dentroDe = null;
              _pinnedId = null;
              _pinnedLabel = null;
            });
            ref.read(periodoProvider.notifier).state = p;
          },
        ),
        const SizedBox(height: Spacing.sm),
        // Qué descuenta toda la pantalla.
        //
        // Acá arriba y no dentro de una tarjeta: el anillo, el calendario y la
        // curva mensual salen de los mismos gastos, y un interruptor que se
        // descubre a mitad de la pantalla ya llegó tarde. Antes había una copia
        // en cada tarjeta, cada una con su estado, y las dos decían "gasto del
        // mes" mientras contaban cosas distintas.
        Align(
          alignment: Alignment.centerLeft,
          child: Pastillas(
            opciones: const ['Sin gastos fijos', 'Sin cuotas de deuda'],
            activas: [_sinFijos, _sinDeudas],
            onSelect: (i) => setState(() {
              if (i == 0) {
                _sinFijos = !_sinFijos;
              } else {
                _sinDeudas = !_sinDeudas;
              }
            }),
          ),
        ),
        const SizedBox(height: Spacing.sm),
        // Cuánto mes queda. Acota todo lo de abajo: las cifras del periodo son
        // "lo que llevas", y lo que llevas se lee distinto el día 3 que el 28.
        const _DiasQueQuedan(),
        const SizedBox(height: Spacing.sm),
        Align(
          alignment: Alignment.centerRight,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _exportar(context, ref, periodo),
            child: Builder(
              builder: (context) {
                final colors = AppTheme.of(context);
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppIcon(AppIconData.download, size: 13, color: colors.sageInk),
                    const SizedBox(width: 5),
                    Text(
                      'Exportar',
                      style: AppText.small(colors.sageInk).copyWith(fontWeight: FontWeight.w500),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        const SizedBox(height: Spacing.lg),
        posicion.when(
          loading: () => const _Esqueleto(alto: 118),
          error: (_, __) => const _NoCargo(),
          // Con todo oculto no hay patrimonio ni movimientos que resumir, y la
          // pantalla se apagaba sin decir por qué. Se distingue de estar de
          // verdad vacío.
          data: (p) => p.accounts.isNotEmpty && p.accounts.every((c) => c.isHidden)
              ? TodoOculto(cuantas: p.accounts.length)
              : _TarjetaSaldo(posicion: p, currency: user.currency),
        ),
        // El bloque de arriba es uno solo, no tres tarjetas sueltas: "cuánto
        // tengo", "cuánto me falta pagar" y "cómo viene la deuda" son una sola
        // respuesta —¿me alcanza?— y con la separación de siempre entre ellas se
        // leían como tres temas distintos. Junto acá y separado del resto por un
        // aire mayor: es lo que se viene a ver, y lo de abajo es el detalle.
        //
        // Lo que falta por pagar, solo en un periodo que llega hasta hoy: en un
        // mes cerrado es una pregunta sin sentido, ya pasó.
        if (!periodo.esMesCerrado) ...[
          const SizedBox(height: Spacing.md),
          _PorPagarEsteMes(currency: user.currency),
        ],
        const SizedBox(height: Spacing.md),
        // La curva de la deuda se mudó a su sección: acá se responde el mes,
        // allá el arco completo. "Cuánto debo" y "cómo viene bajando" son una
        // sola pregunta, y tenerlas en dos pantallas obligaba a saltar entre
        // ellas para responderla. Queda el enlace para no cortar el hilo.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => ref.read(seccionProvider.notifier).state = indiceDe('Deudas'),
          child: Builder(
            builder: (context) {
              final colors = AppTheme.of(context);
              return Row(
                children: [
                  Expanded(
                    child: Text(
                      'Mira cómo viene bajando tu deuda',
                      style: AppText.small(colors.sageInk).copyWith(fontWeight: FontWeight.w500),
                    ),
                  ),
                  AppIcon(AppIconData.chevronRight, size: 14, color: colors.sageInk),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: Spacing.xl),
        const BandLabel('Este periodo'),
        const SizedBox(height: Spacing.lg),
        gastos.when(
          loading: () => const _Esqueleto(alto: 320),
          error: (_, __) => const _NoCargo(),
          data: (lista) => _SeccionCategorias(
            gastos: _contando(lista),
            fuera: lista.length - _contando(lista).length,
            ocultos: _ocultos,
            periodo: periodo,
            currency: user.currency,
            dentroDe: _dentroDe,
            pinnedId: _pinnedId,
            // El patrimonio de hoy, no el del periodo que se esté mirando —
            // un gasto ocultado de un mes cerrado, si nunca hubiera pasado,
            // seguiría sin haberse gastado hoy.
            currentLiquid: posicion.valueOrNull?.total ?? 0,
            onEntrar: _entrar,
            onSalir: _salir,
            onPin: _pinear,
            onToggle: _alternar,
            onReset: () => setState(_ocultos.clear),
          ),
        ),
        const SizedBox(height: Spacing.lg),
        gastos.maybeWhen(
          data: (lista) => _SeccionMasGrandes(
            // Dentro de una categoría, la lista habla de ella; señalada una
            // porción, la lista se recorta más — a esa sola. Es lo que une el
            // anillo con lo de abajo: sin esto son dos cosas que se ignoran.
            gastos: _gastosDelNivel(_contando(lista)),
            ocultos: _ocultos,
            periodo: periodo,
            currency: user.currency,
            titulo: _pinnedLabel ?? _dentroDe,
            alVerTodas: (_dentroDe != null || _pinnedId != null) ? _salir : null,
            onToggle: (id) => _alternar([id]),
          ),
          orElse: () => const SizedBox.shrink(),
        ),
        const SizedBox(height: Spacing.lg),
        // Cuándo se te fue, en las dos escalas.
        //
        // Una sola tarjeta con un conmutador y no dos apiladas: días del
        // periodo y meses son la misma pregunta a distinta distancia, y en dos
        // tarjetas obligaban a decidir cuál mirar antes de mirar nada.
        gastos.maybeWhen(
          data: (lista) => _GastoEnElTiempo(
            gastos: _contando(lista),
            periodo: periodo,
            currency: user.currency,
            sinFijos: _sinFijos,
            sinDeudas: _sinDeudas,
          ),
          orElse: () => const SizedBox.shrink(),
        ),
        // El reparto necesita las dos cosas a la vez: los movimientos del
        // periodo y el saldo con el que ese periodo cerró. Sin el segundo no
        // puede deducir el de apertura, y sin eso el anillo no cierra.
        todos.maybeWhen(
          data: (lista) => posicion.maybeWhen(
            data: (p) {
              // El mismo tramo que se acaba de repartir: es lo que cada porción
              // le pasa al historial para que la lista sume exactamente lo que
              // dice la porción. El extremo derecho es exclusivo, así que se
              // resta un milisegundo para no arrastrar el día siguiente.
              final (desde, finExclusivo) = periodo.rango(DateTime.now());
              return _SeccionReparto(
                allocation: allocatePeriod(lista, _cierreDe(periodo, p.total)),
                currency: user.currency,
                desde: desde,
                hasta: finExclusivo.subtract(const Duration(milliseconds: 1)),
              );
            },
            orElse: () => const SizedBox.shrink(),
          ),
          orElse: () => const _Esqueleto(alto: 280),
        ),
        const SizedBox(height: Spacing.xl),
        const BandLabel('La vista larga'),
        const SizedBox(height: Spacing.lg),
        // En la caja que se aparta: no la recorta el periodo elegido y es lo que
        // se consulta, no lo que se viene a ver.
        AppCard(
          discreta: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionHeader(
                title: 'Tu patrimonio en el tiempo',
                trailing: _Alternador(
                  opciones: const ['Día', 'Mes'],
                  indice: _porDia ? 0 : 1,
                  onSelect: (i) => setState(() => _porDia = i == 0),
                ),
              ),
              const SizedBox(height: Spacing.lg),
              curva.when(
                loading: () => const _Esqueleto(alto: 150),
                error: (_, __) => const _NoCargo(),
                data: (puntos) {
                  final cuentas = posicion.valueOrNull?.accounts ?? const <CashPositionAccount>[];
                  // La serie diaria, para poder recomponer la mensual al
                  // filtrar. Se pide siempre: el provider la cachea, y en la
                  // escala diaria es la misma que ya se está mirando.
                  final diaria =
                      ref.watch(netWorthDailyProvider).valueOrNull ?? const <NetWorthPoint>[];
                  final elegidas =
                      _cuentasDeLaCurva ??
                      cuentas.where((c) => !c.isHidden).map((c) => c.id).toSet();
                  // Si el filtro está en su estado natural se usan los puntos
                  // tal como vienen: recomponerlos daría lo mismo, pero pasar
                  // por dos caminos para el mismo dato es cómo empiezan las
                  // discrepancias.
                  final porDefecto = cuentas.where((c) => !c.isHidden).map((c) => c.id).toSet();
                  final filtrando =
                      elegidas.length != porDefecto.length || !porDefecto.every(elegidas.contains);

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      NetWorthChart(
                        // Con filtro, la curva se recompone desde la serie
                        // **diaria**: es la única que trae el saldo de cada
                        // cuenta. Los puntos mensuales no lo traen, así que
                        // filtrarlos directamente daba cero en todos y la curva
                        // se caía a plano — que es lo que se veía al filtrar en
                        // días y cambiar a meses.
                        points: !filtrando
                            ? puntos
                            : _porDia
                            ? _curvaDe(puntos, elegidas)
                            : _mesesDe(_curvaDe(diaria, elegidas)),
                        currency: user.currency,
                        // Solo en la escala diaria: en la mensual cada punto es
                        // un mes cerrado, y reservar días sueltos al final no
                        // significaría nada sobre ese eje.
                        diasRestantes: _porDia ? Fechas.diasDelMes().faltan : 0,
                      ),
                      // En las dos escalas, no solo en días: estaban ocultos en
                      // mensual, así que filtrar en días y cambiar a meses dejaba
                      // una curva recortada sin nada que dijera por qué ni cómo
                      // deshacerlo.
                      if (cuentas.length > 1)
                        _CuentasDeLaCurva(
                          cuentas: cuentas,
                          elegidas: elegidas,
                          currency: user.currency,
                          onAlternar: (id) => setState(() {
                            final siguiente = {...elegidas};
                            if (!siguiente.remove(id)) siguiente.add(id);
                            _cuentasDeLaCurva = siguiente;
                          }),
                          onTodas: () => setState(() {
                            _cuentasDeLaCurva = elegidas.length == cuentas.length
                                ? porDefecto
                                : cuentas.map((c) => c.id).toSet();
                          }),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Exportar los movimientos del periodo elegido. Réplica de
/// `movimientos/exportar/route.ts`, pero generado en el dispositivo y
/// compartido en vez de descargado — no hay una carpeta de "Descargas" propia
/// en iOS/Android, y la hoja de compartir es el gesto nativo de "sácalo de
/// la app": Archivos, Drive, correo, lo que el usuario elija.
Future<void> _exportar(BuildContext context, WidgetRef ref, PeriodoElegido periodo) async {
  final formato = await showAppModal<ExportFormat>(
    context,
    title: 'Exportar movimientos',
    subtitle: periodo.etiqueta(DateTime.now()),
    builder: (context) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldOption(titulo: 'CSV', onTap: () => Navigator.of(context).pop(ExportFormat.csv)),
        FieldOption(
          titulo: 'Excel (XLSX)',
          onTap: () => Navigator.of(context).pop(ExportFormat.xlsx),
        ),
        FieldOption(titulo: 'JSON', onTap: () => Navigator.of(context).pop(ExportFormat.json)),
        FieldOption(titulo: 'Markdown', onTap: () => Navigator.of(context).pop(ExportFormat.md)),
      ],
    ),
  );
  if (formato == null || !context.mounted) return;

  final user = ref.read(userProvider);
  final transacciones = ref.read(periodTransactionsProvider).valueOrNull ?? const <Transaction>[];
  final (desde, hasta) = periodo.rango(DateTime.now());
  final resultado = buildExport(
    transacciones: transacciones,
    formato: formato,
    periodoId: periodo.id,
    periodoLabel: periodo.etiqueta(DateTime.now()),
    desde: desde,
    hasta: hasta,
    timezone: user.timezone,
    currency: user.currency,
  );

  await SharePlus.instance.share(
    ShareParams(
      files: [XFile.fromData(resultado.bytes, mimeType: resultado.mimeType)],
      fileNameOverrides: [resultado.filename],
    ),
  );

  if (resultado.recortado && context.mounted) {
    await showFeedback(
      context,
      title: 'Archivo recortado',
      message: 'Había más de 1000 movimientos en este periodo; el archivo trae los primeros 1000.',
      tone: FeedbackTone.aviso,
    );
  }
}

// ── Periodo ───────────────────────────────────

/// Las pastillas de periodo.
///
/// Se desplazan en horizontal en vez de comprimirse: con cuatro caben en casi
/// cualquier teléfono, pero con el texto ampliado por accesibilidad no, y una
/// pastilla que corta su etiqueta a "Est…" no se puede elegir.
class _SelectorPeriodo extends StatelessWidget {
  const _SelectorPeriodo({
    required this.opciones,
    required this.seleccionado,
    required this.onSelect,
  });

  final List<PeriodoElegido> opciones;
  final PeriodoElegido seleccionado;
  final void Function(PeriodoElegido) onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return SizedBox(
      height: 40,
      // El degradado del borde derecho es la señal de que hay más.
      //
      // Sin él la última pastilla se cortaba a ras del borde y parecía un
      // recorte, no una lista que sigue: nadie desliza algo que cree roto. Con
      // el desvanecido, el corte se lee como continuación.
      child: ShaderMask(
        shaderCallback: (rect) => LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: const [Color(0xFF000000), Color(0xFF000000), Color(0x00000000)],
          stops: const [0, 0.9, 1],
        ).createShader(rect),
        blendMode: BlendMode.dstIn,
        child: ListView(
          scrollDirection: Axis.horizontal,
          // Aire al final: la última pastilla no debe pegarse al borde ni quedar
          // debajo del desvanecido.
          padding: const EdgeInsets.only(right: Spacing.xxl),
          children: [
            for (final p in opciones)
              Padding(
                padding: const EdgeInsets.only(right: Spacing.sm),
                child: Semantics(
                  button: true,
                  selected: p.id == seleccionado.id,
                  label: p.etiqueta(DateTime.now()),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onSelect(p),
                    child: Container(
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
                      decoration: BoxDecoration(
                        color: p.id == seleccionado.id ? colors.sageDark : null,
                        borderRadius: BorderRadius.circular(Radii.pill),
                        border: Border.all(
                          color: p.id == seleccionado.id ? colors.sageDark : colors.surfaceBorder,
                        ),
                      ),
                      child: Text(
                        // Los meses cerrados llevan mayúscula inicial: "Julio" es
                        // un nombre propio en una pastilla, no una palabra suelta.
                        p.esMesCerrado
                            ? _capitalizar(p.etiqueta(DateTime.now()))
                            : p.etiqueta(DateTime.now()),
                        style: AppText.small(
                          p.id == seleccionado.id
                              ? const Color(0xFFFFFFFF)
                              : colors.oliveInk.withValues(alpha: 0.8),
                        ).copyWith(fontWeight: FontWeight.w500),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _capitalizar(String t) => t.isEmpty ? t : t[0].toUpperCase() + t.substring(1);

/// Un interruptor de dos opciones, para día/mes de la curva.
class _Alternador extends StatelessWidget {
  const _Alternador({required this.opciones, required this.indice, required this.onSelect});

  final List<String> opciones;
  final int indice;
  final void Function(int) onSelect;

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
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < opciones.length; i++)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onSelect(i),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.md, vertical: 5),
                decoration: BoxDecoration(
                  color: i == indice ? colors.surface : null,
                  borderRadius: BorderRadius.circular(Radii.pill),
                ),
                child: Text(
                  opciones[i],
                  style: AppText.tiny(
                    i == indice ? colors.foreground : colors.oliveInk.withValues(alpha: 0.6),
                  ).copyWith(fontWeight: i == indice ? FontWeight.w600 : null),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Patrimonio ────────────────────────────────

/// El patrimonio de Panorama: la misma información de siempre —cuánto tienes,
/// qué entró y qué salió— pero con la ropa del resto de la app.
///
/// Antes era una placa con degradado haciendo de tarjeta de banco. Una tarjeta
/// de banco es un objeto: dice "esto es plástico, esto es una cuenta". Acá
/// arriba lo que hay no es una cuenta sino **la respuesta** —cuánto tienes—, y
/// el degradado la separaba del resto de la pantalla como si fuera de otra app.
/// Sobre la misma superficie que todo lo demás, la cifra manda por tamaño y no
/// por color, y se lee de corrido con las tarjetas de abajo.
class _TarjetaSaldo extends ConsumerWidget {
  const _TarjetaSaldo({required this.posicion, required this.currency});

  final CashPosition posicion;
  final String currency;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppTheme.of(context);
    final ocultos = ref.watch(saldosOcultosProvider);
    final neto = posicion.income - posicion.expenses;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'PATRIMONIO DISPONIBLE',
                      style: AppText.kicker(colors.sageInk.withValues(alpha: 0.8)),
                    ),
                    const SizedBox(height: 3),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        tapar(Money.format(posicion.total, currency), ocultos),
                        style: AppText.money(colors.foreground, size: 26, weight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
              // El ojo tapa las cifras de toda la app: es lo único de esta
              // cabecera que no es información.
              OjoDeLaTarjeta(
                ocultos: ocultos,
                onTap: () => ref.read(saldosOcultosProvider.notifier).alternar(),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),

          // El mes en una línea, igual que en Movimientos: qué entró, qué salió
          // y con qué te quedas. Dos rótulos en mayúsculas con sus cifras
          // ocupaban el doble para decir lo mismo, y el neto —que es lo que uno
          // busca— había que sacarlo de cabeza.
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '+${tapar(Money.format(posicion.income, currency), ocultos)} entró',
                  style: AppText.small(colors.sageInk),
                ),
                TextSpan(
                  text: '   ·   ',
                  style: AppText.small(colors.oliveInk.withValues(alpha: 0.3)),
                ),
                TextSpan(
                  text: '−${tapar(Money.format(posicion.expenses, currency), ocultos)} salió',
                  style: AppText.small(colors.danger),
                ),
                TextSpan(
                  text: '   ·   ',
                  style: AppText.small(colors.oliveInk.withValues(alpha: 0.3)),
                ),
                TextSpan(
                  text:
                      '${neto >= 0 ? "▲" : "▼"} neto '
                      '${tapar(Money.format(neto.abs(), currency), ocultos)}',
                  style: AppText.small(neto >= 0 ? colors.sageInk : colors.danger),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Gastos por categoría ──────────────────────

class _SeccionCategorias extends StatelessWidget {
  const _SeccionCategorias({
    required this.gastos,
    required this.fuera,
    required this.ocultos,
    required this.periodo,
    required this.currency,
    required this.dentroDe,
    required this.pinnedId,
    required this.currentLiquid,
    required this.onEntrar,
    required this.onSalir,
    required this.onPin,
    required this.onToggle,
    required this.onReset,
  });

  final List<Transaction> gastos;

  /// Cuántos movimientos dejaron de contarse por los interruptores.
  final int fuera;
  final Set<String> ocultos;
  final PeriodoElegido periodo;
  final String currency;
  final String? dentroDe;
  final String? pinnedId;
  final double currentLiquid;
  final void Function(String id) onEntrar;
  final VoidCallback onSalir;
  final void Function(String? id, String? label) onPin;
  final void Function(List<String> ids) onToggle;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    if (gastos.isEmpty) {
      return AppCard(
        dashed: true,
        child: Text(
          'No hay gastos ${periodo.enFrase(DateTime.now())}.',
          style: AppText.small(colors.oliveInk.withValues(alpha: 0.75)),
        ),
      );
    }

    // Dentro de una categoría el anillo dibuja **sus hojas**. Es el mismo
    // gráfico con otros datos, no un gráfico distinto: por eso se recalculan los
    // segmentos en vez de montar otra vista.
    final padre = dentroDe == null
        ? null
        : agruparPorCategoria(gastos).where((g) => g.id == dentroDe).firstOrNull;
    final grupos = padre == null ? agruparPorCategoria(gastos) : agruparPorHoja(padre.items);
    final delNivel = padre?.items ?? gastos;

    final segmentos = grupos
        .map(
          (g) => (
            segmento: DonutSegment(
              id: g.id,
              label: g.label,
              value: g.items
                  .where((t) => !ocultos.contains(t.id))
                  .fold<double>(0, (s, t) => s + t.amount),
              fullValue: g.items.fold<double>(0, (s, t) => s + t.amount),
            ),
            ids: g.items.map((t) => t.id).toList(),
          ),
        )
        .toList();

    final totalReal = delNivel.fold<double>(0, (s, t) => s + t.amount);
    final totalVisible = delNivel
        .where((t) => !ocultos.contains(t.id))
        .fold<double>(0, (s, t) => s + t.amount);
    final descontado = totalReal - totalVisible;

    final ocultosPorSegmento = <String>{
      for (final s in segmentos)
        if (s.ids.every(ocultos.contains)) s.segmento.id,
    };

    // Se distingue la categoría entera del gasto suelto: decir "sin Comida y
    // bebidas" cuando solo se quitó un almuerzo hace creer que se quitaron los
    // S/ 541 y se quitaron S/ 205.
    final enteras = segmentos
        .where((s) => s.ids.every(ocultos.contains))
        .map((s) => s.segmento.label)
        .toList();
    final idsDeEnteras = <String>{
      for (final s in segmentos)
        if (s.ids.every(ocultos.contains)) ...s.ids,
    };
    final sueltos = ocultos.where((id) => !idsDeEnteras.contains(id)).length;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: padre == null
                ? // Corto a propósito: el rótulo del tramo ya dice que esto es
                  // "este periodo" y cuál es está elegido arriba. "Gastos de agosto
                  // por categoría" repetía las dos cosas en la misma pantalla.
                  'Por categoría'
                : 'Dentro de ${padre.label}',
            // La salida está siempre visible mientras se esté adentro: un
            // anillo que cambió de contenido sin forma obvia de deshacerlo deja
            // al usuario preguntándose qué está mirando.
            trailing: padre == null
                ? Text(
                    'Toca para entrar',
                    style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.5)),
                  )
                : GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onSalir,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppIcon(AppIconData.chevronLeft, size: 14, color: colors.sageInk),
                        const SizedBox(width: 2),
                        Text(
                          'Todas',
                          style: AppText.small(
                            colors.sageInk,
                          ).copyWith(fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  ),
          ),
          // Los dos interruptores viven en la cabecera de la pantalla, no acá:
          // el anillo, el calendario y la curva mensual cuentan los mismos
          // gastos, y con una copia en cada tarjeta apagar los fijos en una
          // dejaba a las otras contándolos. Queda el recuento de lo que se
          // sacó, que sí es de este anillo.
          if (fuera > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '$fuera ${fuera == 1 ? "movimiento fuera" : "movimientos fuera"} de la cuenta',
                style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.55)),
              ),
            ),
          const SizedBox(height: Spacing.lg),
          DonutChart(
            // La clave cambia al entrar y al salir: sin ella el anillo animaría
            // de las porciones viejas a las nuevas como si fueran las mismas.
            key: ValueKey(padre?.id ?? 'raiz'),
            segments: [for (final s in segmentos) s.segmento],
            total: totalVisible,
            centerLabel: padre == null ? 'Gastos del periodo' : padre.label,
            currency: currency,
            hidden: ocultosPorSegmento,
            onToggleHide: (id) => onToggle(segmentos.firstWhere((s) => s.segmento.id == id).ids),
            // Desde la raíz, tocar una categoría con más de una hoja **entra**
            // en ella — el anillo pasa a dibujar sus subcategorías. Con una
            // sola hoja no hay a dónde entrar, así que ahí (y siempre que ya
            // se esté adentro) tocar **señala** la porción: es lo que recorta
            // "Gastos más grandes" a ella sola, dinámico en cada toque.
            onTapSegment: (id) {
              if (padre == null) {
                final g = grupos.where((x) => x.id == id).firstOrNull;
                if (g != null && agruparPorHoja(g.items).length > 1) {
                  onEntrar(id);
                  return;
                }
              }
              final g = grupos.where((x) => x.id == id).firstOrNull;
              onPin(id, g?.label);
            },
          ),
          if (descontado > 0) ...[
            const SizedBox(height: Spacing.lg),
            Container(
              padding: const EdgeInsets.all(Spacing.md),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.md),
                border: Border.all(color: colors.surfaceBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Sin ${_enumerar(enteras, sueltos)} habrías gastado '
                    '${Money.format(totalVisible, currency)} en vez de '
                    '${Money.format(totalReal, currency)}.',
                    style: AppText.small(colors.foreground),
                  ),
                  const SizedBox(height: Spacing.sm),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '−${Money.format(descontado, currency)}',
                        style: AppText.money(colors.sageInk, size: 13.5, weight: FontWeight.w600),
                      ),
                      GestureDetector(
                        onTap: onReset,
                        child: Text(
                          'Contar todo',
                          style: AppText.small(colors.oliveInk.withValues(alpha: 0.7)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Spacing.sm),
                  Container(
                    padding: const EdgeInsets.only(top: Spacing.sm),
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: colors.surfaceBorder)),
                    ),
                    // Lo que de verdad se pregunta al taparse un gasto no es
                    // "cuánto gasté" sino "cuánto tendría" — esa plata seguiría
                    // en la cuenta hoy, sin importar de qué periodo sea el
                    // gasto que se ocultó.
                    child: Text(
                      'Hoy tendrías ${Money.format(currentLiquid + descontado, currency)} '
                      'en vez de ${Money.format(currentLiquid, currency)}.',
                      style: AppText.small(colors.foreground),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _enumerar(List<String> categorias, int sueltos) {
  final partes = categorias.length <= 3
      ? [...categorias]
      : [...categorias.take(3), '${categorias.length - 3} categorías más'];
  if (sueltos > 0) {
    partes.add('$sueltos ${sueltos == 1 ? "gasto suelto" : "gastos sueltos"}');
  }
  if (partes.isEmpty) return 'lo descontado';
  if (partes.length == 1) return partes.first;
  return '${partes.sublist(0, partes.length - 1).join(", ")} y ${partes.last}';
}

typedef GrupoCategoria = ({String id, String label, List<Transaction> items});

/// Agrupa por categoría **padre**, igual que la web: con noventa hojas el anillo
/// se queda sin colores antes de decir nada útil.
List<GrupoCategoria> agruparPorCategoria(List<Transaction> gastos) {
  final mapa = <String, ({String label, List<Transaction> items})>{};
  for (final t in gastos) {
    final label = t.category == null
        ? 'Sin categoría'
        : (t.category!.parentName ?? t.category!.name);
    final id = t.category == null ? '__sin__' : label;
    mapa.putIfAbsent(id, () => (label: label, items: <Transaction>[])).items.add(t);
  }
  final lista = mapa.entries
      .map((e) => (id: e.key, label: e.value.label, items: e.value.items))
      .toList();
  lista.sort((a, b) {
    final ta = a.items.fold<double>(0, (s, t) => s + t.amount);
    final tb = b.items.fold<double>(0, (s, t) => s + t.amount);
    return tb.compareTo(ta);
  });
  return lista;
}

// ── Los más grandes ───────────────────────────

const _vistaPrevia = 5;

class _SeccionMasGrandes extends StatelessWidget {
  const _SeccionMasGrandes({
    required this.gastos,
    required this.ocultos,
    required this.periodo,
    required this.currency,
    required this.titulo,
    required this.alVerTodas,
    required this.onToggle,
  });

  final List<Transaction> gastos;
  final Set<String> ocultos;
  final PeriodoElegido periodo;
  final String currency;

  /// El nombre de lo que recortó la lista — la categoría en la que se
  /// entró, o la porción señalada dentro de ella. `null` es "todo el
  /// periodo".
  final String? titulo;

  /// Deshace el recorte. `null` cuando ya se está viendo todo el periodo —
  /// no hay a dónde volver.
  final VoidCallback? alVerTodas;
  final void Function(String id) onToggle;

  @override
  Widget build(BuildContext context) {
    if (gastos.isEmpty) return const SizedBox.shrink();

    final ordenados = [...gastos]..sort((a, b) => b.amount.compareTo(a.amount));
    final total = gastos
        .where((t) => !ocultos.contains(t.id))
        .fold<double>(0, (s, t) => s + t.amount);
    final resto = ordenados.length - _vistaPrevia;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: titulo == null ? 'Los más grandes' : 'Gastos de $titulo',
            trailing: alVerTodas == null
                ? null
                : Builder(
                    builder: (context) {
                      final colors = AppTheme.of(context);
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: alVerTodas,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            AppIcon(AppIconData.chevronLeft, size: 14, color: colors.sageInk),
                            const SizedBox(width: 2),
                            Text(
                              'Todas',
                              style: AppText.small(
                                colors.sageInk,
                              ).copyWith(fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: Spacing.md),
          ExpenseRows(
            transactions: ordenados.take(_vistaPrevia).toList(),
            total: total,
            currency: currency,
            hidden: ocultos,
            onToggleHide: onToggle,
          ),
          if (resto > 0) ...[
            const SizedBox(height: Spacing.md),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              // El modal, no una pantalla nueva: la lista completa es un detalle
              // de esta tarjeta, y empujar una ruta haría perder el scroll de
              // Panorama al volver.
              onTap: () => showAppModal<void>(
                context,
                title: 'Gastos ${periodo.enFrase(DateTime.now())}',
                subtitle: '${ordenados.length} movimientos',
                builder: (context) => _ListaCompleta(
                  gastos: ordenados,
                  ocultos: ocultos,
                  total: total,
                  currency: currency,
                ),
              ),
              child: _VerTodos(cuantos: ordenados.length, mas: resto),
            ),
          ],
        ],
      ),
    );
  }
}

class _VerTodos extends StatelessWidget {
  const _VerTodos({required this.cuantos, required this.mas});

  final int cuantos;
  final int mas;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Container(
      alignment: Alignment.center,
      constraints: const BoxConstraints(minHeight: 44),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: colors.surfaceBorder),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(child: Text('Ver los $cuantos gastos', style: AppText.small(colors.foreground))),
          const SizedBox(width: 6),
          Text('($mas más)', style: AppText.small(colors.oliveInk.withValues(alpha: 0.55))),
          const SizedBox(width: Spacing.sm),
          AppIcon(
            AppIconData.chevronRight,
            size: 15,
            color: colors.oliveInk.withValues(alpha: 0.55),
          ),
        ],
      ),
    );
  }
}

/// La lista entera dentro del modal, ordenada por fecha.
///
/// Por fecha y no por monto: la tarjeta responde "cuáles fueron los más
/// grandes"; acá uno recorre lo que pasó, y eso se recorre en el tiempo. Mismo
/// conjunto, dos lecturas.
class _ListaCompleta extends StatelessWidget {
  const _ListaCompleta({
    required this.gastos,
    required this.ocultos,
    required this.total,
    required this.currency,
  });

  final List<Transaction> gastos;
  final Set<String> ocultos;
  final double total;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final porFecha = [...gastos]..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExpenseRows(
          transactions: porFecha,
          total: total,
          currency: currency,
          hidden: ocultos,
          numbered: false,
        ),
        const SizedBox(height: Spacing.lg),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'TOTAL MOSTRADO',
              style: AppText.kicker(colors.oliveInk.withValues(alpha: 0.6)).copyWith(fontSize: 9.5),
            ),
            Text(
              Money.format(total, currency),
              style: AppText.money(colors.foreground, size: 14, weight: FontWeight.w600),
            ),
          ],
        ),
      ],
    );
  }
}

// ── Cuándo se te fue ──────────────────────────

/// El gasto en el tiempo, en las dos escalas: los días del periodo elegido y
/// los meses.
///
/// Una tarjeta y un conmutador, no dos tarjetas apiladas. Es la misma pregunta
/// —"¿cuándo se me fue?"— vista de cerca y de lejos, y separarlas obligaba a
/// elegir cuál mirar antes de haber mirado ninguna, además de empujar hacia
/// abajo todo lo que sigue.
///
/// Los dos ejes cuentan lo mismo que el anillo: los gastos ya llegan filtrados
/// por los interruptores de la cabecera, y la curva mensual los aplica sobre sus
/// propias piezas. Un mismo interruptor, un mismo número en las tres.
class _GastoEnElTiempo extends ConsumerStatefulWidget {
  const _GastoEnElTiempo({
    required this.gastos,
    required this.periodo,
    required this.currency,
    required this.sinFijos,
    required this.sinDeudas,
  });

  final List<Transaction> gastos;
  final PeriodoElegido periodo;
  final String currency;
  final bool sinFijos;
  final bool sinDeudas;

  @override
  ConsumerState<_GastoEnElTiempo> createState() => _GastoEnElTiempoState();
}

class _GastoEnElTiempoState extends ConsumerState<_GastoEnElTiempo> {
  /// Arranca en días: el periodo elegido manda en toda la pantalla, y la escala
  /// que responde a ese periodo es la de días. Los meses lo ignoran a propósito
  /// —su gracia es verlos juntos—, así que entrar por ahí sería contestar una
  /// pregunta que nadie hizo todavía.
  bool _porDia = true;

  /// El mes a mes en cifras, plegado por defecto: el gráfico ya contesta cómo
  /// vienes, y doce filas debajo empujan hacia abajo todo lo que sigue.
  bool _verMesAMes = false;

  /// Cuánto contar de un mes: el total menos lo que los interruptores de la
  /// cabecera hayan apagado. Se compone acá y no en el motor porque el motor
  /// manda las tres piezas juntas — así apagar un interruptor es una resta y no
  /// otra llamada que podría no coincidir.
  double _monto(SpendingPoint p) =>
      p.total - (widget.sinFijos ? p.fixed : 0) - (widget.sinDeudas ? p.debt : 0);

  /// Qué dice la tarjeta que está contando. Sin interruptores es todo el gasto;
  /// con los dos, exactamente el gasto de la vida — que tiene nombre propio y
  /// merece que se lo llame por él.
  String get _queCuenta {
    if (widget.sinFijos && widget.sinDeudas) return 'solo gastos de la vida';
    if (widget.sinFijos) return 'sin gastos fijos';
    if (widget.sinDeudas) return 'sin cuotas de deuda';
    return 'todo tu gasto';
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final serie = ref.watch(spendingHistoryProvider).valueOrNull ?? const <SpendingPoint>[];

    // Con un solo mes no hay tendencia que mostrar, así que ni se ofrece la
    // escala: un conmutador que lleva a una tarjeta vacía es peor que no tenerlo.
    final hayMeses = serie.length > 1;
    // Los días necesitan al menos dos para decir algo. Cuando no los hay —el día
    // 1 de cada mes— la tarjeta cae a la escala mensual en vez de desaparecer:
    // esconderla se llevaba también el conmutador, así que se perdía el acceso a
    // los meses, que sí tenían qué contar.
    // Se arma una sola vez: `_dias` mira los providers y montarlo dos veces solo
    // para preguntarle si existe es trabajo repetido.
    final dias = _dias(context);
    final hayDias = dias != null;
    final porDia = hayDias && (_porDia || !hayMeses);

    final cuerpo = porDia ? dias : (hayMeses ? _meses(context, serie) : null);
    if (cuerpo == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.lg),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              kicker: 'Cuándo se te fue',
              title: porDia ? 'Los días del periodo' : 'Mes a mes',
              trailing: hayMeses && hayDias
                  ? _Alternador(
                      opciones: const ['Días', 'Meses'],
                      indice: porDia ? 0 : 1,
                      onSelect: (i) => setState(() => _porDia = i == 0),
                    )
                  : null,
            ),
            const SizedBox(height: 4),
            Text(
              porDia
                  ? 'Los días con gasto — $_queCuenta.'
                  : 'Los últimos meses enteros, sin importar el periodo — $_queCuenta.',
              style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.6)),
            ),
            const SizedBox(height: Spacing.lg),
            cuerpo,
          ],
        ),
      ),
    );
  }

  /// El calendario del periodo. `null` cuando no hay con qué dibujarlo.
  Widget? _dias(BuildContext context) {
    final (desde, finExclusivo) = widget.periodo.rango(DateTime.now());
    // El último día que se dibuja es el último **dentro** del rango: el extremo
    // derecho es exclusivo, así que tomarlo tal cual pintaba un día de más.
    final hasta = finExclusivo.subtract(const Duration(milliseconds: 1));
    final todo = spendingDays(
      widget.gastos,
      desde,
      hasta,
      primerRegistro: ref.watch(primerRegistroProvider),
    );
    // Con un solo día no hay patrón que mostrar. El corte estaba en tres, y con
    // eso "Esta semana" desaparecía entera los lunes y los martes —dos días—
    // justo cuando uno quiere ver cómo va la semana.
    if (todo.days.length < 2) return null;

    return SpendingDaysChart(
      resumen: todo,
      // Solo subcategorías: "Comida rápida" y "Mercado" son dos gastos que no se
      // parecen en nada, y marcar el padre que los contiene no distinguiría el
      // día del delivery del día de la compra.
      categorias:
          ref
              .watch(categoriesProvider)
              .valueOrNull
              ?.where((c) => c.type == 'EXPENSE' && c.parentId != null)
              .toList() ??
          const [],
      periodo: widget.periodo.enFrase(DateTime.now()),
      currency: widget.currency,
      esPeriodoAbierto: !widget.periodo.esMesCerrado,
      onVerDia: (fecha) => Navigator.of(
        context,
      ).push(PageRouteBuilder(pageBuilder: (context, a, b) => HistorialScreen(dia: fecha))),
    );
  }

  /// La curva mensual, con su lista plegable debajo.
  Widget _meses(BuildContext context, List<SpendingPoint> serie) {
    final colors = AppTheme.of(context);
    // Los cerrados aparte: el que está en curso todavía no terminó y arrastraría
    // la referencia hacia abajo.
    final cerrados = serie.where((p) => !p.inProgress).toList();
    final enCurso = serie.where((p) => p.inProgress).firstOrNull;
    final ultimoCerrado = cerrados.lastOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // El mismo gráfico que el patrimonio, con los mismos puntos: es un área
        // con su línea, y la pregunta —"¿cómo vengo?"— es la misma tendencia.
        NetWorthChart(
          points: [
            for (final p in serie)
              NetWorthPoint(etiqueta: p.month, liquid: _monto(p), enCurso: p.inProgress),
          ],
          currency: widget.currency,
          // Acá menos es mejor, al revés que en el patrimonio: verde cuando
          // baja y rojo cuando sube, con el monto sobre cada punto.
          subirEsMalo: true,
          mostrarMontos: true,
        ),
        const SizedBox(height: Spacing.md),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _verMesAMes = !_verMesAMes),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _verMesAMes ? 'Ocultar el mes a mes' : 'Ver el mes a mes (${serie.length})',
                  style: AppText.small(colors.sageInk).copyWith(fontWeight: FontWeight.w500),
                ),
              ),
              AppIcon(
                _verMesAMes ? AppIconData.chevronDown : AppIconData.chevronRight,
                size: 14,
                color: colors.sageInk,
              ),
            ],
          ),
        ),
        // Los meses con su cifra entera. El gráfico da la forma y esto da el
        // dato: sobre la curva los montos van acortados —"3.0k"— porque enteros
        // no caben, y "cuánto fue julio" merece su número.
        if (_verMesAMes)
          for (final (i, p) in serie.reversed.indexed)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _mesEnLetras(p.month) + (p.inProgress ? ' · en curso' : ''),
                      style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.7)),
                    ),
                  ),
                  // El cambio contra el mes anterior, con su flecha. La lista va
                  // del más nuevo al más viejo, así que el anterior de cada fila
                  // es el de **abajo** — el último de la lista no tiene con qué
                  // compararse.
                  //
                  // La flecha y no solo el color: rojo y verde son el par que
                  // más se confunde con daltonismo, y una cifra que solo se
                  // distingue por el tono no dice nada a quien no lo ve.
                  if (i < serie.length - 1 && _monto(p) != _monto(serie.reversed.elementAt(i + 1)))
                    Builder(
                      builder: (context) {
                        final previo = _monto(serie.reversed.elementAt(i + 1));
                        final sube = _monto(p) > previo;
                        return Padding(
                          padding: const EdgeInsets.only(right: Spacing.sm),
                          child: Text(
                            '${sube ? "↑" : "↓"} '
                            '${Money.format((_monto(p) - previo).abs(), widget.currency)}',
                            style: AppText.tiny(
                              sube ? colors.danger : colors.sageInk,
                            ).copyWith(fontWeight: FontWeight.w600),
                          ),
                        );
                      },
                    ),
                  Text(
                    Money.format(_monto(p), widget.currency),
                    style: AppText.money(colors.foreground, size: 12.5, weight: FontWeight.w600),
                  ),
                ],
              ),
            ),
        // La referencia y el aviso del mes a medias. Son datos, no explicación:
        // una cifra sola no dice si fue un buen mes, y el que está en curso
        // siempre parece mejor porque todavía no terminó.
        //
        // El promedio se saca solo de los meses **cerrados** y con el mismo
        // `_monto`: el promedio de "todo tu gasto" y el de "solo gastos de la
        // vida" son números distintos, y dejarlo fijo pondría la referencia de
        // uno debajo de la curva del otro.
        if (cerrados.isNotEmpty || (enCurso != null && ultimoCerrado != null)) ...[
          const SizedBox(height: Spacing.md),
          Container(height: 1, color: colors.surfaceBorder.withValues(alpha: 0.6)),
          const SizedBox(height: Spacing.sm),
          Text(
            [
              if (cerrados.isNotEmpty)
                'Promedio de los meses cerrados: '
                    '${Money.format(cerrados.fold<double>(0, (a, p) => a + _monto(p)) / cerrados.length, widget.currency)}.',
              if (enCurso != null && ultimoCerrado != null)
                '${_mesEnLetras(ultimoCerrado.month)} cerró en '
                    '${Money.format(_monto(ultimoCerrado), widget.currency)} y este mes todavía '
                    'no termina.',
            ].join(' '),
            style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.7)),
          ),
        ],
      ],
    );
  }
}

/// "2026-07" → "julio". Se arma a mediodía para que la zona no lo corra al mes
/// anterior.
String _mesEnLetras(String clave) {
  final partes = clave.split('-');
  return Fechas.mesLargo(DateTime(int.parse(partes[0]), int.parse(partes[1]), 15));
}

/// Qué cuentas dibuja la curva de patrimonio, y cuánto tiene cada una.
///
/// **Solo afecta al gráfico.** No escribe nada: es estado de la vista, se pierde
/// al salir y ninguna otra pantalla se entera. Para sacar una cuenta del
/// patrimonio de verdad está su interruptor en Movimientos, que sí es una
/// decisión guardada.
///
/// Arranca con las que ya cuentan, así que lo primero que se ve es la curva de
/// siempre. Las apagadas aparecen igual, para poder sumarlas un momento y ver
/// cuánto habría con ellas.
class _CuentasDeLaCurva extends StatelessWidget {
  const _CuentasDeLaCurva({
    required this.cuentas,
    required this.elegidas,
    required this.currency,
    required this.onAlternar,
    required this.onTodas,
  });

  final List<CashPositionAccount> cuentas;
  final Set<String> elegidas;
  final String currency;
  final void Function(String id) onAlternar;
  final VoidCallback onTodas;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final dentro = cuentas.where((c) => elegidas.contains(c.id)).toList();
    final total = dentro.fold<double>(0, (s, c) => s + c.currentBalance);
    final todasDentro = dentro.length == cuentas.length;

    return Padding(
      padding: const EdgeInsets.only(top: Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'QUÉ CUENTAS DIBUJA',
                  style: AppText.kicker(colors.oliveInk.withValues(alpha: 0.5)),
                ),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTodas,
                child: Text(
                  todasDentro ? 'Solo las del patrimonio' : 'Todas mis cuentas',
                  style: AppText.tiny(
                    colors.sageInk,
                  ).copyWith(decoration: TextDecoration.underline),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final c in cuentas)
                _ChipDeCuenta(
                  cuenta: c,
                  dentro: elegidas.contains(c.id),
                  onTap: () => onAlternar(c.id),
                ),
            ],
          ),
          const SizedBox(height: 6),
          // "Solo el gráfico" y punto: la promesa que hay que hacer es que esto
          // no toca nada más. Decir además que no se guarda era explicar la
          // implementación de una promesa que ya se entendió.
          Text(
            'La curva dibuja ${Money.format(total, currency)} de ${dentro.length} '
            '${dentro.length == 1 ? "cuenta" : "cuentas"} · solo cambia el gráfico, '
            'no se guarda.',
            style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.55)),
          ),
        ],
      ),
    );
  }
}

class _ChipDeCuenta extends StatelessWidget {
  const _ChipDeCuenta({required this.cuenta, required this.dentro, required this.onTap});

  final CashPositionAccount cuenta;
  final bool dentro;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: dentro ? colors.sage.withValues(alpha: 0.12) : null,
          borderRadius: BorderRadius.circular(Radii.pill),
          border: Border.all(
            color: dentro ? colors.sageDark.withValues(alpha: 0.35) : colors.surfaceBorder,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Tachado además de apagado: el estado no puede depender solo de un
            // tono más claro.
            Text(
              cuenta.name,
              style:
                  AppText.tiny(
                    dentro ? colors.foreground : colors.oliveInk.withValues(alpha: 0.45),
                  ).copyWith(
                    fontWeight: FontWeight.w500,
                    decoration: dentro ? null : TextDecoration.lineThrough,
                  ),
            ),
            const SizedBox(width: 6),
            Text(
              Money.format(cuenta.currentBalance, cuenta.currency),
              style: AppText.money(
                dentro
                    ? colors.oliveInk.withValues(alpha: 0.75)
                    : colors.oliveInk.withValues(alpha: 0.4),
                size: 11,
              ),
            ),
            // Una cuenta apagada en la app puede estar encendida acá: hay que
            // decir cuál es cuál o la cifra de la curva no cuadra con la de la
            // tarjeta y parece un error.
            if (cuenta.isHidden && dentro) ...[
              const SizedBox(width: 5),
              Text(
                'fuera del patrimonio',
                style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.45)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Lo que falta por pagar este mes ───────────

/// Gastos fijos sin marcar más cuotas de deuda sin cubrir, sumados.
///
/// Las dos mitades responden a la misma pregunta —"¿cuánto tengo comprometido
/// todavía?"— pero viven en dos pantallas distintas, y hasta ahora nadie las
/// sumaba. Es la cifra que decide si el saldo de hoy alcanza, y por eso se
/// muestra siempre contra el patrimonio: decir "te faltan 5,347" sin decir con
/// qué cuentas es media respuesta.
class _PorPagarEsteMes extends ConsumerWidget {
  const _PorPagarEsteMes({required this.currency});

  final String currency;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppTheme.of(context);
    final flujos = ref.watch(recurringFlowsProvider).valueOrNull;
    final deudas = ref.watch(debtsProvider).valueOrNull;
    final posicion = ref.watch(cashPositionProvider).valueOrNull;
    if (flujos == null || deudas == null) return const _Esqueleto(alto: 120);

    final ahora = DateTime.now();
    final mes = '${ahora.year}-${ahora.month.toString().padLeft(2, '0')}';
    final p = pendienteDelMes(
      flujos: flujos,
      deudas: deudas,
      mes: mes,
      moneda: currency,
      tasas: ref.watch(exchangeRatesProvider).valueOrNull ?? const [],
    );

    if (p.nadaPendiente) {
      return AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'TE FALTA PAGAR ESTE MES',
              style: AppText.kicker(colors.oliveInk.withValues(alpha: 0.55)),
            ),
            const SizedBox(height: 6),
            Text(
              'Nada. Este mes ya marcaste todos tus gastos fijos y cuotas.',
              style: AppText.small(colors.sageInk),
            ),
          ],
        ),
      );
    }

    final disponible = posicion?.total ?? 0;
    final queda = ((disponible - p.total) * 100).round() / 100;

    // Plegable, y recordado entre visitas. Es la tarjeta más alta de la pantalla
    // y hay meses en que ya sabes lo que dice y solo estorba para llegar a lo de
    // abajo.
    //
    // Lo que **no** se pliega es la cifra: plegada sube al lado del título.
    // Esconder el número dejaría un rótulo que promete una respuesta y no la da,
    // y para taparlo de una mirada ajena ya está el ojo de la tarjeta de arriba,
    // que es otro problema. Acá se pliega el detalle, no el dato.
    final abierto = ref.watch(pendienteAbiertoProvider);

    Widget linea(String rotulo, String detalle, double monto) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: rotulo,
                    style: AppText.small(colors.oliveInk.withValues(alpha: 0.75)),
                  ),
                  TextSpan(
                    text: ' · $detalle',
                    style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.5)),
                  ),
                ],
              ),
            ),
          ),
          Text(Money.format(monto, currency), style: AppText.money(colors.foreground, size: 13.5)),
        ],
      ),
    );

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => ref.read(pendienteAbiertoProvider.notifier).alternar(),
            child: Row(
              children: [
                AppIcon(
                  abierto ? AppIconData.chevronDown : AppIconData.chevronRight,
                  size: 13,
                  color: colors.oliveInk.withValues(alpha: 0.55),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    'TE FALTA PAGAR ESTE MES',
                    style: AppText.kicker(colors.oliveInk.withValues(alpha: 0.55)),
                  ),
                ),
                Text(
                  abierto
                      ? 'de ${Money.format(p.comprometido, currency)}'
                      : Money.format(p.total, currency),
                  style: abierto
                      ? AppText.tiny(colors.oliveInk.withValues(alpha: 0.5))
                      : AppText.money(colors.foreground, size: 14, weight: FontWeight.w600),
                ),
              ],
            ),
          ),
          if (abierto) ...[
            const SizedBox(height: 6),
            Text(
              Money.format(p.total, currency),
              style: AppText.money(colors.foreground, size: 26, weight: FontWeight.w600),
            ),
            const SizedBox(height: Spacing.sm),
            if (p.fijosCuantos > 0) linea('Gastos fijos', '${p.fijosCuantos} sin marcar', p.fijos),
            if (p.deudasCuantas > 0)
              linea(
                'Cuotas de deuda',
                '${p.deudasCuantas} ${p.deudasCuantas == 1 ? "pendiente" : "pendientes"}',
                p.deudas,
              ),
            const SizedBox(height: Spacing.sm),
            Text(
              queda >= 0
                  ? 'Con tu patrimonio de hoy (${Money.format(disponible, currency)}) te quedarían '
                        '${Money.format(queda, currency)} después de pagarlo.'
                  : 'Tu patrimonio de hoy es ${Money.format(disponible, currency)}: faltarían '
                        '${Money.format(-queda, currency)} para cubrirlo todo.',
              style: AppText.tiny(
                queda >= 0 ? colors.oliveInk.withValues(alpha: 0.7) : colors.danger,
              ),
            ),
            if (p.sinCotizacion.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Sin tipo de cambio para ${p.sinCotizacion.join(", ")} → $currency: esas cuotas '
                'quedan fuera del total.',
                style: AppText.tiny(colors.danger),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

// ── Dónde terminó tu dinero ───────────────────

class _SeccionReparto extends StatefulWidget {
  const _SeccionReparto({
    required this.allocation,
    required this.currency,
    required this.desde,
    required this.hasta,
  });

  final PeriodAllocation allocation;
  final String currency;

  /// El periodo que se está repartiendo. Viaja con cada porción al historial:
  /// sin él, tocar una que dice "S/ 2,122 en julio" abriría el mismo filtro
  /// sobre toda la historia y la lista sumaría otra cosa.
  final DateTime desde;
  final DateTime hasta;

  @override
  State<_SeccionReparto> createState() => _SeccionRepartoState();
}

class _SeccionRepartoState extends State<_SeccionReparto> {
  /// Qué porciones están fuera de la cuenta.
  ///
  /// No se guarda: es una pregunta que uno se hace mirando —"¿y sin las
  /// deudas?"— y no una preferencia que quiera encontrar puesta la próxima vez.
  final _ocultas = <String>{};

  void _alternar(String id) => setState(() {
    if (!_ocultas.remove(id)) _ocultas.add(id);
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final a = widget.allocation;

    // El orden es el de qué tan poco se puede mover, y "Disponible" al final:
    // es lo que queda, no un destino más.
    //
    // Colores fijados por identidad, no por posición: si "Pago de deudas" vale
    // cero un mes y desaparece, las demás no pueden correrse de color detrás —
    // "Disponible" tiene que seguir siendo el mismo verde siempre.
    //
    // "Gastos de la vida" usa el violeta (índice 6) y no un cuarto color
    // cualquiera: contra el naranja de "Gastos fijos" y el verde de
    // "Disponible", que son sus vecinos en el anillo, es el único que pasa el
    // validador de paleta en los dos temas (`node scripts/validate_palette.js`
    // del skill de dataviz) — el amarillo que tocaba por orden quedaba a
    // ΔE 4.8 del naranja en oscuro, indistinguible.
    //
    // Los ajustes y los traspasos van juntos en su propia porción, en el gris
    // neutro de la paleta: no son categorías de gasto, son lo que movió el
    // saldo sin que compraras nada. Estuvieron dentro de "Gastos de la vida" y
    // ahí mentían — un julio con 3,044 de gasto suelto se leía como 9,004,
    // porque arrastraba las contrapartidas que la app escribe sola al marcar
    // pagado un mes pasado. Fuera de la cuenta no pueden ir: son plata que
    // salió de verdad y el anillo dejaría de cerrar con la tarjeta.
    final ajustesYTraspasos = a.adjustmentsOut + a.movedOut;
    // Las de gasto abren su lista; "Disponible" no, y no es un olvido: es un
    // saldo —lo que quedó—, no un conjunto de movimientos.
    final segmentos = <DonutSegment>[
      if (a.debts > 0)
        DonutSegment(
          id: 'deudas',
          label: 'Pago de deudas',
          value: a.debts,
          colorIndex: 0,
          abre: true,
        ),
      if (a.fixed > 0)
        DonutSegment(id: 'fijos', label: 'Gastos fijos', value: a.fixed, colorIndex: 1, abre: true),
      if (a.other > 0)
        DonutSegment(
          id: 'otros',
          label: 'Gastos de la vida',
          value: a.other,
          colorIndex: 6,
          abre: true,
        ),
      if (ajustesYTraspasos > 0)
        DonutSegment(
          id: 'ajustes',
          // "Neto" en el rótulo porque lo es: las parejas que se anulan —el
          // pago de un mes pasado y su contrapartida— no aparecen, y lo que
          // queda es cuánto te bajó el saldo la corrección.
          label: 'Ajustes y traspasos (neto)',
          value: ajustesYTraspasos,
          isOther: true,
          abre: true,
        ),
      if (a.available > 0)
        DonutSegment(id: 'disponible', label: 'Disponible', value: a.available, colorIndex: 2),
    ];

    if (segmentos.isEmpty) return const SizedBox.shrink();

    // Una porción tapada vale cero para el dibujo pero conserva su monto en
    // `fullValue`: la fila se queda a la vista, tachada y con su cifra, porque
    // si desapareciera no habría forma de volver a contarla. Y deja de abrir su
    // lista: está fuera de la cuenta, y un toque que llevara al historial
    // abriría movimientos que el centro ya no suma.
    final dibujados = [
      for (final seg in segmentos)
        DonutSegment(
          id: seg.id,
          label: seg.label,
          value: _ocultas.contains(seg.id) ? 0 : seg.value,
          fullValue: seg.value,
          isOther: seg.isOther,
          colorIndex: seg.colorIndex,
          abre: seg.abre && !_ocultas.contains(seg.id),
        ),
    ];
    // El total del centro es el de lo que sigue contando, no el del periodo: si
    // se quedara en `sources`, los porcentajes de las porciones visibles serían
    // fracciones de un entero al que ya no pertenecen todas.
    final contado = dibujados.fold<double>(0, (suma, seg) => suma + seg.value);
    final tapadas = segmentos.where((seg) => _ocultas.contains(seg.id)).toList();

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader(title: 'Dónde terminó tu dinero'),
          const SizedBox(height: Spacing.lg),
          DonutChart(
            segments: dibujados,
            total: contado,
            centerLabel: tapadas.isEmpty
                ? 'Dinero del periodo'
                : 'Dinero del periodo, sin lo tapado',
            currency: widget.currency,
            // El ojito, y acá significa otra cosa que en el anillo de
            // categorías: allá es "¿cuánto habría gastado sin esto?" y acá es
            // "sácalo de la cuenta para ver cuánto pesa el resto".
            hidden: _ocultas,
            onToggleHide: _alternar,
            // Cada porción de gasto abre los movimientos que la componen, con
            // el mismo tramo y el mismo criterio con el que se sumó acá.
            onAbrir: (id) => Navigator.of(context).push(
              PageRouteBuilder(
                pageBuilder: (context, _, _) =>
                    HistorialScreen(origen: id, desde: widget.desde, hasta: widget.hasta),
              ),
            ),
          ),
          const SizedBox(height: Spacing.lg),
          Text(
            tapadas.isEmpty
                // Con algo tapado, la frase de siempre mentiría: el centro ya
                // no es el total del periodo. Se dice qué falta y cuánto era.
                ? _explicacion(a, widget.currency)
                : 'Fuera de la cuenta: ${tapadas.map((s) => s.label).join(", ")} '
                      '(${Money.format(a.sources - contado, widget.currency)}). '
                      'El total del periodo entero es ${Money.format(a.sources, widget.currency)} '
                      '— vuelve a contarlas con el ojito.',
            style: AppText.small(colors.oliveInk.withValues(alpha: 0.8)),
          ),
        ],
      ),
    );
  }

  /// De dónde salió el 100% del anillo, en una frase.
  ///
  /// Sin ella, quien sume los renglones y no llegue al total del centro concluye
  /// que la app está mal — y lo que pasa es que el saldo con el que empezó el
  /// periodo también forma parte del dinero que pasó por sus manos.
  String _explicacion(PeriodAllocation a, String currency) {
    final partes = <String>[];
    if (a.opening != 0) partes.add('${Money.format(a.opening, currency)} que ya tenías');
    if (a.income > 0) partes.add('${Money.format(a.income, currency)} que entraron');
    if (a.adjustmentsIn > 0) {
      partes.add('${Money.format(a.adjustmentsIn, currency)} de ajustes');
    }
    final origen = partes.isEmpty
        ? Money.format(a.sources, currency)
        : partes.length == 1
        ? partes.first
        : '${partes.sublist(0, partes.length - 1).join(", ")} y ${partes.last}';

    return 'El total sale de $origen. Lo que queda (${Money.format(a.available, currency)}) '
        'es tu patrimonio de hoy, el mismo de la tarjeta de arriba.';
  }
}

// ── Piezas compartidas ────────────────────────

/// El armazón de una pantalla: ancho máximo, scroll y recarga.
/// "Quedan 12 días de agosto", con la barra de lo que va del mes al lado.
class _DiasQueQuedan extends StatelessWidget {
  const _DiasQueQuedan();

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final ahora = DateTime.now();
    final (:faltan, :total, :dia) = Fechas.diasDelMes(ahora);
    final mes = Fechas.mesLargo(ahora);
    // La fecha de hoy en el mismo bloque que los días que faltan: son la misma
    // pregunta contada desde los dos lados —dónde estás y cuánto queda— y
    // separarlas obligaría a buscarlas en dos sitios.
    final hoy = Fechas.hoyLargo(ahora);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${hoy[0].toUpperCase()}${hoy.substring(1)}',
          style: AppText.bodyMedium(colors.foreground),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            SizedBox(
              width: 76,
              child: BarraAvance(
                avance: total == 0 ? 0 : dia / total,
                color: colors.sage,
                canal: colors.sage.withValues(alpha: 0.2),
                alto: 6,
              ),
            ),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: Text(
                faltan == 0
                    ? 'Hoy termina $mes.'
                    : 'Quedan $faltan ${faltan == 1 ? "día" : "días"} de $mes · día $dia de $total',
                style: AppText.small(colors.oliveInk.withValues(alpha: 0.75)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Esqueleto extends StatelessWidget {
  const _Esqueleto({required this.alto});

  final double alto;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Container(
      height: alto,
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
    );
  }
}

class _NoCargo extends StatelessWidget {
  const _NoCargo();

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return AppCard(
      dashed: true,
      child: Text(
        // Sin el mensaje técnico: se dice qué pasó y qué hacer.
        'No pude cargar esto. Arrastra hacia abajo para reintentar.',
        style: AppText.small(colors.oliveInk.withValues(alpha: 0.8)),
      ),
    );
  }
}

/// Agrupa por categoría **hoja**, para el segundo nivel del anillo.
///
/// Es el detalle de una categoría padre: dentro de "Comida y bebidas" están
/// "Restaurant", "Cafetería" y "Comida rápida", que es lo que uno quiere ver al
/// entrar.
List<GrupoCategoria> agruparPorHoja(List<Transaction> gastos) {
  final mapa = <String, ({String label, List<Transaction> items})>{};
  for (final t in gastos) {
    final label = t.category?.name ?? 'Sin categoría';
    final id = t.category?.id ?? '__sin__';
    mapa.putIfAbsent(id, () => (label: label, items: <Transaction>[])).items.add(t);
  }
  final lista = mapa.entries
      .map((e) => (id: e.key, label: e.value.label, items: e.value.items))
      .toList();
  lista.sort((a, b) {
    final ta = a.items.fold<double>(0, (s, t) => s + t.amount);
    final tb = b.items.fold<double>(0, (s, t) => s + t.amount);
    return tb.compareTo(ta);
  });
  return lista;
}
