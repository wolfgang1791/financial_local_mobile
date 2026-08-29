import 'models.dart';

double _round2(double n) => (n * 100).roundToDouble() / 100;

/// Todo el dinero que pasó por tus manos en el periodo, y dónde terminó.
///
/// Es el port exacto de `incomeAllocation.ts` de la web, y se copia la lógica en
/// vez de pedirle el resultado al servidor por una razón concreta: el reparto
/// depende de qué cuentas cuenta el usuario, y eso ya viaja en los movimientos.
/// Duplicarlo en el backend habría significado un cuarto sitio donde el mismo
/// dinero se suma con reglas que se van separando.
///
/// **Cierra como identidad contable, no como aproximación:**
///
///     (lo que tenías + lo que entró) = (deudas + fijos + otros) + lo que queda
///
/// Y "lo que queda" es el patrimonio de hoy, exacto. El saldo de apertura se
/// deduce hacia atrás desde él en vez de sumarse aparte, así el anillo no puede
/// desviarse de la tarjeta que tiene encima.
class PeriodAllocation {
  const PeriodAllocation({
    required this.opening,
    required this.income,
    required this.adjustmentsIn,
    required this.movedIn,
    required this.sources,
    required this.debts,
    required this.fixed,
    required this.other,
    required this.adjustmentsOut,
    required this.movedOut,
    required this.available,
  });

  /// Lo que ya tenías al empezar el periodo.
  final double opening;
  final double income;

  /// Lo que los ajustes movieron **en neto**, cuando movieron hacia arriba.
  /// Ver [adjustmentsOut] para por qué es el neto y no la suma de las entradas.
  final double adjustmentsIn;

  /// Llegó desde una cuenta que no se cuenta.
  final double movedIn;

  /// La suma de los cuatro: el 100% del anillo.
  final double sources;

  final double debts;
  final double fixed;

  /// Gastos sueltos: lo que decidiste tú, día a día.
  final double other;

  /// Lo que los ajustes movieron en neto, cuando movieron hacia abajo.
  ///
  /// Va aparte de [other] porque mezclados decían que habías gastado en tu vida
  /// una plata que nunca se gastó — 5,960 de ajustes dentro de 9,004 de
  /// "gastos".
  ///
  /// **En neto, y no la suma de las salidas.** Un ajuste casi nunca viene solo:
  /// al marcar pagado un mes pasado, la app escribe el pago y su contrapartida
  /// —"Ya estaba reflejado en tu saldo"— con el mismo monto y la misma fecha,
  /// para que el saldo no se mueva dos veces. Contando las dos patas por
  /// separado, el anillo decía que habían entrado 5,866 de ajustes y salido
  /// 5,960: dos cifras enormes, una porción del 34%, y ni un sol se movió de
  /// verdad. Es la misma regla que ya se aplicaba a las transferencias con sus
  /// dos patas dentro del periodo, y por la misma razón.
  ///
  /// Solo uno de los dos campos puede ser distinto de cero: los ajustes del
  /// periodo, todos juntos, o te subieron el saldo o te lo bajaron.
  final double adjustmentsOut;
  final double movedOut;

  /// Lo que queda hoy: tu patrimonio.
  final double available;
}

double _signed(Transaction t) => t.type == 'INCOME' ? t.amount : -t.amount;

PeriodAllocation allocatePeriod(List<Transaction> inPeriod, double currentBalance) {
  var income = 0.0;
  var adjustmentsIn = 0.0;
  var movedIn = 0.0;
  var debts = 0.0;
  var fixed = 0.0;
  var other = 0.0;
  var adjustmentsOut = 0.0;
  var movedOut = 0.0;
  var net = 0.0;

  // Las dos patas de una transferencia se cuentan primero para poder ignorarlas
  // después: si las dos están a la vista, mover plata entre cuentas propias no
  // cambia nada y no debe aparecer ni como origen ni como destino.
  final patas = <String, int>{};
  for (final t in inPeriod) {
    if (t.transferId != null) {
      patas[t.transferId!] = (patas[t.transferId!] ?? 0) + 1;
    }
  }

  for (final t in inPeriod) {
    net += _signed(t);
    if (t.transferId != null && (patas[t.transferId!] ?? 0) >= 2) continue;

    if (t.type == 'INCOME') {
      if (t.kind == 'MOVEMENT') {
        income += t.amount;
      } else if (t.kind == 'TRANSFER') {
        movedIn += t.amount;
      } else {
        adjustmentsIn += t.amount;
      }
      continue;
    }
    if (t.type != 'EXPENSE') continue;

    if (t.kind == 'TRANSFER') {
      movedOut += t.amount;
    } else if (t.kind != 'MOVEMENT') {
      adjustmentsOut += t.amount;
    } else if (t.debtId != null) {
      debts += t.amount;
    } else if (t.recurringFlowId != null) {
      fixed += t.amount;
    } else {
      other += t.amount;
    }
  }

  final available = _round2(currentBalance);
  final opening = _round2(available - net);

  // Los ajustes, netos. Lo que se muestra es cuánto movieron en total, que es
  // la única cifra que significa algo: las parejas que se anulan desaparecen
  // solas y lo que queda es la corrección de verdad.
  final ajusteNeto = _round2(adjustmentsIn - adjustmentsOut);
  final netoIn = ajusteNeto > 0 ? ajusteNeto : 0.0;
  final netoOut = ajusteNeto < 0 ? -ajusteNeto : 0.0;

  return PeriodAllocation(
    opening: opening,
    income: _round2(income),
    adjustmentsIn: netoIn,
    movedIn: _round2(movedIn),
    sources: _round2(opening + income + netoIn + movedIn),
    debts: _round2(debts),
    fixed: _round2(fixed),
    other: _round2(other),
    adjustmentsOut: netoOut,
    movedOut: _round2(movedOut),
    available: available,
  );
}

