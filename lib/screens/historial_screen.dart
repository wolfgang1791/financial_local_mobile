import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../data/api.dart';
import '../data/export.dart';
import '../data/models.dart';
import '../data/payment_method.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../state/providers.dart';
import '../local_engine/months_util.dart';
import '../ui/category_field.dart';
import '../ui/expense_rows.dart';
import '../ui/fields.dart';
import '../ui/format.dart';
import '../ui/icons.dart';
import '../ui/modal.dart';
import '../ui/refreshable_screen.dart';
import '../ui/surface.dart';
import 'edit_transaction_modal.dart';
import 'shell.dart';

/// Cómo se parten las filas en bloques. **No recorta nada**: 'todo' es "sin
/// encabezados", no "todo el historial".
///
/// Vivía en la misma fila de pastillas que "Este mes", que sí recorta, con la
/// misma forma y el mismo tamaño — y hacía falta un párrafo de comentario para
/// explicar por qué dos controles idénticos hacían cosas distintas. Cuando el
/// código tiene que disculpar un control, el control está mal: el usuario no lee
/// comentarios. Ahora agrupar y recortar son dos cosas separadas.
const _agrupaciones = [
  ('todo', 'Sin encabezados'),
  ('dia', 'Día'),
  ('semana', 'Semana'),
  ('mes', 'Mes'),
  ('anio', 'Año'),
];

/// De dónde viene un movimiento, dicho para una persona.
String _etiquetaOrigen(String codigo) => switch (codigo) {
  'fijos' => 'Gastos fijos',
  'deudas' => 'Cuotas de deuda',
  'otros' => 'Gastos de la vida',
  'ajustes' => 'Ajustes y traspasos',
  _ => codigo,
};

/// Un filtro puesto, con su × para soltarlo.
///
/// Sin `onQuitar` es informativo y no se puede soltar: es el caso del recorte
/// con el que se abrió la pantalla desde un gráfico — quitarlo dejaría una lista
/// que nadie pidió, y para eso está el botón de volver.
class _ChipFiltro extends StatelessWidget {
  const _ChipFiltro({required this.texto, required this.onQuitar, this.onTocar});

  final String texto;
  final VoidCallback? onQuitar;

  /// Qué hace al tocarlo cuando no se puede soltar: cambiarlo. Es el caso del
  /// corte de la comparación — siempre hay uno, así que el gesto útil no es
  /// quitarlo sino elegir otro.
  final VoidCallback? onTocar;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onQuitar ?? onTocar,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: colors.sage.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(texto, style: AppText.tiny(colors.sageInk).copyWith(fontWeight: FontWeight.w600)),
            if (onQuitar != null) ...[
              const SizedBox(width: 5),
              AppIcon(AppIconData.close, size: 11, color: colors.sageInk),
            ] else if (onTocar != null) ...[
              const SizedBox(width: 5),
              AppIcon(AppIconData.chevronRight, size: 11, color: colors.sageInk),
            ],
          ],
        ),
      ),
    );
  }
}

/// La lista crece hacia abajo; no se pasa de página.
///
/// Con páginas, agrupar por mes partía julio en varios bloques "JULIO" con
/// varias sumas distintas, y ninguna era el neto de julio. Empezando siempre
/// desde la fila 1, ningún bloque se corta hacia atrás y solo el último puede
/// quedar abierto.
///
/// El tope existe igual: pintar miles de filas deja la pantalla trabada, y al
/// llegar se dice en vez de fingir que eso es todo — una lista que se detiene
/// sin avisar hace pensar que el movimiento que buscas no existe.
const _paso = 50;
const _tope = 500;

/// El historial completo: filtros, paginación de verdad y el saldo previo de
/// cada fila. Réplica de `/movimientos/historial` — a diferencia de
/// Movimientos, acá no hay tope de "últimos 12".
class HistorialScreen extends ConsumerStatefulWidget {
  const HistorialScreen({super.key, this.dia, this.origen, this.desde, this.hasta});

  /// Un día suelto ("2026-08-07"), cuando se llega desde algo que habla de un
  /// día concreto —"el día que más gastaste"— para poder ver *qué* fue ese día
  /// sin tener que buscarlo a mano. Volver devuelve a donde estabas.
  final String? dia;

  /// Con qué filtro de origen abrir: 'fijos', 'deudas', 'otros' o 'ajustes'.
  /// Es lo que trae una porción del anillo de Panorama al tocarla.
  final String? origen;

  /// El tramo que estaba mirando quien enlazó. Sin él, tocar una porción que
  /// dice "S/ 2,122 en julio" abriría el mismo filtro sobre toda la historia y
  /// la lista sumaría otra cosa.
  final DateTime? desde;
  final DateTime? hasta;

  @override
  ConsumerState<HistorialScreen> createState() => _HistorialScreenState();
}

class _HistorialScreenState extends ConsumerState<HistorialScreen> {
  String _agrupacion = 'mes';

  /// Cómo se ordena la lista. `null` es por fecha, que es el orden natural de
  /// un historial y por eso el que manda si no eliges nada.
  ///
  /// Ordenado por monto no se agrupa: los bloques se arman recorriendo la lista
  /// en orden, así que con los montos de mayor a menor saldrían veinte bloques
  /// de una fila. Se ignora la agrupación en vez de borrarla, para que al
  /// volver a "Fecha" siga donde la dejaste.
  String? _orden;
  Category? _categoria;

  /// De dónde viene el movimiento: null es todos, 'fijos' los pagos de un gasto
  /// o ingreso recurrente y 'deudas' las cuotas.
  ///
  /// No es una categoría —un pago de Internet **tiene** la categoría Internet—
  /// sino otra pregunta sobre el mismo movimiento: "¿esto lo decidí este mes o
  /// ya estaba comprometido?". Los mismos dos conceptos que Panorama deja
  /// descontar en el calendario de días.
  String? _origen;

  /// Cuántas filas se están mostrando. Crece de a `_paso` hasta `_tope`.
  int _viendo = _paso;
  bool _mesActual = false;

  /// Los movimientos descontados con el ojito.
  ///
  /// Solo ids: cuánto restan sale de las filas que están a la vista, que es lo
  /// único que se puede descontar — nadie oculta lo que no ve. Sobrevive a
  /// cambiar de página o de filtro sin hacer nada raro: lo que ya no está en
  /// `_items` no resta.
  final _ocultos = <String>{};

  void _alternarOculto(String id) => setState(() {
    if (!_ocultos.remove(id)) _ocultos.add(id);
  });

  /// Lo que el ojito le quita a cada cifra del encabezado.
  ///
  /// Cada fila descuenta de la suya: un gasto baja "gastado", un ingreso baja
  /// "ingresado" y un ajuste baja "ajustes". Mandarlos todos al mismo cajón
  /// haría que tapar una corrección de saldo dijera que gastaste menos.
  ({double gasto, double ingreso, double ajuste, int cuantos}) get _descontado {
    var gasto = 0.0, ingreso = 0.0, ajuste = 0.0, cuantos = 0;
    for (final t in _items) {
      if (!_ocultos.contains(t.id)) continue;
      cuantos++;
      if (t.kind != 'MOVEMENT') {
        ajuste += t.isExpense ? -t.amount : t.amount;
      } else if (t.isExpense) {
        gasto += t.amount;
      } else {
        ingreso += t.amount;
      }
    }
    return (gasto: gasto, ingreso: ingreso, ajuste: ajuste, cuantos: cuantos);
  }

