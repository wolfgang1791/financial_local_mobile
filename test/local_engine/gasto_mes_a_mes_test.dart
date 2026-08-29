// El gasto mes a mes, partido en fijos, cuotas y vida.
//
// Las tres piezas viajan juntas porque quien mira la curva elige qué contar, y
// esa elección tiene que ser una resta en la pantalla y no otra llamada. "De la
// vida" es el complemento de lo comprometido: es la única pieza sobre la que
// tiene sentido preguntarse si va subiendo — el alquiler no sube porque hayas
// salido más.

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
    tmp = await prepararDirectorioTemporal('vida_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<List<Map<String, dynamic>>> serie() async =>
      (await api.get('/financial-engine/spending-history') as List).cast<Map<String, dynamic>>();

  /// Los totales de gasto del historial en un mes, por origen.
  Future<double> gastoDelMes(String mes, String origen) async {
    final partes = mes.split('-');
    final siguiente = partes[1] == '12'
        ? '${int.parse(partes[0]) + 1}-01'
        : '${partes[0]}-${(int.parse(partes[1]) + 1).toString().padLeft(2, '0')}';
    final r =
        await api.get(
              '/transactions?take=500&origen=$origen'
              '&from=$mes-01T05:00:00.000Z&to=$siguiente-01T04:59:59.000Z',
            )
            as Map;
    return ((r['totals'] as Map)['expense'] as num).toDouble();
  }

  test('cada mes suma solo el gasto suelto', () async {
    final s = await serie();
    expect(s, isNotEmpty);

    // Contra la misma pregunta hecha por el otro lado: el filtro "otros" del
    // historial. Si las dos no dan lo mismo, una de las dos miente.
    for (final punto in s) {
      final mes = punto['month'] as String;
      expect(
        (punto['life'] as num).toDouble(),
        closeTo(await gastoDelMes(mes, 'otros'), 0.01),
        reason: 'el mes $mes tiene que coincidir con el filtro "gastos de la vida"',
      );
    }
  });

  test('las tres piezas suman el total, y cada una es su filtro', () async {
    // Es lo que hace que apagar "gastos fijos" en la pantalla sea una resta y no
    // una mentira: si las piezas no suman el total, la curva filtrada muestra un
    // número que no existe en ningún otro sitio de la app.
    for (final punto in await serie()) {
      final mes = punto['month'] as String;
      final total = (punto['total'] as num).toDouble();
      final fijos = (punto['fixed'] as num).toDouble();
      final cuotas = (punto['debt'] as num).toDouble();
      final vida = (punto['life'] as num).toDouble();

      expect(fijos + cuotas + vida, closeTo(total, 0.01), reason: 'las piezas de $mes');
      expect(fijos, closeTo(await gastoDelMes(mes, 'fijos'), 0.01), reason: 'fijos de $mes');
      expect(cuotas, closeTo(await gastoDelMes(mes, 'deudas'), 0.01), reason: 'cuotas de $mes');
    }
  });

  test('no arranca antes del primer registro', () async {
    // Diez meses en cero antes de que la app existiera no son un dato: la línea
    // diría que gastabas nada en enero, y lo que pasa es que no había app.
    final s = await serie();
    final movimientos = (await api.get('/transactions?take=1000') as Map)['items'] as List;
    final primero = movimientos
        .map((t) => (t['occurredAt'] as String).substring(0, 7))
        .reduce((a, b) => a.compareTo(b) < 0 ? a : b);
    expect(s.first['month'], primero);
  });

  test('el mes en curso viene marcado', () async {
    final s = await serie();
    final ahora = DateTime.now();
    final mes = '${ahora.year}-${ahora.month.toString().padLeft(2, '0')}';
    expect(s.last['month'], mes);
    expect(s.last['inProgress'], isTrue);
    // Y ningún otro: comparar contra un mes cerrado es lo que da sentido a la
    // serie, y marcar dos como "en curso" rompería esa lectura.
    expect(s.where((p) => p['inProgress'] == true).length, 1);
  });
}
