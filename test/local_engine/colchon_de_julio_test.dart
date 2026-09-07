// La curva de patrimonio no baja de cero.
//
// El primer registro es del 2 de julio y antes ya había plata en la mano que
// nadie anotó, así que la curva —que se reconstruye hacia atrás desde el saldo
// de hoy— arrancaba bajo cero. El colchón la levanta.
//
// El valor y la fecha del cierre **no se escriben a mano contra una foto de los
// datos**: eso fue lo que envejeció la primera versión. Este test comprueba la
// regla, no los números, así que vuelve a fallar si julio se hunde otra vez.

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
    tmp = await prepararDirectorioTemporal('colchon_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  test('ningún día de la curva queda bajo cero', () async {
    final dias = (await api.get('/financial-engine/net-worth-daily') as List)
        .cast<Map<String, dynamic>>();
    expect(dias, isNotEmpty);

    final bajoCero = dias.where((d) => (d['liquid'] as num).toDouble() < 0).toList();
    expect(
      bajoCero.map((d) => '${d['date']}: ${d['liquid']}'),
      isEmpty,
      reason: 'un patrimonio negativo acá no es un dato, es un registro que falta',
    );
  });

  test('el colchón entra antes del primer gasto y se cierra cuando ya no hace falta', () async {
    final movimientos = ((await api.get('/transactions?take=500') as Map)['items'] as List)
        .cast<Map<String, dynamic>>();
    final entra = movimientos.firstWhere(
      (t) => t['description'] == 'Efectivo que ya tenías al empezar',
    );
    final cierra = movimientos.firstWhere((t) => t['description'] == 'Cierre del efectivo inicial');

    // Los dos por el mismo monto: son la misma plata entrando y saliendo, y si
    // se separan el patrimonio de hoy se mueve.
    expect((entra['amount'] as num).toDouble(), (cierra['amount'] as num).toDouble());
    // Y en ese orden.
    expect((entra['occurredAt'] as String).compareTo(cierra['occurredAt'] as String), lessThan(0));
    // Ninguno de los dos cuenta como gasto ni como ingreso.
    expect(entra['kind'], 'ADJUSTMENT');
    expect(cierra['kind'], 'ADJUSTMENT');
  });
}
