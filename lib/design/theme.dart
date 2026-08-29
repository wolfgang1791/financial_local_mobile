import 'package:flutter/widgets.dart';

import 'tokens.dart';

/// El tema, servido por `InheritedWidget` y no por `Theme.of(context)`.
///
/// **La app no usa MaterialApp ni CupertinoApp.** No es purismo: el requisito es
/// que ningún feedback salga de un widget nativo, y en cuanto hay un
/// `MaterialApp` alrededor, cualquier `showDialog` o `SnackBar` que alguien
/// agregue en el futuro se ve nativo y "funciona", así que el error se cuela
/// solo. Sin ese andamio, escribir un diálogo de sistema exige salirse del
/// camino a propósito.
///
/// Lo que sí se toma prestado de Material son los widgets neutros —`Text`,
/// `Icon`, `GestureDetector`—, que no traen apariencia de plataforma.
class AppTheme extends InheritedWidget {
  const AppTheme({super.key, required this.colors, required super.child});

  final AppColors colors;

  static AppColors of(BuildContext context) {
    final theme = context.dependOnInheritedWidgetOfExactType<AppTheme>();
    assert(theme != null, 'AppTheme falta arriba en el árbol');
    return theme!.colors;
  }

  @override
  bool updateShouldNotify(AppTheme oldWidget) => colors != oldWidget.colors;
}

/// La tipografía del producto.
///
/// Los tamaños vienen de la web pero **no se copian tal cual**: en un teléfono
/// se lee más cerca y con menos ancho, así que el cuerpo sube un punto y los
/// títulos bajan. Un `text-2xl` de escritorio en una pantalla de 390 puntos
/// ocupa tres líneas y deja de ser un título.
///
/// **Las fuentes tampoco son las del sistema.** San Francisco en iOS y Roboto
/// en Android son dos tipografías distintas — la app se leía como dos
/// productos en vez de uno, justo lo que el resto del sistema de diseño
/// (colores, espaciado, iconos propios) existe para evitar. Se usan las
/// mismas dos que ya eligió la web y por el mismo motivo que allá: Plus
/// Jakarta Sans es geométrica pero cálida —terminales redondeados, el mismo
/// registro que las tarjetas `rounded-2xl` y la paleta pastel—, y IBM Plex
/// Mono para las cifras es una monoespaciada pensada para densidad de datos,
/// no para código. Empaquetadas como asset (`assets/fonts/`, ver
/// `pubspec.yaml`) y no vía `google_fonts`: así no dependen de una descarga
/// en el primer uso.
abstract final class AppText {
  static const _family = 'PlusJakartaSans';
  static const _familyMono = 'IBMPlexMono';

  /// Plus Jakarta Sans se empaqueta como fuente variable (un solo archivo,
  /// todos los pesos) y no como cuatro estáticas: el eje `wght` es lo que
  /// selecciona el peso real en tiempo de render. Sin esto, cualquier peso
  /// que no sea el de instancia por defecto del archivo se ve idéntico al
  /// resto — la fuente carga bien pero el texto en negrita deja de estar en
  /// negrita, un fallo silencioso que no tira ningún error.
  static List<FontVariation> _eje(FontWeight peso) => [
    FontVariation('wght', peso.value.toDouble()),
  ];

  static TextStyle display(Color c) => TextStyle(
    fontFamily: _family,
    fontVariations: _eje(FontWeight.w600),
    fontSize: 30,
    height: 1.1,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.6,
    color: c,
  );

  static TextStyle title(Color c) => TextStyle(
    fontFamily: _family,
    fontVariations: _eje(FontWeight.w600),
    fontSize: 20,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
    color: c,
  );

  static TextStyle sectionTitle(Color c) => TextStyle(
    fontFamily: _family,
    fontVariations: _eje(FontWeight.w600),
    fontSize: 16,
    height: 1.3,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    color: c,
  );

  static TextStyle body(Color c) => TextStyle(
    fontFamily: _family,
    fontVariations: _eje(FontWeight.w400),
    fontSize: 15,
    height: 1.45,
    color: c,
  );

  static TextStyle bodyMedium(Color c) => TextStyle(
    fontFamily: _family,
    fontVariations: _eje(FontWeight.w500),
    fontSize: 15,
    height: 1.45,
    fontWeight: FontWeight.w500,
    color: c,
  );

  static TextStyle small(Color c) => TextStyle(
    fontFamily: _family,
    fontVariations: _eje(FontWeight.w400),
    fontSize: 13,
    height: 1.4,
    color: c,
  );

  static TextStyle tiny(Color c) => TextStyle(
    fontFamily: _family,
    fontVariations: _eje(FontWeight.w400),
    fontSize: 11,
    height: 1.35,
    color: c,
  );

  /// El "kicker": la línea en versalitas sobre un título.
  static TextStyle kicker(Color c) => TextStyle(
    fontFamily: _family,
    fontVariations: _eje(FontWeight.w600),
    fontSize: 11,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.6,
    color: c,
  );

  /// Cifras. Monoespaciada y tabular para que las columnas de montos alineen —
  /// una columna de dinero que baila es ilegible. IBM Plex Mono va como cuatro
  /// pesos estáticos (Regular/Medium/SemiBold/Bold) y no variable, que es como
  /// lo publica su fuente de origen.
  static TextStyle money(Color c, {double size = 15, FontWeight weight = FontWeight.w500}) =>
      TextStyle(
        fontFamily: _familyMono,
        fontSize: size,
        height: 1.3,
        fontWeight: weight,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: c,
      );
}
