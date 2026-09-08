// Marcar un mes concreto como pagado o recibido.
//
// Un pago se anota tarde: pagaste el alquiler de marzo y te acordaste en
// agosto. Antes solo se podía marcar "este mes", así que marzo quedaba
// reclamado para siempre y agosto pagado dos veces.

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
    tmp = await prepararDirectorioTemporal('flows_month_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<Map<String, dynamic>> flujoPorId(String id) async {
    final lista = await api.get('/recurring-flows') as List;
    return lista.cast<Map<String, dynamic>>().firstWhere((f) => f['id'] == id);
  }

  /// Un flujo sin ningún mes registrado, con cuenta.
  ///
  /// Si la semilla no tiene ninguno se crea uno. La semilla son datos reales del
  /// usuario, y ahí todos los flujos terminan teniendo meses marcados: depender
  /// de que quedara uno virgen hacía que el archivo entero dejara de correr al
  /// traer datos nuevos, sin que nada del código hubiera cambiado.
  Future<Map<String, dynamic>> unFlujoSinPagos({bool? gasto}) async {
    final lista = await api.get('/recurring-flows') as List;
    final yaHay = lista.cast<Map<String, dynamic>>().where(
      (f) =>
          (f['paidMonths'] as List).isEmpty &&
          f['accountId'] != null &&
          (gasto == null || (f['type'] == 'EXPENSE') == gasto),
    );
    if (yaHay.isNotEmpty) return yaHay.first;

    // Nunca sobre una tarjeta: ahí el saldo es lo que debes y estos tests miran
    // el patrimonio.
    final cuenta = (await api.get('/accounts') as List).cast<Map<String, dynamic>>().firstWhere(
      (c) => const {'CHECKING', 'SAVINGS', 'CASH'}.contains(c['type']),
    );
    final mes = (await hoyDelUsuario()).substring(0, 7);
    final creado =
        await api.post('/recurring-flows', {
              'name': 'Flujo de prueba ${DateTime.now().microsecondsSinceEpoch}',
              'type': (gasto ?? true) ? 'EXPENSE' : 'INCOME',
              'amount': 120.0,
              'frequency': 'MONTHLY',
              'accountId': cuenta['id'],
              'startDate': '2026-01-01',
              'nextDueDate': '$mes-15',
            })
            as Map<String, dynamic>;
    return flujoPorId(creado['id'] as String);
  }

  test('la lista dice qué meses tienen registro, no solo el de hoy', () async {
    final lista = await api.get('/recurring-flows') as List;
    for (final f in lista.cast<Map<String, dynamic>>()) {
      expect(f['paidMonths'], isA<List>());
      // El estado de hoy se deriva de esa misma lista: si dice PAID, el mes
      // actual tiene que estar dentro. Dos verdades para lo mismo es como
      // terminan discrepando.
      final hoy = DateTime.now();
      final claveHoy = '${hoy.year}-${hoy.month.toString().padLeft(2, '0')}';
      expect(
        (f['paidMonths'] as List).contains(claveHoy),
        f['statusThisMonth'] == 'PAID',
        reason: 'flujo ${f['name']}',
      );
    }
  });

  test('marcar un mes pasado lo registra en ese mes y no en el de hoy', () async {
    final flujo = await unFlujoSinPagos();
    final r = await api.post('/recurring-flows/${flujo['id']}/pay', {'month': '2026-03'}) as Map;
    expect(r['mes'], '2026-03');

    final despues = await flujoPorId(flujo['id'] as String);
    expect(despues['paidMonths'], contains('2026-03'));
    // Y hoy sigue pendiente: marcar marzo no es haber pagado agosto.
    expect(despues['statusThisMonth'], 'PENDING');
  });

  test('el mismo mes no se puede marcar dos veces', () async {
    final flujo = await unFlujoSinPagos();
    await api.post('/recurring-flows/${flujo['id']}/pay', {'month': '2026-03'});

    // Sin esto el movimiento se duplicaría y el saldo se movería el doble.
    await expectLater(
      api.post('/recurring-flows/${flujo['id']}/pay', {'month': '2026-03'}),
      throwsA(isA<ApiException>()),
    );
  });

  test('revertir apunta al mes que se marcó, no al de hoy', () async {
    final flujo = await unFlujoSinPagos();
    await api.post('/recurring-flows/${flujo['id']}/pay', {'month': '2026-03'});
    await api.post('/recurring-flows/${flujo['id']}/pay', {'month': '2026-04'});

    await api.post('/recurring-flows/${flujo['id']}/revert-payment', {'month': '2026-03'});

    final despues = await flujoPorId(flujo['id'] as String);
    expect(despues['paidMonths'], isNot(contains('2026-03')));
    // Abril sobrevive: revertir marzo no puede llevarse lo que vino después.
    expect(despues['paidMonths'], contains('2026-04'));
  });

  Future<double> saldoDe(String accountId) async {
    final cuentas = await api.get('/accounts') as List;
    return (cuentas.cast<Map<String, dynamic>>().firstWhere(
              (c) => c['id'] == accountId,
            )['currentBalance']
            as num)
        .toDouble();
  }

  test('marcar un GASTO de un mes pasado no mueve el patrimonio de hoy', () async {
    // El alquiler de marzo salió de la cuenta en marzo: el saldo de hoy ya lo
    // tiene descontado. Registrarlo ahora lo contaría dos veces — que es
    // exactamente lo que infló un patrimonio real en S/ 3,210 al estrenar esta
    // pantalla.
    final flujo = await unFlujoSinPagos(gasto: true);
    final cuentaId = flujo['accountId'] as String;
    final antes = await saldoDe(cuentaId);

    await api.post('/recurring-flows/${flujo['id']}/pay', {'month': '2026-03'});

    expect(await saldoDe(cuentaId), closeTo(antes, 0.001));
    // Y el mes queda registrado igual: no mover el saldo no es no anotarlo.
    expect((await flujoPorId(flujo['id'] as String))['paidMonths'], contains('2026-03'));
  });

  test('marcar un INGRESO de un mes pasado sí lo mueve', () async {
    // Al revés que el gasto, y por dónde está la plata: un sueldo que
    // corresponde a marzo y te entra hoy todavía no está en tu saldo.
    // Neutralizarlo dejaba el patrimonio corto sin forma de arreglarlo.
    final flujo = await unFlujoSinPagos(gasto: false);
    final cuentaId = flujo['accountId'] as String;
    final antes = await saldoDe(cuentaId);

    final r =
        await api.post('/recurring-flows/${flujo['id']}/pay', {'month': '2026-03', 'amount': 800})
            as Map;
    expect(r, isNotNull);

    expect(await saldoDe(cuentaId), closeTo(antes + 800, 0.001));
  });

  test('el mes en curso sí mueve el patrimonio', () async {
    // Ahí la plata está saliendo ahora, así que el saldo tiene que reflejarlo.
    final flujo = await unFlujoSinPagos();
    final cuentaId = flujo['accountId'] as String;
    final antes = await saldoDe(cuentaId);
    final monto = (flujo['amount'] as num).toDouble();

    await api.post('/recurring-flows/${flujo['id']}/pay', const {});

    final esperado = flujo['type'] == 'INCOME' ? antes + monto : antes - monto;
    expect(await saldoDe(cuentaId), closeTo(esperado, 0.01));
  });

  test('revertir un mes pasado tampoco mueve el patrimonio', () async {
    // Entró compensado, así que sale compensado: si el revertir devolviera la
    // plata que nunca se movió, el saldo bajaría al deshacer.
    final flujo = await unFlujoSinPagos();
    final cuentaId = flujo['accountId'] as String;
    final antes = await saldoDe(cuentaId);

    await api.post('/recurring-flows/${flujo['id']}/pay', {'month': '2026-03'});
    await api.post('/recurring-flows/${flujo['id']}/revert-payment', {'month': '2026-03'});

    expect(await saldoDe(cuentaId), closeTo(antes, 0.001));
    expect((await flujoPorId(flujo['id'] as String))['paidMonths'], isNot(contains('2026-03')));
  });

  test('marcar un mes viejo no vuelve a reclamar los meses ya saldados', () async {
    final flujo = await unFlujoSinPagos();
    await api.post('/recurring-flows/${flujo['id']}/pay', {'month': '2026-06'});
    final trasJunio = await flujoPorId(flujo['id'] as String);
    await api.post('/recurring-flows/${flujo['id']}/pay', {'month': '2026-02'});
    final trasFebrero = await flujoPorId(flujo['id'] as String);

    expect(
      (trasFebrero['missedMonths'] as List).length,
      lessThanOrEqualTo((trasJunio['missedMonths'] as List).length),
      reason: 'registrar un mes no puede aumentar lo reclamado',
    );
  });

  test('cambiar el monto de un GASTO de un mes pasado no mueve el patrimonio', () async {
    // El gasto de un mes pasado se guardó con su ajuste compensatorio: los dos
    // tienen que cambiar a la vez. Si solo cambiara el movimiento, la diferencia
    // se le escaparía al saldo por la puerta de atrás.
    final flujo = await unFlujoSinPagos(gasto: true);
    final cuentaId = flujo['accountId'] as String;
    final antes = await saldoDe(cuentaId);

    await api.post('/recurring-flows/${flujo['id']}/pay', {'month': '2026-03', 'amount': 100});
    await api.patch('/recurring-flows/${flujo['id']}/month', {'month': '2026-03', 'amount': 250});

    expect(await saldoDe(cuentaId), closeTo(antes, 0.001));
    final registros = (await flujoPorId(flujo['id'] as String))['monthlyRecords'] as List;
    final marzo = registros.cast<Map<String, dynamic>>().firstWhere((r) => r['month'] == '2026-03');
    expect((marzo['amount'] as num).toDouble(), 250);
  });

  test('cambiar el monto del mes en curso mueve el saldo solo por la diferencia', () async {
    // Ni el monto viejo entero ni el nuevo entero: la plata que se movió de
    // verdad es la diferencia.
    final flujo = await unFlujoSinPagos();
    final cuentaId = flujo['accountId'] as String;
    final antes = await saldoDe(cuentaId);

    await api.post('/recurring-flows/${flujo['id']}/pay', {'amount': 100});
    await api.patch('/recurring-flows/${flujo['id']}/month', {
      'month': _mesActual(),
      'amount': 250,
    });

    final signo = flujo['type'] == 'INCOME' ? 1 : -1;
    expect(await saldoDe(cuentaId), closeTo(antes + signo * 250, 0.01));
  });

  test('un mes sin pagar también puede tener su monto', () async {
    // Antes esto era un error, y ahí estaba el problema: si el único sitio
    // donde vive un monto es el pago, un mes sin pagar no tiene dónde guardar
    // el suyo y la fila cae en el del flujo — que es uno para todos los meses.
    final flujo = await unFlujoSinPagos();
    final r =
        await api.patch('/recurring-flows/${flujo['id']}/month', {'month': '2026-03', 'amount': 50})
            as Map;

    expect((r['amount'] as num).toDouble(), 50);
    final despues = await flujoPorId(flujo['id'] as String);
    expect((((despues['months'] as Map)['2026-03'] as Map)['amount'] as num).toDouble(), 50);
    // Y sigue sin pagar: cambiar cuánto vale un mes no es haberlo pagado.
    expect(despues['paidMonths'], isNot(contains('2026-03')));
  });
}

String _mesActual() {
  final hoy = DateTime.now();
  return '${hoy.year}-${hoy.month.toString().padLeft(2, '0')}';
}
