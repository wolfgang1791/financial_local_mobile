import '../local_engine/ledger.dart' show tiposDeCredito;
import 'package:flutter/widgets.dart' show Color;
import '../design/tokens.dart' show AppColors;

/// Los modelos que la app consume.
///
/// Se parsean a mano y no con generación de código: son diez tipos, el JSON lo
/// produce un backend propio cuyo contrato conocemos, y meter `build_runner` en
/// el proyecto obliga a regenerar en cada cambio a cambio de ahorrar unas líneas.
///
/// Todo lo numérico pasa por [_num]. El backend serializa los `Decimal` de
/// Prisma como **cadenas** —"2408.19"— para no perder precisión en JSON, así que
/// un `as double` revienta en la primera cuenta con céntimos. Es el error que
/// aparece en producción y no en la demo, porque en la demo todo termina en cero.
double _num(dynamic v) => switch (v) {
  null => 0,
  num n => n.toDouble(),
  String s => double.tryParse(s) ?? 0,
  _ => 0,
};

double? _numOrNull(dynamic v) => v == null ? null : _num(v);

class AppUser {
  const AppUser({
    required this.id,
    required this.name,
    required this.email,
    required this.currency,
    required this.timezone,
  });

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '',
    email: (j['email'] as String?) ?? '',
    currency: (j['currency'] as String?) ?? 'PEN',
    timezone: (j['timezone'] as String?) ?? 'America/Lima',
  );

  final String id;
  final String name;
  final String email;
  final String currency;
  final String timezone;

  String get firstName => name.split(' ').first;
}

class Category {
  const Category({
    required this.id,
    required this.name,
    this.parentName,
    this.type = 'EXPENSE',
    this.icon,
    this.isSystem = false,
    this.isEssential,
    this.parentId,
  });

  factory Category.fromJson(Map<String, dynamic> j) => Category(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '',
    parentName: (j['parent'] as Map<String, dynamic>?)?['name'] as String?,
    type: (j['type'] as String?) ?? 'EXPENSE',
    icon: j['icon'] as String?,
    isSystem: (j['isSystem'] as bool?) ?? false,
    isEssential: j['isEssential'] as bool?,
    parentId:
        (j['parentId'] as String?) ?? (j['parent'] as Map<String, dynamic>?)?['id'] as String?,
  );

  final String id;
  final String name;
  final String? parentName;
  final String type;

  /// El ícono guardado al crearla. `null` en la taxonomía sembrada, que cae al
  /// mismo adivinador por palabra clave que usa una categoría nueva.
  final String? icon;

  /// Sembrada por el backend, no creada por el usuario. Solo las no-sistema se
  /// pueden borrar.
  final bool isSystem;

  /// `null` cuando nadie decidió todavía si sobrevive a un corte de ingresos.
  final bool? isEssential;
  final String? parentId;

  /// El nombre completo, para buscar: "Comida y bebidas · Cafetería".
  String get ruta => parentName == null ? name : '$parentName · $name';
}

class Transaction {
  const Transaction({
    required this.id,
    required this.accountId,
    this.accountName = '',
    required this.amount,
    required this.type,
    required this.kind,
    required this.occurredAt,
    required this.detail,
    required this.category,
    required this.transferId,
    required this.debtId,
    required this.recurringFlowId,
    this.paymentMethod,
    this.balanceBefore,
  });

  factory Transaction.fromJson(Map<String, dynamic> j) => Transaction(
    id: j['id'] as String,
    accountId: (j['accountId'] as String?) ?? '',
    accountName: ((j['account'] as Map?)?['name'] as String?) ?? '',
    amount: _num(j['amount']),
    type: (j['type'] as String?) ?? 'EXPENSE',
    kind: (j['kind'] as String?) ?? 'MOVEMENT',
    occurredAt: DateTime.parse(j['occurredAt'] as String),
    detail: (j['detail'] ?? j['description'] ?? '') as String,
    category: j['category'] == null
        ? null
        : Category.fromJson(j['category'] as Map<String, dynamic>),
    transferId: j['transferId'] as String?,
    debtId: j['debtId'] as String?,
    recurringFlowId: j['recurringFlowId'] as String?,
    paymentMethod: j['paymentMethod'] as String?,
    balanceBefore: _numOrNull(j['balanceBefore']),
  );

  final String id;
  final String accountId;

