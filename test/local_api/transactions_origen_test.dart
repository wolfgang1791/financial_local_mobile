// Filtrar el historial por de dónde viene el movimiento.
//
// No es una categoría —un pago de Internet **tiene** la categoría Internet—
// sino otra pregunta sobre el mismo movimiento: "¿esto lo decidí este mes o ya
// estaba comprometido?". Son los mismos dos conceptos que Panorama deja
// descontar en el calendario de días.

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
    tmp = await prepararDirectorioTemporal('transactions_origen_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<List<Map<String, dynamic>>> lista(String query) async =>
      ((await api.get('/transactions?take=200$query') as Map)['items'] as List)
          .cast<Map<String, dynamic>>();

  test('sin filtro vienen todos', () async {
    final todos = await lista('');
    expect(todos.any((t) => t['recurringFlowId'] != null), isTrue);
    expect(todos.any((t) => t['recurringFlowId'] == null), isTrue);
  });

  test('gastos fijos: solo los pagos de un flujo, y solo los de gasto', () async {
    final fijos = await lista('&origen=fijos');
    expect(fijos, isNotEmpty);
    expect(fijos.every((t) => t['recurringFlowId'] != null), isTrue);
    // Un sueldo también es un flujo recurrente. Sin acotar el tipo, la
    // pastilla "Gastos fijos" devolvía el cobro del sueldo entre los gastos:
    // la lista contradecía su propia etiqueta y no podía cuadrar con la
    // porción del anillo que muestra ese mismo número.
    expect(fijos.every((t) => t['type'] == 'EXPENSE'), isTrue);
  });

  test('los cuatro orígenes reparten lo que salió, sin solaparse', () async {
    final todos = await lista('');
    final gastoReal = todos
        .where((t) => t['type'] == 'EXPENSE' && t['kind'] == 'MOVEMENT')
        .map((t) => t['id'])
        .toSet();
    final ajustesTodos = todos.where((t) => t['kind'] != 'MOVEMENT').map((t) => t['id']).toSet();

    final porOrigen = <String, Set<Object?>>{};
    for (final origen in ['fijos', 'deudas', 'otros', 'ajustes']) {
      porOrigen[origen] = (await lista('&origen=$origen')).map((t) => t['id']).toSet();
    }

    // Nada en dos cajones a la vez...
    for (final a in porOrigen.keys) {
      for (final b in porOrigen.keys) {
        if (a == b) continue;
        expect(
          porOrigen[a]!.intersection(porOrigen[b]!),
          isEmpty,
          reason: 'una fila no puede estar en "$a" y en "$b"',
        );
      }
    }

    // ...los tres de gasto se reparten el gasto de verdad, entero. Es lo que
    // permite que el anillo de Panorama enlace cada porción a la lista de lo
    // que la compone: si faltara un gasto, alguna porción diría un número que
    // su lista no suma.
    final gasto = {...porOrigen['fijos']!, ...porOrigen['deudas']!, ...porOrigen['otros']!};
    expect(gasto, gastoReal);

    // Y el cuarto es exactamente los ajustes, en sus dos direcciones: son las
    // filas que hay detrás del neto que muestra el anillo.
    expect(porOrigen['ajustes'], ajustesTodos);
  });

  test('los ajustes salen del gasto de la vida y se cuentan en neto', () async {
    final vida = await lista('&origen=otros');
    expect(vida.every((t) => t['kind'] == 'MOVEMENT'), isTrue);

    final ajustes = await lista('&origen=ajustes');
    expect(ajustes, isNotEmpty, reason: 'la base sembrada tiene ajustes');
    expect(ajustes.every((t) => t['kind'] != 'MOVEMENT'), isTrue);

    // Las cifras del encabezado los separan igual: "Gastado" cuenta plata que
    // salió de verdad —cero acá, porque un ajuste no es un gasto— y los
    // ajustes van en la suya, con sus dos direcciones. El neto de esas dos es
    // lo que dice la porción del anillo.
    final r = await api.get('/transactions?take=200&origen=ajustes') as Map;
    final totales = r['totals'] as Map;
    final deAjustes = totales['adjustments'] as Map;
    expect((totales['expense'] as num).toDouble(), 0);
    expect((totales['income'] as num).toDouble(), 0);

    double suma(String tipo) => ajustes
        .where((t) => t['type'] == tipo)
        .fold<double>(0, (a, t) => a + (t['amount'] as num).toDouble());
    expect((deAjustes['income'] as num).toDouble(), closeTo(suma('INCOME'), 0.01));
    expect((deAjustes['expense'] as num).toDouble(), closeTo(suma('EXPENSE'), 0.01));
  });

  test('cuotas de deuda: solo las que tienen deuda detrás', () async {
    final deudas = await lista('&origen=deudas');
    // La base sembrada puede no tener cuotas todavía; lo que no puede es
    // colarse un movimiento sin deuda.
    expect(deudas.every((t) => t['debtId'] != null), isTrue);
  });

  test('un origen mal escrito no vacía la lista', () async {
    // Un filtro que llega con una errata no es motivo para no mostrar nada.
    final todos = await lista('');
    final raro = await lista('&origen=cualquiercosa');
    expect(raro.length, todos.length);
  });

  test('el origen se combina con la categoría', () async {
    final fijos = await lista('&origen=fijos');
    final conCategoria = fijos.firstWhere((t) => t['categoryId'] != null);
    final combinado = await lista('&origen=fijos&categoryId=${conCategoria['categoryId']}');
    expect(combinado, isNotEmpty);
    expect(
      combinado.every((t) => t['recurringFlowId'] != null),
      isTrue,
      reason: 'los dos filtros se suman, no se pisan',
    );
  });

  test('el orden por monto va de mayor a menor, y por fecha es el de siempre', () async {
    final porFecha = await lista('');
    final fechas = porFecha.map((t) => t['occurredAt'] as String).toList();
    expect(
      fechas,
      List<String>.from(fechas)..sort((a, b) => b.compareTo(a)),
      reason: 'sin pedir nada, el historial es una línea de tiempo',
    );

    final porMonto = await lista('&orden=monto');
    final montos = porMonto.map((t) => (t['amount'] as num).toDouble()).toList();
    expect(montos, List<double>.from(montos)..sort((a, b) => b.compareTo(a)));
    expect(montos.first, greaterThanOrEqualTo(montos.last));

    final ascendente = await lista('&orden=monto-asc');
    final subiendo = ascendente.map((t) => (t['amount'] as num).toDouble()).toList();
    expect(subiendo, List<double>.from(subiendo)..sort());
  });

  test('el orden no cambia qué movimientos hay, solo en qué orden', () async {
    // Es una vista, no un filtro: si además recortara la lista, las cifras del
    // encabezado cambiarían al reordenar y nadie entendería por qué.
    final a = (await lista('&origen=fijos')).map((t) => t['id']).toSet();
    final b = (await lista('&origen=fijos&orden=monto')).map((t) => t['id']).toSet();
    expect(b, a);
  });

  test('un orden mal escrito cae en la fecha, no vacía la lista', () async {
    final todos = await lista('');
    final raro = await lista('&orden=cualquiercosa');
    expect(raro.map((t) => t['id']).toList(), todos.map((t) => t['id']).toList());
  });
}
