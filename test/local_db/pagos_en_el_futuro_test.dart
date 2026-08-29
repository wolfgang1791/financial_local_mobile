// Los pagos que quedaron fechados en el futuro vuelven al día en que se
// marcaron.
//
// El caso: marcar un gasto fijo fechaba su movimiento en el vencimiento de ese
// mes. Con Claude y Movistar venciendo el 31, marcarlos el 24 dejaba el asiento
// en el futuro — el saldo ya lo había descontado, pero el movimiento no salía
// ni en el calendario del día ni en la lista del mes.

import 'dart:io';

import 'package:financial_strategist_local/data/api.dart';
import 'package:financial_strategist_local/local_db/database.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_support.dart';

void main() {
  late Directory tmp;

  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(inicializarMotorDePrueba);

  setUp(() async {
    tmp = await prepararDirectorioTemporal('pagos_futuro_test');
  });

  tearDown(() => tmp.delete(recursive: true));

  test('un pago por delante del reloj se re-fecha al día en que se marcó', () async {
    final api = ApiClient();
    final cuentas = await api.get('/accounts') as List;
    final flujo =
        await api.post('/recurring-flows', {
              'name': 'Con vencimiento lejano',
              'type': 'EXPENSE',
              'amount': 20,
              'frequency': 'MONTHLY',
              'startDate': '2026-08-01',
              'nextDueDate': '2026-08-28',
              'accountId': (cuentas.first as Map)['id'],
            })
            as Map<String, dynamic>;

    final db = await LocalDatabase.open();
    final enUnAnio = DateTime.now().toUtc().add(const Duration(days: 365));
    final marcadoAyer = DateTime.now().toUtc().subtract(const Duration(days: 1));

    // Como lo dejaba el código viejo: el asiento en el futuro y la ficha
    // marcada con esa misma fecha.
    await db.insert('"Transaction"', {
      'id': 'tx-futuro',
      'accountId': (cuentas.first as Map)['id'],
      'recurringFlowId': flujo['id'],
      'type': 'EXPENSE',
      'kind': 'MOVEMENT',
      'amount': 20,
      'description': 'Pago de Con vencimiento lejano',
      'occurredAt': enUnAnio.millisecondsSinceEpoch,
      'createdAt': marcadoAyer.millisecondsSinceEpoch,
    });
    await db.insert('RecurringFlowMonth', {
      'id': 'mes-futuro',
      'recurringFlowId': flujo['id'],
      'month': '2026-12',
      'amount': 20,
      'dueDate': enUnAnio.millisecondsSinceEpoch,
      'paidAt': enUnAnio.millisecondsSinceEpoch,
    });

    // Abrir de nuevo es lo que corre la puesta al día.
    await LocalDatabase.resetForTests();
    final db2 = await LocalDatabase.open();

    final tx = (await db2.query('"Transaction"', where: 'id = ?', whereArgs: ['tx-futuro'])).first;
    expect(tx['occurredAt'], marcadoAyer.millisecondsSinceEpoch);

    final ficha = (await db2.query(
      'RecurringFlowMonth',
      where: 'id = ?',
      whereArgs: ['mes-futuro'],
    )).first;
    // La marca sigue apuntando a su movimiento: es el enlace que usa revertir
    // para encontrarlo.
    expect(ficha['paidAt'], marcadoAyer.millisecondsSinceEpoch);
  });
}
