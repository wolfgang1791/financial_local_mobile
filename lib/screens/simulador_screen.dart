import 'package:flutter/widgets.dart';

import '../ui/proximamente.dart';

/// Simulador: marcador, igual que en la web.
class SimuladorScreen extends StatelessWidget {
  const SimuladorScreen({super.key});

  @override
  Widget build(BuildContext context) => const Proximamente(
    icono: '🧮',
    titulo: 'Simulador',
    descripcion:
        'Simula escenarios — perder un ingreso, un gasto puntual, un aumento — '
        'y mira el impacto antes de que pase.',
  );
}