  /// El nombre de la cuenta donde cayó, para poder decirlo en la fila sin que
  /// cada lista tenga que ir a buscarlo por su id.
  final String accountName;
  final double amount;
  final String type;
  final String kind;
  final DateTime occurredAt;
  final String detail;
  final Category? category;

  /// Las tres marcas que deciden en qué renglón cae este movimiento. Sin ellas
  /// el reparto no puede distinguir una cuota de un almuerzo.
  final String? transferId;
  final String? debtId;
  final String? recurringFlowId;

  final String? paymentMethod;

  /// El saldo justo antes de este movimiento, calculado por el backend sobre
  /// el ledger completo. `null` en una cuenta que no cuenta al patrimonio.
  final double? balanceBefore;

  bool get isExpense => type == 'EXPENSE';

  /// El nombre que se muestra: el detalle si lo hay, si no la categoría.
  /// Un movimiento sin ninguno de los dos igual tiene que decir algo.
  String get label => detail.isNotEmpty ? detail : (category?.name ?? 'Movimiento');
}

/// Una cuenta tal como la pinta la tarjeta de patrimonio: con su saldo ya
/// calculado por el motor y si el usuario la ocultó del total.
class CashPositionAccount {
  const CashPositionAccount({
    required this.id,
    required this.name,
    required this.type,
    required this.currentBalance,
    this.creditLimit,
    required this.currency,
    required this.isHidden,
  });

  factory CashPositionAccount.fromJson(Map<String, dynamic> j) => CashPositionAccount(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '',
    type: (j['type'] as String?) ?? 'CASH',
    currentBalance: _num(j['currentBalance']),
    creditLimit: _numOrNull(j['creditLimit']),
    currency: (j['currency'] as String?) ?? 'PEN',
    isHidden: (j['isHidden'] as bool?) ?? false,
  );

  final String id;
  final String name;
  final String type;
  final double currentBalance;

  /// El cupo de una tarjeta. `null` en el resto de las cuentas y en una tarjeta
  /// sin cupo escrito — ahí se ve lo que debes y no cuánto queda.
  final double? creditLimit;
  final String currency;

  /// Excluida del patrimonio a pedido del usuario. Viaja igual para que la
  /// tarjeta la muestre apagada y se pueda volver a sumar.
  final bool isHidden;
}

class CashPosition {
  const CashPosition({
    required this.total,
    required this.income,
    required this.expenses,
    required this.currency,
    required this.accounts,
  });

