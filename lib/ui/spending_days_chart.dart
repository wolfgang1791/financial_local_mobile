import 'package:flutter/widgets.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import '../data/category_icon.dart';
import '../data/preferencias.dart';
import '../data/models.dart';
import '../local_engine/spending_days.dart';
import 'buttons.dart';
import 'format.dart';
import 'icons.dart';
import 'modal.dart';

/// Los días que gastaste y los que no, con forma de calendario.
///
/// Puerto de `frontend/src/components/SpendingDays.tsx`.
///
/// Un calendario y no un par de barras: "16 con gasto, 5 sin" cabe en una
/// frase, y si el gráfico solo dibujara esas dos cifras sobraría. Lo que una
/// barra no puede mostrar es **el patrón** —si los días sin gastar están
/// sueltos o son una racha, si caen en fin de semana, si el mes arranca
/// tranquilo y se desmadra en la quincena—, y eso se lee de un vistazo en una
/// rejilla con forma de calendario.
///
/// Los colores están validados en los dos temas —bandas de luminosidad,
/// separación para daltonismo y contraste contra la superficie—:
///   node scripts/validate_palette.js "#2a78d6,#e34948,#008300,#9a9a92" --mode light --surface "#e8dcc0"
/// El gris marca FAIL de croma a propósito: no es la identidad de una
/// categoría, es la ausencia de una. Y el rojo contra el verde queda en ΔE 7.2
/// en protanopia, en la banda que solo es legal con codificación secundaria:
/// por eso los dos extremos llevan además su flecha dentro de la casilla y su
/// fecha escrita abajo. El color acelera la lectura; no es lo único que la
/// sostiene.
const _diasSemana = ['L', 'M', 'X', 'J', 'V', 'S', 'D'];
const _mesesCortos = [
  'ene',
  'feb',
  'mar',
  'abr',
  'may',
  'jun',
  'jul',
  'ago',
  'sep',
  'oct',
  'nov',
  'dic',
];
const _mesesLargos = [
  'enero',
  'febrero',
  'marzo',
  'abril',
  'mayo',
  'junio',
  'julio',
  'agosto',
  'septiembre',
  'octubre',
  'noviembre',
  'diciembre',
];
const _diasLargos = ['lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo'];

/// Hasta acá el periodo se dibuja como el calendario que uno tiene en la
/// cabeza. Pasado eso son demasiadas filas para una tarjeta, y se transpone a
/// semanas en columnas, que es la forma que aguanta un año entero.
const _maximoCalendario = 75;

String _fechaLarga(SpendingDay d) =>
    '${_diasLargos[d.weekday]} ${d.day} de ${_mesesLargos[d.month - 1]}';

String _diaCorto(SpendingDay d) => '${d.day} ${_mesesCortos[d.month - 1]}.';

class SpendingDaysChart extends StatefulWidget {
  const SpendingDaysChart({
    super.key,
    required this.resumen,
    required this.categorias,
    required this.periodo,
    required this.currency,
    required this.esPeriodoAbierto,
    required this.onVerDia,
  });

  final SpendingDays resumen;

  /// Las subcategorías que este usuario usa de verdad, para poder elegir cuáles
  /// marcar. Del catálogo entero no sirve: son cien y noventa no le pasan por
  /// delante nunca.
  final List<Category> categorias;

  /// "julio", "los últimos 30 días" — el mismo periodo que filtra todo Panorama.
  final String periodo;
  final String currency;

  /// Si el periodo llega hasta hoy. Manda en si tiene sentido decir "llevas 3
  /// días sin gastar" y en marcar la casilla de hoy.
  final bool esPeriodoAbierto;

  /// Abrir el historial en ese día ("2026-08-07"). La cifra sola deja a medias:
  /// "el jueves se fueron 429.90" invita a preguntar en qué.
  final void Function(String fecha) onVerDia;

  @override
  State<SpendingDaysChart> createState() => _SpendingDaysChartState();
}

class _SpendingDaysChartState extends State<SpendingDaysChart> {
  /// Dos interruptores y no uno.
  ///
  /// El alquiler y la cuota del préstamo son dos cosas distintas: uno puede
  /// querer ver el mes sin el alquiler pero con las cuotas, o al revés, o sin
  /// ninguna de las dos. Juntarlos en una sola pastilla obligaba a aceptar el
  /// paquete. Se apagan y se prenden — mirar sin algo no borra nada, solo
  /// cambia la pregunta.
  bool _sinFijos = false;
  bool _sinDeudas = false;

