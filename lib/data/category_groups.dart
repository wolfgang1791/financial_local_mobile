import 'models.dart';

/// Puerto directo de `frontend/src/lib/categoryGroups.ts`: agrupa la lista
/// plana de categorías por nombre de padre. Una categoría con hijas es
/// *también* elegible — aparece como primer ítem de su propio grupo,
/// marcada como "general" en la pantalla — porque a veces el movimiento es
/// genuinamente general y forzarlo bajo una hoja concreta (o peor, bajo una
/// subcategoría "General" inventada) es menos honesto que etiquetarlo con
/// el padre. Una hoja sin hijas (o una de nivel superior sin ninguna, como
/// "Otros") funciona igual que siempre: una sola entrada.
List<(String, List<Category>)> groupCategories(List<Category> categories) {
  final parentIds = categories.map((c) => c.parentId).whereType<String>().toSet();
  final hojas = categories.where((c) => !parentIds.contains(c.id)).toList();

  final grupos = <String, List<Category>>{};
  for (final c in hojas) {
    final key = c.parentName ?? 'Otros';
    (grupos[key] ??= []).add(c);
  }

  // Los padres con hijas también se pueden elegir: entran al frente del
  // grupo que ya armaron sus propios hijos, como opción "general" — no al
  // final, para que no se lea como una hoja más perdida en la lista.
  final padresConHijos = categories.where((c) => c.parentId == null && parentIds.contains(c.id));
  for (final p in padresConHijos) {
    (grupos[p.name] ??= []).insert(0, p);
  }

  final entradas = grupos.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
  return [for (final e in entradas) (e.key, e.value)];
}

String normalizeForSearch(String s) => s
    .toLowerCase()
    .replaceAll(RegExp('[áàä]'), 'a')
    .replaceAll(RegExp('[éèë]'), 'e')
    .replaceAll(RegExp('[íìï]'), 'i')
    .replaceAll(RegExp('[óòö]'), 'o')
    .replaceAll(RegExp('[úùü]'), 'u');
