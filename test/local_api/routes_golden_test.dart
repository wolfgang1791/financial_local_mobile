// Valores de oro: se compara la salida del router local contra la que dio
// el backend NestJS/Postgres real (`http://localhost:3002`), pedida a mano
// con curl para el mismo usuario ya migrado, en el momento de escribir este
// test. No pega la red durante el test —sería frágil, dependería de que el
// backend esté prendido— así que las cifras quedan fijas acá como
// constantes, con su origen documentado.

import 'dart:io';

import 'package:financial_strategist_local/data/api.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_support.dart';

void main() {
  late Directory tmp;
  late ApiClient api;

  // `rootBundle.load` (para copiar la base sembrada) necesita el binding de
  // servicios inicializado — en un test de widgets lo hace `pumpWidget`
  // solo, pero acá no hay ningún widget de por medio.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(inicializarMotorDePrueba);

  setUp(() async {
    tmp = await prepararDirectorioTemporal('financial_strategist_local_golden_test');
    api = ApiClient();
  });

  tearDown(() => tmp.delete(recursive: true));

  test('GET /accounts — mismas cuentas que el backend real', () async {
    final r = await api.get('/accounts') as List;
    expect(r.length, 4);

    final principal = r.firstWhere((a) => a['name'] == 'Cuenta principal');
    expect(principal['type'], 'CHECKING');
    expect((principal['currentBalance'] as num).toDouble(), 1931.45);
    expect(principal['isHidden'], false);

    // `/accounts` no filtra ocultas —eso lo hace `accountsProvider` en la
    // app—, así que las de ahorro tienen que seguir viniendo con `isHidden`.
    final ahorro = r.firstWhere((a) => a['name'] == 'Ahorro falabella');
    expect(ahorro['type'], 'SAVINGS');
    expect((ahorro['currentBalance'] as num).toDouble(), 2967.94);
    expect(ahorro['isHidden'], true);

    // La tarjeta de uso diario viaja con las demás: no es el espejo de una
    // deuda, así que se puede gastar y pagar con ella desde los mismos sitios.
    final cmr = r.firstWhere((a) => a['name'] == 'CMR');
    expect(cmr['type'], 'CREDIT_CARD');
    expect((cmr['currentBalance'] as num).toDouble(), 38.70);
  });

  test('GET /currencies — mismas 3 monedas activas, mismo orden', () async {
    final r = await api.get('/currencies') as List;
    expect(r.map((c) => c['code']).toList(), ['PEN', 'USD', 'EUR']);
    expect(r[0]['symbol'], 'S/');
    expect(r[0]['decimals'], 2);
  });

  test('GET /transactions?take=1000 — mismo total y mismas sumas que el backend real', () async {
    final r = await api.get('/transactions?take=1000') as Map;
    // `/accounts` no filtra ocultas, pero `/transactions` sí excluye las de una
    // cuenta oculta: por eso son menos filas que las que hay en la tabla entera.
    expect(r['total'], 177);
    final totals = r['totals'] as Map;
    expect((totals['income'] as num).toDouble(), 19706.14);
    expect((totals['expense'] as num).toDouble(), 17075.42);

    // Las tres más recientes, con su `balanceBefore` reconstruido — el
    // mismo que calculó `TransactionsService.balancesBefore` en el backend
    // real para esta misma cuenta y este mismo ledger.
    final items = r['items'] as List;
    expect((items[0]['balanceBefore'] as num).toDouble(), 2018.58);
    expect((items[1]['balanceBefore'] as num).toDouble(), 2008.58);
    expect((items[2]['balanceBefore'] as num).toDouble(), 2067.18);
  });

  test('GET /categories — trae el "general" de una categoría con hijas', () async {
    final r = await api.get('/categories') as List;
    final comida = r.firstWhere((c) => c['name'] == 'Comida y bebidas');
    expect(comida['parent'], isNull);
    expect(comida['isSystem'], true);

    final bar = r.firstWhere((c) => c['name'] == 'Bar' && c['parentId'] == comida['id']);
    expect((bar['parent'] as Map)['name'], 'Comida y bebidas');
  });
}