  /// Dónde empieza la lista, para poder aterrizar ahí.
  final _anclaLista = GlobalKey();
  bool _yaAterrizo = false;

  /// El día que se pidió al abrir, ya en fecha. Null si se abrió normal.
  DateTime? get _diaPedido {
    final crudo = widget.dia;
    if (crudo == null) return null;
    final partes = crudo.split('-');
    if (partes.length != 3) return null;
    return DateTime(int.parse(partes[0]), int.parse(partes[1]), int.parse(partes[2]));
  }

  /// Cuántos filtros acotan o reordenan lo que se ve.
  ///
  /// La agrupación no cuenta: no cambia qué movimientos hay ni en qué orden,
  /// solo dónde caen los encabezados. Y el recorte con el que se abrió la
  /// pantalla tampoco: no se eligió acá y no se puede soltar.
  int get _filtrosPuestos => [
    _busqueda.text.trim().isNotEmpty,
    _categoria != null,
    _origen != null,
    _orden != null,
    _mesActual,
  ].where((puesto) => puesto).length;

  bool get _hayChips =>
      _filtrosPuestos > 0 ||
      _compararMes != null ||
      _diaPedido != null ||
      (widget.desde != null && widget.hasta != null);

  /// La hoja de filtros: todo lo que no se usa en cada visita.
  ///
  /// Cada opción se aplica al tocarla y la hoja se queda abierta —salvo la
  /// categoría, que abre su propio selector— para poder poner dos sin volver a
  /// entrar. `StatefulBuilder` redibuja la hoja; el `setState` de la pantalla
  /// redibuja lo de atrás.
  Future<void> _abrirFiltros() async {
    await showAppModal<void>(
      context,
      title: 'Filtros',
      builder: (context) => StatefulBuilder(
        builder: (context, redibujar) {
          void aplicar(VoidCallback cambio) {
            setState(() {
              cambio();
              _viendo = _paso;
            });
            redibujar(() {});
            _recargar();
          }

          final colors = AppTheme.of(context);
          Widget rotulo(String texto) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              texto.toUpperCase(),
              style: AppText.kicker(colors.sageInk.withValues(alpha: 0.8)),
            ),
          );

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Recortar, que sí acorta la lista.
              rotulo('Cuándo'),
              Row(
                children: [
                  _Pastilla(
                    texto: 'Todo el historial',
                    activa: !_mesActual,
                    onTap: () => aplicar(() => _mesActual = false),
                  ),
                  const SizedBox(width: 6),
                  _Pastilla(
                    texto: 'Solo este mes',
                    activa: _mesActual,
                    onTap: () => aplicar(() => _mesActual = true),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.lg),

              // Agrupar, que solo decide dónde van los encabezados.
              rotulo('Agrupar por'),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final (codigo, etiqueta) in _agrupaciones)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: _Pastilla(
                          texto: etiqueta,
                          activa: _agrupacion == codigo,
                          // Ordenado por monto los bloques se armarían
                          // recorriendo una lista que ya no va por fecha:
                          // veinte encabezados de una fila. Se dice, no se
                          // ignora en silencio.
                          onTap: _orden != null ? () {} : () => aplicar(() => _agrupacion = codigo),
                        ),
                      ),
                  ],
                ),
              ),
              if (_orden != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Ordenado por monto no se agrupa: los encabezados se arman recorriendo la '
                    'lista por fecha.',
                    style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.6)),
                  ),
                ),
              const SizedBox(height: Spacing.lg),

              rotulo('Orden'),
              Row(
                children: [
                  _Pastilla(
                    texto: 'Fecha',
                    activa: _orden == null,
                    onTap: () => aplicar(() => _orden = null),
                  ),
                  const SizedBox(width: 6),
                  _Pastilla(
                    texto: 'Monto ${_orden == 'monto-asc' ? '↑' : '↓'}',
                    activa: _orden != null,
                    onTap: () => aplicar(() => _orden = _orden == 'monto' ? 'monto-asc' : 'monto'),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.lg),

              rotulo('Categoría'),
              FieldSelector(
                texto: _categoria?.ruta ?? 'Todas las categorías',
                icon: AppIconData.filter,
                onTap: () async {
                  final lista =
                      ref.read(_categoriasEnUsoProvider).valueOrNull ?? const <Category>[];
                  // Mismo selector agrupado que en Movimientos — el padre de una
                  // categoría en uso ya viene incluido en `lista` (lo agrega
                  // `/categories/in-use`) y aparece elegible como "(general)",
                  // que filtra por él y por todas sus hojas.
                  final elegida = await elegirCategoria(
                    context,
                    lista,
                    textoNinguna: 'Todas las categorías',
                    titulo: 'Filtrar por categoría',
                  );
                  if (elegida != null) {
                    aplicar(() => _categoria = elegida.id.isEmpty ? null : elegida);
                  }
                },
              ),
              const SizedBox(height: Spacing.lg),

              // De dónde viene, junto a la categoría porque es la misma pregunta
              // desde otro ángulo: la categoría dice **en qué** se fue, esto dice
              // si era una decisión de este mes o algo ya comprometido.
              rotulo('Origen'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final codigo in const [null, 'fijos', 'deudas', 'otros', 'ajustes'])
                    _Pastilla(
                      texto: codigo == null ? 'Todos' : _etiquetaOrigen(codigo),
                      activa: _origen == codigo,
                      onTap: () => aplicar(() => _origen = codigo),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  /// Hasta qué día se corta la comparación.
  ///
  /// El mes en curso no tiene un "completo" propio —todavía le faltan días— así
  /// que "todo" se lee como "el mes comparado, entero" y no como "sin cortar
  /// ninguno de los dos".
  Future<void> _elegirCorte() async {
    final hoy = DateTime.now();
    // -1 es el mismo sentinel que "todo": showAppModal<int> solo devuelve un
    // entero, así que no hace falta un tipo aparte.
    final elegido = await showAppModal<int>(
      context,
      title: 'Comparar hasta el día',
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FieldOption(
            titulo: 'Todo el mes comparado',
            seleccionado: _compararTodoMes,
            onTap: () => Navigator.of(context).pop(-1),
          ),
          for (var d = 1; d <= hoy.day; d++)
            FieldOption(
              titulo: '$d',
              seleccionado: !_compararTodoMes && (_diaCorte ?? hoy.day) == d,
              onTap: () => Navigator.of(context).pop(d),
            ),
        ],
      ),
    );
    if (elegido == null) return;
    setState(() {
      if (elegido == -1) {
        _compararTodoMes = true;
      } else {
        _compararTodoMes = false;
        _diaCorte = elegido;
      }
    });
    await _recargar();
  }

  /// Con qué mes se compara. Solo dentro del modo comparar: sin comparación no
  /// hay mes que elegir.
  Future<void> _elegirMesComparado() async {
    final elegido = await showAppModal<String>(
      context,
      title: 'Comparar lo que llevo con',
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final clave in _mesesParaComparar())
            FieldOption(
              titulo: _etiquetaMes(clave),
              seleccionado: clave == _compararMes,
              onTap: () => Navigator.of(context).pop(clave),
            ),
        ],
      ),
    );
    if (elegido == null) return;
    setState(() => _compararMes = elegido);
    await _recargar();
  }

  final _busqueda = TextEditingController();
  Timer? _debounce;

  bool _cargando = true;
  String? _error;
  List<Transaction> _items = const [];
  int _total = 0;
  double _totalGastos = 0;
  double _totalIngresos = 0;

  /// Lo que movió el saldo sin ser gasto ni ingreso: correcciones y traspasos.
  /// En su propia cifra y solo cuando la hay — es lo que explica que una lista
  /// sume más de lo que dice "Gastado". Sin esto, llegar acá desde la porción
  /// de ajustes del anillo daba dos números distintos para las mismas filas.
  double _totalAjustes = 0;

  // Comparar apaga la lista/paginación normal y las reemplaza por dos: lo
  // que llevo este mes y lo mismo, cortado en el mismo día, del mes elegido.
  String? _compararMes;
  // Hasta qué día del mes se compara. `null` es "hoy" — se guarda aparte del
  // mes elegido para poder cambiar uno sin perder el otro.
  int? _diaCorte;
  // El mes en curso no tiene un "completo" propio —todavía le faltan
  // días—, así que esto solo cambia el corte del lado con el que se compara.
  bool _compararTodoMes = false;
  bool _cargandoComparacion = false;
  bool _errorComparacion = false;
  List<Transaction> _gastosActual = const [];
  double _totalActual = 0;
  List<Transaction> _gastosAnterior = const [];
  double _totalAnterior = 0;
  // El día en que de verdad se cortó cada lado, tras acotarlo a lo que cabe en
  // su propio mes — puede diferir de `_diaCorte` si el mes comparado es más
  // corto (comparar el 31 contra febrero).
  int _diaEfectivoActual = DateTime.now().day;
  int _diaEfectivoAnterior = DateTime.now().day;
  // El ojito de Panorama, replicado acá: tapar un gasto puntual de cualquiera
  // de los dos lados para ver cómo cambiaría la comparación sin él.
  Set<String> _ocultosActual = {};
  Set<String> _ocultosAnterior = {};

  @override
  void initState() {
    super.initState();
    // Con lo que pidió quien abrió la pantalla ya puesto: si se llega desde una
    // porción del anillo, el filtro tiene que estar aplicado y **visible** en
    // su pastilla, no escondido en el pedido.
    _origen = widget.origen;
    _cargar();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _busqueda.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      final texto = _busqueda.text.trim();
      final (desde, hasta) = _rangoDelFiltro();

      final params = <String, String>{
        'take': '$_viendo',
        if (_categoria != null && _categoria!.id.isNotEmpty) 'categoryId': _categoria!.id,
        if (_origen != null) 'origen': _origen!,
        if (_orden != null) 'orden': _orden!,
        if (texto.isNotEmpty) 'q': texto,
        if (desde != null) 'from': desde.toIso8601String(),
        if (hasta != null) 'to': hasta.toIso8601String(),
      };
      // Codificado: un texto de búsqueda con espacios o símbolos rompería la
      // query sin esto — no es un detalle cosmético, es lo que hace que
      // "café con leche" busque eso y no reviente la URL.
      final query = params.entries
          .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
          .join('&');
      final r = await ref.read(apiProvider).get('/transactions?$query') as Map<String, dynamic>;
      final totales = (r['totals'] as Map<String, dynamic>?) ?? const {};
      setState(() {
        _items = (r['items'] as List)
            .map((e) => Transaction.fromJson(e as Map<String, dynamic>))
            .toList();
        _total = (r['total'] as num?)?.toInt() ?? _items.length;
        _totalGastos = (totales['expense'] as num?)?.toDouble() ?? 0;
        _totalIngresos = (totales['income'] as num?)?.toDouble() ?? 0;
        final ajustes = (totales['adjustments'] as Map<String, dynamic>?) ?? const {};
        _totalAjustes =
            ((ajustes['income'] as num?)?.toDouble() ?? 0) -
            ((ajustes['expense'] as num?)?.toDouble() ?? 0);
      });
      _aterrizarEnLaLista();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'No llegué al servidor. Inténtalo otra vez.');
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  /// Qué tramo de fechas recorta la lista.
  ///
  /// La precedencia es la de siempre y ahora vive en un solo sitio: el día
  /// suelto manda sobre el tramo, y el tramo sobre "este mes". Estaba escrita
  /// dentro de `_cargar` y el exportador tenía su propia versión, más corta —
  /// que solo miraba "este mes"—, así que abrir el historial desde una porción
  /// del anillo y exportar bajaba el historial completo.
  (DateTime?, DateTime?) _rangoDelFiltro() {
    final dia = _diaPedido;
    if (dia != null) {
      return (dia, finInclusivo(DateTime(dia.year, dia.month, dia.day + 1)));
    }
    // El tramo con el que se llegó desde un gráfico. Va antes que "este mes" por
    // lo mismo que el día suelto: es el recorte que pidió el enlace, y
    // ensancharlo mostraría una lista que nadie pidió.
    if (widget.desde != null && widget.hasta != null) {
      return (widget.desde, widget.hasta);
    }
    // "Este mes" recorta el rango de verdad — a diferencia de la agrupación, que
    // solo decide en qué bloques se parte lo que ya trajo. Mismo mes calendario
    // que usa Panorama para su pastilla "Mes".
    if (_mesActual) {
      final hoy = DateTime.now();
      return (DateTime(hoy.year, hoy.month, 1), finInclusivo(DateTime(hoy.year, hoy.month + 1, 1)));
    }
    return (null, null);
  }

  /// Alargar la lista. Vuelve a pedir desde la fila 1 con más filas: es lo que
  /// hace que ningún bloque quede cortado hacia atrás.
  void _verMas() {
    setState(() => _viendo = (_viendo + _paso).clamp(_paso, _tope));
    _cargar();
  }

  /// A qué pantalla le toca refrescar: la comparación si está prendida, la
  /// lista normal si no. Un solo punto de entrada para que la búsqueda y el
  /// filtro de categoría —que alimentan a las dos— no tengan que saber cuál
  /// de las dos está mirando el usuario.
  /// Baja hasta la lista, una sola vez, cuando se llegó pidiendo algo concreto
  /// —un día, una porción del anillo, un tramo—.
  ///
  /// La pantalla tiene cabecera, patrimonio, totales y filtros encima: abrirla
  /// arriba del todo deja al usuario buscando las filas que fue a ver.
  void _aterrizarEnLaLista() {
    final llegoPidiendoAlgo = widget.dia != null || widget.origen != null || widget.desde != null;
    if (_yaAterrizo || !llegoPidiendoAlgo || _items.isEmpty) return;
    _yaAterrizo = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final destino = _anclaLista.currentContext;
      if (destino == null || !mounted) return;
      Scrollable.ensureVisible(
        destino,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOut,
        // Un pelo de aire arriba: pegada al borde, la primera fila se lee como
        // cortada.
        alignment: 0.04,
      );
    });
  }

  Future<void> _recargar() => _compararMes != null ? _cargarComparacion() : _cargar();

  void _buscar(String texto) {
    // Redibuja ya, para que la "×" de borrar aparezca al tipear y no 350ms
    // después — lo que sí espera es el viaje al backend, más abajo.
    setState(() {});
    _debounce?.cancel();
    // 350ms de silencio antes de pedirle al backend: sin esto, escribir
    // "cafetería" son diez consultas —una por letra— para una sola búsqueda.
    _debounce = Timer(const Duration(milliseconds: 350), () {
      setState(() => _viendo = _paso);
      _recargar();
    });
  }

  (DateTime, DateTime, int) _rangoHastaDia(String claveMes, int diaCorte) {
    final partes = claveMes.split('-');
    final anio = int.parse(partes[0]);
    final mes = int.parse(partes[1]);
    final diasEnMes = DateTime(anio, mes + 1, 0).day;
    // Un mes más corto que el de hoy (comparar el 31 contra febrero) se corta
    // en su propio último día, no pide un día que no existe.
    final dia = diaCorte > diasEnMes ? diasEnMes : diaCorte;
    return (DateTime(anio, mes, 1), finInclusivo(DateTime(anio, mes, dia + 1)), dia);
  }

  Future<void> _cargarComparacion() async {
    final clave = _compararMes;
    if (clave == null) return;
    setState(() {
      _cargandoComparacion = true;
      _errorComparacion = false;
    });
    try {
      final hoy = DateTime.now();
      final claveActual = '${hoy.year}-${hoy.month.toString().padLeft(2, '0')}';
      // Acotado a [1, hoy.day]: un corte más allá de hoy le pediría al mes en
      // curso gastos que todavía no existen.
      final dia = (_diaCorte ?? hoy.day).clamp(1, hoy.day);
      final (desdeActual, hastaActual, diaEfectivoActual) = _rangoHastaDia(claveActual, dia);
      // "Todo el mes" solo se aplica al lado comparado: 31 se acota solo al
      // tamaño real de ese mes en `_rangoHastaDia`.
      final (desdeAnterior, hastaAnterior, diaEfectivoAnterior) = _rangoHastaDia(
        clave,
        _compararTodoMes ? 31 : dia,
      );
      final texto = _busqueda.text.trim();

      Future<Map<String, dynamic>> pedir(DateTime desde, DateTime hasta) async {
        final params = <String, String>{
          'take': '1000',
          'kind': 'MOVEMENT',
          if (_categoria != null && _categoria!.id.isNotEmpty) 'categoryId': _categoria!.id,
          if (_origen != null) 'origen': _origen!,
          // El orden vale también acá: comparar dos meses y no poder ver el
          // más caro primero es justo lo que uno quiere hacer con dos listas
          // al lado.
          if (_orden != null) 'orden': _orden!,
          if (texto.isNotEmpty) 'q': texto,
          'from': desde.toIso8601String(),
          'to': hasta.toIso8601String(),
        };
        final query = params.entries
            .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
            .join('&');
        return await ref.read(apiProvider).get('/transactions?$query') as Map<String, dynamic>;
      }

      final resultados = await Future.wait([
        pedir(desdeActual, hastaActual),
        pedir(desdeAnterior, hastaAnterior),
      ]);

      List<Transaction> soloGastos(Map<String, dynamic> r) => (r['items'] as List)
          .map((e) => Transaction.fromJson(e as Map<String, dynamic>))
          .where((t) => t.isExpense)
          .toList();
      double totalGasto(Map<String, dynamic> r) =>
          (((r['totals'] as Map<String, dynamic>?) ?? const {})['expense'] as num?)?.toDouble() ??
          0;

      if (!mounted) return;
      setState(() {
        _gastosActual = soloGastos(resultados[0]);
        _totalActual = totalGasto(resultados[0]);
        _gastosAnterior = soloGastos(resultados[1]);
        _totalAnterior = totalGasto(resultados[1]);
        _diaEfectivoActual = diaEfectivoActual;
        _diaEfectivoAnterior = diaEfectivoAnterior;
        _ocultosActual = {};
        _ocultosAnterior = {};
      });
    } catch (_) {
      if (mounted) setState(() => _errorComparacion = true);
    } finally {
      if (mounted) setState(() => _cargandoComparacion = false);
    }
  }

  /// Exportar exactamente este filtro — categoría, búsqueda y "Este mes" si está
  /// prendida — y no las filas que están a la vista. Por eso pide de nuevo al
  /// backend con el mismo filtro y sin tope, en vez de exportar `_items`: la
  /// lista muestra las primeras 50 y crece a pedido, pero lo que se baja es el
  /// filtro entero.
  Future<void> _exportar() async {
    final formato = await showAppModal<ExportFormat>(
      context,
      title: 'Exportar movimientos',
      subtitle: _mesActual ? 'Este mes' : 'Todo el historial',
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
    if (formato == null || !mounted) return;

    final user = ref.read(userProvider);
    // El mismo tramo que la lista, no solo "este mes": abrir el historial desde
    // una porción del anillo y exportar bajaba el historial completo.
    final (desde, hasta) = _rangoDelFiltro();

    List<Transaction> transacciones;
    try {
      final params = <String, String>{
        'take': '1000',
        if (_categoria != null && _categoria!.id.isNotEmpty) 'categoryId': _categoria!.id,
        if (_origen != null) 'origen': _origen!,
        // Lo que se ve es lo que se descarga, también en el orden.
        if (_orden != null) 'orden': _orden!,
        if (_busqueda.text.trim().isNotEmpty) 'q': _busqueda.text.trim(),
        if (desde != null) 'from': desde.toIso8601String(),
        if (hasta != null) 'to': hasta.toIso8601String(),
      };
      final query = params.entries
          .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
          .join('&');
      final r = await ref.read(apiProvider).get('/transactions?$query') as Map<String, dynamic>;
      transacciones = (r['items'] as List)
          .map((e) => Transaction.fromJson(e as Map<String, dynamic>))
          .toList();
    } on ApiException catch (e) {
      if (mounted) {
        await showFeedback(
          context,
          title: 'No se pudo exportar',
          message: e.message,
          tone: FeedbackTone.error,
        );
      }
      return;
    } catch (_) {
      if (mounted) {
        await showFeedback(
          context,
          title: 'No se pudo exportar',
          message: 'No llegué al servidor.',
          tone: FeedbackTone.error,
        );
      }
      return;
    }

    final resultado = buildExport(
      transacciones: transacciones,
      formato: formato,
      periodoId: _mesActual ? 'historial-mes-actual' : 'historial',
      periodoLabel: _mesActual ? 'este mes' : 'todo el historial',
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

    if (resultado.recortado && mounted) {
      await showFeedback(
        context,
        title: 'Archivo recortado',
        message: 'Había más de 1000 movimientos en este filtro; el archivo trae los primeros 1000.',
        tone: FeedbackTone.aviso,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final user = ref.watch(userProvider);
    final posicion = ref.watch(cashPositionProvider);
    // Con una sola cuenta el nombre no aporta: sería la misma palabra en cada
    // fila. Con dos es lo que uno viene a comprobar.
    final variasCuentas = (ref.watch(accountsProvider).valueOrNull ?? const []).length > 1;

    // Cuántas filas quedan sin mostrar, que es lo que decide si hay "ver más".
    final faltan = _total - _items.length > 0 ? _total - _items.length : 0;

    return RefreshableScreen(
      onRefresh: () async {
        ref.invalidate(cashPositionProvider);
        await _recargar();
      },
      children: [
        Row(
          children: [
            IconTapTarget(
              semanticLabel: 'Volver',
              onTap: () => Navigator.of(context).maybePop(),
              child: AppIcon(AppIconData.chevronLeft, size: 20, color: colors.foreground),
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: ScreenHeader(kicker: 'Movimientos', title: 'Historial'),
            ),
          ],
        ),
        const SizedBox(height: Spacing.md),

        // El titular: lo que suma lo que estás viendo.
        //
        // Es la pregunta de esta pantalla y estaba en texto chico, en una línea
        // con otras dos cifras, debajo del patrimonio — un número que ni
        // siquiera depende del filtro. Ahora el patrimonio es la línea de apoyo
        // y esto es el titular.
        if (!_cargando && _error == null && _compararMes == null) ...[
          Text(
            'GASTADO EN LO QUE ESTÁS VIENDO',
            style: AppText.kicker(colors.sageInk.withValues(alpha: 0.8)),
          ),
          const SizedBox(height: 3),
          Text(
            Money.format(_totalGastos - _descontado.gasto, user.currency),
            style: AppText.money(colors.danger, size: 28, weight: FontWeight.w700),
          ),
          const SizedBox(height: 3),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$_total ${_total == 1 ? "movimiento" : "movimientos"}',
                  style: AppText.small(colors.oliveInk.withValues(alpha: 0.75)),
                ),
                if (faltan > 0)
                  TextSpan(
                    text: ' · viendo ${_items.length}',
                    style: AppText.small(colors.oliveInk.withValues(alpha: 0.55)),
                  ),
                TextSpan(
                  text: '   ·   Ingresado ',
                  style: AppText.small(colors.oliveInk.withValues(alpha: 0.75)),
                ),
                TextSpan(
                  text: Money.format(_totalIngresos - _descontado.ingreso, user.currency),
                  style: AppText.small(colors.sageInk).copyWith(fontWeight: FontWeight.w600),
                ),
                if (_totalAjustes - _descontado.ajuste != 0) ...[
                  TextSpan(
                    text: '   ·   Ajustes ',
                    style: AppText.small(colors.oliveInk.withValues(alpha: 0.75)),
                  ),
                  TextSpan(
                    text:
                        '${_totalAjustes - _descontado.ajuste > 0 ? '+' : '−'}'
                        '${Money.format((_totalAjustes - _descontado.ajuste).abs(), user.currency)}',
                    style: AppText.small(
                      colors.oliveInk.withValues(alpha: 0.75),
                    ).copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
              ],
            ),
          ),
          // Que las cifras de arriba no son todo lo que hay hay que decirlo: un
          // total descontado sin aviso es un total equivocado.
          if (_descontado.cuantos > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(_ocultos.clear),
                child: Text(
                  'Sin ${_descontado.cuantos} '
                  '${_descontado.cuantos == 1 ? "movimiento descontado" : "movimientos descontados"}'
                  ' · volver a contarlos',
                  style: AppText.tiny(
                    colors.sageInk,
                  ).copyWith(decoration: TextDecoration.underline),
                ),
              ),
            ),
          // El patrimonio, degradado a línea de apoyo. Sigue acá porque cada
          // fila muestra el saldo que había *antes* de ese movimiento y la cifra
          // de hoy es el extremo de esa misma cadena — pero no compite con el
          // total, que es lo que se vino a ver.
          posicion.maybeWhen(
            data: (p) => Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Tu patrimonio de hoy: ${Money.format(p.total, user.currency)}',
                style: AppText.small(colors.oliveInk.withValues(alpha: 0.6)),
              ),
            ),
            orElse: () => const SizedBox.shrink(),
          ),
          const SizedBox(height: Spacing.lg),
        ],

        // La línea que siempre está: buscar, el resto plegado, y el modo.
        //
        // Antes eran seis bloques de filtros apilados que empujaban la lista
        // fuera de la pantalla: había que hacer scroll para ver un movimiento en
        // la pantalla que existe para ver movimientos.
        FieldBox(
          child: Row(
            children: [
              AppIcon(AppIconData.filter, size: 15, color: colors.oliveInk.withValues(alpha: 0.5)),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: AppTextField(
                  controller: _busqueda,
                  // Dice lo que busca de verdad: desde que también mira la
                  // categoría y el monto, "buscar por detalle" prometía menos de
                  // lo que hace.
                  placeholder: 'Detalle, categoría o monto',
                  onChanged: _buscar,
                ),
              ),
              if (_busqueda.text.isNotEmpty)
                IconTapTarget(
                  semanticLabel: 'Borrar búsqueda',
                  onTap: () {
                    _busqueda.clear();
                    _buscar('');
                  },
                  child: AppIcon(
                    AppIconData.close,
                    size: 14,
                    color: colors.oliveInk.withValues(alpha: 0.5),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.sm),
        Row(
          children: [
            _Pastilla(
              texto: _filtrosPuestos > 0 ? 'Filtros · $_filtrosPuestos' : 'Filtros',
              activa: _filtrosPuestos > 0,
              onTap: _abrirFiltros,
            ),
            const Spacer(),
            // Comparar es un modo, no un filtro: al activarlo desaparecen la
            // lista, la paginación y el resumen, y aparecen dos columnas. Estaba
            // escondido en un selector en medio de los filtros, sin nada que
            // avisara del cambio ni forma obvia de volver.
            _Pastilla(
              texto: 'Lista',
              activa: _compararMes == null,
              onTap: () {
                if (_compararMes == null) return;
                setState(() => _compararMes = null);
                _recargar();
              },
            ),
            const SizedBox(width: 6),
            _Pastilla(
              texto: 'Comparar',
              activa: _compararMes != null,
              onTap: () {
                if (_compararMes != null) {
                  _elegirMesComparado();
                  return;
                }
                // Al mes anterior, que es la comparación que se quiere casi
                // siempre. Desde el chip se cambia a cuál.
                setState(() => _compararMes = _mesesParaComparar().first);
                _recargar();
              },
            ),
          ],
        ),

        // Lo que está puesto, y cada cosa se suelta donde se lee. Antes cada
        // filtro se quitaba de una forma distinta —la categoría eligiendo
        // "Todas", el origen tocando "Todo", la búsqueda borrando el texto— y
        // solo el recorte de fechas tenía una ×.
        if (_hayChips) ...[
          const SizedBox(height: Spacing.sm),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (_compararMes != null) ...[
                _ChipFiltro(
                  texto: 'comparando con ${_etiquetaMes(_compararMes!)}',
                  onQuitar: () {
                    setState(() => _compararMes = null);
                    _recargar();
                  },
                ),
                // Hasta qué día se corta. Solo dentro del modo comparar: sin
                // comparación no hay corte que elegir. Se toca para cambiarlo,
                // no para soltarlo — siempre hay un corte, aunque sea hoy.
                _ChipFiltro(
                  texto: _compararTodoMes
                      ? 'todo el mes comparado'
                      : 'hasta el día ${_diaCorte ?? DateTime.now().day}',
                  onQuitar: null,
                  onTocar: _elegirCorte,
                ),
              ],
              if (_busqueda.text.trim().isNotEmpty)
                _ChipFiltro(
                  texto: '“${_busqueda.text.trim()}”',
                  onQuitar: () {
                    _busqueda.clear();
                    _buscar('');
                  },
                ),
              if (_categoria != null)
                _ChipFiltro(
                  texto: _categoria!.ruta,
                  onQuitar: () {
                    setState(() {
                      _categoria = null;
                      _viendo = _paso;
                    });
                    _recargar();
                  },
                ),
              if (_origen != null)
                _ChipFiltro(
                  texto: _etiquetaOrigen(_origen!),
                  onQuitar: () {
                    setState(() {
                      _origen = null;
                      _viendo = _paso;
                    });
                    _recargar();
                  },
                ),
              if (_mesActual)
                _ChipFiltro(
                  texto: 'solo este mes',
                  onQuitar: () {
                    setState(() {
                      _mesActual = false;
                      _viendo = _paso;
                    });
                    _recargar();
                  },
                ),
              if (_orden != null)
                _ChipFiltro(
                  texto: _orden == 'monto' ? 'de mayor a menor' : 'de menor a mayor',
                  onQuitar: () {
                    setState(() {
                      _orden = null;
                      _viendo = _paso;
                    });
                    _recargar();
                  },
                ),
              // De dónde vino este historial, cuando vino de un día o un tramo
              // concreto. Sin esto la pantalla se abre con cinco filas y ninguna
              // explicación de por qué faltan las demás. No se puede soltar: es
              // con lo que se abrió, y quitarlo dejaría una pantalla que nadie
              // pidió — para eso está el botón de volver.
              if (_diaPedido != null)
                _ChipFiltro(texto: 'solo el ${Fechas.diaConAnio(_diaPedido!)}', onQuitar: null)
              else if (widget.desde != null && widget.hasta != null)
                _ChipFiltro(
                  texto:
                      'del ${Fechas.diaConAnio(widget.desde!)} al ${Fechas.diaConAnio(widget.hasta!)}',
                  onQuitar: null,
                ),
            ],
          ),
        ],

        const SizedBox(height: Spacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _exportar,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIcon(AppIconData.download, size: 13, color: colors.sageInk),
                const SizedBox(width: 5),
                Text(
                  'Exportar este filtro',
                  style: AppText.small(colors.sageInk).copyWith(fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Spacing.lg),

        if (_compararMes != null)
          _cargandoComparacion
              ? Container(
                  height: 240,
                  decoration: BoxDecoration(
                    color: colors.surface.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(Radii.lg),
                  ),
                )
              : _errorComparacion
              ? AppCard(
                  dashed: true,
                  child: Text(
                    'No llegué al servidor. Inténtalo otra vez.',
                    style: AppText.small(colors.danger),
                  ),
                )
              : _Comparacion(
                  compararMes: _compararMes!,
                  etiquetaMes: _etiquetaMes,
                  gastosActual: _gastosActual,
                  totalActual: _totalActual,
                  diaActual: _diaEfectivoActual,
                  gastosAnterior: _gastosAnterior,
                  totalAnterior: _totalAnterior,
                  diaAnterior: _diaEfectivoAnterior,
                  compararTodoMes: _compararTodoMes,
                  ocultosActual: _ocultosActual,
                  ocultosAnterior: _ocultosAnterior,
                  onToggleActual: (id) => setState(() {
                    _ocultosActual = {..._ocultosActual};
                    if (!_ocultosActual.remove(id)) _ocultosActual.add(id);
                  }),
                  onToggleAnterior: (id) => setState(() {
                    _ocultosAnterior = {..._ocultosAnterior};
                    if (!_ocultosAnterior.remove(id)) _ocultosAnterior.add(id);
                  }),
                  currency: user.currency,
                )
        else if (_cargando)
          Container(
            height: 240,
            decoration: BoxDecoration(
              color: colors.surface.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(Radii.lg),
            ),
          )
        else if (_error != null)
          AppCard(dashed: true, child: Text(_error!, style: AppText.small(colors.danger)))
        else if (_items.isEmpty)
          AppCard(
            dashed: true,
            child: Text(
              'No hay movimientos con estos filtros.',
              style: AppText.small(colors.oliveInk.withValues(alpha: 0.75)),
            ),
          )
        else
          (_agrupacion == 'todo' || _orden != null)
              ? AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final t in _items)
                        _FilaHistorial(
                          t: t,
                          currency: user.currency,
                          oculto: _ocultos.contains(t.id),
                          onAlternar: _alternarOculto,
                          mostrarSaldoPrevio: _orden == null,
                          mostrarCuenta: variasCuentas,
                        ),
                    ],
                  ),
                )
              : _ListaAgrupada(
                  items: _items,
                  agrupacion: _agrupacion,
                  currency: user.currency,
                  ocultos: _ocultos,
                  onAlternar: _alternarOculto,
                  mostrarCuenta: variasCuentas,
                ),

        // El pie de la lista: cuánto se ve, cuánto falta y el botón para
        // alargarla.
        if (_compararMes == null && !_cargando && _error == null) ...[
          const SizedBox(height: Spacing.lg),
          Center(
            child: Column(
              children: [
                Text(
                  '${_items.length} de $_total ${_total == 1 ? "movimiento" : "movimientos"}',
                  style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.6)),
                ),
                if (faltan > 0) ...[
                  const SizedBox(height: Spacing.sm),
                  if (_viendo >= _tope)
                    // Al tope se dice, en vez de fingir que eso es todo.
                    Text(
                      'Son los primeros $_tope. Quedan $faltan más — acota con un filtro o '
                      'búscalo por su detalle, que llega mucho más rápido que seguir alargando '
                      'la lista.',
                      textAlign: TextAlign.center,
                      style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.6)),
                    )
                  else
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _verMas,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Spacing.lg,
                          vertical: Spacing.sm,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(Radii.md),
                          border: Border.all(color: colors.sage.withValues(alpha: 0.5)),
                        ),
                        child: Text(
                          'Ver ${faltan < _paso ? faltan : _paso} más',
                          style: AppText.small(
                            colors.sageInk,
                          ).copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// Los últimos 6 meses calendario antes del actual, más nuevo primero —
  /// los mismos que ofrece la web (`recentMonthKeys`).
  List<String> _mesesParaComparar() {
    final hoy = DateTime.now();
    return [
      for (var i = 1; i <= 6; i++)
        () {
          final d = DateTime(hoy.year, hoy.month - i, 1);
          return '${d.year}-${d.month.toString().padLeft(2, '0')}';
        }(),
    ];
  }

  String _etiquetaMes(String clave) {
    final partes = clave.split('-');
    final anio = int.parse(partes[0]);
    final mes = int.parse(partes[1]);
    final d = DateTime(anio, mes, 15);
    final nombre = Fechas.mesLargo(d);
    final nombreCapitalizado = '${nombre[0].toUpperCase()}${nombre.substring(1)}';
    return anio == DateTime.now().year ? nombreCapitalizado : '$nombreCapitalizado $anio';
  }
}

final _categoriasEnUsoProvider = FutureProvider<List<Category>>((ref) async {
  final r = await ref.watch(apiProvider).get('/categories/in-use') as List;
  return r.map((e) => Category.fromJson(e as Map<String, dynamic>)).toList();
});

double _sumaVisible(List<Transaction> gastos, Set<String> ocultos) =>
    gastos.where((t) => !ocultos.contains(t.id)).fold<double>(0, (acc, t) => acc + t.amount);

/// Dos meses, mismo corte de día, uno al lado del otro. La cifra de arriba
/// responde "¿voy peor o mejor?"; las listas de abajo, "¿en qué?" — réplica de
/// `HistorialComparison.tsx`. El ojito es el mismo de Panorama: tapar un gasto
/// puntual de cualquiera de los dos lados recalcula la cifra de arriba en el
/// momento, sin salir a editar nada.
class _Comparacion extends StatelessWidget {
  const _Comparacion({
    required this.compararMes,
    required this.etiquetaMes,
    required this.gastosActual,
    required this.totalActual,
    required this.diaActual,
    required this.gastosAnterior,
    required this.totalAnterior,
    required this.diaAnterior,
    required this.compararTodoMes,
    required this.ocultosActual,
    required this.ocultosAnterior,
    required this.onToggleActual,
    required this.onToggleAnterior,
    required this.currency,
  });

  final String compararMes;
  final String Function(String) etiquetaMes;
  final List<Transaction> gastosActual;
  final double totalActual;
  final int diaActual;
  final List<Transaction> gastosAnterior;
  final double totalAnterior;
  final int diaAnterior;
  final bool compararTodoMes;
  final Set<String> ocultosActual;
  final Set<String> ocultosAnterior;
  final void Function(String id) onToggleActual;
  final void Function(String id) onToggleAnterior;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final visibleActual = _sumaVisible(gastosActual, ocultosActual);
    final visibleAnterior = _sumaVisible(gastosAnterior, ocultosAnterior);
    final diferencia = visibleActual - visibleAnterior;
    final porcentaje = visibleAnterior > 0 ? (diferencia / visibleAnterior) * 100 : null;
    final etiquetaAnterior = etiquetaMes(compararMes);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppCard(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: 'Llevas gastado ', style: AppText.small(colors.foreground)),
                TextSpan(
                  text: Money.format(visibleActual, currency),
                  style: AppText.small(colors.danger).copyWith(fontWeight: FontWeight.w600),
                ),
                TextSpan(text: ' del 1 al $diaActual', style: AppText.small(colors.foreground)),
                if (visibleAnterior > 0) ...[
                  TextSpan(
                    text: diferencia == 0 ? ', igual que en ' : ', ',
                    style: AppText.small(colors.foreground),
                  ),
                  if (diferencia != 0)
                    TextSpan(
                      text:
                          '${diferencia > 0 ? '${Money.format(diferencia, currency)} más' : '${Money.format(diferencia.abs(), currency)} menos'}'
                          '${porcentaje != null ? ' (${porcentaje > 0 ? '+' : ''}${porcentaje.toStringAsFixed(0)}%)' : ''} que en ',
                      style: AppText.small(
                        diferencia > 0 ? colors.danger : colors.sageInk,
                      ).copyWith(fontWeight: FontWeight.w600),
                    ),
                  TextSpan(text: etiquetaAnterior, style: AppText.small(colors.foreground)),
                ],
                const TextSpan(text: '.'),
              ],
            ),
          ),
        ),
        const SizedBox(height: Spacing.md),
        _LadoComparacion(
          titulo: 'Este mes',
          rangoLabel: 'del 1 al $diaActual',
          total: visibleActual,
          gastos: gastosActual,
          ocultos: ocultosActual,
          onToggleHide: onToggleActual,
          currency: currency,
        ),
        const SizedBox(height: Spacing.md),
        _LadoComparacion(
          titulo: etiquetaAnterior,
          rangoLabel: compararTodoMes ? 'el mes completo' : 'del 1 al $diaAnterior',
          total: visibleAnterior,
          gastos: gastosAnterior,
          ocultos: ocultosAnterior,
          onToggleHide: onToggleAnterior,
          currency: currency,
        ),
      ],
    );
  }
}

