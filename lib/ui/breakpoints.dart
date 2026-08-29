/// Los cortes de ancho de la app.
///
/// Tres y no cinco: la web tiene más porque una ventana de escritorio puede
/// tener cualquier ancho, pero acá los dispositivos se agrupan de verdad en
/// teléfono, tablet y tablet grande. Un corte que ningún dispositivo cruza es
/// código que nunca se ejecuta y nadie prueba.
abstract final class Breakpoints {
  /// Teléfonos, incluido el iPhone SE en horizontal.
  static const compact = 600.0;

  /// Tablets en vertical.
  static const medium = 900.0;

  static bool isCompact(double width) => width < compact;
  static bool isMedium(double width) => width >= compact && width < medium;
  static bool isExpanded(double width) => width >= medium;

  /// El ancho máximo del contenido.
  ///
  /// En una tablet el texto no se estira a 1200 puntos: una línea de sesenta
  /// caracteres se lee y una de ciento sesenta no. La web usa `max-w-3xl` por
  /// la misma razón.
  static double contentWidth(double width) => width < 760 ? width : 720;

  /// Cuántas columnas caben para tarjetas de estadística.
  static int statColumns(double width) {
    if (width < 380) return 1;
    if (width < compact) return 2;
    return 4;
  }
}
