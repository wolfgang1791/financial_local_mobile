// La deuda mes a mes: que el desglose sume la cuota y que el saldo de cierre
// sea el que de verdad se debía.
//
// Es aritmética reconstruida hacia atrás desde el saldo de hoy, que es la parte
// fácil de equivocar: un mes corrido deja el gráfico contando una historia que
// no pasó.

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
    tmp = await prepararDirectorioTemporal('debts_history_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<List<Map<String, dynamic>>> mesesDe(String moneda) async {
    final r = await api.get('/debts/history') as List;
    final serie = r.cast<Map<String, dynamic>>().firstWhere((s) => s['currency'] == moneda);
    return (serie['months'] as List).cast<Map<String, dynamic>>();
  }

  test('la serie arranca donde hay algo que contar y llega hasta hoy', () async {
    final meses = await mesesDe('PEN');
    expect(meses, isNotEmpty);

    // Nada de ceros al principio: con una deuda de julio, los meses anteriores
    // aplastarían el gráfico contra el borde derecho sin contar nada.
    expect(
      (meses.first['paid'] as num) > 0 || (meses.first['balance'] as num) > 0,
      isTrue,
      reason: 'el primer mes tiene datos',
    );
    expect(meses.length, lessThanOrEqualTo(12));

    // Pero seguidos: un hueco *entre* dos meses con datos sí informa —ese mes
    // no se pagó— y tiene que seguir apareciendo como hueco, no faltar. Si
    // faltara, dos meses no consecutivos quedarían pegados en el gráfico.
    for (var i = 1; i < meses.length; i++) {
      expect(_mesSiguiente(meses[i - 1]['month'] as String), meses[i]['month']);
    }
  });

  test('el desglose reparte exactamente lo pagado', () async {
    // Nada se pierde entre capital, interés y cargos: el interés se deriva como
    // el resto justamente para que las tres partes sumen la cuota. Si sumaran
    // de menos, el gráfico dibujaría una barra más corta que el pago.
    for (final m in await mesesDe('PEN')) {
      final partes = (m['principal'] as num) + (m['interest'] as num) + (m['other'] as num);
      expect(partes, closeTo((m['paid'] as num).toDouble(), 0.01), reason: 'en ${m['month']}');
    }
  });

  test('el saldo del último mes es el que se debe hoy', () async {
    final deudas = await api.get('/debts') as List;
    final hoyPen = deudas
        .cast<Map<String, dynamic>>()
        .where((d) => (d['account'] as Map)['currency'] == 'PEN')
        .fold<double>(0, (a, d) => a + (d['currentBalance'] as num).toDouble());

    final meses = await mesesDe('PEN');
    expect((meses.last['balance'] as num).toDouble(), closeTo(hoyPen, 0.01));
  });

  test('pagar una cuota baja el saldo del mes y aparece en su desglose', () async {
    final antes = await mesesDe('PEN');
    final saldoAntes = (antes.last['balance'] as num).toDouble();
    final capitalAntes = (antes.last['principal'] as num).toDouble();
    final pagadoAntes = (antes.last['paid'] as num).toDouble();

    final deuda = (await api.get('/debts') as List).cast<Map<String, dynamic>>().firstWhere(
      (d) => (d['account'] as Map)['currency'] == 'PEN' && (d['currentBalance'] as num) > 0,
    );
    final cuentas = await api.get('/accounts') as List;

    // La cuota entera y no un monto suelto: pagando poco todo se va en interés
    // —primero se cubre el del período— y el capital no se movería, que es
    // justo lo que este test quiere ver moverse.
    await api.post('/debts/${deuda['id']}/pay', {
      'accountId': (cuentas.first as Map)['id'],
      'amount': deuda['installmentAmount'],
    });

    final despues = await mesesDe('PEN');
    // Lo pagado entra en el mes en curso...
    expect((despues.last['paid'] as num).toDouble(), greaterThan(pagadoAntes));
    expect((despues.last['principal'] as num).toDouble(), greaterThan(capitalAntes));
    // ...y el saldo de cierre baja exactamente por el capital amortizado, no
    // por lo pagado: lo que se fue en interés no bajó la deuda.
    final capitalNuevo = (despues.last['principal'] as num).toDouble() - capitalAntes;
    expect((despues.last['balance'] as num).toDouble(), closeTo(saldoAntes - capitalNuevo, 0.01));
  });
}

String _mesSiguiente(String clave) {
  final partes = clave.split('-');
  final anio = int.parse(partes[0]);
  final mes = int.parse(partes[1]);
  final siguiente = mes == 12 ? DateTime(anio + 1, 1) : DateTime(anio, mes + 1);
  return '${siguiente.year}-${siguiente.month.toString().padLeft(2, '0')}';
}
