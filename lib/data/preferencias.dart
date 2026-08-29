import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Las preferencias de vista, guardadas en un archivo al lado de la base.
///
/// No van en la base ni en el usuario: son de *cómo se mira*, no de la plata.
/// Meterlas en `User` habría creado una columna que el backend de verdad no
/// tiene, y con eso el clon local dejaría de ser un espejo — la próxima
/// migración que se copie tendría que acordarse de un campo que solo existe
/// acá.
///
/// Un archivo JSON y no una tabla porque es exactamente eso: un puñado de
/// claves que se leen enteras al abrir y se escriben enteras al cambiar. Si se
/// corrompe o desaparece, la app arranca con los valores por defecto — perder
/// una preferencia de vista no es perder nada.
class Preferencias {
  Preferencias._(this._archivo, this._valores);

  final File _archivo;
  final Map<String, dynamic> _valores;

  /// Se memoriza el **futuro**, no la instancia.
  ///
  /// Con la instancia había una carrera de verdad: dos llamadas a la vez —el
  /// tema leyendo lo guardado mientras el ojito escribe— encontraban el campo
  /// todavía en null, abrían el archivo las dos y creaban dos objetos con dos
  /// mapas distintos. El último en asignarse ganaba, y la escritura del otro se
  /// perdía en silencio. Con el futuro compartido, la segunda llamada espera a
  /// la primera y las dos trabajan sobre el mismo mapa.
  static Future<Preferencias>? _abriendo;

  static Future<Preferencias> abrir() => _abriendo ??= _abrir();

  static Future<Preferencias> _abrir() async {
    final dir = await getApplicationDocumentsDirectory();
    final archivo = File(p.join(dir.path, 'preferencias.json'));
    Map<String, dynamic> valores = {};
    if (await archivo.exists()) {
      try {
        final crudo = jsonDecode(await archivo.readAsString());
        if (crudo is Map<String, dynamic>) valores = crudo;
      } catch (_) {
        // Un archivo ilegible se trata como si no estuviera: la alternativa
        // sería no abrir la app por una preferencia rota.
      }
    }
    return Preferencias._(archivo, valores);
  }

  /// Solo para tests: obliga a releer desde disco en el próximo [abrir].
  static void olvidarParaTests() => _abriendo = null;

  bool bandera(String clave) => _valores[clave] == true;

  /// Una preferencia de tres estados, donde null es "sin decidir".
  bool? banderaOpcional(String clave) {
    final v = _valores[clave];
    return v is bool ? v : null;
  }

  Future<void> guardarBanderaOpcional(String clave, bool? valor) async {
    if (valor == null) {
      _valores.remove(clave);
    } else {
      _valores[clave] = valor;
    }
    await _archivo.writeAsString(jsonEncode(_valores));
  }

  Future<void> guardarBandera(String clave, bool valor) async {
    _valores[clave] = valor;
    await _archivo.writeAsString(jsonEncode(_valores));
  }

  List<String> listaDeTextos(String clave) =>
      ((_valores[clave] as List?) ?? const []).whereType<String>().toList();

  Future<void> guardarLista(String clave, List<String> valores) async {
    _valores[clave] = valores;
    await _archivo.writeAsString(jsonEncode(_valores));
  }
}

/// Las subcategorías marcadas en el calendario de días.
const claveMarcasDelCalendario = 'panorama.marcasDelCalendario';

/// Si las cifras de la tarjeta están tapadas.
const claveSaldosOcultos = 'saldos.ocultos';

/// El tema: true oscuro, false claro, ausente "lo que diga el sistema".
const claveTemaOscuro = 'tema.oscuro';
