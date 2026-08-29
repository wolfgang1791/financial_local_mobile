// El monto de cada mes, independiente del resto.
//
// El bug que fija, y que costó dos intentos: el monto vivía solo en el flujo,
// uno para todos los meses. Poner 0 en agosto ponía 0 en julio. Y como el único
// sitio donde podía vivir un monto era el pago, un mes sin pagar no tenía dónde
// guardar el suyo.

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
    tmp = await prepararDirectorioTemporal('flow_month_amount_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<Map<String, dynamic>> flujoPorId(String id) async {
    final lista = await api.get('/recurring-flows') as List;
    return lista.cast<Map<String, dynamic>>().firstWhere((f) => f['id'] == id);
  }

  /// Un flujo recién creado, para que el test no dependa de qué trae sembrada
  /// la base ni de si a ese flujo ya le tocaron los meses que usa este test.
  Future<Map<String, dynamic>> unFlujo(String tipo) async {
    final cuentas = await api.get('/accounts') as List;
    return await api.post('/recurring-flows', {
          'name': tipo == 'EXPENSE' ? 'Luz de prueba' : 'Sueldo de prueba',
          'type': tipo,
          'amount': 100,
          'frequency': 'MONTHLY',
          'startDate': '2026-01-05',
          'nextDueDate': '2026-08-05',
          'accountId': (cuentas.first as Map)['id'],
        })
        as Map<String, dynamic>;
  }

  /// El monto de un mes según las fichas que devuelve el API.
  double montoDe(Map<String, dynamic> flujo, String mes) {
    final meses = (flujo['months'] as Map).cast<String, dynamic>();
    final propio = meses[mes];
    if (propio != null) return ((propio as Map)['amount'] as num).toDouble();
    final anteriores = meses.keys.where((m) => m.compareTo(mes) < 0).toList()..sort();
    return anteriores.isEmpty
        ? (flujo['amount'] as num).toDouble()
        : ((meses[anteriores.last] as Map)['amount'] as num).toDouble();
  }

  for (final tipo in ['EXPENSE', 'INCOME']) {
    final etiqueta = tipo == 'EXPENSE' ? 'gasto fijo' : 'ingreso fijo';

    test('$etiqueta: cambiar un mes no toca los demás', () async {
      final flujo = await unFlujo(tipo);
      final id = flujo['id'] as String;

      await api.patch('/recurring-flows/$id/month', {'month': '2026-07', 'amount': 450});
      await api.patch('/recurring-flows/$id/month', {'month': '2026-08', 'amount': 0});

      final despues = await flujoPorId(id);
      // Julio no se entera de lo que se puso en agosto. Este es el caso exacto
      // que se reportó: poner 0 en agosto ponía 0 en julio.
      expect(montoDe(despues, '2026-07'), 450);
      expect(montoDe(despues, '2026-08'), 0);
    });

    test('$etiqueta: un mes sin pagar puede tener su monto', () async {
      final flujo = await unFlujo(tipo);
      final id = flujo['id'] as String;

      await api.patch('/recurring-flows/$id/month', {'month': '2026-07', 'amount': 500});

      final despues = await flujoPorId(id);
      expect(montoDe(despues, '2026-07'), 500);
      // Sin pagar: cambiar cuánto vale un mes no es haberlo pagado.
      expect(despues['paidMonths'], isNot(contains('2026-07')));
    });

    test('$etiqueta: el mes siguiente hereda del anterior', () async {
      final flujo = await unFlujo(tipo);
      final id = flujo['id'] as String;

      await api.patch('/recurring-flows/$id/month', {'month': '2026-06', 'amount': 210});

      // Septiembre se parece a junio, no a lo que se declaró al crear el flujo.
      expect(montoDe(await flujoPorId(id), '2026-09'), 210);
    });

    test('$etiqueta: marcar usa el monto del mes, no el declarado', () async {
      final flujo = await unFlujo(tipo);
      final id = flujo['id'] as String;

      await api.patch('/recurring-flows/$id/month', {'month': '2026-07', 'amount': 333});
      await api.post('/recurring-flows/$id/pay', {'month': '2026-07'});

      final registros = (await flujoPorId(id))['monthlyRecords'] as List;
      final julio = registros.cast<Map<String, dynamic>>().firstWhere(
        (r) => r['month'] == '2026-07',
      );
      expect((julio['amount'] as num).toDouble(), 333);
    });
  }

  for (final tipo in ['EXPENSE', 'INCOME']) {
    final etiqueta = tipo == 'EXPENSE' ? 'gasto fijo' : 'ingreso fijo';

    test('$etiqueta: el mes en curso nace solo, copiando al anterior', () async {
      // El caso tal cual: es 31 de agosto, llega el 1 de septiembre y hace falta
      // una ficha nueva para HBO Max — distinta, con el monto de referencia del
      // último mes y el mismo día de cobro.
      final flujo = await unFlujo(tipo);
      final id = flujo['id'] as String;

      // Junio quedó en 44.90 (le subieron el precio) y cobrando el 12.
      await api.patch('/recurring-flows/$id/month', {'month': '2026-06', 'amount': 44.90});
      await api.patch('/recurring-flows/$id/month', {'month': '2026-06', 'dueDate': '2026-06-12'});

      final meses = (await flujoPorId(id))['months'] as Map;
      final actual = _mesActual();
      expect(meses[actual], isNotNull, reason: 'el mes en curso tiene ficha propia');
      expect((meses[actual]['amount'] as num).toDouble(), 44.90, reason: 'hereda el monto');
      // Y el día de cobro, que es lo que se repite mes a mes: HBO Max no pasa a
      // cobrar a fin de mes porque haya cambiado el calendario.
      expect(meses[actual]['dueDate'], '$actual-12');
      expect(meses[actual]['paidAt'], isNull, reason: 'nace sin pagar');
    });

    test('$etiqueta: editar la ficha de un mes no toca la de los otros', () async {
      final flujo = await unFlujo(tipo);
      final id = flujo['id'] as String;

      await api.patch('/recurring-flows/$id/month', {'month': '2026-07', 'amount': 44.90});
      await api.patch('/recurring-flows/$id/month', {'month': '2026-08', 'amount': 62.90});

      final meses = (await flujoPorId(id))['months'] as Map;
      expect((meses['2026-07']['amount'] as num).toDouble(), 44.90);
      expect((meses['2026-08']['amount'] as num).toDouble(), 62.90);
    });

    test('$etiqueta: la caducidad de un mes se mueve sin tocar las demás', () async {
      final flujo = await unFlujo(tipo);
      final id = flujo['id'] as String;

      await api.patch('/recurring-flows/$id/month', {'month': '2026-07', 'amount': 44.90});
      await api.patch('/recurring-flows/$id/month', {'month': '2026-07', 'dueDate': '2026-07-20'});
      // Leer hace nacer agosto, que hereda de julio el día 20.
      await flujoPorId(id);

      // Y ahora se mueve julio, con agosto ya existiendo.
      await api.patch('/recurring-flows/$id/month', {'month': '2026-07', 'dueDate': '2026-07-05'});

      final meses = (await flujoPorId(id))['months'] as Map;
      expect(meses['2026-07']['dueDate'], '2026-07-05');
      // El monto sobrevive a un cambio de fecha: son dos campos de la misma
      // ficha, y mandar uno no puede borrar el otro.
      expect((meses['2026-07']['amount'] as num).toDouble(), 44.90);
      // Agosto ya tenía ficha: mover julio no lo arrastra.
      expect(meses['2026-08']['dueDate'], '2026-08-20');
    });

    test('$etiqueta: la marca de pagado vive en la ficha del mes', () async {
      final flujo = await unFlujo(tipo);
      final id = flujo['id'] as String;

      await api.patch('/recurring-flows/$id/month', {'month': '2026-07', 'amount': 44.90});
      await api.post('/recurring-flows/$id/pay', {'month': '2026-07'});

      var meses = (await flujoPorId(id))['months'] as Map;
      // Julio pagado, agosto no: es lo que permite que un mes esté saldado
      // mientras el siguiente sigue pendiente.
      expect(meses['2026-07']['paidAt'], isNotNull);
      expect(DateTime.parse(meses['2026-07']['paidAt'] as String).month, 7);
      expect(meses['2026-08']['paidAt'], isNull);

      await api.post('/recurring-flows/$id/revert-payment', {'month': '2026-07'});

      meses = (await flujoPorId(id))['months'] as Map;
      expect(meses['2026-07']['paidAt'], isNull, reason: 'revertir desmarca');
      // Pero el monto se queda: revertir es "no lo pagué", no "no sé cuánto era".
      expect((meses['2026-07']['amount'] as num).toDouble(), 44.90);
    });
  }

  test('marcar un mes cuyo vencimiento cae fuera marca ese mes, no el siguiente', () async {
    // El caso de "Luz": la ficha de agosto vencía el 1 de septiembre —legítimo,
    // una tarjeta que cierra el 28 se paga el 5 del siguiente—. Marcar agosto
    // fechaba el movimiento en septiembre y deducía de ahí el mes: escribía la
    // marca en septiembre, agosto seguía sin registro, la pantalla volvía a
    // ofrecer "Marcar como pagado" y el API contestaba "ya tiene un registro en
    // ese mes". Un callejón sin salida.
    final flujo = await unFlujo('EXPENSE');
    final id = flujo['id'] as String;

    await api.patch('/recurring-flows/$id/month', {'month': '2026-07', 'dueDate': '2026-08-03'});
    final pago = await api.post('/recurring-flows/$id/pay', {'month': '2026-07'});

    expect((pago as Map)['mes'], '2026-07');
    // Y el movimiento cae **dentro de julio**: el vencimiento del 3 de agosto
    // es una referencia, no la fecha del hecho, y un pago de julio fechado en
    // agosto le cambiaría el gasto a los dos meses.
    final registro = ((await flujoPorId(id))['monthlyRecords'] as List).first as Map;
    expect(registro['month'], '2026-07');

    final despues = await flujoPorId(id);
    final meses = despues['months'] as Map;
    expect(meses['2026-07']['paidAt'], isNotNull, reason: 'julio quedó marcado');
    expect(meses['2026-08']['paidAt'], isNull, reason: 'agosto no se enteró');
    expect((despues['paidMonths'] as List), contains('2026-07'));
    expect((despues['paidMonths'] as List), isNot(contains('2026-08')));

    // Y volver a marcarlo dice que ya está, en vez de confundirse de mes.
    await expectLater(
      api.post('/recurring-flows/$id/pay', {'month': '2026-07'}),
      throwsA(isA<ApiException>()),
    );
  });

  test('revertir encuentra el pago aunque esté fechado en otro mes', () async {
    final flujo = await unFlujo('EXPENSE');
    final id = flujo['id'] as String;

    await api.patch('/recurring-flows/$id/month', {'month': '2026-07', 'dueDate': '2026-08-03'});
    await api.post('/recurring-flows/$id/pay', {'month': '2026-07'});
    await api.post('/recurring-flows/$id/revert-payment', {'month': '2026-07'});

    final meses = (await flujoPorId(id))['months'] as Map;
    expect(meses['2026-07']['paidAt'], isNull);
    // Y el movimiento se fue con él: si quedara, marcar otra vez volvería a
    // fallar por un pago que ya nadie ve.
    final registros = (await flujoPorId(id))['monthlyRecords'] as List;
    expect(registros, isEmpty);
  });

  test('revertir y volver a marcar: manda el último', () async {
    // "Si lo revierto y pago otro día, ese debe primar". Marcar no es un sello
    // que se queda: es el registro de un hecho, y si el hecho cambia de fecha
    // el registro también.
    final flujo = await unFlujo('EXPENSE');
    final id = flujo['id'] as String;
    final mes = _mesActual();

    await api.post('/recurring-flows/$id/pay', {'month': mes});
    final primero = ((await flujoPorId(id))['months'] as Map)[mes]['paidAt'] as String;

    await api.post('/recurring-flows/$id/revert-payment', {'month': mes});
    expect(((await flujoPorId(id))['months'] as Map)[mes]['paidAt'], isNull);
    // Y no queda un movimiento huérfano: si quedara, el mes seguiría contando
    // un gasto que ya nadie ve.
    expect((await flujoPorId(id))['monthlyRecords'], isEmpty);

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await api.post('/recurring-flows/$id/pay', {'month': mes});

    final despues = await flujoPorId(id);
    final segundo = (despues['months'] as Map)[mes]['paidAt'] as String;
    expect(DateTime.parse(segundo).isAfter(DateTime.parse(primero)), isTrue);
    // Uno solo: volver a marcar reemplaza, no acumula.
    expect((despues['monthlyRecords'] as List).length, 1);
  });

  test('la fecha del marcado se puede corregir, y el movimiento va con ella', () async {
    // El caso normal: lo pagaste el martes y lo marcaste el viernes. Corregir
    // la fecha tiene que mover el asiento, porque la marca de la ficha y la
    // fecha del movimiento son la misma cosa vista desde dos tablas.
    final flujo = await unFlujo('EXPENSE');
    final id = flujo['id'] as String;
    final mes = _mesActual();

    await api.post('/recurring-flows/$id/pay', {'month': mes});

    await api.patch('/recurring-flows/$id/month', {'month': mes, 'paidAt': '$mes-03'});

    final despues = await flujoPorId(id);
    final marca = DateTime.parse((despues['months'] as Map)[mes]['paidAt'] as String).toLocal();
    expect(marca.day, 3);

    // Y el movimiento quedó ese mismo día: si se quedara atrás, revertir no lo
    // encontraría y el mes contaría un gasto que ya nadie ve.
    final registro = ((despues['monthlyRecords'] as List).first as Map)['transactionId'];
    final movimientos = (await api.get('/transactions?take=100') as Map)['items'] as List;
    final asiento = movimientos.cast<Map<String, dynamic>>().firstWhere((t) => t['id'] == registro);
    expect(DateTime.parse(asiento['occurredAt'] as String).toLocal().day, 3);

    // Y revertir sigue encontrándolo por la marca nueva.
    await api.post('/recurring-flows/$id/revert-payment', {'month': mes});
    expect(((await flujoPorId(id))['months'] as Map)[mes]['paidAt'], isNull);
    expect((await flujoPorId(id))['monthlyRecords'], isEmpty);
  });

  test('sin pago, mandar una fecha de marcado no inventa uno', () async {
    final flujo = await unFlujo('EXPENSE');
    final id = flujo['id'] as String;
    final mes = _mesActual();

    await api.patch('/recurring-flows/$id/month', {'month': mes, 'paidAt': '$mes-03'});

    // Decir "se pagó el 3" sin que exista el asiento sería marcar pagado por la
    // puerta de atrás, saltándose el movimiento y el saldo.
    expect(((await flujoPorId(id))['months'] as Map)[mes]['paidAt'], isNull);
  });
}

String _mesActual() {
  final hoy = DateTime.now();
  return '${hoy.year}-${hoy.month.toString().padLeft(2, '0')}';
}
