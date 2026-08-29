import 'dart:convert';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../data/api.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../state/providers.dart';
import '../ui/buttons.dart';
import '../ui/icons.dart';
import '../ui/modal.dart';
import '../ui/refreshable_screen.dart';
import '../ui/surface.dart';
import 'shell.dart';

/// Qué hay dentro de la base de este teléfono.
///
/// Existe por una razón concreta: la base sembrada del repositorio y la que usa
/// la app no son la misma, y explicar algo que pasa en tu teléfono mirando la
/// de fábrica es mirar el sitio equivocado. Esta pantalla lee la de verdad.
///
/// Lo importante no son los conteos sino los **avisos**: las incoherencias que
/// ya causaron errores antes, dichas en una frase y con su porqué. Y el botón
/// de copiar, para que el diagnóstico entero se pueda pegar en una conversación
/// sin transcribir nada a mano.
final diagnosticoProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  return await ref.watch(apiProvider).get('/diagnostico') as Map<String, dynamic>;
});

/// Las filas de una tabla, de a tandas. `familia` es el nombre de la tabla y el
/// número de filas ya pedidas: pedir más es volver a leer con un tope mayor, no
/// acumular listas sueltas que puedan discrepar entre sí.
final tablaProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, ({String nombre, int cuantas})>((ref, familia) async {
      return await ref
              .watch(apiProvider)
              .get('/diagnostico/tabla?nombre=${familia.nombre}&take=${familia.cuantas}')
          as Map<String, dynamic>;
    });

class DiagnosticoScreen extends ConsumerWidget {
  const DiagnosticoScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppTheme.of(context);
    final diagnostico = ref.watch(diagnosticoProvider);

    return RefreshableScreen(
      onRefresh: () async => ref.invalidate(diagnosticoProvider),
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
              child: ScreenHeader(
                kicker: 'Tu cuenta',
                title: 'Diagnóstico',
                subtitle: 'Qué hay dentro de la base de este teléfono.',
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.lg),
        diagnostico.when(
          loading: () => const AppCard(child: Text('Leyendo la base…')),
          error: (e, __) => AppCard(
            dashed: true,
            child: Text('No pude leerla: $e', style: AppText.small(colors.danger)),
          ),
          data: (d) => _Informe(datos: d),
        ),
      ],
    );
  }
}

class _Informe extends StatelessWidget {
  const _Informe({required this.datos});