  /// Los ingresos y gastos del mes vienen **anidados** bajo `month`, no en la
  /// raíz: leerlos de la raíz devolvía cero y la tarjeta mostraba un mes vacío
  /// sobre un patrimonio correcto, que es la clase de incoherencia que hace
  /// dudar del resto de la pantalla.
  factory CashPosition.fromJson(Map<String, dynamic> j) {
    final mes = (j['month'] as Map<String, dynamic>?) ?? const {};
    return CashPosition(
      total: _num(j['total']),
      income: _num(mes['income']),
      expenses: _num(mes['expenses']),
      currency: (j['currency'] as String?) ?? 'PEN',
      accounts: ((j['accounts'] as List?) ?? [])
          .map((e) => CashPositionAccount.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  final double total;
  final double income;
  final double expenses;
  final String currency;
  final List<CashPositionAccount> accounts;
}

/// Un punto de la curva de patrimonio.
///
/// Sirve para las dos series —la diaria y la mensual— porque el gráfico es el
/// mismo y solo cambia el paso. Dos tipos para dos ejes distintos habría
/// obligado a dos pintores idénticos.
/// Un mes de gasto, partido en las tres cosas que lo componen: lo fijo, las
/// cuotas y lo que decidiste tú.
class SpendingPoint {
  const SpendingPoint({
    required this.month,
    required this.total,
    required this.fixed,
    required this.debt,
    required this.life,
    required this.count,
    required this.inProgress,
  });

  factory SpendingPoint.fromJson(Map<String, dynamic> j) => SpendingPoint(
    month: (j['month'] as String?) ?? '',
    total: _num(j['total']),
    fixed: _num(j['fixed']),
    debt: _num(j['debt']),
    life: _num(j['life']),
    count: (j['count'] as num?)?.toInt() ?? 0,
    inProgress: (j['inProgress'] as bool?) ?? false,
  );

  final String month;

  /// Todo el gasto corriente del mes: la suma de los tres de abajo.
  final double total;
  final double fixed;
  final double debt;
  final double life;
  final int count;

  /// El mes en curso todavía no terminó: compararlo con los cerrados sin avisar
  /// hace pensar que vas mucho mejor cuando lo que pasa es que aún no acaba.
  final bool inProgress;
}

class NetWorthPoint {
  const NetWorthPoint({
    required this.etiqueta,
    required this.liquid,
    required this.enCurso,
    this.byAccount = const {},
  });

  factory NetWorthPoint.mensual(Map<String, dynamic> j) => NetWorthPoint(
    etiqueta: (j['month'] as String?) ?? '',
    liquid: _num(j['liquid']),
    enCurso: (j['inProgress'] as bool?) ?? false,
  );

  factory NetWorthPoint.diario(Map<String, dynamic> j) => NetWorthPoint(
    etiqueta: (j['date'] as String?) ?? '',
    liquid: _num(j['liquid']),
    enCurso: false,
    // El saldo de cada cuenta ese día: es lo que deja al gráfico elegir cuáles
    // dibuja sin tocar nada de la app.
    byAccount: ((j['byAccount'] as Map?) ?? const {}).map((k, v) => MapEntry(k as String, _num(v))),
  );

  final String etiqueta;
  final double liquid;
  final bool enCurso;

  /// El saldo de cada cuenta ese día, por su id. Solo lo trae la serie diaria.
  final Map<String, double> byAccount;
}

/// Un flujo recurrente: un sueldo o un gasto fijo.
/// La ficha de un mes de un flujo: cuánto es y hasta cuándo hay para pagarlo.
class FlowMonth {
  const FlowMonth({required this.amount, required this.dueDate, this.paidAt});

  factory FlowMonth.fromJson(Map<String, dynamic> j) => FlowMonth(
    amount: _num(j['amount']),
    dueDate: DateTime.parse(j['dueDate'] as String),
    paidAt: j['paidAt'] == null ? null : DateTime.parse(j['paidAt'] as String),
  );

  final double amount;

  /// La caducidad de ese mes. Nace en su último día y se puede mover.
  final DateTime dueDate;

  /// Cuándo se marcó pagado o cobrado este mes, y null si todavía no.
  ///
  /// Vive acá y no en el flujo porque es de este mes: julio puede estar pagado
  /// con agosto pendiente, y marcar agosto no puede desmarcar julio.
  final DateTime? paidAt;

  bool get pagado => paidAt != null;
}

/// Lo que un flujo registró en un mes: cuánto y con qué movimiento.
class FlowMonthRecord {
  const FlowMonthRecord({required this.month, required this.amount, required this.transactionId});

  factory FlowMonthRecord.fromJson(Map<String, dynamic> j) => FlowMonthRecord(
    month: (j['month'] as String?) ?? '',
    amount: _num(j['amount']),
    transactionId: (j['transactionId'] as String?) ?? '',
  );

  final String month;
  final double amount;
  final String transactionId;
}

class RecurringFlow {
  const RecurringFlow({
    required this.id,
    required this.name,
    required this.type,
    required this.amount,
    required this.frequency,
    required this.nextDueDate,
    required this.paidThisMonth,
    required this.missedMonths,
    required this.paidMonths,
    required this.monthlyRecords,
    this.months = const {},
    this.isActive = true,
    required this.categoryName,
    required this.accountId,
  });

  factory RecurringFlow.fromJson(Map<String, dynamic> j) => RecurringFlow(
    id: j['id'] as String,
    // Archivado: borraste el flujo pero tenía pagos, así que se conserva por su
    // historia. Sigue en la lista para que sus meses anteriores no desaparezcan,
    // y sin botón de marcar — no se sigue registrando algo ya terminado.
    isActive: (j['isActive'] as bool?) ?? true,
    name: (j['name'] as String?) ?? '',
    type: (j['type'] as String?) ?? 'EXPENSE',
    amount: _num(j['amount']),
    frequency: (j['frequency'] as String?) ?? 'MONTHLY',
    nextDueDate: DateTime.parse(j['nextDueDate'] as String),
    paidThisMonth: j['statusThisMonth'] == 'PAID',
    missedMonths: ((j['missedMonths'] as List?) ?? []).cast<String>(),
    paidMonths: ((j['paidMonths'] as List?) ?? []).cast<String>(),
    monthlyRecords: ((j['monthlyRecords'] as List?) ?? [])
        .map((e) => FlowMonthRecord.fromJson(e as Map<String, dynamic>))
        .toList(),
    months: {
      for (final e in ((j['months'] as Map?) ?? const {}).entries)
        if (e.value is Map)
          e.key as String: FlowMonth.fromJson((e.value as Map).cast<String, dynamic>()),
    },
    categoryName: (j['category'] as Map<String, dynamic>?)?['name'] as String?,
    accountId: j['accountId'] as String?,
  );

  final String id;
  final String name;
  final String type;
  final double amount;
  final String frequency;
  final DateTime nextDueDate;
  final bool paidThisMonth;

  /// Meses cerrados sin ningún registro. Es lo único que deja rastro de un mes
  /// que pasó vacío: el estado del mes en curso se deriva y se reinicia solo.
  final List<String> missedMonths;

  /// Todos los meses con algún registro, como "2026-03".
  ///
  /// Es lo que permite mirar el estado de *cualquier* mes y no solo el de hoy:
  /// un pago se anota tarde, y "pagado" es una pregunta con fecha.
  final List<String> paidMonths;

  /// Lo registrado en cada mes, con su monto.
  ///
  /// [amount] es la expectativa del flujo; esto es lo que de verdad pasó cada
  /// mes. Difieren más de lo que uno cree —la luz nunca es la misma— y
  /// confundirlos hacía que cambiar el monto del flujo reescribiera el pasado a
  /// la vista: ponías 0 en agosto y julio también mostraba 0.
  final List<FlowMonthRecord> monthlyRecords;

  /// La ficha de cada mes: cuánto es y hasta cuándo.
  ///
  /// Cada mes es un registro propio, con su monto y su caducidad, y editar uno
  /// no toca a los demás. Nacen solos: al llegar septiembre se crea su ficha
  /// con el monto de agosto y su caducidad a fin de mes.
  ///
  /// Vale igual para gastos fijos y para ingresos: ni la luz es la misma todos
  /// los meses ni el sueldo es el mismo todo el año. [amount] queda como la
  /// semilla del primero.
  final Map<String, FlowMonth> months;

  /// Si sigue vivo. Un archivado se muestra por su historia y no se puede
  /// marcar.
  final bool isActive;

  /// Si ese mes está marcado como pagado o cobrado.
  ///
  /// Cualquiera de las dos cosas basta: la marca en la ficha del mes —que es
  /// donde vive para que sea de ese mes y de ningún otro, julio puede estar
  /// pagado con agosto pendiente— o el movimiento registrado.
  ///
  /// **Las dos, y no solo la ficha.** Los meses que se marcaron antes de que la
  /// ficha tuviera `paidAt` tienen su movimiento pero la marca en null, y leer
  /// solo la ficha los daba por pendientes: la fila ofrecía marcarlos otra vez
  /// y el backend contestaba que ese mes ya estaba registrado.
  bool pagadoEn(String mes) => months[mes]?.pagado == true || paidMonths.contains(mes);

  /// El registro de ese mes, si lo hay.
  FlowMonthRecord? registroDe(String mes) {
    for (final r in monthlyRecords) {
      if (r.month == mes) return r;
    }
    return null;
  }

  /// La ficha de un mes, si existe.
  FlowMonth? mesDe(String mes) => months[mes];

  /// El monto de un mes es el de su ficha. Y punto.
  ///
  /// Antes esto heredaba del mes anterior al mostrar, y ahí estaba el bug que
  /// se veía en pantalla: editabas julio y agosto —que aún no tenía ficha—
  /// pasaba a mostrar lo mismo, porque lo heredaba en vivo. Un cambio en un mes
  /// se propagaba hacia adelante a todos los que no tuvieran ficha propia.
  ///
  /// La herencia sigue existiendo, pero donde corresponde: **al crear** la
  /// ficha de un mes nuevo, que nace copiando al anterior y desde ahí vive su
  /// vida. Una vez creada, nadie la mueve por detrás.
  ///
  /// El respaldo a [amount] es solo para meses anteriores a que el flujo
  /// existiera, que no tienen ficha ni la van a tener.
  double montoDe(String mes) => months[mes]?.amount ?? amount;

  /// Hasta cuándo hay tiempo de pagar ese mes. Por defecto, su último día.
  DateTime caducidadDe(String mes) {
    final propio = months[mes];
    if (propio != null) return propio.dueDate;
    final partes = mes.split('-');
    return DateTime(int.parse(partes[0]), int.parse(partes[1]) + 1, 0);
  }

  final String? categoryName;
  final String? accountId;

  bool get isExpense => type == 'EXPENSE';
}

/// Un tipo de deuda: además de cómo se llama y se ve, trae qué campos tiene
/// sentido pedir. El formulario ya no mantiene su propia lista de tipos.
class DebtKind {
  const DebtKind({
    required this.code,
    required this.label,
    required this.hint,
    required this.icon,
    required this.principalLabel,
    required this.counterpartyLabel,
    required this.hasRates,
    required this.hasTerm,
    required this.hasDueDay,
  });

  factory DebtKind.fromJson(Map<String, dynamic> j) => DebtKind(
    code: (j['code'] as String?) ?? '',
    label: (j['label'] as String?) ?? '',
    hint: (j['hint'] as String?) ?? '',
    icon: (j['icon'] as String?) ?? '💳',
    principalLabel: (j['principalLabel'] as String?) ?? 'Monto',
    counterpartyLabel: (j['counterpartyLabel'] as String?) ?? 'Con quién',
    hasRates: (j['hasRates'] as bool?) ?? true,
    hasTerm: (j['hasTerm'] as bool?) ?? true,
    hasDueDay: (j['hasDueDay'] as bool?) ?? true,
  );

  final String code;
  final String label;
  final String hint;
  final String icon;
  final String principalLabel;
  final String counterpartyLabel;
  final bool hasRates;
  final bool hasTerm;
  final bool hasDueDay;
}

/// Una deuda, con lo que de verdad decide qué hacer con ella.
/// La deuda mes a mes, una serie por moneda: sumar una cuota en dólares con
/// otra en soles daría un número que no es plata de nada.
class DebtHistorySeries {
  const DebtHistorySeries({required this.currency, required this.months});

  factory DebtHistorySeries.fromJson(Map<String, dynamic> j) => DebtHistorySeries(
    currency: (j['currency'] as String?) ?? 'PEN',
    months: ((j['months'] as List?) ?? [])
        .map((e) => DebtMonth.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  final String currency;
  final List<DebtMonth> months;
}

/// Un mes: lo pagado y en qué se repartió, más el saldo con el que cerró.
class DebtMonth {
  const DebtMonth({
    required this.month,
    required this.paid,
    required this.principal,
    required this.interest,
    required this.other,
    required this.balance,
  });

  factory DebtMonth.fromJson(Map<String, dynamic> j) => DebtMonth(
    month: (j['month'] as String?) ?? '',
    paid: _num(j['paid']),
    principal: _num(j['principal']),
    interest: _num(j['interest']),
    other: _num(j['other']),
    balance: _num(j['balance']),
  );

  final String month;
  final double paid;
  final double principal;
  final double interest;
  final double other;
  final double balance;
}

/// Cuánto falta de una deuda, tal como lo manda el API.
class DebtProjectionView {
  const DebtProjectionView({
    required this.monthsLeft,
    required this.interestLeft,
    required this.totalLeft,
    required this.principalShare,
    required this.modeledInstallment,
    required this.installmentGap,
  });

  factory DebtProjectionView.fromJson(Map<String, dynamic> j) => DebtProjectionView(
    monthsLeft: (j['monthsLeft'] as num?)?.toInt(),
    interestLeft: _num(j['interestLeft']),
    totalLeft: _num(j['totalLeft']),
    principalShare: (j['principalShare'] as num?)?.toInt() ?? 0,
    modeledInstallment: (j['modeledInstallment'] as num?)?.toDouble(),
    installmentGap: _num(j['installmentGap']),
  );

  /// `null` = a este ritmo no se termina: la cuota no cubre el interés del mes.
  final int? monthsLeft;
  final double interestLeft;
  final double totalLeft;

  /// De cada 100 que pagues, cuántos bajan lo que debes.
  final int principalShare;
  final double? modeledInstallment;

  /// Cuánto más grande es tu cuota que la que sale de la tasa. Casi siempre es
  /// desgravamen y portes, y hoy se acredita a capital.
  final double installmentGap;
}

class Debt {
  const Debt({
    required this.id,
    required this.accountId,
    required this.name,
    required this.institution,
    required this.currency,
    required this.balance,
    required this.originalPrincipal,
    required this.interestRateAnnual,
    required this.costRateAnnual,
    required this.minimumPayment,
    this.monthlyInsurance,
    required this.termMonths,
    required this.statusThisMonth,
    required this.missedMonths,
    required this.debtTypeCode,
    this.isActive = true,
    this.debtKind,
    this.originationDate,
    this.dueDay,
    this.dueDate,
    this.paidAmountThisMonth = 0,
    this.pendingThisMonth = 0,
    this.installmentInterest = 0,
    this.interestPendingThisMonth = 0,
    this.scheduledInstallment = 0,
    this.installmentAmount = 0,
    this.projection,
  });

  factory Debt.fromJson(Map<String, dynamic> j) {
    final cuenta = (j['account'] as Map<String, dynamic>?) ?? const {};
    return Debt(
      id: j['id'] as String,
      accountId: (j['accountId'] as String?) ?? '',
      name: (cuenta['name'] as String?) ?? 'Deuda',
      institution: cuenta['institution'] as String?,
      currency: (cuenta['currency'] as String?) ?? 'PEN',
      balance: _num(j['currentBalance']),
      originalPrincipal: _num(j['originalPrincipal']),
      interestRateAnnual: _num(j['interestRateAnnual']),
      costRateAnnual: _numOrNull(j['costRateAnnual']),
      minimumPayment: _num(j['minimumPayment']),
      monthlyInsurance: _numOrNull(j['monthlyInsurance']),
      termMonths: (j['termMonths'] as num?)?.toInt(),
      statusThisMonth: (j['statusThisMonth'] as String?) ?? 'PENDING',
      missedMonths: ((j['missedMonths'] as List?) ?? []).cast<String>(),
      debtTypeCode: (j['debtTypeCode'] as String?) ?? '',
      isActive: (j['isActive'] as bool?) ?? true,
      debtKind: j['debtKind'] == null
          ? null
          : DebtKind.fromJson(j['debtKind'] as Map<String, dynamic>),
      originationDate: j['originationDate'] == null
          ? null
          : DateTime.parse(j['originationDate'] as String),
      dueDay: (j['dueDay'] as num?)?.toInt(),
      dueDate: j['dueDate'] == null ? null : DateTime.parse(j['dueDate'] as String),
      paidAmountThisMonth: _num(j['paidThisMonth']),
      pendingThisMonth: _num(j['pendingThisMonth']),
      installmentInterest: _num(j['installmentInterest']),
      interestPendingThisMonth: _num(j['interestPendingThisMonth']),
      scheduledInstallment: _num(j['scheduledInstallment']),
      installmentAmount: _num(j['installmentAmount']),
      projection: j['projection'] == null
          ? null
          : DebtProjectionView.fromJson((j['projection'] as Map).cast<String, dynamic>()),
    );
  }

  final String id;
  final String accountId;
  final String name;
  final String? institution;
  final String currency;
  final double balance;
  final double originalPrincipal;

  /// TEA: solo interés.
  final double interestRateAnnual;

  /// TCEA: el costo real, con seguros y portes. `null` cuando no aplica — un
  /// préstamo entre personas no tiene.
  final double? costRateAnnual;
  final double minimumPayment;

  /// Cuánto de la cuota es seguro de desgravamen.
  ///
  /// Es una condición del crédito —"la cuota de C incluye S/25 de seguro"— y
  /// sale de la cuota **antes** que el capital: sin él, la app acredita ese
  /// dinero a bajar la deuda y su saldo se separa del que lleva el banco.
  final double? monthlyInsurance;
  final int? termMonths;

  /// PAID, PARTIAL (se abonó algo pero no toda la cuota) o PENDING.
  final String statusThisMonth;
  final List<String> missedMonths;

  final String debtTypeCode;

  /// Si sigue contando. Una deuda cancelada viaja igual en la lista —es lo
  /// único que queda de ella— pero está fuera de todo cálculo.
  final bool isActive;
  final DebtKind? debtKind;
  final DateTime? originationDate;

  /// Día del mes en que vence, para deudas a cuotas.
  final int? dueDay;

  /// Fecha única de devolución, para deudas que no se pagan a cuotas.
  final DateTime? dueDate;

  /// Cuánto ya se pagó / falta pagar este mes, y de eso cuánto es interés.
  final double paidAmountThisMonth;
  final double pendingThisMonth;
  final double installmentInterest;
  final double interestPendingThisMonth;

  /// La cuota que sale del cronograma, para comparar con la declarada.
  final double scheduledInstallment;

  /// La cuota que toca: la del cronograma, o el pago mínimo cuando no hay
  /// cronograma (tarjeta).
  final double installmentAmount;

  /// Cuánto falta hasta terminarla, simulado desde el saldo de hoy.
  final DebtProjectionView? projection;

  /// La tasa que de verdad cuesta la deuda. La TCEA cuando existe, porque ya
  /// incluye lo que la TEA deja fuera; priorizar por la TEA hace que una deuda
  /// cara con muchos seguros parezca barata.
  double get tasaReal => costRateAnnual ?? interestRateAnnual;

  bool get pagadaEsteMes => statusThisMonth == 'PAID';
  bool get pagoParcial => statusThisMonth == 'PARTIAL';
  bool get saldada => balance <= 0;

  /// Cuánto se ha amortizado, de 0 a 1.
  double get avance =>
      originalPrincipal <= 0 ? 0 : ((originalPrincipal - balance) / originalPrincipal).clamp(0, 1);
}

/// Una cuenta, para elegir de dónde sale o entra el dinero.
class Account {
  const Account({
    required this.id,
    required this.name,
    this.type = 'CASH',
    required this.currency,
    required this.balance,
    this.creditLimit,
    required this.isHidden,
  });

  factory Account.fromJson(Map<String, dynamic> j) => Account(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '',
    type: (j['type'] as String?) ?? 'CASH',
    currency: (j['currency'] as String?) ?? 'PEN',
    balance: _num(j['currentBalance']),
    creditLimit: _numOrNull(j['creditLimit']),
    isHidden: (j['isHidden'] as bool?) ?? false,
  );

  final String id;
  final String name;

  /// CASH, CHECKING, SAVINGS, INVESTMENT o CREDIT_CARD. Decide si su saldo es lo
  /// que tienes o **lo que debes**, y si suma al patrimonio.
  final String type;
  final String currency;
  final double balance;

  /// El cupo de una tarjeta. `null` en el resto y en una tarjeta sin cupo.
  final double? creditLimit;
  final bool isHidden;

  /// Su saldo es deuda, no dinero: nunca entra en el patrimonio, y en un
  /// selector hay que decirlo.
  bool get esDeCredito => tiposDeCredito.contains(type);
}

/// Una moneda que el backend conoce, para los selectores.
class Currency {
  const Currency({
    required this.code,
    required this.name,
    required this.symbol,
    required this.decimals,
  });

  factory Currency.fromJson(Map<String, dynamic> j) => Currency(
    code: (j['code'] as String?) ?? '',
    name: (j['name'] as String?) ?? '',
    symbol: (j['symbol'] as String?) ?? '',
    decimals: (j['decimals'] as num?)?.toInt() ?? 2,
  );

  final String code;
  final String name;
  final String symbol;
  final int decimals;
}

/// Una cotización. Compra y venta se guardan por separado: una deuda en
/// dólares se paga comprando dólares (venta) y un ahorro se valoriza
/// vendiéndolos (compra).
class ExchangeRate {
  const ExchangeRate({
    required this.baseCode,
    required this.quoteCode,
    required this.date,
    required this.buy,
    required this.sell,
    this.source,
  });

  factory ExchangeRate.fromJson(Map<String, dynamic> j) => ExchangeRate(
    baseCode: (j['baseCode'] as String?) ?? '',
    quoteCode: (j['quoteCode'] as String?) ?? '',
    date: (j['date'] as String?) ?? '',
    buy: _num(j['buy']),
    sell: _num(j['sell']),
    source: j['source'] as String?,
  );

  final String baseCode;
  final String quoteCode;
  final String date;
  final double buy;
  final double sell;

  /// De dónde salió. `'manual'` es la que puso el usuario desde la app, y es la
  /// única que se puede quitar: una que vino cargada es el registro de lo que
  /// costaba ese día.
  final String? source;
}

/// Qué se lleva de por medio borrar una cuenta, para preguntar antes de
/// hacerlo y no después.
class AccountDeletionImpact {
  const AccountDeletionImpact({
    required this.name,
    required this.balance,
    required this.movements,
    required this.recurringFlows,
    required this.blockedBy,
    required this.debtPayments,
  });

  factory AccountDeletionImpact.fromJson(Map<String, dynamic> j) => AccountDeletionImpact(
    name: (j['name'] as String?) ?? '',
    balance: _num(j['balance']),
    movements: (j['movements'] as num?)?.toInt() ?? 0,
    recurringFlows: (j['recurringFlows'] as num?)?.toInt() ?? 0,
    blockedBy: j['blockedBy'] as String?,
    debtPayments: (j['debtPayments'] as num?)?.toInt() ?? 0,
  );

  final String name;
  final double balance;
  final int movements;
  final int recurringFlows;

  /// 'DEBT_ACCOUNT' | 'DEBT_PAYMENTS' | null — cuándo el backend directamente
  /// rechaza el borrado.
  final String? blockedBy;
  final int debtPayments;

  bool get bloqueada => blockedBy != null;
}

/// Cómo se nombra una cuenta en un selector.
///
/// Una cuenta oculta no entra en el patrimonio: registrar ahí le sube el saldo y
/// deja el patrimonio igual. No es un error —la ocultaste tú— pero sin decirlo
/// se lee como que la app perdió la plata.
///
/// Se listan igual, no se esconden: a veces el dinero entra ahí de verdad, y un
/// selector que no ofrece una de tus cuentas es un callejón sin salida. Lo que
/// se arregla es la sorpresa, no la opción.
extension EtiquetaDeCuenta on Account {
  /// El aviso para el subtítulo de una opción, o `null` si no hace falta.
  ///
  /// Dos razones distintas para no contar, y conviene distinguirlas: una cuenta
  /// oculta la sacaste tú y se devuelve con un toque; una tarjeta de crédito
  /// nunca cuenta, porque su saldo es deuda y no dinero.
  String? get avisoDePatrimonio => esDeCredito
      ? 'Crédito · lo que gastes acá lo debes, no sale de tu patrimonio'
      : isHidden
      ? 'Oculta · no cuenta en tu patrimonio'
      : null;

  /// El nombre para un campo ya elegido, con el aviso pegado si hace falta.
  String get nombreConAviso => esDeCredito
      ? '$name · crédito'
      : isHidden
      ? '$name · no cuenta en tu patrimonio'
      : name;
}

/// De qué color es cada tipo de cuenta, y con qué ícono se dibuja.
///
/// Salen de la **misma paleta que los gráficos**, no de colores inventados para
/// la lista: así "azul" significa lo mismo en toda la app y la fila de cuentas
/// conversa con el anillo y con las curvas en vez de competir.
///
/// El color es un refuerzo, nunca la información: al lado va el ícono y el
/// nombre completo. Nadie tiene que aprenderse que el naranja es la tarjeta.
Color colorDeCuenta(String type, AppColors colors) => switch (type) {
  // La del día a día, el azul del gasto corriente.
  'CHECKING' => colors.chartAt(0),
  // Guardar: el verde azulado, cerca del azul de la corriente pero distinto.
  'SAVINGS' => colors.chartAt(2),
  'CASH' => colors.chartAt(5),
  'INVESTMENT' => colors.chartAt(6),
  // Naranja y no rojo: el rojo ya significa "gasto" y "peor día" en los
  // gráficos, y una tarjeta no es una alarma — es otra naturaleza de cuenta.
  'CREDIT_CARD' || 'LOAN' => colors.chartAt(1),
  _ => colors.chartOther,
};

String iconoDeCuenta(String type) => switch (type) {
  'CHECKING' => '🏦',
  'SAVINGS' => '🐷',
  'CASH' => '💵',
  'INVESTMENT' => '📈',
  'CREDIT_CARD' => '💳',
  'LOAN' => '📄',
  _ => '💼',
};

/// En qué grupo cae cada cuenta, y cómo se llama ese grupo.
///
/// Por naturaleza y no por tipo exacto: "corriente" y "ahorros" son las dos
/// cosas que tienes en el banco, y separarlas en dos bloques de una fila cada
/// uno es partir la lista sin decir nada. Lo que sí hay que separar es lo que
/// **tienes** de lo que **debes** — justo lo que se volvió confuso al entrar las
/// tarjetas.
enum GrupoDeCuenta { banco, efectivo, inversion, credito }

/// El orden: primero donde está el grueso del dinero, al final lo que se debe.
const gruposDeCuenta = [
  (GrupoDeCuenta.banco, 'En el banco'),
  (GrupoDeCuenta.efectivo, 'Efectivo'),
  (GrupoDeCuenta.inversion, 'Inversión'),
  (GrupoDeCuenta.credito, 'Crédito'),
];

GrupoDeCuenta grupoDeCuenta(String type) => switch (type) {
  'CHECKING' || 'SAVINGS' => GrupoDeCuenta.banco,
  'CASH' => GrupoDeCuenta.efectivo,
  'INVESTMENT' => GrupoDeCuenta.inversion,
  _ => GrupoDeCuenta.credito,
};
