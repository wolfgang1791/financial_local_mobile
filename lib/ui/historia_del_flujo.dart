import 'package:flutter/widgets.dart';

import '../data/models.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../ui/format.dart';

/// Cómo ha cambiado un gasto fijo, mes a mes.
///
/// Vive dentro del formulario del propio flujo y no en una pantalla aparte: la
/// pregunta —"¿la luz subió?"— aparece justo cuando estás mirando el recibo de
/// este mes, y la respuesta tiene que estar ahí, no a tres toques. En Panorama
/// sería una tarjeta más compitiendo con el resto; acá es el contexto de lo que
/// ya abriste.
///
/// **La serie es el dato, no una reconstrucción.** Cada mes guarda su propio
/// monto —lo que valió ese mes, exista o no el pago— así que un mes sin marcar
/// también cuenta. Sacarla de los movimientos registrados habría perdido esos
/// meses y habría fechado cada uno el día en que se marcó, que es otra cosa.
class HistoriaDelFlujo extends StatelessWidget {
  const HistoriaDelFlujo({
    super.key,
    required this.meses,
    required this.mesElegido,
    required this.currency,
  });

  /// Los meses del flujo, con lo que valió cada uno.
  final Map<String, FlowMonth> meses;

  /// El mes que se está editando: se marca para no perder el hilo.
  final String? mesElegido;
  final String currency;

  static const _ultimos = 8;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    // Solo los meses que este flujo tuvo. Uno dado de alta en agosto no tiene
    // julio, y pintarlo en cero diría que ese mes costó nada.
    final ordenados = meses.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    final serie = ordenados.length > _ultimos
        ? ordenados.sublist(ordenados.length - _ultimos)
        : ordenados;
    if (serie.isEmpty) return const SizedBox.shrink();

    final maximo = serie.map((e) => e.value.amount).fold<double>(0, (a, b) => a > b ? a : b);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: Spacing.lg),
        Text('CÓMO HA CAMBIADO', style: AppText.kicker(colors.sageInk.withValues(alpha: 0.8))),
        const SizedBox(height: 6),
        if (serie.length == 1)
          Text(
            'Es el primer mes registrado: todavía no hay con qué compararlo.',
            style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.6)),
          )
        else ...[
          for (var i = 0; i < serie.length; i++)
            _FilaDelMes(
              mes: serie[i].key,
              monto: serie[i].value.amount,
              anterior: i > 0 ? serie[i - 1].value.amount : null,
              maximo: maximo,
              esElElegido: serie[i].key == mesElegido,
              currency: currency,
            ),
          const SizedBox(height: 6),
          // El salto entre el primero y el último, que es la pregunta de fondo:
          // "¿esto viene subiendo?". Una serie de ocho meses no la contesta sola.
          _Resumen(
            primero: serie.first.value.amount,
            ultimo: serie.last.value.amount,
            desde: serie.first.key,
            currency: currency,
          ),
        ],
      ],
    );
  }
}

class _FilaDelMes extends StatelessWidget {
  const _FilaDelMes({
    required this.mes,
    required this.monto,
    required this.anterior,
    required this.maximo,
    required this.esElElegido,
    required this.currency,
  });

  final String mes;
  final double monto;
  final double? anterior;
  final double maximo;
  final bool esElElegido;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final cambio = anterior == null ? 0.0 : monto - anterior!;
    // La barra se mide contra el mes más caro de la serie: es lo que deja ver la
    // forma —subió, bajó, se mantiene— sin leer un número.
    final proporcion = maximo > 0 ? (monto / maximo).clamp(0.04, 1.0) : 0.0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          SizedBox(
            width: 46,
            child: Text(
              _etiqueta(mes),
              maxLines: 1,
              style: AppText.tiny(
                esElElegido ? colors.sageInk : colors.oliveInk.withValues(alpha: 0.55),
              ).copyWith(fontWeight: esElElegido ? FontWeight.w600 : FontWeight.w400),
            ),
          ),
          Expanded(
            child: Container(
              height: 6,
              decoration: BoxDecoration(
                color: colors.foreground.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(Radii.pill),
              ),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: proporcion,
                child: Container(
                  decoration: BoxDecoration(
                    color: colors.sage.withValues(alpha: esElElegido ? 1 : 0.45),
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: Spacing.sm),
          SizedBox(
            width: 66,
            child: Text(
              Money.format(monto, currency),
              textAlign: TextAlign.right,
              style: AppText.money(colors.foreground, size: 12),
            ),
          ),
          // La variación, solo cuando la hay: una columna de guiones ocupa el
          // mismo ancho y no dice nada.
          SizedBox(
            width: 52,
            child: Text(
              cambio == 0 ? '' : '${cambio > 0 ? "+" : "−"}${cambio.abs().toStringAsFixed(2)}',
              textAlign: TextAlign.right,
              style: AppText.tiny(
                cambio == 0
                    ? colors.oliveInk.withValues(alpha: 0.3)
                    : cambio > 0
                    ? colors.danger
                    : colors.sageInk,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Resumen extends StatelessWidget {
  const _Resumen({
    required this.primero,
    required this.ultimo,
    required this.desde,
    required this.currency,
  });

  final double primero;
  final double ultimo;
  final String desde;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final cambio = ultimo - primero;
    final estilo = AppText.tiny(colors.oliveInk.withValues(alpha: 0.6));

    if (cambio.abs() < 0.005) {
      return Text('Igual que en ${_etiqueta(desde, largo: true)}.', style: estilo);
    }
    final porcentaje = primero > 0 ? (cambio / primero).abs() * 100 : 0;
    return Text(
      '${cambio > 0 ? "Subió" : "Bajó"} ${Money.format(cambio.abs(), currency)} '
      'desde ${_etiqueta(desde, largo: true)}'
      '${porcentaje >= 1 ? " (${porcentaje.toStringAsFixed(0)}%)" : ""}.',
      style: estilo,
    );
  }
}

const _nombres = [
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

/// "2026-07" → "jul 26", o "julio" en su versión larga. Sin `intl` a propósito:
/// son doce palabras y acá no hace falta cargar el formateo de fechas para
/// escribir tres letras.
String _etiqueta(String mes, {bool largo = false}) {
  final partes = mes.split('-');
  if (partes.length != 2) return mes;
  final indice = (int.tryParse(partes[1]) ?? 1) - 1;
  if (indice < 0 || indice > 11) return mes;
  if (largo) {
    const completos = [
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
    return completos[indice];
  }
  return '${_nombres[indice]} ${partes[0].substring(2)}';
}
