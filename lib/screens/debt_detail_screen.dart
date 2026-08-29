import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api.dart';
import '../data/models.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../state/providers.dart';
import '../ui/buttons.dart';
import '../ui/format.dart';
import '../ui/icons.dart';
import '../ui/modal.dart';
import '../ui/refreshable_screen.dart';
import '../ui/surface.dart';
import 'corregir_reparto_modal.dart';
import 'debt_form.dart';
import 'shell.dart';
import 'pay_installment_modal.dart';

/// El detalle de una deuda: lo que cuesta, cómo va, y las acciones —pagar,
/// revertir, editar, cancelar—.
///
/// **Pantalla y no modal.** Era un modal, y le fueron cayendo encima el saldo,
/// seis datos, la proyección, el aviso del desajuste, el historial de pagos y
/// cinco botones: en 390 puntos eso es una hoja que hay que desplazar a ciegas,
/// sin sitio para respirar entre secciones ni para que ninguna tenga jerarquía.
/// Como pantalla cabe la estructura —lo que debes arriba, después a dónde vas,
/// después de dónde vienes, y las condiciones y los botones al final— y además
/// se puede quedar abierta: pagar o corregir un reparto ya no la cierra, la
/// actualiza.
Future<void> abrirDetalleDeuda(BuildContext context, {required Debt deuda}) async {
  await Navigator.of(
    context,
  ).push(PageRouteBuilder(pageBuilder: (context, _, _) => DebtDetailScreen(deudaId: deuda.id)));
}

class DebtDetailScreen extends ConsumerStatefulWidget {
  const DebtDetailScreen({super.key, required this.deudaId});

  /// Se recibe el **id** y no la deuda: la pantalla se queda abierta mientras
  /// se paga y se corrigen repartos, así que tiene que leer siempre la versión
  /// vigente. Con una copia congelada, el saldo de arriba seguiría diciendo lo
  /// de antes después de pagar.
  final String deudaId;

  @override
  ConsumerState<DebtDetailScreen> createState() => _DebtDetailScreenState();
}

class _DebtDetailScreenState extends ConsumerState<DebtDetailScreen> {
  bool _revirtiendo = false;
  bool _cambiandoEstado = false;

  /// La deuda, siempre la vigente. `null` mientras carga o si se eliminó.
  Debt? get _deuda =>
      ref.watch(debtsProvider).valueOrNull?.where((x) => x.id == widget.deudaId).firstOrNull;

  Future<void> _revertir() async {
    final d = _deuda;
    if (d == null) return;
    final ok = await showFeedback(
      context,
      title: '¿Revertir el pago de este mes?',
      message:
          'Devuelve ${Money.format(d.paidAmountThisMonth, d.currency)} a tu cuenta y borra el pago registrado.',
      tone: FeedbackTone.aviso,
      confirmLabel: 'Sí, revertir',
      cancelLabel: 'Cancelar',
      destructive: true,
    );
    if (ok != true || !mounted) return;
    setState(() => _revirtiendo = true);
    try {
      await ref.read(apiProvider).post('/debts/${d.id}/revert-payment', const {});
      ref
        ..invalidate(debtsProvider)
        ..invalidate(cashPositionProvider)
        ..invalidate(recentTransactionsProvider);
      // Sin `pop`: la pantalla se queda y se actualiza sola al invalidarse el
      // proveedor. Cerrarla obligaba a volver a buscar la deuda para ver el
      // resultado de lo que acabas de hacer.
    } on ApiException catch (e) {
      if (mounted) {
        await showFeedback(
          context,
          title: 'No se pudo revertir',
          message: e.message,
          tone: FeedbackTone.error,
        );
      }
    } finally {
      if (mounted) setState(() => _revirtiendo = false);
    }
  }

