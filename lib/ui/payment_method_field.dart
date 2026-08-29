import 'package:flutter/widgets.dart';

import '../data/payment_method.dart';
import 'fields.dart';
import 'modal.dart';

/// El selector de medio de pago: la lista fija de [MediosDePago] más la opción
/// de dejarlo en blanco.
///
/// Devuelve `null` si se cerró la hoja sin elegir, y un registro con `codigo`
/// —que puede ser `null`— si se eligió algo. Los dos casos hay que poder
/// distinguirlos: "salí sin tocar nada" tiene que dejar el campo como estaba, y
/// "elegí Sin especificar" tiene que borrarlo. Con un `String?` pelado los dos
/// llegarían como `null` y no habría forma de quitarle el medio de pago a un
/// movimiento que ya lo tenía.
Future<({String? codigo})?> elegirMedioDePago(BuildContext context, {String? actual}) {
  return showAppModal<({String? codigo})>(
    context,
    title: 'Medio de pago',
    builder: (context) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldOption(
          titulo: MediosDePago.sinEspecificar,
          seleccionado: actual == null,
          onTap: () => Navigator.of(context).pop((codigo: null)),
        ),
        for (final (codigo, etiqueta) in MediosDePago.opciones)
          FieldOption(
            titulo: etiqueta,
            seleccionado: actual == codigo,
            onTap: () => Navigator.of(context).pop((codigo: codigo)),
          ),
      ],
    ),
  );
}
