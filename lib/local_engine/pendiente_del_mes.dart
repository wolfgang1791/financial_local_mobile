import '../data/exchange.dart' as fx;
import '../data/models.dart';

/// Cuántas veces cae al mes cada frecuencia.
///
/// La misma tabla que `OCCURRENCES_PER_MONTH` del motor financiero del backend.
/// Sumando los montos crudos, un gasto anual de S/ 1,200 entraría al total del
/// mes como S/ 1,200 y el compromiso saldría doce veces más grande.
const ocurrenciasPorMes = {
  'WEEKLY': 4.345,
  'BIWEEKLY': 2.1725,
  'MONTHLY': 1.0,
  'QUARTERLY': 1 / 3,
  'YEARLY': 1 / 12,
};

double montoDelMes(RecurringFlow f, String mes) =>
    f.montoDe(mes) * (ocurrenciasPorMes[f.frequency] ?? 1.0);

/// Lo que te queda por pagar este mes, junto.
class PendienteDelMes {
  const PendienteDelMes({
    required this.fijos,
    required this.fijosCuantos,
    required this.fijosTotal,
    required this.deudas,
    required this.deudasCuantas,
    required this.deudasTotal,
    required this.sinCotizacion,
  });

  final double fijos;
  final int fijosCuantos;
  final double fijosTotal;
  final double deudas;
  final int deudasCuantas;
  final double deudasTotal;

  /// Monedas que no se pudieron convertir por falta de cotización. Quedan fuera
  /// del total y hay que decirlo: un total al que le falta una deuda es un
  /// total equivocado.
  final List<String> sinCotizacion;

  double get total => _r(fijos + deudas);
  double get comprometido => _r(fijosTotal + deudasTotal);
  bool get nadaPendiente => fijosCuantos == 0 && deudasCuantas == 0;
}

double _r(double n) => (n * 100).round() / 100;

/// Gastos fijos sin marcar más cuotas de deuda sin cubrir.
///
/// Las dos mitades responden a la misma pregunta —"¿cuánto tengo comprometido
/// todavía?"— pero viven en dos pantallas distintas, y hasta ahora nadie las
/// sumaba. Es la cifra que decide si el saldo de hoy alcanza.
///
/// Todo en la moneda del usuario: una cuota en dólares se convierte al tipo de
/// cambio **venta**, porque pagarla obliga a comprar esa moneda.
PendienteDelMes pendienteDelMes({
  required List<RecurringFlow> flujos,
  required List<Debt> deudas,
  required String mes,
  required String moneda,
  required List<ExchangeRate> tasas,
}) {
  var fijos = 0.0;
  var fijosCuantos = 0;
  var fijosTotal = 0.0;
  for (final f in flujos) {
    // Solo gastos: un sueldo pendiente de cobrar no es algo que debas pagar.
    if (f.type != 'EXPENSE') continue;
    // Sin ficha de este mes no hay compromiso que reclamar: el flujo todavía no
    // existía o ya terminó.
    if (!f.months.containsKey(mes)) continue;
    final monto = montoDelMes(f, mes);
    fijosTotal += monto;
    if (!f.pagadoEn(mes)) {
      fijos += monto;
      fijosCuantos++;
    }
  }

  var pendientes = 0.0;
  var cuantas = 0;
  var totalCuotas = 0.0;
  final sinCotizacion = <String>[];
  for (final d in deudas) {
    if (!d.isActive || d.balance <= 0) continue;

    double? aMoneda(double monto) {
      if (monto <= 0) return 0;
      if (d.currency == moneda) return monto;
      final c = fx.convert(monto, d.currency, moneda, tasas, purpose: fx.ConversionPurpose.debt);
      if (c == null) {
        if (!sinCotizacion.contains(d.currency)) sinCotizacion.add(d.currency);
        return null;
      }
      return c.amount;
    }

    final cuota = aMoneda(d.installmentAmount);
    final falta = aMoneda(d.pendingThisMonth);
    if (cuota == null || falta == null) continue;
    totalCuotas += cuota;
    if (d.pendingThisMonth > 0) {
      pendientes += falta;
      cuantas++;
    }
  }

  return PendienteDelMes(
    fijos: _r(fijos),
    fijosCuantos: fijosCuantos,
    fijosTotal: _r(fijosTotal),
    deudas: _r(pendientes),
    deudasCuantas: cuantas,
    deudasTotal: _r(totalCuotas),
    sinCotizacion: sinCotizacion,
  );
}