  /// Cancelar o reactivar.
  ///
  /// Cancelar no es eliminar: la deuda deja de contar en los totales, en el
  /// plan y en las recomendaciones, pero se queda a la vista como histórico. Es
  /// lo que sirve para la que ya no aplica y que igual pasó —te la condonaron,
  /// la refinanciaste, resultó que no era tuya—, donde borrar se llevaría una
  /// historia que explica movimientos reales.
  Future<void> _alternarActiva() async {
    final d = _deuda;
    if (d == null) return;
    final cancelar = d.isActive;

    // Se pregunta solo al cancelar: reactivar devuelve las cosas a como
    // estaban, y pedir permiso para deshacer algo es ruido.
    if (cancelar) {
      final ok = await showFeedback(
        context,
        title: '¿Cancelar esta deuda?',
        message:
            'Deja de contar en tus totales, en el plan y en las recomendaciones. '
            'Se queda en la lista como histórico y la puedes reactivar cuando quieras.',
        tone: FeedbackTone.aviso,
        confirmLabel: 'Sí, cancelar',
        cancelLabel: 'No',
      );
      if (ok != true || !mounted) return;
    }

    setState(() => _cambiandoEstado = true);
    try {
      await ref
          .read(apiProvider)
          .post('/debts/${d.id}/${cancelar ? "cancel" : "reactivate"}', const {});
      ref
        ..invalidate(debtsProvider)
        ..invalidate(cashPositionProvider);
    } on ApiException catch (e) {
      if (mounted) {
        await showFeedback(
          context,
          title: cancelar ? 'No se pudo cancelar' : 'No se pudo reactivar',
          message: e.message,
          tone: FeedbackTone.error,
        );
      }
    } finally {
      if (mounted) setState(() => _cambiandoEstado = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final d = _deuda;

    if (d == null) {
      // O todavía carga, o se eliminó desde otro sitio. En los dos casos lo
      // honesto es no dibujar cifras viejas.
      return RefreshableScreen(
        onRefresh: () async => ref.invalidate(debtsProvider),
        children: [
          _Cabecera(titulo: 'Deuda', subtitulo: null, colors: colors),
          const SizedBox(height: Spacing.lg),
          const AppCard(child: Text('Cargando…')),
        ],
      );
    }

    final tieneTcea = d.costRateAnnual != null;
    final p = d.projection;

    // Cómo va la cuota de este mes, con la única urgencia que hay en toda la
    // pantalla: cuántos días faltan para que venza. "Pendiente" a secas no dice
    // si es hoy o dentro de tres semanas, y esa es justo la diferencia que hace
    // actuar.
    final hoy = DateTime.now();
    final diasParaVencer = d.dueDate != null
        ? DateTime(
            d.dueDate!.year,
            d.dueDate!.month,
            d.dueDate!.day,
          ).difference(DateTime(hoy.year, hoy.month, hoy.day)).inDays
        : (d.dueDay == null ? null : d.dueDay! - hoy.day);

    String estadoDelMes() {
      if (d.pagadaEsteMes) return 'Ya la pagaste este mes';
      final falta = d.pagoParcial
          ? 'Faltan ${Money.format(d.pendingThisMonth, d.currency)}'
          : 'Pendiente';
      if (diasParaVencer == null) return falta;
      if (diasParaVencer == 0) return '$falta · vence hoy';
      if (diasParaVencer > 0) {
        return '$falta · vence en $diasParaVencer ${diasParaVencer == 1 ? "día" : "días"}';
      }
      final atraso = -diasParaVencer;
      return '$falta · venció hace $atraso ${atraso == 1 ? "día" : "días"}';
    }

    // Rojo solo cuando de verdad aprieta. Si todo lo pendiente se pinta de rojo,
    // el rojo deja de significar algo.
    final urgente = !d.pagadaEsteMes && diasParaVencer != null && diasParaVencer <= 3;

    // Cuánto llevas amortizado: el único dato emocional de una pantalla de
    // deuda, y no estaba en ninguna parte.
    final avance = d.originalPrincipal > 0
        ? ((d.originalPrincipal - d.balance) / d.originalPrincipal * 100).clamp(0, 100)
        : 0.0;

    return RefreshableScreen(
      onRefresh: () async {
        ref.invalidate(debtsProvider);
        setState(() {});
      },
      children: [
        _Cabecera(titulo: d.name, subtitulo: d.institution, colors: colors),
        const SizedBox(height: Spacing.lg),

        // Arriba de todo: lo que hace que el resto de la pantalla sea creíble.
        // Si tu cuota no cuadra con tu tasa, la proyección de abajo miente, y
        // enterarse después de leerla es enterarse tarde.
        _AvisoDelDesajuste(deuda: d, onCambio: () => setState(() {})),

        // ── La tarjeta que manda: "¿cuándo salgo y cuánto me cuesta?", que es
        // lo único accionable de una deuda. El saldo es contexto.
        if (d.saldada)
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('DEUDA PAGADA', style: AppText.kicker(colors.sageInk)),
                const SizedBox(height: 6),
                Text(
                  Money.format(0, d.currency),
                  style: AppText.money(colors.sageInk, size: 30, weight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  'Terminaste de pagar ${Money.format(d.originalPrincipal, d.currency)}',
                  style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.6)),
                ),
              ],
            ),
          )
        else
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (p != null && p.monthsLeft != null) ...[
                  Text(
                    'TERMINAS DE PAGARLA EN',
                    style: AppText.kicker(colors.oliveInk.withValues(alpha: 0.55)),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _mesDeSalida(p.monthsLeft!),
                    style: AppText.sectionTitle(colors.foreground).copyWith(fontSize: 26),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Faltan ${_enAnios(p.monthsLeft!)} · te cuesta '
                    '${Money.format(p.interestLeft, d.currency)} en intereses',
                    style: AppText.small(colors.oliveInk.withValues(alpha: 0.75)),
                  ),
                  const SizedBox(height: Spacing.md),
                ] else if (p != null && p.monthsLeft == null) ...[
                  Text(
                    'Con esta cuota, esta deuda no se termina.',
                    style: AppText.small(colors.danger).copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Pagas ${Money.format(d.installmentAmount, d.currency)} al mes y solo el '
                    'interés ya son ${Money.format(d.installmentInterest, d.currency)}. El saldo '
                    'sube todos los meses.',
                    style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.65)),
                  ),
                  const SizedBox(height: Spacing.md),
                ],

                // Cuánto llevas, con la cifra al lado y no solo el color.
                ClipRRect(
                  borderRadius: BorderRadius.circular(Radii.pill),
                  child: SizedBox(
                    height: 9,
                    child: Row(
                      children: [
                        Expanded(
                          flex: avance.round().clamp(1, 100),
                          child: ColoredBox(color: colors.sage),
                        ),
                        Expanded(
                          flex: (100 - avance).round().clamp(0, 99),
                          child: ColoredBox(color: colors.oliveInk.withValues(alpha: 0.12)),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Llevas ${avance.toStringAsFixed(1)}% pagado · debes '
                  '${Money.format(d.balance, d.currency)} de '
                  '${Money.format(d.originalPrincipal, d.currency)}',
                  style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.7)),
                ),

                if (p != null && p.monthsLeft != null) ...[
                  const SizedBox(height: Spacing.md),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(Radii.pill),
                    child: SizedBox(
                      height: 8,
                      child: Row(
                        children: [
                          Expanded(
                            flex: p.principalShare.clamp(1, 100),
                            child: ColoredBox(color: colors.sage),
                          ),
                          Expanded(
                            flex: (100 - p.principalShare).clamp(0, 99),
                            child: ColoredBox(color: colors.danger.withValues(alpha: 0.3)),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Vas a pagar ${Money.format(p.totalLeft, d.currency)}: de cada 100, '
                    '${p.principalShare} bajan lo que debes y ${100 - p.principalShare} se los '
                    'lleva el préstamo.',
                    style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.7)),
                  ),
                ],

                // La cuota y su urgencia, pegadas al botón que la paga: es la
                // única decisión con fecha de toda la pantalla.
                const SizedBox(height: Spacing.lg),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'CUOTA DE ESTE MES',
                            style: AppText.kicker(colors.oliveInk.withValues(alpha: 0.5)),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            Money.format(d.installmentAmount, d.currency),
                            style: AppText.money(
                              colors.foreground,
                              size: 18,
                              weight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            estadoDelMes(),
                            style: AppText.tiny(
                              urgente ? colors.danger : colors.oliveInk.withValues(alpha: 0.6),
                            ).copyWith(fontWeight: urgente ? FontWeight.w600 : FontWeight.w400),
                          ),
                        ],
                      ),
                    ),
                    if (d.isActive && d.installmentAmount > 0)
                      AppButton(
                        label: d.pagoParcial ? 'Completar' : 'Pagar cuota',
                        onPressed: () async {
                          if (await abrirPagoCuota(context, deuda: d) && mounted) setState(() {});
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),

        // ── De dónde vienes.
        const SizedBox(height: Spacing.lg),
        _HistorialDePagos(deudaId: d.id),

        // ── Las condiciones, al final: se consultan de vez en cuando, no se
        // miran cada vez que se entra. Sin "Moneda": todas las cifras de la
        // pantalla ya la llevan delante.
        const SizedBox(height: Spacing.lg),
        Text('CONDICIONES', style: AppText.kicker(colors.oliveInk.withValues(alpha: 0.5))),
        const SizedBox(height: Spacing.sm),
        AppCard(
          child: Row(
            children: [
              Expanded(
                child: _Dato(
                  rotulo: tieneTcea ? 'TCEA' : 'TEA',
                  valor: '${(d.tasaReal * 100).toStringAsFixed(2)}%',
                  colors: colors,
                ),
              ),
              Expanded(
                child: _Dato(
                  rotulo: 'PLAZO',
                  valor: d.termMonths == null ? 'Sin plazo' : '${d.termMonths} cuotas',
                  colors: colors,
                ),
              ),
              Expanded(
                child: _Dato(
                  rotulo: 'VENCE',
                  valor: d.dueDay != null
                      ? 'Día ${d.dueDay}'
                      : (d.dueDate != null ? Fechas.dia(d.dueDate!) : '—'),
                  colors: colors,
                ),
              ),
            ],
          ),
        ),

        // ── Lo demás que se puede hacer, sin el peso de la acción principal:
        // editar y cancelar son de otra frecuencia, y revertir no debería
        // competir con pagar.
        const SizedBox(height: Spacing.lg),
        if (d.isActive) ...[
          if (d.paidAmountThisMonth > 0) ...[
            AppButton(
              label: 'Revertir pago de este mes',
              variant: AppButtonVariant.secondary,
              busy: _revirtiendo,
              onPressed: _revirtiendo ? null : _revertir,
            ),
            const SizedBox(height: Spacing.sm),
          ],
          AppButton(
            label: 'Editar deuda',
            variant: AppButtonVariant.secondary,
            onPressed: () async {
              if (await abrirEditarDeuda(context, deuda: d) && mounted) setState(() {});
            },
          ),
          const SizedBox(height: Spacing.sm),
        ],
        AppButton(
          label: d.isActive ? 'Cancelar deuda' : 'Reactivar deuda',
          variant: AppButtonVariant.secondary,
          busy: _cambiandoEstado,
          onPressed: _cambiandoEstado ? null : _alternarActiva,
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          d.isActive
              ? 'Cancelarla la saca de tus totales y del plan, pero la deja visible como histórico.'
              : 'Está cancelada: no cuenta en ningún total. Reactivarla la devuelve a tus deudas.',
          style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.65)),
        ),
      ],
    );
  }
}