class _LadoComparacion extends StatelessWidget {
  const _LadoComparacion({
    required this.titulo,
    required this.rangoLabel,
    required this.total,
    required this.gastos,
    required this.ocultos,
    required this.onToggleHide,
    required this.currency,
  });

  final String titulo;
  final String rangoLabel;
  final double total;
  final List<Transaction> gastos;
  final Set<String> ocultos;
  final void Function(String id) onToggleHide;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    titulo,
                    style: AppText.small(colors.foreground).copyWith(fontWeight: FontWeight.w600),
                  ),
                  Text(rangoLabel, style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.55))),
                ],
              ),
              Row(
                children: [
                  if (ocultos.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: Spacing.sm),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          for (final id in [...ocultos]) {
                            onToggleHide(id);
                          }
                        },
                        child: Text(
                          'Contar todo',
                          style: AppText.tiny(
                            colors.oliveInk.withValues(alpha: 0.6),
                          ).copyWith(fontWeight: FontWeight.w500),
                        ),
                      ),
                    ),
                  Text(
                    Money.format(total, currency),
                    style: AppText.money(colors.danger, size: 13.5),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          if (gastos.isEmpty)
            Text(
              'Sin gastos en este rango.',
              style: AppText.small(colors.oliveInk.withValues(alpha: 0.55)),
            )
          else
            ExpenseRows(
              transactions: gastos,
              total: total,
              currency: currency,
              hidden: ocultos,
              onToggleHide: onToggleHide,
              numbered: false,
            ),
        ],
      ),
    );
  }
}