/// Los periodos que se pueden mirar.
///
/// Son los mismos diez de la web, en el mismo orden y con la misma aritmética.
/// La primera versión de la app traía solo cuatro —hoy, semana, mes, año— y eso
/// dejaba fuera justo los rangos que uno quiere en un teléfono: "30 días" y
/// "6 meses" responden "¿cómo vengo?" sin obligar a pensar en qué día empieza
/// el mes.
enum Periodo { hoy, semana, mes, anio, d7, d30, s12, m6, a1, a5 }

extension PeriodoX on Periodo {
  String get etiqueta => switch (this) {
    Periodo.hoy => 'Hoy',
    Periodo.semana => 'Esta semana',
    Periodo.mes => 'Este mes',
    Periodo.anio => 'Este año',
    Periodo.d7 => '7 días',
    Periodo.d30 => '30 días',
    Periodo.s12 => '12 semanas',
    Periodo.m6 => '6 meses',
    Periodo.a1 => '1 año',
    Periodo.a5 => '5 años',
  };

  /// El rótulo dentro de una frase: "gastos **de los últimos 30 días**".
  String get enFrase => switch (this) {
    Periodo.hoy => 'de hoy',
    Periodo.semana => 'de esta semana',
    Periodo.mes => 'de este mes',
    Periodo.anio => 'de este año',
    Periodo.d7 => 'de los últimos 7 días',
    Periodo.d30 => 'de los últimos 30 días',
    Periodo.s12 => 'de las últimas 12 semanas',
    Periodo.m6 => 'de los últimos 6 meses',
    Periodo.a1 => 'del último año',
    Periodo.a5 => 'de los últimos 5 años',
  };

  /// Desde cuándo cuenta, en la zona local.
  ///
  /// Los relativos cuentan **días de calendario incluyendo hoy**, no ventanas de
  /// horas: "7 días" va de hace seis días a medianoche hasta ahora. Con 168 horas
  /// hacia atrás, un gasto de esta mañana hace siete días entra o no según la
  /// hora en que mires la pantalla, y el total cambia solo.
  ///
  /// La semana arranca el **lunes**: es la convención peruana, y con el domingo
  /// como inicio una salida del sábado y otra del domingo caen en semanas
  /// distintas.
  DateTime desde(DateTime ahora) {
    final hoy = DateTime(ahora.year, ahora.month, ahora.day);
    return switch (this) {
      Periodo.hoy => hoy,
      Periodo.semana => hoy.subtract(Duration(days: hoy.weekday - 1)),
      Periodo.mes => DateTime(ahora.year, ahora.month, 1),
      Periodo.anio => DateTime(ahora.year, 1, 1),
      Periodo.d7 => hoy.subtract(const Duration(days: 6)),
      Periodo.d30 => hoy.subtract(const Duration(days: 29)),
      Periodo.s12 => hoy.subtract(const Duration(days: 83)),
      // Los de meses se anclan al inicio del mes, no a "hace N por 30 días": es
      // lo que hace que "6 meses" signifique seis meses de calendario.
      Periodo.m6 => DateTime(ahora.year, ahora.month - 6, 1),
      Periodo.a1 => DateTime(ahora.year, ahora.month - 12, 1),
      Periodo.a5 => DateTime(ahora.year, ahora.month - 60, 1),
    };
  }
}

