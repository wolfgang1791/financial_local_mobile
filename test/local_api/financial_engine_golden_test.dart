// Valores de oro — comparados contra el backend NestJS/Postgres vivo, mismo
// usuario, mismo instante.
//
// Salen de la semilla, así que se rehacen cuando la semilla se rehace
// (`tool/regenerar_semilla.mjs`): son la prueba de que el motor en Dart contesta
// lo mismo que el de Nest sobre los mismos datos, y para eso los números tienen
// que venir del backend, nunca de este motor.
//
// Última toma: 08/09/2026, con la semilla traída ese día.

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
    tmp = await prepararDirectorioTemporal('financial_strategist_local_fe_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  test('GET /financial-engine/safe-to-spend — mismos números que el backend real', () async {
    final r = await api.get('/financial-engine/safe-to-spend') as Map;
    expect((r['liquidAssets'] as num).toDouble(), 1931.45);
    expect((r['upcomingExpenses'] as num).toDouble(), 1955.70);
    // El horizonte es el próximo ingreso de la base sembrada, y esa fecha no se
    // mueve: es el valor de oro. Lo que sí cambia todos los días es la cuenta
    // atrás hasta ella, así que se comprueba contra la fecha en vez de tener el
    // número escrito — antes decía 12, y bastó que pasaran tres días para que el
    // test fallara sin que nada se hubiera roto.
    expect(DateTime.parse(r['horizon'] as String).toUtc(), _horizonteSembrado);
    expect(r['daysUntilHorizon'], _diasHasta(_horizonteSembrado));
    // Cero porque los gastos comprometidos superan la liquidez: no queda nada
    // por repartir, y eso no depende de cuántos días falten.
    expect((r['safeToSpendToday'] as num).toDouble(), 0);
  });

  test('GET /financial-engine/cash-position — mismo total, mismas cuentas, mismo mes', () async {
    final r = await api.get('/financial-engine/cash-position') as Map;
    expect((r['total'] as num).toDouble(), 1931.45);

    // Cuatro cuentas, y el total es solo la que cuenta: las dos de ahorro están
    // ocultas y la tarjeta nunca suma —su saldo es lo que debes—.
    final cuentas = r['accounts'] as List;
    expect(cuentas.length, 4);
    expect(
      cuentas.where((c) => c['isHidden'] == true).map((c) => c['name']),
      containsAll(['Ahorro falabella', 'Cerdo Saldo']),
    );
    final tarjeta = cuentas.firstWhere((c) => c['type'] == 'CREDIT_CARD');
    expect((tarjeta['currentBalance'] as num).toDouble(), 38.70);

    // El mes que devuelve es el **en curso**, así que su clave y sus cifras
    // cambian solas al pasar de mes. Estaba escrito '2026-08' con las cifras de
    // agosto y bastó que llegara septiembre para que fallara sin que nada se
    // hubiera roto. Lo que se comprueba es la regla: es el mes de hoy y su neto
    // cuadra con sus dos mitades.
    final mes = r['month'] as Map;
    expect(mes['key'], (await hoyDelUsuario()).substring(0, 7));
    final entro = (mes['income'] as num).toDouble();
    final salio = (mes['expenses'] as num).toDouble();
    expect((mes['net'] as num).toDouble(), closeTo(entro - salio, 0.01));
  });

  test('GET /financial-engine/net-worth-history — los meses cerrados no se mueven', () async {
    final r = await api.get('/financial-engine/net-worth-history') as List;
    // La serie crece un punto por mes, así que el largo no es un valor de oro:
    // estaba escrito 2 y bastó que llegara septiembre para que fallara. Lo que
    // no puede cambiar es lo que ya cerró.
    expect(r.length, greaterThanOrEqualTo(2));
    // Solo el último está en curso: dos meses marcados así harían pensar que hay
    // dos meses sin terminar.
    expect(r.where((p) => p['inProgress'] == true).length, 1);
    expect(r.last['inProgress'], true);
    expect(r.last['month'], (await hoyDelUsuario()).substring(0, 7));

    final julio = r.firstWhere((p) => p['month'] == '2026-07');
    expect((julio['liquid'] as num).toDouble(), 2525.29);
    expect((julio['income'] as num).toDouble(), 11559.31);
    expect((julio['expenses'] as num).toDouble(), 8836.54);
    expect(julio['inProgress'], false);

    final agosto = r.firstWhere((p) => p['month'] == '2026-08');
    expect((agosto['liquid'] as num).toDouble(), 2427.46);
    expect((agosto['delta'] as num).toDouble(), closeTo(-97.83, 0.01));
  });

  test(
    'GET /financial-engine/net-worth-daily — un punto por día hasta hoy, mismo cierre',
    () async {
      final r = await api.get('/financial-engine/net-worth-daily') as List;

      // El largo de la serie crece un punto por día, así que lo que se comprueba
      // es la regla y no el número: arranca en el primer registro de la base
      // sembrada, termina hoy, y entre medio no falta ni sobra un día.
      expect(r.first['date'], _primerRegistroSembrado);
      expect(r.last['date'], await hoyDelUsuario());
      expect(r.length, _diasEntre(_primerRegistroSembrado, r.last['date'] as String) + 1);

      expect((r.last['liquid'] as num).toDouble(), 1931.45);

      // Un día concreto del pasado sí es un valor de oro: ya cerró y no puede
      // cambiar.
      final dia14 = r.firstWhere((p) => p['date'] == '2026-08-14');
      expect((dia14['liquid'] as num).toDouble(), 1358.93);
      expect((dia14['moved'] as num).toDouble(), -68);
    },
  );
}

// El próximo ingreso de la base sembrada, en la zona del usuario.
final _horizonteSembrado = DateTime.utc(2026, 7, 30, 5);

// El día del primer movimiento de la base sembrada.
const _primerRegistroSembrado = '2026-07-02';

// Los días que faltan para una fecha, redondeando hacia arriba y con un mínimo
// de uno — la misma cuenta que hace la ruta, que reparte el dinero disponible
// entre los días que quedan y por eso nunca puede dividir entre cero.
int _diasHasta(DateTime objetivo) {
  final ahora = DateTime.now().toUtc();
  final dias =
      ((objetivo.millisecondsSinceEpoch - ahora.millisecondsSinceEpoch) /
              Duration.millisecondsPerDay)
          .ceil();
  return dias < 1 ? 1 : dias;
}

int _diasEntre(String desde, String hasta) =>
    DateTime.parse(hasta).difference(DateTime.parse(desde)).inDays;

/// Qué día es hoy para el usuario de la base sembrada.
///
/// Se le pregunta al mismo reloj que usa el motor y no a `DateTime.now()`: la
/// serie se corta en el día del usuario, y cerca de medianoche la zona del
/// dispositivo y la suya no están en la misma fecha.
