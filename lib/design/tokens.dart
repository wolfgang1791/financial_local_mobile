import 'package:flutter/widgets.dart';

/// Los colores del producto, portados de `globals.css` del frontend web.
///
/// Se copian los valores en vez de inventar unos nuevos "que peguen": son el
/// mismo producto, y dos paletas que se parecen pero no son iguales es peor que
/// dos que se distinguen — el usuario nota que algo cambió y no sabe qué.
///
/// Cada color existe en claro y oscuro. No hay un "modo por defecto": la app
/// sigue al sistema, igual que la web, y por eso el tema no se elige nunca a
/// mano en un widget.
@immutable
class AppColors {
  const AppColors({
    required this.background,
    required this.foreground,
    required this.surface,
    required this.surfaceBorder,
    required this.sage,
    required this.sageDark,
    required this.sageInk,
    required this.mint,
    required this.mintSoft,
    required this.olive,
    required this.oliveInk,
    required this.danger,
    required this.positiveBalance,
    required this.chart,
    required this.chartOther,
    required this.glow,
  });

  final Color background;
  final Color foreground;

  /// La superficie de una tarjeta. En claro es casi blanco; en oscuro es un
  /// gris azulado que se levanta del fondo sin llegar a blanco.
  final Color surface;
  final Color surfaceBorder;

  /// El azul de acción. Se llama `sage` por herencia del diseño original —el
  /// nombre quedó de una paleta verde anterior— y se conserva para que buscar
  /// "sage" encuentre lo mismo en los dos repos.
  final Color sage;
  final Color sageDark;

  /// Tinta sobre fondo claro: el azul oscuro que sí tiene contraste para texto.
  final Color sageInk;
  final Color mint;
  final Color mintSoft;

  /// Texto secundario en oscuro.
  final Color olive;

  /// Texto secundario en claro.
  final Color oliveInk;
  final Color danger;

  /// El verde del "saldo anterior" en Últimos movimientos — deliberadamente
  /// distinto del azul de marca (`sageInk`). En la web es
  /// `text-emerald-600 dark:text-emerald-400`, no `text-sage-ink`.
  final Color positiveBalance;

  /// La paleta categórica de los gráficos, en orden fijo.
  ///
  /// **El orden no se cicla ni se reordena.** Una categoría conserva su color
  /// aunque cambie de posición: si el color siguiera al ranking, filtrar
  /// repintaría el gráfico entero y dejaría de ser reconocible.
  final List<Color> chart;

  /// El gris del cajón "Otras categorías". Neutro a propósito: no es una
  /// categoría, es el resto.
  final Color chartOther;

  /// El halo de color del fondo. En la web son tres `radial-gradient`; acá se
  /// pintan igual pero con un `RadialGradient` por capa.
  final List<Color> glow;

  static const light = AppColors(
    background: Color(0xFFE8DCC0),
    foreground: Color(0xFF171717),
    surface: Color(0xFFFDFCF8),
    surfaceBorder: Color(0x1F0A8FCD),
    sage: Color(0xFF24B3F5),
    sageDark: Color(0xFF0A8FCD),
    sageInk: Color(0xFF0A5A7F),
    mint: Color(0xFF81D4FA),
    mintSoft: Color(0xFFE1F5FE),
    olive: Color(0xFFA4C3D2),
    oliveInk: Color(0xFF1D5E63),
    danger: Color(0xFFDC2626),
    positiveBalance: Color(0xFF059669),
    chart: [
      Color(0xFF2A78D6),
      Color(0xFFEB6834),
      Color(0xFF1BAF7A),
      Color(0xFFEDA100),
      Color(0xFFE87BA4),
      Color(0xFF008300),
      Color(0xFF4A3AA7),
      Color(0xFFE34948),
    ],
    chartOther: Color(0xFF9A9A92),
    glow: [Color(0x8CE1F5FE), Color(0x2424B3F5), Color(0x3381D4FA)],
  );

  static const dark = AppColors(
    background: Color(0xFF222D35),
    foreground: Color(0xFFEDEDED),
    surface: Color(0xFF2A3740),
    surfaceBorder: Color(0x2624B3F5),
    sage: Color(0xFF24B3F5),
    sageDark: Color(0xFF0A8FCD),
    sageInk: Color(0xFF24B3F5),
    mint: Color(0xFF81D4FA),
    mintSoft: Color(0xFF1B3A4A),
    olive: Color(0xFFA4C3D2),
    oliveInk: Color(0xFFA4C3D2),
    danger: Color(0xFFF87171),
    positiveBalance: Color(0xFF34D399),
    chart: [
      Color(0xFF3987E5),
      Color(0xFFD95926),
      Color(0xFF199E70),
      Color(0xFFC98500),
      Color(0xFFD55181),
      Color(0xFF008300),
      Color(0xFF9085E9),
      Color(0xFFE66767),
    ],
    chartOther: Color(0xFF7A7A72),
    glow: [Color(0x2924B3F5), Color(0x1A24B3F5), Color(0x1A81D4FA)],
  );

  /// El color de una porción por su posición, sin ciclar más allá de la paleta.
  Color chartAt(int index) => chart[index % chart.length];
}

/// Espaciado en una escala de 4, la misma de Tailwind.
///
/// Constantes con nombre y no números sueltos: `Spacing.md` dice que ese hueco
/// es el mismo que el de al lado, y `12` no dice nada.
abstract final class Spacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
  static const section = 32.0;
}

abstract final class Radii {
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const pill = 999.0;
}