  /// Hasta tres subcategorías marcadas, por id.
  ///
  /// Tres y no las que quiera: el ícono vive dentro de una casilla de 38 puntos
  /// y a partir de ahí deja de leerse de un vistazo, que es lo único que esta
  /// marca sabe hacer. Marcar todo es no marcar nada.
  final _marcadas = <String>[];

  SpendingDay? _tocado;

  @override
  void initState() {
    super.initState();
    // Lo marcado sobrevive a cerrar la app: elegir tres subcategorías es una
    // decisión, y volver a tomarla en cada arranque la convierte en un trámite.
    Preferencias.abrir().then((prefs) {
      if (!mounted) return;
      final guardadas = prefs.listaDeTextos(claveMarcasDelCalendario);
      if (guardadas.isEmpty) return;
      setState(() => _marcadas.addAll(guardadas));
    });
  }

  /// Lo marcado, ya resuelto a ícono y nombre, en el orden en que se eligió.
  List<({String id, String icono, String label})> get _marcas => [
    for (final id in _marcadas)
      if (widget.categorias.where((c) => c.id == id).firstOrNull case final c?)
        (id: c.id, icono: categoryIconFor(c.icon, c.name), label: c.ruta),
  ];

  List<({String id, String icono, String label})> _marcasDe(SpendingDay dia) => [
    for (final m in _marcas)
      if (dia.categorias.contains(m.id)) m,
  ];

  Future<void> _elegirMarcas() async {
    final elegidas = await showAppModal<List<String>>(
      context,
      title: 'Marcar en el calendario',
      builder: (context) =>
          _SelectorMarcas(categorias: widget.categorias, elegidas: [..._marcadas]),
    );
    if (elegidas == null || !mounted) return;
    setState(() {
      _marcadas
        ..clear()
        ..addAll(elegidas);
    });
    final prefs = await Preferencias.abrir();
    await prefs.guardarLista(claveMarcasDelCalendario, elegidas);
  }

  /// Tocar un día abre sus movimientos.
  ///
  /// Un día sin nada registrado no lleva a ningún lado: iría a una lista vacía,
  /// que es un callejón sin salida disfrazado de enlace.
  void tocar(SpendingDay dia) {
    if (!dia.conGasto) return;
    widget.onVerDia(dia.date);
  }

  SpendingDays get _vista => _sinFijos || _sinDeudas
      ? resumirDias(widget.resumen.days, sinFijos: _sinFijos, sinDeudas: _sinDeudas)
      : widget.resumen;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final vista = _vista;
    // Un periodo de dos días no tiene patrón que mostrar; la frase de arriba ya
    // lo dice todo.
    if (vista.days.length < 3) return const SizedBox.shrink();

