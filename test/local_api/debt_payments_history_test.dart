// El historial de pagos de una deuda: qué hizo cada uno.
//
// La pregunta que contesta no es "cuánto he pagado" —eso ya está en el
// historial de movimientos— sino "de todo lo que pagué, cuánto bajó la deuda",
// que sobre un crédito caro son dos cifras muy distintas.

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
    tmp = await prepararDirectorioTemporal('debt_pagos_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<List<Map<String, dynamic>>> deudas() async =>
      (await api.get('/debts') as List).cast<Map<String, dynamic>>();

  Future<String> cuentaLiquida() async {
    final cuentas = (await api.get('/accounts') as List).cast<Map<String, dynamic>>();
    return cuentas.firstWhere((c) => c['type'] == 'CHECKING')['id'] as String;
  }

  test('cada pago dice cuánto bajó la deuda y cuánto fue costo', () async {
    final deuda = (await deudas()).firstWhere((d) => (d['termMonths'] as num?) != null);
    final saldoAntes = (deuda['currentBalance'] as num).toDouble();

    await api.post('/debts/${deuda['id']}/pay', {
      'accountId': await cuentaLiquida(),
      'amount': 500.0,
    });

    final r = await api.get('/debts/${deuda['id']}/payments') as Map<String, dynamic>;
    final pagos = (r['payments'] as List).cast<Map<String, dynamic>>();
    expect(pagos, isNotEmpty);

    final ultimo = pagos.first;
    expect((ultimo['paid'] as num).toDouble(), 500.0);
    // Con cronograma, parte de la cuota es interés y no baja un céntimo.
    expect((ultimo['interest'] as num).toDouble(), greaterThan(0));
    expect(
      (ultimo['principal'] as num).toDouble() +
          (ultimo['interest'] as num).toDouble() +
          (ultimo['insurance'] as num).toDouble() +
          (ultimo['fees'] as num).toDouble(),
      closeTo(500.0, 0.01),
      reason: 'lo pagado se reparte entero, sin sobrantes ni dobles',
    );

    // El saldo de cada fila se reconstruye hacia atrás desde el actual, así que
    // la primera fila —la más reciente— termina exactamente en el saldo de hoy.
    final deudaAhora = (await deudas()).firstWhere((d) => d['id'] == deuda['id']);
    expect(
      (ultimo['balanceAfter'] as num).toDouble(),
      closeTo((deudaAhora['currentBalance'] as num).toDouble(), 0.01),
    );
    expect(
      (ultimo['balanceBefore'] as num).toDouble(),
      closeTo(saldoAntes, 0.01),
    );
  });

  test('una tarjeta sin cronograma también cobra interés', () async {
    // Antes, sin cuotas proyectadas el interés se daba por cero y **todo** lo
    // que pagabas bajaba el capital: sobre una tarjeta al 66% TEA eso son
    // cientos de soles al mes acreditados de más, y el saldo de la app se
    // separa del estado de cuenta un poco más cada mes.
    final tarjeta = (await deudas()).firstWhere(
      (d) => (d['termMonths'] as num?) == null && (d['interestRateAnnual'] as num) > 0,
    );
    expect(
      (tarjeta['installmentInterest'] as num).toDouble(),
      greaterThan(0),
      reason: 'el interés del mes se estima sobre el saldo',
    );

    final saldoAntes = (tarjeta['currentBalance'] as num).toDouble();
    await api.post('/debts/${tarjeta['id']}/pay', {
      'accountId': await cuentaLiquida(),
      'amount': 300.0,
    });

    final r = await api.get('/debts/${tarjeta['id']}/payments') as Map<String, dynamic>;
    final ultimo = (r['payments'] as List).cast<Map<String, dynamic>>().first;
    expect((ultimo['interest'] as num).toDouble(), greaterThan(0));
    expect((ultimo['principal'] as num).toDouble(), lessThan(300.0));

    final ahora = (await deudas()).firstWhere((d) => d['id'] == tarjeta['id']);
    expect(
      (ahora['currentBalance'] as num).toDouble(),
      closeTo(saldoAntes - (ultimo['principal'] as num).toDouble(), 0.01),
      reason: 'la deuda baja por el capital, no por lo pagado',
    );
  });

  test('el desglose declarado manda sobre el estimado', () async {
    // Con el estado de cuenta delante, esa es la verdad. Antes se guardaba lo
    // declarado pero se repartía con lo estimado: la fila decía una cosa y el
    // saldo bajaba otra.
    final deuda = (await deudas()).firstWhere((d) => (d['termMonths'] as num?) != null);
    final saldoAntes = (deuda['currentBalance'] as num).toDouble();

    await api.post('/debts/${deuda['id']}/pay', {
      'accountId': await cuentaLiquida(),
      'amount': 500.0,
      'interest': 100.0,
      'insurance': 20.0,
      'fees': 5.0,
    });

    final r = await api.get('/debts/${deuda['id']}/payments') as Map<String, dynamic>;
    final ultimo = (r['payments'] as List).cast<Map<String, dynamic>>().first;
    expect((ultimo['interest'] as num).toDouble(), 100.0);
    expect((ultimo['insurance'] as num).toDouble(), 20.0);
    expect((ultimo['fees'] as num).toDouble(), 5.0);
    expect((ultimo['principal'] as num).toDouble(), closeTo(375.0, 0.01));

    final ahora = (await deudas()).firstWhere((d) => d['id'] == deuda['id']);
    expect(
      (ahora['currentBalance'] as num).toDouble(),
      closeTo(saldoAntes - 375.0, 0.01),
      reason: 'el saldo baja por el capital declarado, no por otro',
    );
  });

  test('los totales dicen cuánto de todo lo pagado bajó la deuda', () async {
    final deuda = (await deudas()).firstWhere((d) => (d['termMonths'] as num?) != null);
    final cuenta = await cuentaLiquida();
    await api.post('/debts/${deuda['id']}/pay', {'accountId': cuenta, 'amount': 400.0});

    final r = await api.get('/debts/${deuda['id']}/payments') as Map<String, dynamic>;
    final t = (r['totals'] as Map).cast<String, dynamic>();
    expect(
      (t['principal'] as num).toDouble() + (t['cost'] as num).toDouble(),
      closeTo((t['paid'] as num).toDouble(), 0.02),
      reason: 'lo pagado o bajó la deuda o fue costo; no hay tercera',
    );
  });

  test('corregir el reparto de un pago mueve el saldo por la diferencia', () async {
    // El caso real: una tarjeta pagada cuando la app daba el interés por cero,
    // así que acreditó al capital lo que el banco cobró como interés. Con el
    // estado de cuenta delante se corrige, y el saldo vuelve a donde debía.
    final tarjeta = (await deudas()).firstWhere((d) => (d['termMonths'] as num?) == null);
    await api.post('/debts/${tarjeta['id']}/pay', {
      'accountId': await cuentaLiquida(),
      'amount': 300.0,
      // Declarado a cero para reproducir el estado viejo: todo a capital.
      'interest': 0.0,
    });

    final antes = (await deudas()).firstWhere((d) => d['id'] == tarjeta['id']);
    final saldoAntes = (antes['currentBalance'] as num).toDouble();
    final pago =
        ((await api.get('/debts/${tarjeta['id']}/payments') as Map)['payments'] as List).first
            as Map<String, dynamic>;
    // 275 y no 300: esta tarjeta tiene 25 de desgravamen declarado, que sale
    // antes que el capital.
    expect((pago['principal'] as num).toDouble(), 275.0);

    await api.patch('/debts/${tarjeta['id']}/payments/${pago['id']}', {'interest': 120.0});

    final r = await api.get('/debts/${tarjeta['id']}/payments') as Map<String, dynamic>;
    final corregido = (r['payments'] as List).first as Map<String, dynamic>;
    // Lo pagado no cambia: es el mismo dinero que salió el mismo día.
    expect((corregido['paid'] as num).toDouble(), 300.0);
    expect((corregido['interest'] as num).toDouble(), 120.0);
    // Y el capital lo absorbe, para que las cuatro partes sigan sumando lo
    // pagado: 300 = 120 de interés + 25 de seguro + 155 de capital.
    expect((corregido['principal'] as num).toDouble(), 155.0);

    // El saldo sube por la diferencia: se había amortizado 120 de más.
    final despues = (await deudas()).firstWhere((d) => d['id'] == tarjeta['id']);
    expect((despues['currentBalance'] as num).toDouble(), closeTo(saldoAntes + 120, 0.01));
  });

  test('corregir el capital deja que el interés ceda', () async {
    final deuda = (await deudas()).firstWhere((d) => (d['termMonths'] as num?) != null);
    await api.post('/debts/${deuda['id']}/pay', {
      'accountId': await cuentaLiquida(),
      'amount': 500.0,
    });
    final pago =
        ((await api.get('/debts/${deuda['id']}/payments') as Map)['payments'] as List).first
            as Map<String, dynamic>;

    await api.patch('/debts/${deuda['id']}/payments/${pago['id']}', {'principal': 200.0});

    final corregido =
        ((await api.get('/debts/${deuda['id']}/payments') as Map)['payments'] as List).first
            as Map<String, dynamic>;
    expect((corregido['principal'] as num).toDouble(), 200.0);
    expect((corregido['interest'] as num).toDouble(), 300.0);
  });

  test('no se puede acreditar más capital del que se pagó', () async {
    final deuda = (await deudas()).firstWhere((d) => (d['termMonths'] as num?) != null);
    await api.post('/debts/${deuda['id']}/pay', {
      'accountId': await cuentaLiquida(),
      'amount': 500.0,
    });
    final pago =
        ((await api.get('/debts/${deuda['id']}/payments') as Map)['payments'] as List).first
            as Map<String, dynamic>;

    // Se acota a lo pagado en vez de reventar: pedir 900 de capital sobre un
    // pago de 500 es un dedazo, y la respuesta útil es 500.
    await api.patch('/debts/${deuda['id']}/payments/${pago['id']}', {'principal': 900.0});
    final corregido =
        ((await api.get('/debts/${deuda['id']}/payments') as Map)['payments'] as List).first
            as Map<String, dynamic>;
    expect((corregido['principal'] as num).toDouble(), lessThanOrEqualTo(500.0));
  });
}
