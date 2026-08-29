import 'package:flutter/widgets.dart';

import '../data/category_groups.dart';
import '../data/category_icon.dart';
import '../data/models.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import 'fields.dart';
import 'icons.dart';
import 'modal.dart';

/// El selector de categoría, agrupado por padre y con buscador — mismo
/// comportamiento y estilo que `CategoryPicker.tsx` en la web: un acordeón
/// de grupos en vez de una lista plana de noventa filas, con el padre de
/// cada grupo elegible como "(general)" cuando tiene hijas.
Future<Category?> elegirCategoria(
  BuildContext context,
  List<Category> categorias, {
  bool permitirNinguna = true,
  // "Sin categoría" al registrar un movimiento, "Todas las categorías" al
  // filtrar el historial — mismo widget, dos preguntas distintas.
  String textoNinguna = 'Sin categoría',
  String titulo = 'Elige categoría',
}) {
  return showAppModal<Category>(
    context,
    title: titulo,
    builder: (context) => _SelectorCategorias(
      categorias: categorias,
      permitirNinguna: permitirNinguna,
      textoNinguna: textoNinguna,
    ),
  );
}

class _SelectorCategorias extends StatefulWidget {
  const _SelectorCategorias({
    required this.categorias,
    required this.permitirNinguna,
    required this.textoNinguna,
  });

  final List<Category> categorias;
  final bool permitirNinguna;
  final String textoNinguna;

  @override
  State<_SelectorCategorias> createState() => _SelectorCategoriasState();
}

class _SelectorCategoriasState extends State<_SelectorCategorias> {
  final _campo = TextEditingController();
  // Acordeón: abrir un grupo cierra el que estaba abierto — un directorio de
  // nombres, no un muro de noventa categorías.
  String? _grupoAbierto;

  @override
  void dispose() {
    _campo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final q = normalizeForSearch(_campo.text.trim());
    final buscando = q.isNotEmpty;

    final grupos = groupCategories(widget.categorias);
    final filtrados = !buscando
        ? grupos
        : [
            for (final g in grupos)
              (g.$1, g.$2.where((c) => normalizeForSearch(c.name).contains(q)).toList()),
          ].where((g) => g.$2.isNotEmpty).toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldBox(
          child: AppTextField(
            controller: _campo,
            autofocus: true,
            placeholder: 'Buscar una categoría',
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(height: Spacing.md),
        if (widget.permitirNinguna)
          FieldOption(
            titulo: widget.textoNinguna,
            onTap: () => Navigator.of(context).pop(Category(id: '', name: widget.textoNinguna)),
          ),
        if (filtrados.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.xl),
            child: Text(
              'No encontré ninguna con ese nombre.',
              textAlign: TextAlign.center,
              style: AppText.small(colors.oliveInk.withValues(alpha: 0.6)),
            ),
          )
        else
          // 420 de alto: deja ver varios grupos y que el buscador siga
          // visible arriba — con noventa categorías la hoja completa se
          // saldría de la pantalla.
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final (nombre, cats) in filtrados)
                  _GrupoCategoria(
                    nombre: nombre,
                    categorias: cats,
                    abierto: buscando || _grupoAbierto == nombre,
                    onToggle: () =>
                        setState(() => _grupoAbierto = _grupoAbierto == nombre ? null : nombre),
                    onSelect: (c) => Navigator.of(context).pop(c),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _GrupoCategoria extends StatelessWidget {
  const _GrupoCategoria({
    required this.nombre,
    required this.categorias,
    required this.abierto,
    required this.onToggle,
    required this.onSelect,
  });

  final String nombre;
  final List<Category> categorias;
  final bool abierto;
  final VoidCallback onToggle;
  final void Function(Category) onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onToggle,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    nombre.toUpperCase(),
                    style: AppText.kicker(
                      colors.oliveInk.withValues(alpha: 0.6),
                    ).copyWith(fontSize: 10.5),
                  ),
                ),
                Text(
                  '${categorias.length}',
                  style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.45)),
                ),
                const SizedBox(width: Spacing.sm),
                AppIcon(
                  abierto ? AppIconData.chevronDown : AppIconData.chevronRight,
                  size: 13,
                  color: colors.oliveInk.withValues(alpha: 0.45),
                ),
              ],
            ),
          ),
        ),
        if (abierto)
          for (final c in categorias)
            _FilaCategoria(categoria: c, esGeneral: c.name == nombre, onTap: () => onSelect(c)),
      ],
    );
  }
}

class _FilaCategoria extends StatelessWidget {
  const _FilaCategoria({required this.categoria, required this.esGeneral, required this.onTap});

  final Category categoria;
  final bool esGeneral;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final fallback = categoria.type == 'INCOME'
        ? CategoryIconFallback.income
        : CategoryIconFallback.expense;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colors.sage.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: Text(
                categoryIconFor(categoria.icon, categoria.name, fallback),
                style: const TextStyle(fontSize: 13),
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: categoria.name, style: AppText.body(colors.foreground)),
                    if (esGeneral)
                      TextSpan(
                        text: ' (general)',
                        style: AppText.small(colors.oliveInk.withValues(alpha: 0.5)),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