    final total = vista.days.length;
    final calendario = total <= _maximoCalendario;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('${vista.conGasto} de $total días', style: AppText.sectionTitle(colors.foreground)),
        const SizedBox(height: 2),
        Text(
          vista.sinGasto == 0
              ? 'Gastaste todos los días ${widget.periodo}.'
              : '${vista.sinGasto} ${vista.sinGasto == 1 ? "día" : "días"} sin gastar nada '
                    '${widget.periodo}.',
          style: AppText.small(colors.oliveInk.withValues(alpha: 0.75)),
        ),
        const SizedBox(height: Spacing.md),
        // Lo que ya estaba comprometido, fuera de la cuenta — cada cosa por su
        // lado. El alquiler y la cuota del préstamo salen de la cuenta el mismo
        // día todos los meses: cuentan como gasto, pero no como "salí a
        // gastar". Cada combinación contesta una pregunta distinta.
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
              _tocado = null;
            }),
          ),
        ),
        // Marcar subcategorías: el ícono dentro del día.
        //
        // Un calendario dice cuándo saliste a gastar; con esto dice además en
        // qué, sin abrir nada.
        const SizedBox(height: Spacing.md),
        Align(
          alignment: Alignment.centerLeft,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _elegirMarcas,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIcon(AppIconData.edit, size: 12, color: colors.sageInk),
                const SizedBox(width: 5),
                // Flexible: en un teléfono angosto el rótulo largo se pasaba
                // del ancho de la tarjeta.
                Flexible(
                  child: Text(
                    _marcas.isEmpty
                        ? 'Marcar categorías'
                        : 'Marcando ${_marcas.map((m) => m.icono).join(" ")}',
                    overflow: TextOverflow.ellipsis,
                    style: AppText.small(colors.sageInk).copyWith(fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Spacing.lg),
        if (calendario)
          _Calendario(vista: vista, estado: this)
        else
          _Tira(vista: vista, estado: this),
        const SizedBox(height: Spacing.lg),
        _Cifras(vista: vista, estado: this),
        const SizedBox(height: Spacing.md),
        // La línea de detalle vive siempre en el mismo sitio y cambia al tocar
        // un día, en vez de aparecer y desaparecer moviendo todo lo de abajo.
        SizedBox(
          height: 34,
          child: Text(
            _tocado == null
                ? 'Toca un día para ver sus movimientos'
                      '${_sinFijos || _sinDeudas ? ", ya descontado lo de arriba." : "."}'
                : _tocado!.conGasto
                ? '${_fechaLarga(_tocado!)}: '
                      '${Money.format(_tocado!.amount, widget.currency)} en '
                      '${_tocado!.count} ${_tocado!.count == 1 ? "movimiento" : "movimientos"}.'
                : '${_fechaLarga(_tocado!)}: no gastaste nada.',
            style: AppText.small(colors.oliveInk.withValues(alpha: 0.85)),
          ),
        ),
        // La leyenda dice solo lo que la tarjeta no dice ya en otro sitio.
        //
        // Tenía ocho entradas en dos renglones y cuatro sobraban: "Con gasto" y
        // "Sin gasto" con sus cuentas están palabra por palabra en el título de
        // arriba, y "Más gasto ▲" / "Menos gasto ▼" están en las dos fichas de
        // abajo, con su mismo color y además con el monto. Una leyenda que
        // repite lo de al lado no explica el gráfico: lo tapa.
        //
        // Quedan las dos cosas que solo se pueden saber acá: qué significa cada
        // ícono marcado y cuál casilla es hoy.
        Wrap(
          spacing: Spacing.lg,
          runSpacing: Spacing.xs,
          children: [
            // Una entrada por subcategoría marcada que de verdad apareció: la
            // leyenda explica lo que se ve, no el catálogo de lo que podría
            // verse.
            for (final m in _marcas)
              if (vista.days.any((d) => d.categorias.contains(m.id)))
                _Leyenda(color: null, emoji: m.icono, texto: m.label),
            if (widget.esPeriodoAbierto) _Leyenda(color: null, texto: 'Hoy'),
          ],
        ),
      ],
    );
  }
}

/// El extremo al que pertenece una casilla, si es alguno de los dos.
({Color color, String flecha})? _extremoDe(SpendingDay dia, SpendingDays vista, AppColors colors) {
  if (!dia.conGasto || vista.mayor?.date == vista.menor?.date) return null;
  if (dia.date == vista.mayor?.date) return (color: colors.chartAt(7), flecha: '▲');
  if (dia.date == vista.menor?.date) return (color: colors.chartAt(5), flecha: '▼');
  return null;
}

/// Una casilla: un día, con su color y su número.
class _Casilla extends StatelessWidget {
  const _Casilla({
    required this.dia,
    required this.vista,
    required this.tam,
    required this.conNumero,
    required this.esHoy,
    required this.marcas,
    required this.onTap,
  });

  final SpendingDay dia;
  final SpendingDays vista;
  final double tam;
  final bool conNumero;
  final bool esHoy;

  /// Las subcategorías marcadas que aparecieron ese día, ya resueltas a ícono.
  final List<({String id, String icono, String label})> marcas;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final extremo = _extremoDe(dia, vista, colors);
    final fondo =
        extremo?.color ??
        (dia.conGasto ? colors.chartAt(0) : colors.chartOther.withValues(alpha: 0.45));

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: tam,
        height: tam,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: fondo,
          borderRadius: BorderRadius.circular(4),
          border: esHoy ? Border.all(color: colors.sage, width: 2) : null,
        ),
        child: conNumero
            ? FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${dia.day}',
                          style: AppText.tiny(
                            dia.conGasto ? const Color(0xFFFFFFFF) : colors.foreground,
                          ).copyWith(fontWeight: FontWeight.w600),
                        ),
                        if (extremo != null)
                          Text(
                            extremo.flecha,
                            style: AppText.tiny(
                              const Color(0xFFFFFFFF),
                            ).copyWith(fontSize: 7, height: 1.6),
                          ),
                      ],
                    ),
                    // Los íconos van dentro de la casilla, bajo el número: son
                    // marcas de ese día, y afuera serían otra fila de cosas que
                    // leer.
                    if (marcas.isNotEmpty)
                      Text(
                        marcas.map((m) => m.icono).join(),
                        style: AppText.tiny(colors.foreground).copyWith(fontSize: 8),
                      ),
                  ],
                ),
              )
            : null,
      ),
    );
  }
}

