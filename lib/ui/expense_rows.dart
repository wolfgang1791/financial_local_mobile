import 'package:flutter/widgets.dart';

import '../data/models.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import 'format.dart';
import 'icons.dart';

/// Las filas de gasto, de mayor a menor.
///
/// La barra va **detrás** de la fila y no en una columna aparte: así la magnitud
/// se lee sin quitarle ancho al nombre, que es lo primero que se achica en un
/// teléfono. Es la misma decisión que en la web, y acá pesa más todavía porque
/// hay la mitad de ancho.
class ExpenseRows extends StatelessWidget {
  const ExpenseRows({
    super.key,
    required this.transactions,
    required this.total,
    required this.currency,
    this.hidden = const {},
    this.onToggleHide,
    this.numbered = true,
  });

  final List<Transaction> transactions;

  /// El denominador del porcentaje: el gasto del periodo. Siempre el mismo,
  /// incluso al entrar en una categoría, para que un porcentaje signifique lo
  /// mismo acá que en el anillo.
  final double total;
  final String currency;
  final Set<String> hidden;
  final void Function(String id)? onToggleHide;
  final bool numbered;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    if (transactions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.xl),
        child: Text(
          'No hay gastos en este periodo.',
          textAlign: TextAlign.center,
          style: AppText.small(colors.oliveInk.withValues(alpha: 0.6)),
        ),
      );
    }

    // El tope de las barras sale de lo que sigue contando: medirlas contra un
    // gasto que el usuario acaba de descontar las dejaría todas cortas frente a
    // una referencia que ya no está en pantalla.
    final contando = transactions.where((t) => !hidden.contains(t.id)).toList();
    final max = (contando.isEmpty ? transactions : contando)
        .map((t) => t.amount)
        .fold<double>(0, (a, b) => a > b ? a : b);

    return Column(
      children: [
        for (var i = 0; i < transactions.length; i++)
          _Fila(
            t: transactions[i],
            indice: i + 1,
            max: max,
            total: total,
            currency: currency,
            oculto: hidden.contains(transactions[i].id),
            numbered: numbered,
            onToggleHide: onToggleHide,
            colors: colors,
          ),
      ],
    );
  }
}

class _Fila extends StatelessWidget {
  const _Fila({
    required this.t,
    required this.indice,
    required this.max,
    required this.total,
    required this.currency,
    required this.oculto,
    required this.numbered,
    required this.onToggleHide,
    required this.colors,
  });

  final Transaction t;
  final int indice;
  final double max;
  final double total;
  final String currency;
  final bool oculto;
  final bool numbered;
  final void Function(String id)? onToggleHide;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    final tachado = oculto ? TextDecoration.lineThrough : TextDecoration.none;
    final proporcion = max > 0 && !oculto ? (t.amount / max).clamp(0.0, 1.0) : 0.0;

    return Opacity(
      opacity: oculto ? 0.45 : 1,
      child: Stack(
        children: [
          // La barra, decorativa: el monto exacto y el porcentaje ya están
          // escritos al lado.
          Positioned.fill(
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: proporcion,
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  decoration: BoxDecoration(
                    color: colors.sage.withValues(alpha: 0.14),
                    borderRadius: const BorderRadius.horizontal(right: Radius.circular(Radii.sm)),
                  ),
                ),
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: colors.foreground.withValues(alpha: 0.06))),
            ),
            padding: const EdgeInsets.symmetric(vertical: Spacing.sm, horizontal: 2),
            child: Row(
              children: [
                if (numbered)
                  SizedBox(
                    width: 18,
                    child: Text(
                      '$indice',
                      textAlign: TextAlign.right,
                      style: AppText.money(colors.oliveInk.withValues(alpha: 0.4), size: 11),
                    ),
                  ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.bodyMedium(colors.foreground).copyWith(decoration: tachado),
                      ),
                      Text(
                        [
                          t.category?.name,
                          Fechas.dia(t.occurredAt),
                        ].whereType<String>().join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.6)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      Money.format(t.amount, currency),
                      style: AppText.money(
                        colors.foreground,
                        size: 13.5,
                      ).copyWith(decoration: tachado),
                    ),
                    Text(
                      oculto || total <= 0
                          ? '—'
                          : '${(t.amount / total * 100).toStringAsFixed(1)}%',
                      style: AppText.money(colors.sageInk, size: 11, weight: FontWeight.w600),
                    ),
                  ],
                ),
                if (onToggleHide != null)
                  IconTapTarget(
                    semanticLabel: oculto
                        ? 'Volver a contar este gasto'
                        : 'Quitar este gasto de la cuenta',
                    onTap: () => onToggleHide!(t.id),
                    child: AppIcon(
                      oculto ? AppIconData.eyeOff : AppIconData.eye,
                      size: 16,
                      color: colors.foreground.withValues(alpha: 0.35),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