const _meses = [
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

/// En qué mes cae la última cuota, contando desde hoy. Se opera sobre año y mes
/// y no sumando días: los meses no miden lo mismo.
String _mesDeSalida(int meses) {
  final hoy = DateTime.now();
  final total = hoy.month - 1 + meses;
  return '${_meses[total % 12]} de ${hoy.year + total ~/ 12}';
}

String _enAnios(int meses) {
  if (meses < 12) return '$meses ${meses == 1 ? "mes" : "meses"}';
  final anios = meses ~/ 12;
  final resto = meses % 12;
  final a = '$anios ${anios == 1 ? "año" : "años"}';
  return resto == 0 ? a : '$a y $resto ${resto == 1 ? "mes" : "meses"}';
}

/// La cabecera de la pantalla: volver, y de qué deuda se está hablando.
class _Cabecera extends StatelessWidget {
  const _Cabecera({required this.titulo, required this.subtitulo, required this.colors});

  final String titulo;
  final String? subtitulo;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconTapTarget(
          semanticLabel: 'Volver',
          onTap: () => Navigator.of(context).maybePop(),
          child: AppIcon(AppIconData.chevronLeft, size: 20, color: colors.foreground),
        ),
        const SizedBox(width: Spacing.sm),
        Expanded(
          child: ScreenHeader(kicker: 'Deudas', title: titulo, subtitle: subtitulo),
        ),
      ],
    );
  }
}