/// Un bloque por mes, con el 1 bajo su día de la semana. Un calendario que no
/// empieza en su columna no es un calendario, es una lista de números.
class _Calendario extends StatelessWidget {
  const _Calendario({required this.vista, required this.estado});

  final SpendingDays vista;
  final _SpendingDaysChartState estado;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final hoy = estado.widget.esPeriodoAbierto ? vista.days.last.date : null;

    final bloques = <String, List<SpendingDay?>>{};
    for (final d in vista.days) {
      final clave = '${d.year}-${d.month}';
      final celdas = bloques[clave] ??= List<SpendingDay?>.filled(d.weekday, null, growable: true);
      celdas.add(d);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Las casillas ocupan el ancho disponible, sin pasarse de 44: en una
        // tarjeta ancha un calendario de cuadritos diminutos se ve a medio
        // cargar, y uno de cuadrados enormes tampoco es un calendario.
        final tam = ((constraints.maxWidth - 6 * 4) / 7).clamp(20.0, 44.0);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (final entrada in bloques.entries) ...[
              SizedBox(
                width: tam * 7 + 24,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _mesesLargos[int.parse(entrada.key.split('-')[1]) - 1],
                      style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.6)),
                    ),
                    const SizedBox(height: Spacing.xs),
                    // La cabecera mide exactamente lo mismo que la rejilla —
                    // siete casillas y seis huecos—, para que cada letra caiga
                    // sobre su columna y el bloque no se pase del ancho.
                    Row(
                      children: [
                        for (var i = 0; i < _diasSemana.length; i++) ...[
                          if (i > 0) const SizedBox(width: 4),
                          SizedBox(
                            width: tam,
                            child: Text(
                              _diasSemana[i],
                              textAlign: TextAlign.center,
                              style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.45)),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: Spacing.xs),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final dia in entrada.value)
                          if (dia == null)
                            SizedBox(width: tam, height: tam)
                          else
                            _Casilla(
                              dia: dia,
                              vista: vista,
                              tam: tam,
                              conNumero: tam >= 26,
                              esHoy: dia.date == hoy,
                              marcas: estado._marcasDe(dia),
                              onTap: () => estado.tocar(dia),
                            ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Spacing.lg),
            ],
          ],
        );
      },
    );
  }
}

/// Semanas en columnas, que se desplaza a lo ancho. Un año son 53 columnas y
/// encogerlas hasta que entren las volvería ilegibles.
class _Tira extends StatelessWidget {
  const _Tira({required this.vista, required this.estado});

  final SpendingDays vista;
  final _SpendingDaysChartState estado;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final hoy = estado.widget.esPeriodoAbierto ? vista.days.last.date : null;
    final tam = vista.days.length <= 120 ? 16.0 : 11.0;

