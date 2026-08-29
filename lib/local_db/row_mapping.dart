/// Una fila de `sqflite` no es el JSON que las pantallas esperan: un booleano
/// vuelve como `0`/`1` (SQLite no tiene tipo booleano propio) y una fecha
/// vuelve como enteros de milisegundos desde época (así los graba Prisma),
/// no como texto ISO. Los modelos de `data/models.dart` —que no cambian,
/// porque antes los llenaba el backend por HTTP— esperan `bool` de verdad y
/// fechas en ISO-8601. Este helper hace esa traducción una sola vez por
/// tabla en vez de repetirla a mano en cada repositorio.
Map<String, Object?> mapRow(
  Map<String, Object?> fila, {
  Set<String> columnasBooleanas = const {},
  Set<String> columnasFecha = const {},
}) {
  final resultado = Map<String, Object?>.from(fila);
  for (final columna in columnasBooleanas) {
    final valor = resultado[columna];
    if (valor is int) resultado[columna] = valor == 1;
  }
  for (final columna in columnasFecha) {
    final valor = resultado[columna];
    if (valor is int) {
      resultado[columna] = DateTime.fromMillisecondsSinceEpoch(
        valor,
        isUtc: true,
      ).toIso8601String();
    }
  }
  return resultado;
}