/// El aviso de que tu cuota no cuadra con tu tasa.
///
/// Va **arriba de todo y en seis palabras**. Es la información más valiosa de la
/// pantalla —te dice que la proyección de abajo es más optimista de lo que toca,
/// y te da el botón que lo arregla— y estaba de cuarto bloque, detrás de
/// cuarenta palabras que nadie lee. El porqué sigue estando, plegado: quien
/// quiera entenderlo lo abre, y quien solo quiera arreglarlo toca el botón.
class _AvisoDelDesajuste extends ConsumerStatefulWidget {
  const _AvisoDelDesajuste({required this.deuda, required this.onCambio});

  final Debt deuda;
  final VoidCallback onCambio;

  @override
  ConsumerState<_AvisoDelDesajuste> createState() => _AvisoDelDesajusteState();
}

class _AvisoDelDesajusteState extends ConsumerState<_AvisoDelDesajuste> {
  bool _guardando = false;
  bool _abierto = false;

  /// Anotar el desajuste como desgravamen, de un toque. Es el arreglo del
  /// aviso, no solo el reproche: hasta que esa cifra esté declarada, la app
  /// cuenta esos soles como capital y la proyección sale más optimista.
  Future<void> _anotar(double monto) async {
    setState(() => _guardando = true);
    try {
      await ref.read(apiProvider).patch('/debts/${widget.deuda.id}', {'monthlyInsurance': monto});
      ref.invalidate(debtsProvider);
      widget.onCambio();
    } catch (_) {
      // Sin ruido: el aviso sigue ahí y se puede reintentar.
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final d = widget.deuda;
    final p = d.projection;
    if (p == null || p.installmentGap <= 0 || p.modeledInstallment == null || d.saldada) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.lg),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Tu cuota tiene ${Money.format(p.installmentGap, d.currency)} que no bajan la deuda',
              style: AppText.small(colors.chart[3]).copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: Spacing.sm),
            AppButton(
              label: _guardando ? 'Guardando...' : 'Anotarlo como seguro y portes',
              variant: AppButtonVariant.secondary,
              onPressed: _guardando ? null : () => _anotar(p.installmentGap),
            ),
            const SizedBox(height: 6),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _abierto = !_abierto),
              child: Text(
                _abierto ? 'Ocultar el porqué' : '¿Por qué?',
                style: AppText.tiny(colors.sageInk).copyWith(decoration: TextDecoration.underline),
              ),
            ),
            if (_abierto) ...[
              const SizedBox(height: 6),
              Text(
                'Pagas ${Money.format(d.installmentAmount, d.currency)} y con tu saldo, tu tasa '
                'y las cuotas que quedan saldría ${Money.format(p.modeledInstallment!, d.currency)}. '
                'Esa diferencia suele ser el seguro de desgravamen y los portes, que no bajan un '
                'céntimo de la deuda — y ahora mismo la app los cuenta como capital, así que la '
                'proyección de abajo es más optimista de lo que toca.',
                style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.7)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Qué hizo cada pago de esta deuda.
///
/// La pregunta que contesta no es "cuánto he pagado" —eso ya está en el
/// historial de movimientos— sino **"de todo lo que pagué, cuánto bajó la
/// deuda"**, que sobre un crédito caro son dos cifras muy distintas: de
/// S/ 1,694 pagados, S/ 677 bajaron el capital y S/ 1,017 se los llevó el
/// préstamo. Sin verlo, uno cree que amortiza al ritmo de lo que paga.
///
/// Se pide al abrir el detalle y no con la lista: solo se mira el de la deuda
/// que se abre.
class _HistorialDePagos extends ConsumerStatefulWidget {
  const _HistorialDePagos({required this.deudaId});

  final String deudaId;

  @override
  ConsumerState<_HistorialDePagos> createState() => _HistorialDePagosState();
}

class _HistorialDePagosState extends ConsumerState<_HistorialDePagos> {
  Map<String, dynamic>? _datos;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      final r =
          await ref.read(apiProvider).get('/debts/${widget.deudaId}/payments')
              as Map<String, dynamic>;
      if (mounted) setState(() => _datos = r);
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final apagado = AppText.tiny(colors.oliveInk.withValues(alpha: 0.6));

    if (_error) return Text('No se pudo cargar el historial de pagos.', style: apagado);
    if (_datos == null) return Text('Cargando los pagos...', style: apagado);

    final moneda = _datos!['currency'] as String;
    final pagos = (_datos!['payments'] as List).cast<Map<String, dynamic>>();
    if (pagos.isEmpty) {
      return Text(
        'Todavía no has registrado ningún pago. Cuando registres uno, acá vas a '
        'ver cuánto de él bajó el capital y cuánto se lo llevó el interés.',
        style: apagado,
      );
    }

    final t = (_datos!['totals'] as Map).cast<String, dynamic>();
    final pagado = (t['paid'] as num).toDouble();
    final capital = (t['principal'] as num).toDouble();
    final costo = (t['cost'] as num).toDouble();
    // Qué proporción de lo pagado sirvió para deber menos. Es el número que
    // cambia cómo se mira una deuda: al 66% anual, más de la mitad de cada
    // cuota no baja un céntimo.
    final porcentaje = pagado > 0 ? (capital / pagado * 100).round() : 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('PAGOS REGISTRADOS', style: AppText.kicker(colors.oliveInk.withValues(alpha: 0.5))),
        const SizedBox(height: Spacing.sm),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Has pagado ${Money.format(pagado, moneda)} y la deuda bajó '
                '${Money.format(capital, moneda)}.',
                style: AppText.small(colors.foreground),
              ),
              if (costo > 0) ...[
                const SizedBox(height: 4),
                Text(
                  'Los otros ${Money.format(costo, moneda)} fueron el costo de tenerla. '
                  'Solo el $porcentaje% de lo que pagaste bajó lo que debes.',
                  style: apagado,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Toca un pago para corregir su reparto con lo que diga tu estado de cuenta.',
          style: apagado,
        ),
        const SizedBox(height: Spacing.sm),
        for (final p in pagos)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () async {
              final cambiado = await abrirCorregirReparto(
                context,
                deudaId: widget.deudaId,
                pago: p,
                moneda: moneda,
              );
              if (cambiado) await _cargar();
            },
            child: Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Text(
                      Fechas.diaConAnio(DateTime.parse(p['occurredAt'] as String)),
                      style: apagado,
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      Money.format((p['paid'] as num).toDouble(), moneda),
                      textAlign: TextAlign.right,
                      style: AppText.money(colors.foreground, size: 12.5),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      Money.format((p['principal'] as num).toDouble(), moneda),
                      textAlign: TextAlign.right,
                      style: AppText.money(colors.sageInk, size: 12.5, weight: FontWeight.w600),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      Money.format(
                        (p['interest'] as num).toDouble() +
                            (p['insurance'] as num).toDouble() +
                            (p['fees'] as num).toDouble(),
                        moneda,
                      ),
                      textAlign: TextAlign.right,
                      style: AppText.money(colors.danger, size: 12.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 2),
        Text('pagaste · a capital · costo', textAlign: TextAlign.right, style: apagado),
      ],
    );
  }
}

class _Dato extends StatelessWidget {
  const _Dato({required this.rotulo, required this.valor, required this.colors});

  final String rotulo;
  final String valor;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          rotulo,
          style: AppText.kicker(colors.oliveInk.withValues(alpha: 0.5)).copyWith(fontSize: 9),
        ),
        const SizedBox(height: 2),
        Text(valor, style: AppText.money(colors.foreground, size: 15, weight: FontWeight.w600)),
      ],
    );
  }
}