    final semanas = <List<SpendingDay?>>[];
    var actual = List<SpendingDay?>.filled(vista.days.first.weekday, null, growable: true);
    for (final d in vista.days) {
      actual.add(d);
      if (actual.length == 7) {
        semanas.add(actual);
        actual = [];
      }
    }
    if (actual.isNotEmpty) {
      semanas.add([...actual, ...List<SpendingDay?>.filled(7 - actual.length, null)]);
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      // Arranca mostrando el final: se dibuja del día más viejo al más nuevo,
      // así que en un periodo largo lo primero que se vería es hace medio año y
      // hoy quedaría fuera de pantalla. La pregunta casi siempre es "cómo
      // vengo", no "cómo venía en febrero".
      reverse: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Solo lunes, miércoles y viernes: las siete letras a este tamaño se
          // convierten en una mancha.
          Column(
            children: [
              for (var i = 0; i < 7; i++)
                SizedBox(
                  height: tam + 3,
                  width: 14,
                  child: Text(
                    i.isEven ? _diasSemana[i] : '',
                    textAlign: TextAlign.right,
                    style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.45)),
                  ),
                ),
            ],
          ),
          const SizedBox(width: Spacing.xs),
          for (var i = 0; i < semanas.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final dia in semanas[i])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: dia == null
                          ? SizedBox(width: tam, height: tam)
                          : _Casilla(
                              dia: dia,
                              vista: vista,
                              tam: tam,
                              conNumero: false,
                              esHoy: dia.date == hoy,
                              marcas: const [],
                              onTap: () => estado.tocar(dia),
                            ),
                    ),
                  // El rótulo del mes va sobre la primera semana que lo estrena.
                  SizedBox(
                    width: tam,
                    child: Text(
                      _estrenaMes(semanas, i)
                          ? _mesesCortos[semanas[i].firstWhere((d) => d != null)!.month - 1]
                          : '',
                      style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.5)),
                      overflow: TextOverflow.visible,
                      softWrap: false,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  bool _estrenaMes(List<List<SpendingDay?>> semanas, int i) {
    final primero = semanas[i].where((d) => d != null).firstOrNull;
    if (primero == null) return false;
    if (i == 0) return true;
    final anterior = semanas[i - 1].where((d) => d != null).lastOrNull;
    return anterior == null || anterior.month != primero.month;
  }
}

/// Las cifras que el calendario no puede decir solo.
class _Cifras extends StatelessWidget {
  const _Cifras({required this.vista, required this.estado});

  final SpendingDays vista;
  final _SpendingDaysChartState estado;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final currency = estado.widget.currency;
    final promedio = vista.conGasto > 0 ? vista.totalGastado / vista.conGasto : 0.0;

    return Wrap(
      spacing: Spacing.xxl,
      runSpacing: Spacing.md,
      children: [
        _Dato(
          etiqueta: 'Racha sin gastar',
          valor: vista.rachaSinGasto == 0
              ? 'Ninguna'
              : '${vista.rachaSinGasto} ${vista.rachaSinGasto == 1 ? "día" : "días seguidos"}',
        ),
        if (estado.widget.esPeriodoAbierto && vista.rachaActual > 0)
          _Dato(
            etiqueta: 'Llevas',
            valor: '${vista.rachaActual} ${vista.rachaActual == 1 ? "día" : "días"} sin gastar',
          ),
        _Dato(etiqueta: 'Promedio por día con gasto', valor: Money.format(promedio, currency)),
        // Los dos extremos, y un toque abre el historial de ese día: la cifra
        // sola deja a medias — "el jueves se fueron 429.90" invita a preguntar
        // en qué.
        if (vista.mayor != null)
          _Dato(
            etiqueta: 'Día de más gasto',
            valor: '${Money.format(vista.mayor!.amount, currency)}  ${_diaCorto(vista.mayor!)}',
            color: colors.chartAt(7),
            onTap: () => estado.widget.onVerDia(vista.mayor!.date),
          ),
        if (vista.menor != null && vista.menor!.date != vista.mayor?.date)
          _Dato(
            etiqueta: 'Día de menos gasto',
            valor: '${Money.format(vista.menor!.amount, currency)}  ${_diaCorto(vista.menor!)}',
            color: colors.chartAt(5),
            onTap: () => estado.widget.onVerDia(vista.menor!.date),
          ),
      ],
    );
  }
}

class _Dato extends StatelessWidget {
  const _Dato({required this.etiqueta, required this.valor, this.color, this.onTap});

  final String etiqueta;
  final String valor;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (color != null) ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
                ),
                const SizedBox(width: 5),
              ],
              Text(etiqueta, style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.6))),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            valor,
            style: AppText.bodyMedium(
              onTap == null ? colors.foreground : colors.sageInk,
            ).copyWith(decoration: onTap == null ? null : TextDecoration.underline),
          ),
        ],
      ),
    );
  }
}

class _Leyenda extends StatelessWidget {
  const _Leyenda({required this.color, required this.texto, this.emoji});

  /// Null dibuja el marco de "hoy" en vez de un relleno.
  final Color? color;
  final String texto;

  /// Si lo que identifica no es un color sino una marca dentro de la casilla.
  final String? emoji;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (emoji != null)
          Text(emoji!, style: AppText.tiny(colors.foreground).copyWith(fontSize: 10))
        else
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(3),
              border: color == null ? Border.all(color: colors.sage, width: 2) : null,
            ),
          ),
        const SizedBox(width: 5),
        Text(texto, style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.75))),
      ],
    );
  }
}

