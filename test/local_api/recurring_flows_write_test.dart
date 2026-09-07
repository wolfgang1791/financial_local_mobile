import 'dart:io';

import 'package:financial_strategist_local/data/api.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_support.dart';

void main() {
  late Directory tmp;
  late ApiClient api;

  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(inicializarMotorDePrueba);

  setUp(() async {
    tmp = await prepararDirectorioTemporal('financial_strategist_local_flow_write_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  test('pagar un flujo crea el movimiento, sube el saldo y marca "pagado este mes"', () async {
    final flujos = await api.get('/recurring-flows') as List;
    final sueldo = flujos.firstWhere((f) => f['name'] == 'Sueldo');
    expect(sueldo['statusThisMonth'], 'PENDING');

    final cuentas = await api.get('/accounts') as List;
    final antes =
        (cuentas.firstWhere((c) => c['id'] == sueldo['accountId'])['currentBalance'] as num)
            .toDouble();

    final resultado = await api.post('/recurring-flows/${sueldo['id']}/pay', const {}) as Map;
    expect(resultado['transactionId'], isNotNull);

    final cuentasDespues = await api.get('/accounts') as List;
    final despues =
        (cuentasDespues.firstWhere((c) => c['id'] == sueldo['accountId'])['currentBalance'] as num)
            .toDouble();
    expect(despues, closeTo(antes + (sueldo['amount'] as num).toDouble(), 0.001));

    final flujosDespues = await api.get('/recurring-flows') as List;
    final sueldoDespues = flujosDespues.firstWhere((f) => f['id'] == sueldo['id']);
    expect(sueldoDespues['statusThisMonth'], 'PAID');

    // Revertir deshace las dos cosas: el saldo vuelve y el estado vuelve a
    // pendiente.
    await api.post('/recurring-flows/${sueldo['id']}/revert-payment', const {});
    final cuentasRevertido = await api.get('/accounts') as List;
    expect(
      (cuentasRevertido.firstWhere((c) => c['id'] == sueldo['accountId'])['currentBalance'] as num)
          .toDouble(),
      closeTo(antes, 0.001),
    );
    final flujosRevertido = await api.get('/recurring-flows') as List;
    expect(
      flujosRevertido.firstWhere((f) => f['id'] == sueldo['id'])['statusThisMonth'],
      'PENDING',
    );
  });

  test('crear, editar y borrar un flujo sin pagos se borra de verdad', () async {
    final cuentas = await api.get('/accounts') as List;
    final creado =
        await api.post('/recurring-flows', {
              'accountId': cuentas.first['id'],
              'type': 'EXPENSE',
              'name': 'Gimnasio',
              'amount': 120,
              'frequency': 'MONTHLY',
              'startDate': '2026-01-01',
              'nextDueDate': '2026-08-05',
            })
            as Map;
    expect(creado['name'], 'Gimnasio');

    await api.patch('/recurring-flows/${creado['id']}', {'amount': 135});
    final flujos = await api.get('/recurring-flows') as List;
    expect((flujos.firstWhere((f) => f['id'] == creado['id'])['amount'] as num).toDouble(), 135);

    final borrado = await api.delete('/recurring-flows/${creado['id']}') as Map;
    expect(borrado['archived'], false);
    final flujosFinal = await api.get('/recurring-flows') as List;
    expect(flujosFinal.any((f) => f['id'] == creado['id']), false);
  });

  test('crear un ingreso recurrente con lo que manda el formulario', () async {
    // El formulario del móvil no mandaba `startDate` y la ruta lo casteaba a
    // String: el error salía como "No llegué al servidor", que manda a buscar el
    // problema en la red cuando estaba en el cuerpo.
    final cuentas = await api.get('/accounts') as List;
    final creado =
        await api.post('/recurring-flows', {
              'name': 'Clases de guitarra',
              'type': 'INCOME',
              'amount': 120,
              'frequency': 'MONTHLY',
              'startDate': '2026-08-21',
              'nextDueDate': '2026-08-28',
              'accountId': (cuentas.first as Map)['id'],
            })
            as Map<String, dynamic>;

    expect(creado['name'], 'Clases de guitarra');
    expect(creado['type'], 'INCOME');
    expect(
      (await api.get('/recurring-flows') as List).any((f) => (f as Map)['id'] == creado['id']),
      isTrue,
    );
  });

  test('sin startDate lo dice, en vez de parecer un problema de red', () async {
    final cuentas = await api.get('/accounts') as List;
    await expectLater(
      api.post('/recurring-flows', {
        'name': 'Sin fecha',
        'type': 'EXPENSE',
        'amount': 10,
        'frequency': 'MONTHLY',
        'nextDueDate': '2026-08-28',
        'accountId': (cuentas.first as Map)['id'],
      }),
      throwsA(isA<ApiException>()),
    );
  });
  test('borrar un flujo con pagos lo archiva: la plata de los meses anteriores se queda', () async {
    // Borrar un flujo no puede borrar plata. Los meses que ya se marcaron
    // movieron el saldo de verdad, y sus asientos son lo que explica el
    // patrimonio de hoy: si se fueran con el flujo, la curva quedaría con un
    // agujero sin causa visible.
    final lista = (await api.get('/recurring-flows') as List).cast<Map<String, dynamic>>();
    final conPagos = lista.firstWhere((f) => (f['paidMonths'] as List).isNotEmpty);
    final id = conPagos['id'] as String;

    final antesDelPatrimonio =
        ((await api.get('/financial-engine/cash-position') as Map)['total'] as num).toDouble();
    final asientosAntes = ((await api.get('/transactions?take=500') as Map)['items'] as List)
        .where((t) => (t as Map)['recurringFlowId'] == id)
        .length;
    expect(asientosAntes, greaterThan(0));

    final r = await api.delete('/recurring-flows/$id') as Map;
    // Archivado, no borrado: es la diferencia entre "esto ya no aplica de aquí
    // en adelante" y "esto nunca pasó".
    expect(r['archived'], true);

    // Sigue en la lista, marcado como archivado: sus meses anteriores tienen
    // que poder verse. Sacarlo del todo hacía que julio dejara de mostrar el
    // sueldo que sí se cobró en julio.
    final despues = (await api.get('/recurring-flows') as List).cast<Map<String, dynamic>>();
    final archivado = despues.firstWhere((f) => f['id'] == id);
    expect(archivado['isActive'], false);
    expect(archivado['paidMonths'], isNotEmpty);

    // ...pero sus movimientos y el patrimonio no se mueven.
    final asientosDespues = ((await api.get('/transactions?take=500') as Map)['items'] as List)
        .where((t) => (t as Map)['recurringFlowId'] == id)
        .length;
    expect(asientosDespues, asientosAntes);
    expect(
      ((await api.get('/financial-engine/cash-position') as Map)['total'] as num).toDouble(),
      closeTo(antesDelPatrimonio, 0.01),
    );
  });

  test('los meses anteriores siguen contando como gasto fijo', () async {
    // El historial reparte por `origen`, y "fijos" son los que llevan
    // `recurringFlowId`. Ese id sobrevive al archivado —la fila del flujo sigue
    // ahí— así que julio se sigue leyendo igual después de borrar. Si el flujo
    // se hubiera borrado de verdad, el id quedaría en null y esos pagos se
    // mudarían solos al cajón de "gastos de la vida".
    final lista = (await api.get('/recurring-flows') as List).cast<Map<String, dynamic>>();
    final conPagos = lista.firstWhere(
      (f) => (f['paidMonths'] as List).isNotEmpty && f['type'] == 'EXPENSE',
    );

    Future<double> fijosDeSiempre() async =>
        (((await api.get('/transactions?take=500&origen=fijos') as Map)['totals'] as Map)['expense']
                as num)
            .toDouble();

    final antes = await fijosDeSiempre();
    await api.delete('/recurring-flows/${conPagos['id']}');
    expect(await fijosDeSiempre(), closeTo(antes, 0.01));
  });
}