  final Map<String, dynamic> datos;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final avisos = (datos['avisos'] as List).cast<Map<String, dynamic>>();
    final base = datos['base'] as Map<String, dynamic>;
    final tablas = (datos['tablas'] as Map).cast<String, dynamic>();
    final movimientos = (datos['movimientos'] as Map).cast<String, dynamic>();
    final meses = (datos['meses'] as List).cast<Map<String, dynamic>>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Los avisos primero: es lo único que pide una decisión. Todo lo demás
        // es contexto para entenderlos.
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionHeader(
                title: avisos.isEmpty ? 'Todo en orden' : 'Qué revisar',
                trailing: Text(
                  '${avisos.length}',
                  style: AppText.money(
                    avisos.isEmpty ? colors.sageInk : colors.danger,
                    size: 18,
                    weight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: Spacing.sm),
              if (avisos.isEmpty)
                Text(
                  'Ninguna de las incoherencias conocidas aparece en tu base.',
                  style: AppText.small(colors.oliveInk.withValues(alpha: 0.75)),
                )
              else
                for (final a in avisos)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Spacing.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(a['que'] as String, style: AppText.bodyMedium(colors.foreground)),
                        const SizedBox(height: 2),
                        Text(
                          a['porque'] as String,
                          style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.75)),
                        ),
                      ],
                    ),
                  ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.lg),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionHeader(title: 'La base'),
              const SizedBox(height: Spacing.sm),
              _Fila(
                rotulo: 'Generado',
                valor: (datos['generado'] as String).replaceFirst('T', ' '),
              ),
              _Fila(rotulo: 'Zona', valor: '${datos['zona']} · mes ${datos['mesActual']}'),
              _Fila(rotulo: 'Archivo', valor: '${base['kb']} KB'),
              _Fila(rotulo: 'Ruta', valor: base['ruta'] as String, pequena: true),
              const SizedBox(height: Spacing.md),
              SectionHeader(title: 'Filas por tabla'),
              const SizedBox(height: Spacing.sm),
              // Tocar una tabla la abre: los conteos dicen que algo no cuadra
              // y las filas dicen por qué.
              for (final e in tablas.entries)
                _Fila(
                  rotulo: e.key,
                  valor: '${e.value}',
                  onTap: (e.value as num) > 0
                      ? () => Navigator.of(context).push(
                          PageRouteBuilder<void>(
                            pageBuilder: (context, a, b) => TablaScreen(nombre: e.key),
                          ),
                        )
                      : null,
                ),
              const SizedBox(height: Spacing.md),
              SectionHeader(title: 'Movimientos'),
              const SizedBox(height: Spacing.sm),
              _Fila(rotulo: 'Primero', valor: _dia(movimientos['primero'])),
              _Fila(rotulo: 'Último', valor: _dia(movimientos['ultimo'])),
              _Fila(rotulo: 'Con fecha futura', valor: '${movimientos['enElFuturo']}'),
            ],
          ),
        ),
        const SizedBox(height: Spacing.lg),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionHeader(title: 'Fichas por mes'),
              const SizedBox(height: Spacing.sm),
              if (meses.isEmpty)
                Text(
                  'Ninguna todavía.',
                  style: AppText.small(colors.oliveInk.withValues(alpha: 0.75)),
                )
              else
                for (final m in meses)
                  _Fila(
                    rotulo: m['mes'] as String,
                    valor: '${m['fichas']} fichas · ${m['marcadas']} marcadas',
                  ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.lg),
        // Copiar el diagnóstico entero. Es la razón de ser de la pantalla tanto
        // como los avisos: pegar esto en una conversación evita transcribir
        // cifras a mano, que es donde se pierde el dato que importaba.
        _BotonCopiar(datos: datos),
        const SizedBox(height: Spacing.sm),
        // Y la base entera, cuando el diagnóstico no alcanza. Un informe dice
        // cuántas filas hay y cuáles no cuadran; con el archivo se puede mirar
        // **por qué**, que es la pregunta que sigue.
        const _BotonCompartirLaBase(),
      ],
    );
  }

  static String _dia(Object? iso) =>
      iso == null ? '—' : (iso as String).replaceFirst('T', ' ').substring(0, 16);
}

class _BotonCopiar extends StatefulWidget {
  const _BotonCopiar({required this.datos});

  final Map<String, dynamic> datos;

  @override
  State<_BotonCopiar> createState() => _BotonCopiarState();
}

class _BotonCopiarState extends State<_BotonCopiar> {
  bool _copiado = false;

  @override
  Widget build(BuildContext context) {
    return AppButton(
      label: _copiado ? 'Copiado' : 'Copiar diagnóstico',
      onPressed: () async {
        await Clipboard.setData(
          ClipboardData(text: const JsonEncoder.withIndent('  ').convert(widget.datos)),
        );
        if (!mounted) return;
        setState(() => _copiado = true);
      },
    );
  }
}

/// Compartir una copia de la base de este teléfono.
///
/// La copia la saca el API con `VACUUM INTO`, no una copia del archivo abierto:
/// SQLite guarda parte de lo escrito en su diario hasta que hace checkpoint, y
/// mandar el archivo tal cual puede entregar una base sin los últimos cambios —
/// justo los que uno quería que el otro viera.
class _BotonCompartirLaBase extends ConsumerStatefulWidget {
  const _BotonCompartirLaBase();

  @override
  ConsumerState<_BotonCompartirLaBase> createState() => _BotonCompartirLaBaseState();
}

class _BotonCompartirLaBaseState extends ConsumerState<_BotonCompartirLaBase> {
  bool _trabajando = false;

  @override
  Widget build(BuildContext context) {
    return AppButton(
      label: _trabajando ? 'Preparando...' : 'Compartir la base',
      variant: AppButtonVariant.secondary,
      onPressed: _trabajando ? null : _compartir,
    );
  }