/// Pastillas que se prenden y se apagan, no una barra de opciones excluyentes.
///
/// Pública porque el anillo de categorías usa las mismas dos —"sin fijos", "sin
/// cuotas"— y con dos copias se separan al primer retoque.
class Pastillas extends StatelessWidget {
  const Pastillas({
    super.key,
    required this.opciones,
    required this.activas,
    required this.onSelect,
  });

  final List<String> opciones;
  final List<bool> activas;
  final void Function(int) onSelect;

  // Envuelven en vez de vivir dentro de una barra rígida: "Todo el gasto" y
  // "Sin fijos ni deudas" no entran en una fila de 340 puntos, y una barra que
  // no entra no se encoge — se desborda. Dos pastillas sueltas caen a la
  // segunda línea solas.
  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Wrap(
      spacing: Spacing.sm,
      runSpacing: Spacing.sm,
      children: [
        for (var i = 0; i < opciones.length; i++)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onSelect(i),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.md, vertical: 6),
              decoration: BoxDecoration(
                color: activas[i] ? colors.sage : null,
                borderRadius: BorderRadius.circular(Radii.pill),
                border: activas[i]
                    ? null
                    : Border.all(color: colors.foreground.withValues(alpha: 0.14)),
              ),
              child: Text(
                '${activas[i] ? "✓ " : ""}${opciones[i]}',
                style: AppText.tiny(
                  activas[i] ? const Color(0xFF171717) : colors.oliveInk.withValues(alpha: 0.7),
                ).copyWith(fontWeight: activas[i] ? FontWeight.w600 : null),
              ),
            ),
          ),
      ],
    );
  }
}

/// Elegir hasta tres subcategorías para marcarlas en el calendario.
///
/// Al llegar a tres, las que no están elegidas se apagan en vez de
/// desaparecer: una lista que se acorta sola deja al usuario buscando la que
/// acaba de ver.
class _SelectorMarcas extends StatefulWidget {
  const _SelectorMarcas({required this.categorias, required this.elegidas});

  final List<Category> categorias;
  final List<String> elegidas;

  @override
  State<_SelectorMarcas> createState() => _SelectorMarcasState();
}

class _SelectorMarcasState extends State<_SelectorMarcas> {
  late final _elegidas = [...widget.elegidas];

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Elige hasta 3 subcategorías. Los días con ese gasto llevan su ícono dentro.',
          style: AppText.small(colors.oliveInk.withValues(alpha: 0.75)),
        ),
        const SizedBox(height: Spacing.md),
        Flexible(
          child: SingleChildScrollView(
            child: Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.sm,
              children: [
                for (final c in widget.categorias)
                  Builder(
                    builder: (context) {
                      final elegida = _elegidas.contains(c.id);
                      final bloqueada = !elegida && _elegidas.length >= 3;
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: bloqueada
                            ? null
                            : () => setState(() {
                                if (elegida) {
                                  _elegidas.remove(c.id);
                                } else {
                                  _elegidas.add(c.id);
                                }
                              }),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: Spacing.md, vertical: 6),
                          decoration: BoxDecoration(
                            color: elegida ? colors.sage : null,
                            borderRadius: BorderRadius.circular(Radii.pill),
                            border: elegida
                                ? null
                                : Border.all(
                                    color: colors.foreground.withValues(
                                      alpha: bloqueada ? 0.06 : 0.14,
                                    ),
                                  ),
                          ),
                          child: Text(
                            '${categoryIconFor(c.icon, c.name)} ${c.name}',
                            style: AppText.tiny(
                              elegida
                                  ? const Color(0xFF171717)
                                  : colors.oliveInk.withValues(alpha: bloqueada ? 0.3 : 0.75),
                            ).copyWith(fontWeight: elegida ? FontWeight.w600 : null),
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Spacing.lg),
        AppButton(label: 'Listo', onPressed: () => Navigator.of(context).pop(_elegidas)),
        if (_elegidas.isNotEmpty) ...[
          const SizedBox(height: Spacing.sm),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(_elegidas.clear),
            child: Text(
              'Quitar todas',
              textAlign: TextAlign.center,
              style: AppText.small(colors.oliveInk.withValues(alpha: 0.7)),
            ),
          ),
        ],
      ],
    );
  }
}
