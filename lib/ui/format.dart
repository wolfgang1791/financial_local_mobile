import 'package:intl/intl.dart';

/// El formato de dinero de la app: dos decimales, siempre.
///
/// Los formateadores se cachean porque construir un `NumberFormat` cuesta
/// bastante más que usarlo, y una pantalla de gastos formatea decenas de cifras
/// en cada reconstrucción. Es la misma decisión que ya está tomada en la web.
/// Lo que se muestra en lugar de una cifra tapada.
///
/// Puntos y no ceros ni asteriscos: un "S/ 0.00" es una cifra que se puede leer
/// mal —y da un susto—, y los asteriscos se leen como contraseña. Los puntos
/// dicen "hay un número acá y no lo estás viendo".
const cifraTapada = '•••••';

/// Una cifra ya formateada, o los puntos si están tapadas.
String tapar(String texto, bool ocultos) => ocultos ? cifraTapada : texto;

abstract final class Money {
  /// El patrón se fija a mano en vez de pedirle a `intl` el de la moneda.
  ///
  /// `NumberFormat.currency(locale: 'es_PE')` no da el formato peruano: `intl`
  /// no trae datos de es_PE y cae a los de España, que separa los miles con
  /// punto, los decimales con coma y pone el símbolo **detrás** — "2.412,32 S/"
  /// donde debería decir "S/ 2,412.32". Se ve raro y, peor, se lee mal: quien
  /// vea "2.412,32" puede entender dos mil cuatrocientos o dos con cuarenta.
  ///
  /// Con el patrón explícito el formato es el mismo que produce la web, que es
  /// el requisito de verdad: las dos pantallas muestran el mismo número.
  static final _patron = NumberFormat('#,##0.00', 'en_US');

  static String _simbolo(String currency) => switch (currency) {
    'PEN' => 'S/',
    'USD' => r'$',
    _ => currency,
  };

  static String format(double amount, String currency) =>
      '${_simbolo(currency)} ${_patron.format(amount)}';

  /// Con signo explícito. Para los netos, donde "+" y "−" son el dato.
  /// Un monto acortado, para donde no cabe entero: "3.0k", "1.5k", "480".
  ///
  /// Sin símbolo de moneda: se usa como etiqueta encima de un punto de un
  /// gráfico, donde la moneda ya la dice la cifra grande de arriba y repetirla
  /// en cada punto es tinta que no informa.
  static String compacto(double amount) {
    final v = amount.abs();
    if (v >= 1000) return '${(amount / 100).round() / 10}k';
    return amount.round().toString();
  }

  static String signed(double amount, String currency) {
    final s = format(amount.abs(), currency);
    return amount < 0 ? '−$s' : '+$s';
  }
}

/// Fechas en la zona del usuario.
///
/// La app **no** usa la zona del dispositivo: usa la del perfil, igual que la
/// web. Un usuario que viaja no debería ver sus meses correrse porque cruzó un
/// meridiano — su mes financiero sigue siendo el de su país.
abstract final class Fechas {
  static String dia(DateTime d) => DateFormat('d MMM', 'es').format(d.toLocal());
  static String diaLargo(DateTime d) => DateFormat("d 'de' MMMM", 'es').format(d.toLocal());
  static String diaConAnio(DateTime d) =>
      DateFormat("d 'de' MMMM 'de' y", 'es').format(d.toLocal());
  static String hora(DateTime d) => DateFormat('HH:mm').format(d.toLocal());
  static String mesLargo(DateTime d) => DateFormat('MMMM', 'es').format(d.toLocal());

  /// "miércoles 19 de agosto". Con el día de la semana porque es lo que sitúa
  /// una fecha sin hacer cuentas: "19" solo dice poco.
  static String hoyLargo(DateTime d) => DateFormat("EEEE d 'de' MMMM", 'es').format(d.toLocal());

  /// Cuánto mes queda, contando hoy como gastado: el 19 de agosto faltan 12.
  ///
  /// El último día del mes se pide como "el día 0 del siguiente", que resuelve
  /// febrero y los bisiestos sin una tabla de largos de mes que mantener.
  static ({int faltan, int total, int dia}) diasDelMes([DateTime? ahora]) {
    final d = ahora ?? DateTime.now();
    final total = DateTime(d.year, d.month + 1, 0).day;
    return (faltan: total - d.day, total: total, dia: d.day);
  }
}
