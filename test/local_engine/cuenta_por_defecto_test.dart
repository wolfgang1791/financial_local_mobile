// Qué cuenta proponen los formularios cuando preguntan de dónde salió la plata.
//
// Sin base de datos: es una regla sobre una lista de cuentas, y probarla contra
// la semilla la ataría a los datos que hoy tenga el usuario.

import 'package:financial_strategist_local/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sin ninguna elegida, se propone la primera cuenta corriente', () {
    const cuentasDePrueba = [
      Account(
        id: 'a',
        name: 'Efectivo',
        type: 'CASH',
        currency: 'PEN',
        balance: 10,
        isHidden: false,
      ),
      Account(
        id: 'b',
        name: 'Corriente',
        type: 'CHECKING',
        currency: 'PEN',
        balance: 20,
        isHidden: false,
      ),
      Account(
        id: 'c',
        name: 'Ahorros',
        type: 'SAVINGS',
        currency: 'PEN',
        balance: 30,
        isHidden: false,
        isPrimary: true,
      ),
    ];
    expect(cuentaPorDefecto(cuentasDePrueba)?.id, 'c', reason: 'manda la elegida');
    expect(
      cuentaPorDefecto(cuentasDePrueba.sublist(0, 2))?.id,
      'b',
      reason: 'sin elegida, la primera corriente',
    );
    expect(
      cuentaPorDefecto(const [
        Account(
          id: 'd',
          name: 'Tarjeta',
          type: 'CREDIT_CARD',
          currency: 'PEN',
          balance: 5,
          isHidden: false,
        ),
        Account(
          id: 'e',
          name: 'Billetera',
          type: 'CASH',
          currency: 'PEN',
          balance: 5,
          isHidden: false,
        ),
      ])?.id,
      'e',
      reason: 'nunca una tarjeta mientras haya de dónde sacar plata',
    );
  });
}
