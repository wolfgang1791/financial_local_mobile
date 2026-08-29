import '../data/models.dart';

/// Los días del periodo, uno por uno, con lo que se gastó en cada uno.
///
/// Puerto de `frontend/src/lib/spendingDays.ts`.
///
/// Contesta una pregunta que ninguna otra vista de Panorama contesta: no cuánto
/// gastaste ni en qué, sino **cuándo** — qué días saliste a gastar y qué días no
/// tocaste la plata. Dos meses con el mismo total se viven distinto si uno son
/// treinta días de goteo y el otro son cuatro compras grandes.

class SpendingDay {
  const SpendingDay({
    required this.date,
    required this.day,
    required this.month,
    required this.year,
    required this.weekday,
    required this.amount,
    required this.count,
    this.fijo = 0,
    this.fijoCount = 0,
    this.deuda = 0,
    this.deudaCount = 0,
    this.categorias = const [],
  });

  /// "2026-08-16" — el día del calendario.
  final String date;
  final int day;
  final int month;
  final int year;

  /// 0 = lunes. La semana como la cuenta quien va a leer esto.
  final int weekday;
  final double amount;
  final int count;

  /// Lo de ese día que ya estaba comprometido, para poder descontarlo sin
  /// volver a preguntar: cuotas de deuda por un lado y gastos fijos marcados
  /// por el otro. Separados porque son dos decisiones distintas —"el alquiler
  /// no cuenta" y "la cuota del préstamo no cuenta"— y uno puede querer una sin
  /// la otra.
  final double fijo;
  final int fijoCount;
  final double deuda;
  final int deudaCount;

  /// Las subcategorías que tuvieron gasto ese día, por id.
  ///
  /// Viajan todas y la pantalla elige cuáles dibuja: cuáles marcar es una
  /// decisión del usuario que cambia con un toque, y volver a la base por cada
  /// cambio de opinión sería pagar una consulta por una pregunta contestada.
  final List<String> categorias;

  bool get conGasto => count > 0;

  /// El mismo día sin lo que se haya decidido no contar.
  SpendingDay descontando({required bool sinFijos, required bool sinDeudas}) {
    if (!sinFijos && !sinDeudas) return this;
    final fuera = (sinFijos ? fijo : 0) + (sinDeudas ? deuda : 0);
    final fueraCount = (sinFijos ? fijoCount : 0) + (sinDeudas ? deudaCount : 0);
    return SpendingDay(
      date: date,
      day: day,
      month: month,
      year: year,
      weekday: weekday,
      // Nunca por debajo de cero: un día con una cuota y nada más queda en
      // cero, que es exactamente "no saliste a gastar".
      amount: amount - fuera < 0 ? 0 : amount - fuera,
      count: count - fueraCount < 0 ? 0 : count - fueraCount,
      fijo: fijo,
      fijoCount: fijoCount,
      deuda: deuda,
      deudaCount: deudaCount,
      categorias: categorias,
    );
  }
}

class SpendingDays {
  const SpendingDays({
    required this.days,
    required this.conGasto,
    required this.sinGasto,
    required this.rachaSinGasto,
    required this.rachaActual,
    required this.totalGastado,
    required this.mayor,
    required this.menor,
  });

  final List<SpendingDay> days;
  final int conGasto;
  final int sinGasto;

  /// La racha más larga de días seguidos sin gastar nada. Es el número que la
  /// gente recuerda de un mes austero.
  final int rachaSinGasto;

  /// Los días seguidos sin gastar contando desde el final del periodo. Solo
  /// significa algo en un periodo que llega hasta hoy.
  final int rachaActual;
  final double totalGastado;

  /// El día que más se gastó y el que menos, **entre los que tuvieron gasto**.
  /// Un día en cero no es "el que menos gastaste", es uno de los que no
  /// gastaste — y ya se cuentan aparte. Null si no hubo ningún gasto.
  final SpendingDay? mayor;
  final SpendingDay? menor;
}

String _clave(int y, int m, int d) =>
    '$y-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';

