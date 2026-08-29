import 'package:sqflite/sqflite.dart';

/// Puerto directo de `backend/src/common/ledger.util.ts` +
/// `TransactionsService.balancesBefore`.
///
/// Qué cuenta como patrimonio: líquida, no archivada, no oculta. Es el
/// mismo criterio en todos lados a propósito — ocultar una cuenta tiene que
/// mover el mismo número en todo cálculo de dinero, y si cada consulta arma
/// su propio filtro tarde o temprano una queda afuera.
const liquidAccountTypes = ['CHECKING', 'SAVINGS', 'CASH'];

/// El mismo `COUNTED_ACCOUNT_WHERE`, como fragmento SQL. [alias] es el alias
/// de tabla en la consulta que lo use (`a` en un JOIN, o vacío para
/// `Account` sin alias).
String countedAccountWhereSql([String alias = '']) {
  final prefijo = alias.isEmpty ? '' : '$alias.';
  return "${prefijo}isArchived = 0 AND ${prefijo}isHidden = 0 "
      "AND ${prefijo}type IN ('CHECKING','SAVINGS','CASH')";
}

double round2(double n) => (n * 100).round() / 100;

/// La dirección en la que un asiento mueve el saldo de su cuenta. Vale para
/// todo `LedgerEntryKind` — un ajuste hacia arriba es un INCOME, hacia abajo
/// un EXPENSE — así la aritmética no distingue tipos de asiento.
double signedAmount(String type, double amount) => type == 'INCOME' ? amount : -amount;

/// El saldo que había antes de cada movimiento, por id — reconstruido
/// caminando el ledger de más nuevo a más viejo desde el saldo de hoy.
///
/// Por qué así y no calculado por fila: el saldo previo de un movimiento
/// depende de *todos* los movimientos más nuevos que él, no solo de los que
/// están en la misma página. Caminar el ledger entero una vez es la única
/// forma de que no mienta.
Future<Map<String, double>> balancesBefore(Database db, String userId) async {
  final cuentas = await db.rawQuery(
    'SELECT currentBalance FROM Account WHERE userId = ? AND ${countedAccountWhereSql()}',
    [userId],
  );
  double actual = round2(
    cuentas.fold<double>(0, (acc, fila) => acc + (fila['currentBalance'] as num).toDouble()),
  );

  final entradas = await db.rawQuery(
    '''
    SELECT t.id AS id, t.type AS type, t.amount AS amount
    FROM "Transaction" t
    JOIN Account a ON a.id = t.accountId
    WHERE a.userId = ? AND ${countedAccountWhereSql('a')}
    ORDER BY t.occurredAt DESC, t.createdAt DESC
    ''',
    [userId],
  );

  final antes = <String, double>{};
  for (final entrada in entradas) {
    actual = round2(
      actual - signedAmount(entrada['type'] as String, (entrada['amount'] as num).toDouble()),
    );
    antes[entrada['id'] as String] = actual;
  }
  return antes;
}
