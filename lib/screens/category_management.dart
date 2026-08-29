import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api.dart';
import '../data/category_icon.dart';
import '../data/category_match.dart';
import '../data/models.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../state/providers.dart';
import '../ui/buttons.dart';
import '../ui/fields.dart';
import '../ui/icons.dart';
import '../ui/modal.dart';
import '../ui/surface.dart';

/// Tus categorías: las que tú creaste, no la taxonomía sembrada. Solo estas
/// se pueden borrar — las de sistema son la base que el resto del producto
/// asume que existe.
class CategoryManagementSection extends ConsumerWidget {
  const CategoryManagementSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppTheme.of(context);
    final categorias = ref.watch(categoriesProvider);

    // La caja que se aparta: es la sección menos tocada de la app, y estaba con
    // el mismo peso que el botón de registrar.
    return AppCard(
      discreta: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader(title: 'Tus categorías'),
          const SizedBox(height: Spacing.sm),
          categorias.when(
            loading: () =>
                Text('Cargando…', style: AppText.small(colors.oliveInk.withValues(alpha: 0.6))),
            error: (_, __) =>
                Text('No pude cargar tus categorías.', style: AppText.small(colors.danger)),
            data: (todas) {
              final propias = todas.where((c) => !c.isSystem).toList();
              return propias.isEmpty
                  ? Text(
                      'Las categorías que armes tú van a aparecer acá.',
                      style: AppText.small(colors.oliveInk.withValues(alpha: 0.7)),
                    )
                  : Wrap(
                      spacing: Spacing.sm,
                      runSpacing: Spacing.sm,
                      children: [for (final c in propias) _ChipCategoria(categoria: c)],
                    );
            },
          ),
          const SizedBox(height: Spacing.md),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () async {
              final todas = ref.read(categoriesProvider).valueOrNull ?? const <Category>[];
              if (await abrirNuevaCategoria(context, categoriasExistentes: todas)) {
                ref.invalidate(categoriesProvider);
              }
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIcon(AppIconData.plus, size: 13, color: colors.sageInk),
                const SizedBox(width: 6),
                Text(
                  'Nueva categoría',
                  style: AppText.small(colors.sageInk).copyWith(fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChipCategoria extends ConsumerWidget {
  const _ChipCategoria({required this.categoria});

  final Category categoria;

  Future<void> _borrar(BuildContext context, WidgetRef ref) async {
    final ok = await showFeedback(
      context,
      title: '¿Eliminar "${categoria.name}"?',
      message: 'Los movimientos y flujos que la usan se quedan sin categoría, no se borran.',
      tone: FeedbackTone.aviso,
      confirmLabel: 'Sí, eliminar',
      cancelLabel: 'Cancelar',
      destructive: true,
    );
    if (ok != true) return;
    try {
      final r =
          await ref.read(apiProvider).delete('/categories/${categoria.id}') as Map<String, dynamic>;
      ref.invalidate(categoriesProvider);
      final transacciones = (r['unlinkedTransactions'] as num?)?.toInt() ?? 0;
      final flujos = (r['unlinkedFlows'] as num?)?.toInt() ?? 0;
      if (context.mounted && (transacciones > 0 || flujos > 0)) {
        await showFeedback(
          context,
          title: 'Categoría eliminada',
          message: '$transacciones movimientos y $flujos flujos se quedaron sin categoría.',
        );
      }
    } on ApiException catch (e) {
      if (context.mounted) {
        await showFeedback(
          context,
          title: 'No se pudo eliminar',
          message: e.message,
          tone: FeedbackTone.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = AppTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _borrar(context, ref),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md, vertical: Spacing.sm),
        decoration: BoxDecoration(
          color: colors.surface.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(Radii.pill),
          border: Border.all(color: colors.surfaceBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              categoryIconFor(
                categoria.icon,
                categoria.name,
                categoria.type == 'INCOME'
                    ? CategoryIconFallback.income
                    : CategoryIconFallback.expense,
              ),
            ),
            const SizedBox(width: 6),
            Text(categoria.ruta, style: AppText.small(colors.foreground)),
            const SizedBox(width: 6),
            AppIcon(AppIconData.trash, size: 12, color: colors.oliveInk.withValues(alpha: 0.4)),
          ],
        ),
      ),
    );
  }
}

/// El formulario de categoría nueva.
Future<bool> abrirNuevaCategoria(
  BuildContext context, {
  required List<Category> categoriasExistentes,
}) async {
  final creada = await showAppModal<bool>(
    context,
    title: 'Nueva categoría',
    builder: (context) => _FormularioCategoria(categoriasExistentes: categoriasExistentes),
  );
  return creada ?? false;
}

class _FormularioCategoria extends ConsumerStatefulWidget {
  const _FormularioCategoria({required this.categoriasExistentes});

  final List<Category> categoriasExistentes;

  @override
  ConsumerState<_FormularioCategoria> createState() => _FormularioCategoriaState();
}

class _FormularioCategoriaState extends ConsumerState<_FormularioCategoria> {
  final _nombre = TextEditingController();
  bool _esGasto = true;
  Category? _padre;
  bool _guardando = false;
  String? _error;

  @override
  void dispose() {
    _nombre.dispose();
    super.dispose();
  }

  Future<void> _guardar() async {
    final nombre = _nombre.text.trim();
    if (nombre.isEmpty) {
      setState(() => _error = 'Ponle un nombre.');
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      final icono = suggestCategoryIcon(nombre);
      await ref.read(apiProvider).post('/categories', {
        'name': nombre,
        'type': _esGasto ? 'EXPENSE' : 'INCOME',
        if (_padre != null) 'parentId': _padre!.id,
        if (icono != null) 'icon': icono,
      });
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'No llegué al servidor. Inténtalo otra vez.');
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final nombre = _nombre.text.trim();
    final icono = suggestCategoryIcon(nombre);
    final delTipo = widget.categoriasExistentes
        .where((c) => c.type == (_esGasto ? 'EXPENSE' : 'INCOME'))
        .toList();
    final candidatosPadre = delTipo.where((c) => c.parentName == null).toList();
    final coincidencias = nombre.length >= 3
        ? findCategoryMatches(nombre, delTipo)
        : const CategoryMatches(exact: [], related: []);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldSwitch<bool>(
          opciones: const [('Gasto', true), ('Ingreso', false)],
          valor: _esGasto,
          onChange: (v) => setState(() {
            _esGasto = v;
            _padre = null;
          }),
        ),
        const SizedBox(height: Spacing.xl),
        const FieldLabel('Nombre'),
        FieldBox(
          child: Row(
            children: [
              if (icono != null) ...[Text(icono), const SizedBox(width: Spacing.sm)],
              Expanded(
                child: AppTextField(
                  controller: _nombre,
                  autofocus: true,
                  placeholder: 'Nombre de la categoría',
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
        ),
        if (coincidencias.exact.isNotEmpty) ...[
          const SizedBox(height: Spacing.sm),
          Text(
            'Ya existe "${coincidencias.exact.first.name}".',
            style: AppText.tiny(colors.chart[3]),
          ),
        ] else if (coincidencias.related.isNotEmpty) ...[
          const SizedBox(height: Spacing.sm),
          Text(
            '¿Alguna de estas es lo mismo? Tócala para anidar la nueva ahí.',
            style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.6)),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final c in coincidencias.related)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _padre = c),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 5),
                    decoration: BoxDecoration(
                      color: _padre?.id == c.id ? colors.sage.withValues(alpha: 0.18) : null,
                      borderRadius: BorderRadius.circular(Radii.pill),
                      border: Border.all(color: colors.surfaceBorder),
                    ),
                    child: Text(c.ruta, style: AppText.tiny(colors.foreground)),
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: Spacing.lg),
        const FieldLabel('Categoría padre (opcional)'),
        FieldSelector(
          texto: _padre?.name ?? 'Ninguna — va suelta',
          onTap: candidatosPadre.isEmpty
              ? () {}
              : () async {
                  final elegida = await showAppModal<Category>(
                    context,
                    title: 'Categoría padre',
                    builder: (context) => Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FieldOption(
                          titulo: 'Ninguna — va suelta',
                          onTap: () => Navigator.of(context).pop(const Category(id: '', name: '')),
                        ),
                        for (final c in candidatosPadre)
                          FieldOption(titulo: c.name, onTap: () => Navigator.of(context).pop(c)),
                      ],
                    ),
                  );
                  if (elegida != null) {
                    setState(() => _padre = elegida.id.isEmpty ? null : elegida);
                  }
                },
        ),
        if (_error != null) ...[
          const SizedBox(height: Spacing.md),
          Text(_error!, style: AppText.small(colors.danger)),
        ],
        const SizedBox(height: Spacing.xl),
        AppButton(
          label: 'Crear categoría',
          busy: _guardando,
          onPressed: _guardando ? null : _guardar,
        ),
      ],
    );
  }
}