  Future<void> _compartir() async {
    setState(() => _trabajando = true);
    try {
      final r = await ref.read(apiProvider).get('/diagnostico/dump') as Map<String, dynamic>;
      final ruta = r['ruta'] as String;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(ruta, mimeType: 'application/vnd.sqlite3')],
          fileNameOverrides: [r['nombre'] as String],
          text: 'Base de Financial Strategist (${r['kb']} KB)',
        ),
      );
    } catch (e) {
      if (!mounted) return;
      await showFeedback(
        context,
        title: 'No se pudo preparar la copia',
        message: e is ApiException ? e.message : 'Algo falló al copiar la base.',
        tone: FeedbackTone.error,
      );
    } finally {
      if (mounted) setState(() => _trabajando = false);
    }
  }
}

class _Fila extends StatelessWidget {
  const _Fila({required this.rotulo, required this.valor, this.pequena = false, this.onTap});

  final String rotulo;
  final String valor;
  final VoidCallback? onTap;

  /// Para la ruta del archivo, que es larga y no se lee de un vistazo: va
  /// debajo y en chico en vez de pelearse por el ancho con su rótulo.
  final bool pequena;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    if (pequena) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(rotulo, style: AppText.small(colors.oliveInk.withValues(alpha: 0.7))),
            Text(valor, style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.6))),
          ],
        ),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            Expanded(
              child: Text(rotulo, style: AppText.small(colors.oliveInk.withValues(alpha: 0.75))),
            ),
            Text(valor, style: AppText.small(onTap == null ? colors.foreground : colors.sageInk)),
            if (onTap != null) ...[
              const SizedBox(width: 4),
              AppIcon(AppIconData.chevronRight, size: 12, color: colors.sageInk),
            ],
          ],
        ),
      ),
    );
  }
}

/// Las filas de una tabla, tal como están en la base.
///
/// Con las fechas ya legibles y los nulos dichos con todas las letras: un
/// diagnóstico que muestra `1756093200000` o una línea en blanco obliga a
/// adivinar, que es el trabajo que uno viene a evitar.
class TablaScreen extends ConsumerStatefulWidget {
  const TablaScreen({super.key, required this.nombre});

  final String nombre;

  @override
  ConsumerState<TablaScreen> createState() => _TablaScreenState();
}

class _TablaScreenState extends ConsumerState<TablaScreen> {
  static const _tanda = 50;
  int _cuantas = _tanda;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final datos = ref.watch(tablaProvider((nombre: widget.nombre, cuantas: _cuantas)));

    return RefreshableScreen(
      onRefresh: () async =>
          ref.invalidate(tablaProvider((nombre: widget.nombre, cuantas: _cuantas))),
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
              child: ScreenHeader(kicker: 'Diagnóstico', title: widget.nombre),
            ),
          ],
        ),
        const SizedBox(height: Spacing.lg),
        datos.when(
          loading: () => const AppCard(child: Text('Leyendo…')),
          error: (e, __) =>
              AppCard(dashed: true, child: Text('$e', style: AppText.small(colors.danger))),
          data: (d) {
            final filas = (d['filas'] as List).cast<Map<String, dynamic>>();
            final total = d['total'] as int;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  filas.length >= total ? '$total fila(s)' : '${filas.length} de $total filas',
                  style: AppText.small(colors.oliveInk.withValues(alpha: 0.75)),
                ),
                const SizedBox(height: Spacing.md),
                for (final fila in filas) ...[
                  AppCard(
                    padding: const EdgeInsets.all(Spacing.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final campo in fila.entries)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: '${campo.key}: ',
                                    style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.65)),
                                  ),
                                  TextSpan(
                                    text: campo.value?.toString() ?? '—',
                                    style: AppText.tiny(
                                      campo.value == null
                                          ? colors.oliveInk.withValues(alpha: 0.4)
                                          : colors.foreground,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Spacing.sm),
                ],
                if (filas.length < total) ...[
                  const SizedBox(height: Spacing.sm),
                  AppButton(
                    label: 'Ver 50 más',
                    onPressed: () => setState(() => _cuantas += _tanda),
                  ),
                ],
                const SizedBox(height: Spacing.sm),
                _BotonCopiar(datos: datos.value!),
              ],
            );
          },
        ),
      ],
    );
  }
}
