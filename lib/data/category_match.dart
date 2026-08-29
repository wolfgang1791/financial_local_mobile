import '../data/models.dart';
import 'category_icon.dart';

/// Puerto directo de `frontend/src/lib/categoryMatch.ts`.
///
/// El acento y las mayúsculas no deberían decidir si dos categorías son la
/// misma cosa: "Peluquería" y "peluqueria" son una categoría escrita dos
/// veces.
String normalizeName(String name) {
  var t = name.trim().toLowerCase();
  const combinantes = {
    'á': 'a',
    'à': 'a',
    'ä': 'a',
    'é': 'e',
    'è': 'e',
    'ë': 'e',
    'í': 'i',
    'ì': 'i',
    'ï': 'i',
    'ó': 'o',
    'ò': 'o',
    'ö': 'o',
    'ú': 'u',
    'ù': 'u',
    'ü': 'u',
  };
  for (final entrada in combinantes.entries) {
    t = t.replaceAll(entrada.key, entrada.value);
  }
  return t;
}

/// Palabras demasiado cortas o comunes como para decir algo de parecido — sin
/// esto, "gastos de la casa" emparentaría con cualquier categoría que
/// contenga "de".
const _palabrasVacias = {'para', 'desde', 'hasta', 'sobre', 'otros', 'otro', 'varios'};

List<String> _palabrasSignificativas(String name) => normalizeName(
  name,
).split(RegExp('[^a-z0-9]+')).where((w) => w.length >= 4 && !_palabrasVacias.contains(w)).toList();

class CategoryMatches {
  const CategoryMatches({required this.exact, required this.related});

  final List<Category> exact;
  final List<Category> related;
}

/// Qué ya existe que se parece a lo que se está escribiendo, para notar un
/// casi-duplicado antes de crearlo — "Comida rapida" cuando ya existe "Comida
/// rápida", o "Peluquería" cuando ya existe "Belleza".
///
/// Tres señales, la más barata primero:
///   1. mismo nombre (sin acento/mayúscula) → ya existe,
///   2. un nombre contiene al otro → "Comida" vs "Comida y bebidas",
///   3. los dos nombres resuelven al mismo ícono por palabra clave — funciona
///      sin tabla de sinónimos porque el diccionario de íconos ya sabe que
///      peluquería y belleza son la misma familia. Solo cuenta cuando *hay*
///      coincidencia, porque el ícono genérico emparentaría con todo.
CategoryMatches findCategoryMatches(String rawName, List<Category> categories, {int limit = 4}) {
  final name = normalizeName(rawName);
  if (name.length < 3) return const CategoryMatches(exact: [], related: []);

  final palabrasEscritas = _palabrasSignificativas(rawName);
  final iconoEscrito = suggestCategoryIcon(rawName);

  final exact = <Category>[];
  final related = <Category>[];

  for (final categoria in categories) {
    final otro = normalizeName(categoria.name);

    if (otro == name) {
      exact.add(categoria);
      continue;
    }
    if (otro.contains(name) || name.contains(otro)) {
      related.add(categoria);
      continue;
    }
    final otrasPalabras = _palabrasSignificativas(categoria.name);
    if (palabrasEscritas.any(otrasPalabras.contains)) {
      related.add(categoria);
      continue;
    }
    if (iconoEscrito != null && suggestCategoryIcon(categoria.name) == iconoEscrito) {
      related.add(categoria);
    }
  }

  return CategoryMatches(exact: exact, related: related.take(limit).toList());
}
