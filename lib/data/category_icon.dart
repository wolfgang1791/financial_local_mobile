/// Puerto directo de `frontend/src/lib/categoryIcon.ts`.
///
/// Palabra clave → emoji, para que las filas de la lista tengan un ícono de
/// categoría sin obligar al usuario a elegir uno. Cubre tanto nombres libres
/// como la taxonomía sembrada (`backend/prisma/seed.ts`).
final List<(RegExp, String)> _keywordIcon = [
  // Comida y bebidas
  (RegExp(r'\bbar\b|alcohol|tabaco'), '🍺'),
  (RegExp(r'cafeter|caf[eé]\b'), '☕'),
  (RegExp(r'restaurant|comida r[aá]pida|delivery'), '🍔'),
  (RegExp(r'comida|super|mercado|vale de comida'), '🛒'),
  // Vivienda
  (RegExp(r'alquiler|renta|vivienda|hipoteca|inmobil'), '🏠'),
  (RegExp(r'luz|energ[ií]a|electric'), '💡'),
  (RegExp(r'\bagua\b'), '🚿'),
  (RegExp(r'\bgas\b'), '🔥'),
  (RegExp(r'internet|wifi'), '🌐'),
  // Comunicación y PC
  (RegExp(r'tel[eé]fono|movistar|claro|entel|bitel'), '📱'),
  (RegExp(r'software|apps?\b'), '💻'),
  (RegExp(r'juegos?\b'), '🎮'),
  (RegExp(r'pel[ií]cula|movie'), '🎬'),
  // Transporte / Vehículo
  (RegExp(r'transporte p[uú]blico|taxi|uber'), '🚕'),
  (RegExp(r'boletos? de avi[oó]n|viajes? de negocio'), '✈️'),
  (RegExp(r'combustible|gasolina|estacionamiento|veh[ií]cul'), '🚗'),
  // Compras
  (RegExp(r'farmacia|salud|m[eé]dico|clinica|bienestar'), '💊'),
  (RegExp(r'joyer[ií]a'), '💍'),
  (RegExp(r'jard[ií]n'), '🌱'),
  (RegExp(r'mascota|animales|veterinari'), '🐾'),
  (RegExp(r'ni[ñn]os'), '🧸'),
  (RegExp(r'herramientas|tr[aá]mites'), '🔧'),
  (RegExp(r'regalo|cumplea[ñn]os'), '🎁'),
  (RegExp(r'ropa|vestimenta|calzado'), '👕'),
  (RegExp(r'belleza'), '💄'),
  // Mandados cotidianos que caían al ícono genérico — y, vía la regla de
  // ícono compartido en category_match.dart, hacen que "peluquería" y
  // "barbería" se lean como la misma familia en vez de dos sin relación.
  (RegExp(r'peluquer|barber|manicur|pedicur|est[eé]tica|\bspa\b'), '💇'),
  (RegExp(r'gimnasio|\bgym\b'), '🏋️'),
  (RegExp(r'lavander[ií]a|tintorer[ií]a'), '🧺'),
  (RegExp(r'panader[ií]a|pasteler[ií]a'), '🥖'),
  // Vida y entretenimiento
  (
    RegExp(r'netflix|spotify|streaming|suscrip|hbo|disney|youtube|claude|chatgpt|openai|audio'),
    '🎬',
  ),
  (RegExp(r'concierto|cultura|evento deportivo|deporte|fitness'), '🎉'),
  (RegExp(r'libro'), '📚'),
  (RegExp(r'loter[ií]a|apuesta'), '🎰'),
  (RegExp(r'vacacion|hotel|viaje'), '🧳'),
  (RegExp(r'caridad|donaci[oó]n'), '❤️'),
  (RegExp(r'pasatiempo|ocio'), '🎨'),
  // Gastos financieros / Inversiones
  (RegExp(r'seguro|interseguro|rimac'), '🛡️'),
  (RegExp(r'impuesto|multa'), '📋'),
  (RegExp(r'comisi[oó]n|cargo|asesoramiento'), '💳'),
  (RegExp(r'inter[eé]s|dividendo'), '📈'),
  (RegExp(r'pr[eé]stamo|cuota|pensi[oó]n aliment'), '🏦'),
  (RegExp(r'ahorro'), '🐖'),
  (RegExp(r'bienes ra[ií]ces'), '🏢'),
  (RegExp(r'inversi[oó]n|colecci[oó]n'), '📊'),
  // Educación
  (RegExp(r'educaci[oó]n|colegio|universidad|curso'), '🎓'),
  (RegExp(r'mantenimiento|reparaci[oó]n'), '🔧'),
  // Ingreso
  (RegExp(r'sueldo|salario|planilla'), '💼'),
  (RegExp(r'freelance|honorario'), '💻'),
  (RegExp(r'factura|reembolso|cheque|cup[oó]n'), '🧾'),
  (RegExp(r'gratificaci[oó]n|extraordinario|bono'), '🎁'),
];

/// El ícono que un nombre de verdad coincide, o `null` si ninguno. Separado
/// de [categoryIconFor] para que un *adivinado* se distinga de un
/// *reemplazo*: al crear una categoría solo vale la pena guardar una
/// coincidencia real — congelar el 🧾 genérico en la base seguiría
/// mostrándolo aunque esta lista aprenda la palabra después.
String? suggestCategoryIcon(String name) {
  final normalizado = name.toLowerCase();
  for (final (patron, icono) in _keywordIcon) {
    if (patron.hasMatch(normalizado)) return icono;
  }
  return null;
}

enum CategoryIconFallback { income, expense, debt }

String categoryIcon(String name, [CategoryIconFallback fallback = CategoryIconFallback.expense]) {
  final coincidencia = suggestCategoryIcon(name);
  if (coincidencia != null) return coincidencia;
  return switch (fallback) {
    CategoryIconFallback.income => '💰',
    CategoryIconFallback.debt => '💳',
    CategoryIconFallback.expense => '🧾',
  };
}

/// Qué dibujar para una categoría que existe: el ícono guardado al crearla
/// gana sobre la adivinanza por palabra clave, así una categoría del usuario
/// conserva el ícono que se le dio aunque el nombre deje de calzar con
/// ninguna palabra. Las sembradas no tienen ícono guardado y caen a la regla.
String categoryIconFor(
  String? storedIcon,
  String name, [
  CategoryIconFallback fallback = CategoryIconFallback.expense,
]) {
  if (storedIcon != null && storedIcon.isNotEmpty) return storedIcon;
  return categoryIcon(name, fallback);
}
