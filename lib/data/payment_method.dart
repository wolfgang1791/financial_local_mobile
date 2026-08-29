/// Los medios de pago, con los mismos códigos y las mismas etiquetas que la web.
///
/// Los códigos son los que guarda la columna `paymentMethod` y los que entiende
/// el backend real; las etiquetas son las de `PAYMENT_METHOD_LABEL`, copiadas
/// palabra por palabra. Dos listas que se parecen pero no son iguales —"Tarjeta
/// débito" acá y "Tarjeta de débito" allá— son el mismo dato contado de dos
/// formas, y quien exporta desde los dos lados termina con dos columnas que no
/// cruzan.
///
/// El orden tampoco es alfabético ni casual: es el de la web, de lo más común a
/// lo menos en un bolsillo peruano.
abstract final class MediosDePago {
  static const opciones = <(String codigo, String etiqueta)>[
    ('CASH', 'Efectivo'),
    ('BANK_TRANSFER', 'Transferencia bancaria'),
    ('PLIN', 'Plin'),
    ('YAPE', 'Yape'),
    ('DEBIT_CARD', 'Tarjeta de débito'),
    ('CREDIT_CARD', 'Tarjeta de crédito'),
  ];

  /// Lo que se muestra cuando un movimiento no lo tiene. No es un medio de pago
  /// más: es la ausencia de uno, y por eso nunca se guarda como código.
  static const sinEspecificar = 'Sin especificar';

  /// La etiqueta de un código, o `null` si no hay medio de pago.
  ///
  /// Un código que esta versión no conoce —uno que agregó el backend después—
  /// se devuelve tal cual en vez de desaparecer: un dato feo a la vista es mejor
  /// que un dato que se perdió sin avisar.
  static String? etiqueta(String? codigo) {
    if (codigo == null || codigo.isEmpty) return null;
    for (final (c, e) in opciones) {
      if (c == codigo) return e;
    }
    return codigo;
  }
}
