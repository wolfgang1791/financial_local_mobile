import 'package:intl/intl.dart';

/// Puerto directo de `backend/src/spending/money-format.ts` — el formato de
/// dinero que usa el motor para redactar prosa ("liberas S/ 500 al mes"), no
/// el que usa la UI para pintar cifras sueltas (`ui/format.dart`).
///
/// Reproduce byte a byte lo que produce
/// `Intl.NumberFormat('es-PE', {style: 'currency', currency}).format(n)` en
/// Node: confirmado contra Node mismo que PEN da "S/" y cualquier otra
/// moneda (USD, EUR) da su código ISO tal cual — nunca "$" ni "€" — y que
/// el signo negativo va antes del símbolo, no antes del número.
final _patron = NumberFormat('#,##0.00', 'en_US');

String _simbolo(String currency) => currency == 'PEN' ? 'S/' : currency;

String formatMoney(double amount, String currency) {
  final negativo = amount < 0;
  final texto = '${_simbolo(currency)} ${_patron.format(amount.abs())}';
  return negativo ? '-$texto' : texto;
}
