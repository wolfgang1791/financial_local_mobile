// Cancelar una deuda: que deje de contar sin desaparecer.
//
// Es la diferencia con borrar, y es toda la función: si la cancelada siguiera
// entrando en los cálculos no serviría de nada, y si se fuera de la lista sería
// un borrado con otro nombre.

import 'dart:io';

import 'package:financial_strategist_local/data/api.dart';
import 'package:financial_strategist_local/local_db/database.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_support.dart';

void main() {
  late Directory tmp;
  late ApiClient api;

  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(inicializarMotorDePrueba);

  setUp(() async {
    tmp = await prepararDirectorioTemporal('debts_cancel_test');
    api = ApiClient();
  });

  tearDown(() async {
    await LocalDatabase.resetForTests();
    await tmp.delete(recursive: true);
  });

  Future<Map> deudaPorId(String id) async {
    final lista = await api.get('/debts') as List;
    return lista.firstWhere((d) => d['id'] == id) as Map;
  }

  /// Si la cuenta espejo quedó archivada. Se lee de la base y no de `/accounts`
  /// porque esa ruta nunca devuelve cuentas de deuda, archivadas o no.
  Future<bool> cuentaArchivada(String accountId) async {
    final db = await LocalDatabase.open();
    final fila = (await db.query(
      'Account',
      columns: ['isArchived'],
      where: 'id = ?',
      whereArgs: [accountId],
    )).first;
    return (fila['isArchived'] as int) == 1;
  }

  test('cancelar la apaga y archiva su cuenta, sin sacarla de la lista', () async {
    final lista = await api.get('/debts') as List;
    final id = lista.first['id'] as String;
    final cuentaId = lista.first['accountId'] as String;
    expect(lista.first['isActive'], true, reason: 'arranca contando');

    await api.post('/debts/$id/cancel', const {});

    // Sigue estando, marcada: es lo que permite mostrarla como histórico.
    expect((await deudaPorId(id))['isActive'], false);
    // Y su cuenta espejo se archiva, igual que al borrar: una deuda que no
    // cuenta no puede dejar una cuenta suelta por ahí.
    expect(await cuentaArchivada(cuentaId), isTrue);
  });

  test('reactivar la devuelve tal como estaba', () async {
    final lista = await api.get('/debts') as List;
    final id = lista.first['id'] as String;
    final cuentaId = lista.first['accountId'] as String;
    final saldoAntes = (lista.first['currentBalance'] as num).toDouble();

    await api.post('/debts/$id/cancel', const {});
    await api.post('/debts/$id/reactivate', const {});

    final vuelta = await deudaPorId(id);
    expect(vuelta['isActive'], true);
    expect((vuelta['currentBalance'] as num).toDouble(), saldoAntes);
    expect(await cuentaArchivada(cuentaId), isFalse, reason: 'la cuenta vuelve con ella');
  });

  test('una cancelada no reclama meses sin pagar', () async {
    // Se fabrica el caso en vez de buscarlo: una deuda con desembolso viejo y
    // sin un solo pago acumula un mes reclamado por cada mes transcurrido.
    final creada =
        await api.post('/debts', {
              'debtTypeCode': 'PERSONAL_LOAN',
              'name': 'Préstamo viejo',
              'currency': 'PEN',
              'originalPrincipal': 5000,
              'currentBalance': 5000,
              'interestRateAnnual': 0.2,
              'minimumPayment': 300,
              'originationDate': '2026-01-15',
              'dueDay': 15,
            })
            as Map;
    final id = creada['id'] as String;
    expect(
      (await deudaPorId(id))['missedMonths'],
      isNotEmpty,
      reason: 'sin pagos desde enero, algo debe reclamar',
    );

    await api.post('/debts/$id/cancel', const {});
    expect((await deudaPorId(id))['missedMonths'], isEmpty);
  });
}