String _claveGrupo(DateTime d, String agrupacion) => switch (agrupacion) {
  'dia' => '${d.year}-${d.month}-${d.day}',
  'semana' => () {
    final lunes = d.subtract(Duration(days: d.weekday - 1));
    return '${lunes.year}-${lunes.month}-${lunes.day}';
  }(),
  'mes' => '${d.year}-${d.month}',
  _ => '${d.year}',
};

String _tituloGrupo(DateTime d, String agrupacion) => switch (agrupacion) {
  'dia' => Fechas.diaLargo(d),
  'semana' => 'Semana del ${Fechas.dia(d.subtract(Duration(days: d.weekday - 1)))}',
  'mes' => '${Fechas.mesLargo(d)[0].toUpperCase()}${Fechas.mesLargo(d).substring(1)} ${d.year}',
  _ => '${d.year}',
};

class _ListaAgrupada extends StatelessWidget {
  const _ListaAgrupada({
    required this.mostrarCuenta,
    required this.items,
    required this.agrupacion,
    required this.currency,
    required this.ocultos,
    required this.onAlternar,
  });

  final List<Transaction> items;
  final String agrupacion;
  final String currency;
  final Set<String> ocultos;
  final void Function(String id) onAlternar;
  final bool mostrarCuenta;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final grupos = <String, List<Transaction>>{};
    final ordenGrupos = <String>[];
    for (final t in items) {
      final clave = _claveGrupo(t.occurredAt.toLocal(), agrupacion);
      if (!grupos.containsKey(clave)) {
        grupos[clave] = [];
        ordenGrupos.add(clave);
      }
      grupos[clave]!.add(t);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final clave in ordenGrupos) ...[
          Builder(
            builder: (context) {
              final filas = grupos[clave]!;
              final neto = filas
                  .where((t) => t.kind == 'MOVEMENT')
                  .fold<double>(0, (acc, t) => acc + (t.isExpense ? -t.amount : t.amount));
              return Padding(
                padding: const EdgeInsets.only(bottom: Spacing.sm, top: Spacing.md),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _tituloGrupo(filas.first.occurredAt.toLocal(), agrupacion),
                      style: AppText.kicker(colors.sageInk.withValues(alpha: 0.8)),
                    ),
                    // El neto del grupo sigue el mismo código de color que sus
                    // filas: un día que cerró en rojo se ve rojo desde el
                    // encabezado, sin tener que sumar las filas con la vista.
                    Text(
                      Money.signed(neto, currency),
                      style: AppText.money(
                        neto >= 0 ? colors.sageInk : colors.danger,
                        size: 12,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final t in grupos[clave]!)
                  _FilaHistorial(
                    t: t,
                    currency: currency,
                    oculto: ocultos.contains(t.id),
                    onAlternar: onAlternar,
                  ), // agrupada: siempre cronológica, así que el saldo previo va
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _FilaHistorial extends StatelessWidget {
  const _FilaHistorial({
    required this.t,
    required this.currency,
    required this.oculto,
    required this.onAlternar,
    this.mostrarSaldoPrevio = true,
    this.mostrarCuenta = false,
  });

  final Transaction t;
  final String currency;

  /// Si está descontado de las cifras del encabezado. No se borra ni se filtra:
  /// la fila se queda a la vista, apagada, porque si desapareciera no habría
  /// forma de volver a contarla.
  final bool oculto;
  final void Function(String id) onAlternar;

  /// El saldo que había antes de este movimiento.
  ///
  /// **Solo en orden cronológico.** Cada valor es correcto por separado, pero la
  /// columna se lee como un saldo corrido —"tenías esto, pasó esto"— y ordenada
  /// por monto las filas no son consecutivas: se ven 1.240 → 890 → 1.310 uno
  /// debajo del otro y parece que el dinero fue y vino. La cifra no está mal;
  /// presentarla en ese orden sí.
  final bool mostrarSaldoPrevio;

  /// Si la fila dice a qué cuenta fue.
  ///
  /// Solo con más de una cuenta: con una sola, repetir su nombre en cada fila es
  /// decir lo mismo cincuenta veces.
  final bool mostrarCuenta;

  String get _etiqueta => switch (t.kind) {
    'TRANSFER' => t.detail.isNotEmpty ? t.detail : 'Transferencia',
    'ADJUSTMENT' => 'Ajuste de saldo',
    'OPENING_BALANCE' => 'Saldo inicial',
    _ => t.label,
  };

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final esOpening = t.kind == 'OPENING_BALANCE';

    final fila = Container(
      padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.foreground.withValues(alpha: 0.06))),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _etiqueta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body(colors.foreground.withValues(alpha: esOpening ? 0.6 : 1)),
                ),
                Text(
                  [
                    if (t.kind == 'MOVEMENT') t.category?.name,
                    if (t.kind == 'MOVEMENT') MediosDePago.etiqueta(t.paymentMethod),
                    if (mostrarCuenta && t.accountName.isNotEmpty) t.accountName,
                    Fechas.diaConAnio(t.occurredAt.toLocal()),
                  ].whereType<String>().join(' · '),
                  style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.55)),
                ),
              ],
            ),
          ),
          const SizedBox(width: Spacing.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                t.kind == 'TRANSFER' || esOpening
                    ? Money.format(t.amount, currency)
                    : '${t.isExpense ? "−" : "+"}${Money.format(t.amount, currency)}',
                style: AppText.money(
                  // Mismo criterio que en Movimientos y que en la web: el gasto
                  // en rojo. Las filas que no son ni gasto ni ingreso —el saldo
                  // inicial, una transferencia— se quedan en gris, porque
                  // pintarlas de rojo diría que salió plata y no salió.
                  esOpening
                      ? colors.oliveInk.withValues(alpha: 0.6)
                      : t.kind == 'TRANSFER'
                      ? colors.oliveInk.withValues(alpha: 0.8)
                      : t.isExpense
                      ? colors.danger
                      : colors.sageInk,
                  size: 13.5,
                ),
              ),
              // Mismo tratamiento que en Movimientos: el saldo previo en su
              // propia línea, verde salvo en rojo — no mezclado en el
              // subtítulo gris con la categoría y la fecha.
              if (t.balanceBefore != null && mostrarSaldoPrevio)
                Text(
                  Money.format(t.balanceBefore!, currency),
                  style: AppText.money(
                    t.balanceBefore! >= 0 ? colors.positiveBalance : colors.danger,
                    size: 11,
                    weight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ],
      ),
    );

    // El ojito va fuera del gesto que abre el detalle: si estuviera dentro,
    // tocarlo abriría el movimiento en vez de descontarlo.
    return Row(
      children: [
        Expanded(
          child: Opacity(
            opacity: oculto ? 0.4 : 1,
            child: esOpening
                ? fila
                : GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => abrirDetalleMovimiento(context, t),
                    child: fila,
                  ),
          ),
        ),
        Semantics(
          button: true,
          label: oculto ? 'Volver a contar este movimiento' : 'Descontar este movimiento',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onAlternar(t.id),
            child: Padding(
              padding: const EdgeInsets.only(left: Spacing.sm, top: Spacing.sm, bottom: Spacing.sm),
              child: AppIcon(
                oculto ? AppIconData.eyeOff : AppIconData.eye,
                size: 15,
                color: colors.oliveInk.withValues(alpha: oculto ? 0.7 : 0.35),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Pastilla extends StatelessWidget {
  const _Pastilla({required this.texto, required this.activa, required this.onTap});

  final String texto;
  final bool activa;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md, vertical: 7),
        decoration: BoxDecoration(
          color: activa ? colors.sageDark : null,
          borderRadius: BorderRadius.circular(Radii.pill),
          border: Border.all(color: activa ? colors.sageDark : colors.surfaceBorder),
        ),
        alignment: Alignment.center,
        child: Text(
          texto,
          style: AppText.small(
            activa ? const Color(0xFFFFFFFF) : colors.foreground,
          ).copyWith(fontWeight: FontWeight.w500),
        ),
      ),
    );
  }
}
