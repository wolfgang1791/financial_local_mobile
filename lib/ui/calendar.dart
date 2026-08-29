import 'package:flutter/widgets.dart';

import '../design/theme.dart';
import '../design/tokens.dart';
import 'icons.dart';
import 'modal.dart';

const _diasSemana = ['L', 'M', 'M', 'J', 'V', 'S', 'D'];
const _meses = [
  'Enero',
  'Febrero',
  'Marzo',
  'Abril',
  'Mayo',
  'Junio',
  'Julio',
  'Agosto',
  'Septiembre',
  'Octubre',
  'Noviembre',
  'Diciembre',
];

/// Elegir una fecha con un calendario propio.
///
/// Reemplaza al selector de 14 días que tenía `nuevo_movimiento.dart`: ese
/// alcance bastaba cuando la única forma de tocar una fecha vieja era el
/// historial de la web, pero con edición de movimientos y formularios de
/// deudas/metas/flujos ya hace falta poder elegir cualquier día, no solo los
/// últimos catorce.
///
/// Sin `showDatePicker` de Material por la misma razón que el resto de la
/// app: se ve como un widget de plataforma y rompe la paleta propia.
Future<DateTime?> pickDate(
  BuildContext context, {
  required DateTime inicial,
  DateTime? primera,
  DateTime? ultima,
  String titulo = 'Elige una fecha',
}) {
  return showAppModal<DateTime>(
    context,
    title: titulo,
    builder: (context) => _Calendario(inicial: inicial, primera: primera, ultima: ultima),
  );
}

bool _mismoDia(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

class _Calendario extends StatefulWidget {
  const _Calendario({required this.inicial, this.primera, this.ultima});

  final DateTime inicial;
  final DateTime? primera;
  final DateTime? ultima;

  @override
  State<_Calendario> createState() => _CalendarioState();
}

class _CalendarioState extends State<_Calendario> {
  late DateTime _mesMostrado = DateTime(widget.inicial.year, widget.inicial.month);

  bool _mesHabilitado(int delta) {
    final objetivo = DateTime(_mesMostrado.year, _mesMostrado.month + delta);
    if (delta < 0 && widget.primera != null) {
      if (objetivo.isBefore(DateTime(widget.primera!.year, widget.primera!.month))) return false;
    }
    if (delta > 0 && widget.ultima != null) {
      if (objetivo.isAfter(DateTime(widget.ultima!.year, widget.ultima!.month))) return false;
    }
    return true;
  }

  bool _diaHabilitado(DateTime d) {
    if (widget.primera != null &&
        d.isBefore(DateTime(widget.primera!.year, widget.primera!.month, widget.primera!.day))) {
      return false;
    }
    if (widget.ultima != null &&
        d.isAfter(DateTime(widget.ultima!.year, widget.ultima!.month, widget.ultima!.day))) {
      return false;
    }
    return true;
  }

  void _cambiarMes(int delta) {
    if (!_mesHabilitado(delta)) return;
    setState(() => _mesMostrado = DateTime(_mesMostrado.year, _mesMostrado.month + delta));
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final hoy = DateTime.now();
    final primerDiaMes = DateTime(_mesMostrado.year, _mesMostrado.month, 1);
    final offset = primerDiaMes.weekday - 1; // lunes = 0
    final diasEnMes = DateTime(_mesMostrado.year, _mesMostrado.month + 1, 0).day;
    final celdas = offset + diasEnMes;
    final filas = (celdas / 7).ceil();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _FlechaMes(
              icono: AppIconData.chevronLeft,
              habilitada: _mesHabilitado(-1),
              onTap: () => _cambiarMes(-1),
            ),
            Expanded(
              child: Text(
                '${_meses[_mesMostrado.month - 1]} ${_mesMostrado.year}',
                textAlign: TextAlign.center,
                style: AppText.bodyMedium(colors.foreground),
              ),
            ),
            _FlechaMes(
              icono: AppIconData.chevronRight,
              habilitada: _mesHabilitado(1),
              onTap: () => _cambiarMes(1),
            ),
          ],
        ),
        const SizedBox(height: Spacing.md),
        Row(
          children: [
            for (final d in _diasSemana)
              Expanded(
                child: Center(
                  child: Text(d, style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.55))),
                ),
              ),
          ],
        ),
        const SizedBox(height: Spacing.xs),
        for (var fila = 0; fila < filas; fila++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                for (var col = 0; col < 7; col++)
                  Expanded(
                    child: Builder(
                      builder: (context) {
                        final indice = fila * 7 + col - offset;
                        if (indice < 0 || indice >= diasEnMes) return const SizedBox(height: 40);
                        final dia = DateTime(_mesMostrado.year, _mesMostrado.month, indice + 1);
                        return _CeldaDia(
                          dia: dia,
                          esHoy: _mismoDia(dia, hoy),
                          seleccionado: _mismoDia(dia, widget.inicial),
                          habilitado: _diaHabilitado(dia),
                          onTap: () => Navigator.of(context).pop(dia),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _FlechaMes extends StatelessWidget {
  const _FlechaMes({required this.icono, required this.habilitada, required this.onTap});

  final AppIconData icono;
  final bool habilitada;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return IconTapTarget(
      semanticLabel: icono == AppIconData.chevronLeft ? 'Mes anterior' : 'Mes siguiente',
      onTap: habilitada ? onTap : () {},
      child: AppIcon(
        icono,
        size: 18,
        color: habilitada ? colors.foreground : colors.foreground.withValues(alpha: 0.22),
      ),
    );
  }
}

class _CeldaDia extends StatelessWidget {
  const _CeldaDia({
    required this.dia,
    required this.esHoy,
    required this.seleccionado,
    required this.habilitado,
    required this.onTap,
  });

  final DateTime dia;
  final bool esHoy;
  final bool seleccionado;
  final bool habilitado;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final color = !habilitado
        ? colors.foreground.withValues(alpha: 0.2)
        : seleccionado
        ? const Color(0xFFFFFFFF)
        : colors.foreground;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: habilitado ? onTap : null,
      child: Container(
        height: 40,
        alignment: Alignment.center,
        margin: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: seleccionado ? colors.sageDark : null,
          border: esHoy && !seleccionado
              ? Border.all(color: colors.sage.withValues(alpha: 0.6))
              : null,
        ),
        child: Text('${dia.day}', style: AppText.small(color)),
      ),
    );
  }
}
