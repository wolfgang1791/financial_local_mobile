// Poner el tipo de cambio a mano, con el que ya había como respaldo.
//
// La gracia no es guardar un número: es que **no reemplace** al anterior. La
// búsqueda toma siempre la cotización más reciente que no sea posterior al
// movimiento, así que la tuya manda de hoy en adelante y un pago fechado en
// julio se sigue convirtiendo con la de julio. Eso es lo que hace que quitarla
// devuelva a la anterior sin tener que volver a escribirla.

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
    tmp = await prepararDirectorioTemporal('tc_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<Map<String, dynamic>?> vigente(String fecha) async {
    final r = (await api.get('/currencies/rates?date=$fecha') as List).cast<Map<String, dynamic>>();
    return r.where((e) => e['baseCode'] == 'USD' && e['quoteCode'] == 'PEN').firstOrNull;
  }

  test('el tuyo manda desde su fecha, y lo anterior sigue en su sitio', () async {
    final antes = await vigente('2026-08-25');
    expect(antes, isNotNull, reason: 'la base sembrada trae una cotización');
    expect((antes!['sell'] as num).toDouble(), 3.417);

    await api.put('/currencies/rates', {
      'baseCode': 'USD',
      'quoteCode': 'PEN',
      'buy': 3.40,
      'sell': 3.50,
      'date': '2026-08-25',
    });

    expect((await vigente('2026-08-25'))!['sell'], 3.50);
    // Y julio no se entera: su cotización es la que era.
    expect(((await vigente('2026-07-31'))!['sell'] as num).toDouble(), 3.417);
  });

  test('quitar el tuyo devuelve al anterior', () async {
    await api.put('/currencies/rates', {
      'baseCode': 'USD',
      'quoteCode': 'PEN',
      'buy': 3.40,
      'sell': 3.50,
      'date': '2026-08-25',
    });
    await api.delete('/currencies/rates?base=USD&quote=PEN&date=2026-08-25');
    expect(((await vigente('2026-08-25'))!['sell'] as num).toDouble(), 3.417);
  });

  test('el cargado no se puede borrar: no es tuyo', () async {
    // Una cotización que vino cargada es el registro de lo que costaba ese día.
    await expectLater(
      api.delete('/currencies/rates?base=USD&quote=PEN&date=2026-07-30'),
      throwsA(isA<ApiException>()),
    );
    expect(((await vigente('2026-07-31'))!['sell'] as num).toDouble(), 3.417);
  });

  test('cero no es una cotización', () async {
    // Con un cero de por medio, una deuda en dólares valdría cero soles.
    await expectLater(
      api.put('/currencies/rates', {'baseCode': 'USD', 'quoteCode': 'PEN', 'buy': 0, 'sell': 3.5}),
      throwsA(isA<ApiException>()),
    );
  });

  test('sin fecha se guarda con el día del usuario, no con el de UTC', () async {
    final r =
        await api.put('/currencies/rates', {
              'baseCode': 'USD',
              'quoteCode': 'PEN',
              'buy': 3.41,
              'sell': 3.52,
            })
            as Map<String, dynamic>;

    // A las diez de la noche en Lima, `DateTime.now()` en UTC ya es mañana: si
    // se guardara así, el tipo de cambio de hoy quedaría fechado en un día que
    // no ha llegado y no lo usaría ningún pago de hoy.
    // Se calcula acá el día de Lima a mano, sin usar el reloj de la app: si se
    // preguntara con la misma herramienta que se está probando, el test pasaría
    // aunque las dos estuvieran equivocadas igual.
    final enLima = DateTime.now().toUtc().subtract(const Duration(hours: 5));
    String dd(int n) => n.toString().padLeft(2, '0');
    expect(
      (r['date'] as String).substring(0, 10),
      '${enLima.year}-${dd(enLima.month)}-${dd(enLima.day)}',
    );
  });
}