/// Un periodo elegido: o un rango relativo, o un mes ya cerrado.
///
/// Son dos cosas distintas y por eso conviven en un tipo en vez de en un enum
/// más grande. Un relativo **termina ahora** y por eso su patrimonio es el de
/// hoy; un mes cerrado terminó, y mirarlo es mirar algo que ya no se puede
/// cambiar. Meter "julio" como una constante más del enum habría borrado esa
/// diferencia, que es la que decide si la pantalla ofrece ajustar el saldo.
class PeriodoElegido {
  const PeriodoElegido.relativo(Periodo this.relativo) : mes = null;
  const PeriodoElegido.mes(String this.mes) : relativo = null;

  final Periodo? relativo;

  /// "2026-07" cuando es un mes cerrado.
  final String? mes;

  bool get esMesCerrado => mes != null;

  /// Un identificador estable para compararlos.
  String get id => mes ?? relativo!.name;

  String etiqueta(DateTime ahora) {
    if (relativo != null) return relativo!.etiqueta;
    final partes = mes!.split('-');
    final n = int.tryParse(partes[1]) ?? 1;
    // El año solo cuando no es el actual: "julio de 2026" repetido doce veces
    // es ruido si todo pasó este año.
    final nombre = _meses[(n - 1).clamp(0, 11)];
    return partes[0] == '${ahora.year}' ? nombre : '$nombre ${partes[0]}';
  }

  String enFrase(DateTime ahora) => relativo?.enFrase ?? 'de ${etiqueta(ahora).toLowerCase()}';

  /// El rango, en la zona local, con el extremo derecho **exclusivo**.
  ///
  /// Un relativo llega hasta el final de hoy —no hasta este segundo—, y ahí
  /// está la diferencia que costó un bug: un gasto se guarda fechado a mediodía
  /// porque es una fecha, no una hora. Con el rango terminando en "ahora", un
  /// café anotado a las 8 de la mañana quedaba en el futuro respecto del filtro
  /// y desaparecía del calendario, del anillo y del reparto — mientras el
  /// patrimonio, que lo calcula el motor y no el filtro, sí lo mostraba.
  ///
  /// Un mes cerrado termina cuando terminó: el 1 del siguiente ya no es suyo.
  (DateTime desde, DateTime hasta) rango(DateTime ahora) {
    if (relativo != null) {
      return (relativo!.desde(ahora), DateTime(ahora.year, ahora.month, ahora.day + 1));
    }
    final partes = mes!.split('-');
    final anio = int.parse(partes[0]);
    final n = int.parse(partes[1]);
    return (DateTime(anio, n, 1), DateTime(anio, n + 1, 1));
  }
}

const _meses = [
  'enero',
  'febrero',
  'marzo',
  'abril',
  'mayo',
  'junio',
  'julio',
  'agosto',
  'septiembre',
  'octubre',
  'noviembre',
  'diciembre',
];

/// Los periodos que tiene sentido ofrecer, dados los datos que hay.
///
/// Un rango que empieza antes del primer registro muestra exactamente lo mismo
/// que el anterior. Con un mes de historia, "6 meses", "1 año" y "5 años" son
/// tres pastillas que llevan a la misma pantalla — y tres formas de que el
/// usuario crea que la app se rompió. Se queda solo la primera que ya cubre
/// todo.
///
/// Después de los relativos van los **meses cerrados**, del más nuevo al más
/// viejo. Son el otro modo de mirar y faltaban: sin ellos, en agosto no había
/// forma de ver julio — "Este año" lo incluye pero mezclado con todo lo demás, y
/// "el mes pasado" es justo la pregunta que uno se hace al cerrar un mes.
List<PeriodoElegido> periodosOfrecidos(
  DateTime? primerRegistro,
  DateTime ahora, {
  List<String> mesesCerrados = const [],
}) {
  final ofrecidos = <PeriodoElegido>[];
  var yaCubreTodo = false;
  for (final p in Periodo.values) {
    if (primerRegistro != null) {
      final cubreTodo = !p.desde(ahora).isAfter(primerRegistro);
      if (cubreTodo && yaCubreTodo) continue;
      if (cubreTodo) yaCubreTodo = true;
    }
    ofrecidos.add(PeriodoElegido.relativo(p));
  }

  final mesActual = '${ahora.year}-${ahora.month.toString().padLeft(2, "0")}';
  for (final m in mesesCerrados.reversed) {
    // El mes en curso no entra: ya está arriba como "Este mes".
    if (m == mesActual) continue;
    ofrecidos.add(PeriodoElegido.mes(m));
  }
  return ofrecidos;
}