/// Reparte el gasto del periodo día por día.
///
/// [desde] y [hasta] son el rango que está mirando el usuario —el mismo que
/// filtra todo lo demás en Panorama— y se recorren **enteros**, incluidos los
/// días vacíos: los días sin gasto son justamente la mitad de la respuesta, y
/// agrupar solo los que tienen movimientos los haría desaparecer.
///
/// [primerRegistro] corta por la izquierda. Sin él, mirar "5 años" con seis
/// meses de historia diría "1.600 días sin gastar", que no es austeridad sino
/// que la app no existía. Un día que nadie pudo registrar no es un día sin
/// gasto.
SpendingDays spendingDays(
  List<Transaction> gastos,
  DateTime desde,
  DateTime hasta, {
  DateTime? primerRegistro,
}) {
  final porDia = <String, List<double>>{};
  final categoriasPorDia = <String, Set<String>>{};
  for (final t in gastos) {
    final local = t.occurredAt.toLocal();
    final key = _clave(local.year, local.month, local.day);
    // [monto, cuantos, fijo, fijoCuantos, deuda, deudaCuantos]
    final acc = porDia[key] ??= [0, 0, 0, 0, 0, 0];
    acc[0] += t.amount;
    acc[1] += 1;
    if (t.recurringFlowId != null) {
      acc[2] += t.amount;
      acc[3] += 1;
    }
    if (t.debtId != null) {
      acc[4] += t.amount;
      acc[5] += 1;
    }
    // La subcategoría concreta y no su padre: "Comida rápida" y "Mercado" son
    // dos gastos que no se parecen en nada, y marcarlos juntos bajo "Comida" no
    // distinguiría el día que pediste delivery del día que hiciste la compra.
    final categoria = t.category?.id;
    if (categoria != null) (categoriasPorDia[key] ??= <String>{}).add(categoria);
  }

  final arranque = primerRegistro != null && primerRegistro.isAfter(desde)
      ? primerRegistro.toLocal()
      : desde.toLocal();
  final fin = hasta.toLocal();
  final ultimo = _clave(fin.year, fin.month, fin.day);

  final days = <SpendingDay>[];
  var cursor = DateTime(arranque.year, arranque.month, arranque.day);
  // Tope de 2000 vueltas: más que el periodo más largo que se puede elegir, y
  // evita que una fecha corrupta se lleve por delante el dibujo entero.
  for (var i = 0; i < 2000; i++) {
    final key = _clave(cursor.year, cursor.month, cursor.day);
    final gasto = porDia[key];
    days.add(
      SpendingDay(
        date: key,
        day: cursor.day,
        month: cursor.month,
        year: cursor.year,
        // DateTime.weekday es 1 = lunes; acá 0 = lunes.
        weekday: cursor.weekday - 1,
        amount: gasto?[0] ?? 0,
        count: (gasto?[1] ?? 0).toInt(),
        fijo: gasto?[2] ?? 0,
        fijoCount: (gasto?[3] ?? 0).toInt(),
        deuda: gasto?[4] ?? 0,
        deudaCount: (gasto?[5] ?? 0).toInt(),
        categorias: [...?categoriasPorDia[key]],
      ),
    );
    if (key.compareTo(ultimo) >= 0) break;
    cursor = DateTime(cursor.year, cursor.month, cursor.day + 1);
  }

  return resumirDias(days);
}

/// Las cifras de una lista de días, ya descontado lo que no se quiera contar.
///
/// Va aparte de [spendingDays] para que la pantalla pueda cambiar los
/// descuentos sin volver a pedir nada: los días traen su desglose, y prender o
/// apagar "sin deudas" es rehacer esta cuenta, no otro viaje a la base.
SpendingDays resumirDias(List<SpendingDay> dias, {bool sinFijos = false, bool sinDeudas = false}) {
  final days = sinFijos || sinDeudas
      ? [for (final d in dias) d.descontando(sinFijos: sinFijos, sinDeudas: sinDeudas)]
      : dias;

  final conGasto = days.where((d) => d.conGasto).length;
  final totalGastado = days.fold<double>(0, (a, d) => a + d.amount);

  var racha = 0;
  var mejor = 0;
  for (final d in days) {
    if (d.conGasto) {
      racha = 0;
      continue;
    }
    racha++;
    if (racha > mejor) mejor = racha;
  }

  var rachaActual = 0;
  for (var i = days.length - 1; i >= 0 && !days[i].conGasto; i--) {
    rachaActual++;
  }

  // Empates: se queda el primero, que es el más antiguo. Da igual cuál, pero da
  // igual siempre del mismo modo — el número no baila entre dos recargas.
  SpendingDay? mayor;
  SpendingDay? menor;
  for (final d in days.where((d) => d.conGasto)) {
    if (mayor == null || d.amount > mayor.amount) mayor = d;
    if (menor == null || d.amount < menor.amount) menor = d;
  }

  return SpendingDays(
    days: days,
    conGasto: conGasto,
    sinGasto: days.length - conGasto,
    rachaSinGasto: mejor,
    rachaActual: rachaActual,
    totalGastado: totalGastado,
    mayor: mayor,
    menor: menor,
  );
}
