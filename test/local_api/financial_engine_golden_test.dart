// Valores de oro para la Fase 4 — comparados contra el backend NestJS/
// Postgres vivo, mismo usuario, mismo instante.

import 'dart:io';

import 'package:financial_strategist_local/data/api.dart';
import 'package:financial_strategist_local/local_api/current_user.dart';
import 'package:financial_strategist_local/local_db/database.dart';
import 'package:financial_strategist_local/local_engine/user_clock.dart';
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
    expect((r['liquidAssets'] as num).toDouble(), 1408.97);
    expect((r['upcomingExpenses'] as num).toDouble(), 2066.25);
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
    expect((r['total'] as num).toDouble(), 1408.97);

    final cuentas = r['accounts'] as List;
    expect(cuentas.length, 2);
    final sip = cuentas.firstWhere((c) => c['name'] == 'sip');
    expect(sip['isHidden'], true);

    final mes = r['month'] as Map;
    expect(mes['key'], '2026-08');
    expect((mes['income'] as num).toDouble(), 0);
    expect((mes['expenses'] as num).toDouble(), 1187.33);
    expect((mes['net'] as num).toDouble(), -1187.33);
  });

  test('GET /financial-engine/net-worth-history — mismos 2 meses, mismas cifras', () async {
    final r = await api.get('/financial-engine/net-worth-history') as List;
    expect(r.length, 2);

    final julio = r.firstWhere((p) => p['month'] == '2026-07');
    expect((julio['liquid'] as num).toDouble(), 2629.13);
    expect((julio['income'] as num).toDouble(), 8349.31);
    // 8,836.54, que es exactamente lo que dice la web para julio: la base
    // sembrada no tenía el pago de Netflix del 27 y `_igualarConLaWeb` lo trae.
    expect((julio['expenses'] as num).toDouble(), 8836.54);
    expect(julio['inProgress'], false);

    final agosto = r.firstWhere((p) => p['month'] == '2026-08');
    expect((agosto['liquid'] as num).toDouble(), 1408.97);
    expect((agosto['delta'] as num).toDouble(), closeTo(-1220.16, 0.01));
    expect(agosto['inProgress'], true);
  });

  test(
    'GET /financial-engine/net-worth-daily — un punto por día hasta hoy, mismo cierre',
    () async {
      final r = await api.get('/financial-engine/net-worth-daily') as List;

      // El largo de la serie crece un punto por día, así que lo que se comprueba
      // es la regla y no el número: arranca en el primer registro de la base
      // sembrada, termina hoy, y entre medio no falta ni sobra un día.
      expect(r.first['date'], _primerRegistroSembrado);
      expect(r.last['date'], await _hoyDelUsuario());
      expect(r.length, _diasEntre(_primerRegistroSembrado, r.last['date'] as String) + 1);

      expect((r.last['liquid'] as num).toDouble(), 1408.97);
      expect((r.last['moved'] as num).toDouble(), 0);

      // Un día concreto del pasado sí es un valor de oro: ya cerró y no puede
      // cambiar.
      final dia14 = r.firstWhere((p) => p['date'] == '2026-08-14');
      expect((dia14['liquid'] as num).toDouble(), 1462.77);
      expect((dia14['moved'] as num).toDouble(), -68);
    },
  );
}

// El próximo ingreso de la base sembrada — medianoche del 28 de agosto en la
// zona del usuario.
final _horizonteSembrado = DateTime.utc(2026, 8, 28, 5);

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
Future<String> _hoyDelUsuario() async {
  final db = await LocalDatabase.open();
  final clock = UserClock(
    (await db.query(
          'User',
          columns: ['timezone'],
          where: 'id = ?',
          whereArgs: [await currentUserId(db)],
          limit: 1,
        )).first['timezone']
        as String,
  );
  final p = clock.parts();
  return '${p.year}-${p.month.toString().padLeft(2, '0')}-${p.day.toString().padLeft(2, '0')}';
}
