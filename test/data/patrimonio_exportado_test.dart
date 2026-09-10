// La foto de activos y pasivos que viaja con los movimientos exportados.
//
// Un archivo de movimientos sin saldos obliga a reconstruirlos sumando, que es
// el trabajo que la app hace por ti. Lo que se prueba acá son las reglas que
// hacen que las cifras del archivo signifiquen lo mismo que las de la pantalla.

import 'dart:convert';

import 'package:financial_strategist_local/data/export.dart';
import 'package:financial_strategist_local/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Account cuenta(
    String nombre,
    String tipo,
    double saldo, {
    bool oculta = false,
    double? cupo,
    String moneda = 'PEN',
  }) => Account(
    id: nombre,
    name: nombre,
    type: tipo,
    currency: moneda,
    balance: saldo,
    creditLimit: cupo,
    isHidden: oculta,
  );

  Debt deuda(
    String nombre,
    double saldo, {
    String moneda = 'PEN',
    bool activa = true,
    double tasa = 0.14,
  }) => Debt(
    id: nombre,
    accountId: nombre,
    name: nombre,
    institution: null,
    currency: moneda,
    balance: saldo,
    originalPrincipal: saldo,
    interestRateAnnual: tasa,
    costRateAnnual: null,
    minimumPayment: 100,
    termMonths: 12,
    statusThisMonth: 'PENDING',
    missedMonths: const [],
    debtTypeCode: 'PERSONAL_LOAN',
    isActive: activa,
  );

  test('lo que tienes suma y lo que debes resta, cada uno con su signo', () {
    final p = buildPatrimonio(
      cuentas: [cuenta('Corriente', 'CHECKING', 1000), cuenta('CMR', 'CREDIT_CARD', 250)],
      deudas: [deuda('Préstamo', 5000)],
      tomadaEl: '2026-09-09',
    );

    final total = p.totales.single;
    expect(total.activos, 1000);
    expect(total.pasivos, -5250, reason: 'la tarjeta del día a día también es pasivo');
    expect(total.neto, -4250);
  });

  test('una cuenta oculta viaja igual, pero no cuenta en el patrimonio', () {
    final p = buildPatrimonio(
      cuentas: [
        cuenta('Corriente', 'CHECKING', 1000),
        cuenta('Ahorros dormidos', 'SAVINGS', 900, oculta: true),
      ],
      deudas: const [],
      tomadaEl: '2026-09-09',
    );

    expect(p.lineas.length, 2, reason: 'sigue siendo tuya: el archivo la trae');
    final total = p.totales.single;
    expect(total.activos, 1900);
    expect(total.enPatrimonio, 1000, reason: 'el patrimonio que muestra la app');
  });

  test('cada moneda con su total: soles y dólares no se suman', () {
    final p = buildPatrimonio(
      cuentas: [cuenta('Corriente', 'CHECKING', 1000)],
      deudas: [deuda('Tarjeta en dólares', 300, moneda: 'USD')],
      tomadaEl: '2026-09-09',
    );

    expect(p.totales.length, 2);
    expect(p.totales.firstWhere((t) => t.moneda == 'PEN').neto, 1000);
    expect(p.totales.firstWhere((t) => t.moneda == 'USD').neto, -300);
  });

  test('una deuda cancelada no infla el pasivo', () {
    final p = buildPatrimonio(
      cuentas: const [],
      deudas: [deuda('Ya pagada', 800, activa: false)],
      tomadaEl: '2026-09-09',
    );

    expect(p.lineas, isEmpty);
    expect(p.totales, isEmpty);
  });

  test('la tasa se escribe como porcentaje, no como fracción', () {
    final p = buildPatrimonio(
      cuentas: const [],
      deudas: [deuda('Préstamo', 5000, tasa: 0.139)],
      tomadaEl: '2026-09-09',
    );

    expect(p.lineas.single.detalle, contains('TEA 13.90%'));
  });

  test('el archivo trae los movimientos y la foto en el mismo sitio', () {
    final resultado = buildExport(
      transacciones: const [],
      formato: ExportFormat.json,
      periodoId: 'mes',
      periodoLabel: 'este mes',
      timezone: 'America/Lima',
      currency: 'PEN',
      patrimonio: buildPatrimonio(
        cuentas: [cuenta('Corriente', 'CHECKING', 1000)],
        deudas: [deuda('Préstamo', 5000)],
        tomadaEl: '2026-09-09',
      ),
    );

    final json = jsonDecode(utf8.decode(resultado.bytes)) as Map<String, dynamic>;
    expect(json['movimientos'], isEmpty);
    final patrimonio = json['patrimonio'] as Map<String, dynamic>;
    // La fecha de la foto es parte del dato: sin ella se leería como el saldo
    // del periodo que se estaba mirando.
    expect(patrimonio['tomadaEl'], '2026-09-09');
    expect((patrimonio['lineas'] as List).length, 2);
  });

  test('en Markdown y CSV la foto se distingue de los movimientos', () {
    final foto = buildPatrimonio(
      cuentas: [cuenta('Corriente', 'CHECKING', 1000)],
      deudas: const [],
      tomadaEl: '2026-09-09',
    );
    for (final formato in [ExportFormat.md, ExportFormat.csv]) {
      final texto = utf8.decode(
        buildExport(
          transacciones: const [],
          formato: formato,
          periodoId: 'mes',
          periodoLabel: 'este mes',
          timezone: 'America/Lima',
          currency: 'PEN',
          patrimonio: foto,
        ).bytes,
      );
      expect(texto, contains('Activos y pasivos'), reason: '$formato');
      expect(texto, contains('2026-09-09'), reason: '$formato');
      expect(texto, contains('Corriente'), reason: '$formato');
    }
  });
}
