import 'package:flutter/widgets.dart';

import '../ui/proximamente.dart';

/// Decisiones, esperando al agente.
///
/// Acá vivía un motor de reglas: recomendaciones calculadas, el informe de
/// cierre de mes y un chat contra un analizador propio. Se fue entero, backend
/// incluido. Esa capa —la que mira tus cifras y opina— la va a hacer el agente,
/// y mantener en paralelo una versión anterior del mismo trabajo solo
/// garantizaba dos opiniones distintas sobre los mismos números.
///
/// La sección se queda en su sitio, dicha como lo que es. Sacarla del menú
/// hubiera sido esconder el plan: la app se sigue leyendo como lo que va a ser,
/// y mientras tanto lo que hay debajo —el registro— es de verdad.
class DecisionesScreen extends StatelessWidget {
  const DecisionesScreen({super.key});

  @override
  Widget build(BuildContext context) => const Proximamente(
    icono: '🧭',
    titulo: 'Decisiones',
    descripcion:
        'Aquí va a vivir el agente: qué hacer hoy con tu dinero, leído de tus '
        'propios registros y explicado en tus términos.',
  );
}
