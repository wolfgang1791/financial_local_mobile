import 'package:flutter/widgets.dart';

import '../ui/proximamente.dart';

/// Los objetivos vuelven con el agente.
///
/// Tenían su propio motor: una escalera de metas trazada desde tus cifras, con
/// propuestas que se adoptaban. Se fue con el resto de la capa de consejo — es
/// trabajo que el agente hace mejor con el contexto entero, y dos sistemas
/// proponiendo metas sobre los mismos números es la forma segura de que se
/// contradigan.
class ObjetivosScreen extends StatelessWidget {
  const ObjetivosScreen({super.key});

  @override
  Widget build(BuildContext context) => const Proximamente(
    icono: '🎯',
    titulo: 'Objetivos',
    descripcion:
        'A dónde quieres llegar —salir de deudas, un fondo de emergencia, una '
        'mudanza— y si lo que haces cada mes te acerca o te aleja.',
  );
}
