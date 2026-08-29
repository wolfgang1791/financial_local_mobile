import 'models.dart';

/// Puerto directo de `frontend/src/lib/exchange.ts`.
///
/// Convierte usando el lado correcto de la cotización. No es un detalle
/// contable: con compra 3.37 y venta 3.417, una deuda de $1,000 vista en
/// soles cambia S/ 47 según qué cifra se use. Una deuda se paga comprando la
/// moneda (venta); un activo se valoriza vendiéndola (compra).
enum ConversionPurpose { debt, asset }

class Converted {
  const Converted({
    required this.amount,
    required this.quote,
    required this.side,
    required this.date,
  });

  final double amount;

  /// La cotización tal como se publica (3.417), no el multiplicador interno:
  /// al pasar de soles a dólares el multiplicador es 0.297, un número que
  /// nadie reconoce como "el tipo de cambio de hoy".
  final double quote;
  final String side; // 'compra' | 'venta'
  final String date;
}

Converted? convert(
  double amount,
  String from,
  String to,
  List<ExchangeRate> rates, {
  ConversionPurpose purpose = ConversionPurpose.asset,
}) {
  if (from == to) return Converted(amount: amount, quote: 1, side: 'compra', date: '');

  final wantsSell = purpose == ConversionPurpose.debt;

  ExchangeRate? directa;
  for (final r in rates) {
    if (r.baseCode == from && r.quoteCode == to) {
      directa = r;
      break;
    }
  }
  if (directa != null) {
    final cotizacion = wantsSell ? directa.sell : directa.buy;
    return Converted(
      amount: amount * cotizacion,
      quote: cotizacion,
      side: wantsSell ? 'venta' : 'compra',
      date: directa.date,
    );
  }

  // Cotización inversa: con USD→PEN cargado, PEN→USD se resuelve dividiendo,
  // y los lados se invierten — comprar dólares con soles es la venta del otro
  // lado del mostrador.
  ExchangeRate? inversa;
  for (final r in rates) {
    if (r.baseCode == to && r.quoteCode == from) {
      inversa = r;
      break;
    }
  }
  if (inversa != null) {
    final cotizacion = wantsSell ? inversa.buy : inversa.sell;
    return Converted(
      amount: amount / cotizacion,
      quote: cotizacion,
      side: wantsSell ? 'compra' : 'venta',
      date: inversa.date,
    );
  }

  return null;
}
