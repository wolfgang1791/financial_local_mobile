import 'package:sqflite/sqflite.dart';

import 'ledger.dart' show round2;

/// Puerto directo de `CurrenciesService.convert`. Para qué se convierte
/// decide qué lado del tipo de cambio se usa: comprar la moneda para pagar
/// una deuda usa venta; vender lo que ya tienes usa compra. Con el lado
/// equivocado una deuda en dólares se subestima.
enum ConversionPurpose { debt, asset }

class ConvertedAmount {
  const ConvertedAmount({
    required this.amount,
    required this.currency,
    required this.rate,
    required this.rateSide,
  });
  final double amount;
  final String currency;
  final double rate;
  final String rateSide; // buy | sell
}

double _round4(double n) => (n * 10000).round() / 10000;

Future<Map<String, Object?>?> _findRate(
  Database db,
  String baseCode,
  String quoteCode,
  DateTime date,
) async {
  final filas = await db.query(
    'ExchangeRate',
    where: 'baseCode = ? AND quoteCode = ? AND date <= ?',
    whereArgs: [baseCode, quoteCode, date.millisecondsSinceEpoch],
    orderBy: 'date DESC',
    limit: 1,
  );
  return filas.isEmpty ? null : filas.first;
}

/// Convierte respetando el lado del tipo de cambio que corresponde. Busca
/// la cotización en los dos sentidos: si existe USD→PEN, PEN→USD se
/// resuelve invirtiéndola, sin necesitar la fila espejo.
Future<ConvertedAmount> convert(
  Database db,
  double amount,
  String from,
  String to, {
  ConversionPurpose purpose = ConversionPurpose.asset,
  DateTime? date,
}) async {
  final fecha = date ?? DateTime.now().toUtc();
  if (from == to) {
    return ConvertedAmount(amount: round2(amount), currency: to, rate: 1, rateSide: 'buy');
  }

  final side = purpose == ConversionPurpose.debt ? 'sell' : 'buy';

  final directa = await _findRate(db, from, to, fecha);
  if (directa != null) {
    final rate = (directa[side] as num).toDouble();
    return ConvertedAmount(amount: round2(amount * rate), currency: to, rate: rate, rateSide: side);
  }

  // Cotización inversa: si tenemos USD→PEN y piden PEN→USD, se divide, y el
  // lado también se invierte — comprar dólares con soles es la venta de
  // dólares del otro lado del mostrador.
  final inversa = await _findRate(db, to, from, fecha);
  if (inversa != null) {
    final ladoInverso = side == 'buy' ? 'sell' : 'buy';
    final rate = (inversa[ladoInverso] as num).toDouble();
    return ConvertedAmount(
      amount: round2(amount / rate),
      currency: to,
      rate: _round4(1 / rate),
      rateSide: side,
    );
  }

  throw StateError(
    'No hay tipo de cambio de $from a $to al ${fecha.toIso8601String().substring(0, 10)}',
  );
}
