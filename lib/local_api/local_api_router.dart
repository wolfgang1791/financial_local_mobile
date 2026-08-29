import 'package:sqflite/sqflite.dart';

import '../data/api.dart' show ApiException;

/// Qué hacer con un método+ruta ya resuelto contra la base local. Cada fase
/// del port agrega sus rutas acá — hoy (Fase 0) no hay ninguna todavía, así
/// que cualquier llamada explica claramente que esa parte del clon local
/// todavía no existe, en vez de fallar con un error de red que no aplica.
typedef RouteHandler = Future<dynamic> Function(Database db, Uri uri, Object? body);

/// Convierte el `body` que llegó al handler en un `Map<String, dynamic>`
/// de verdad. Hace falta porque `const {}` —lo que mandan varias pantallas
/// cuando no hay nada que decir, como "marcar pagado" sin monto distinto—
/// llega tipado como `Map<dynamic, dynamic>`, y un `as Map<String, dynamic>`
/// directo revienta con ese tipo aunque el mapa esté vacío.
Map<String, dynamic> bodyAsMap(Object? body) {
  if (body == null) return const {};
  return Map<String, dynamic>.from(body as Map);
}

/// Un campo de texto que el cuerpo tiene que traer sí o sí.
///
/// Existe para que falte un campo y se diga, en vez de reventar con un error de
/// casteo. La diferencia no es cosmética: la pantalla distingue `ApiException`
/// —que muestra su mensaje— de cualquier otro error —que muestra "no llegué al
/// servidor"—, así que un `as String` sobre un null mandaba al usuario a buscar
/// el problema en la red cuando estaba en el formulario. Un fallo que miente
/// sobre dónde está cuesta más que el fallo.
String campoObligatorio(Map<String, dynamic> datos, String campo) {
  final valor = datos[campo];
  if (valor is String && valor.isNotEmpty) return valor;
  throw ApiException('Falta "$campo".');
}

/// El router local: hace lo que hacía el servidor NestJS, pero en el mismo
/// proceso y contra SQLite en vez de Postgres. `ApiClient` le pasa método +
/// ruta tal cual las arman hoy los providers/pantallas (`/accounts`,
/// `/transactions?take=40`, `/debts/{id}/pay`, ...) y este decide qué
/// función local responde — el mismo trabajo que hacían los `@Controller`
/// de Nest, sin el salto de red.
abstract final class LocalApiRouter {
  static final Map<String, RouteHandler> _get = {};
  static final Map<String, RouteHandler> _post = {};
  static final Map<String, RouteHandler> _patch = {};
  static final Map<String, RouteHandler> _put = {};
  static final Map<String, RouteHandler> _delete = {};

  static void registerGet(String patron, RouteHandler handler) => _get[patron] = handler;
  static void registerPost(String patron, RouteHandler handler) => _post[patron] = handler;
  static void registerPatch(String patron, RouteHandler handler) => _patch[patron] = handler;
  static void registerPut(String patron, RouteHandler handler) => _put[patron] = handler;
  static void registerDelete(String patron, RouteHandler handler) => _delete[patron] = handler;

  static Future<dynamic> dispatch(Database db, String method, String path, [Object? body]) async {
    final uri = Uri.parse(path);
    final tabla = switch (method) {
      'GET' => _get,
      'POST' => _post,
      'PATCH' => _patch,
      'PUT' => _put,
      'DELETE' => _delete,
      _ => throw ApiException('Método no soportado: $method'),
    };

    final segmentos = uri.pathSegments;
    for (final entry in tabla.entries) {
      final params = _match(entry.key, segmentos);
      if (params != null) {
        final uriConParams = uri.replace(queryParameters: {...uri.queryParameters, ...params});
        return entry.value(db, uriConParams, body);
      }
    }

    throw ApiException(
      'Esta parte del clon local todavía no está portada: $method $path',
      status: 501,
    );
  }

  /// Compara un patrón tipo `/debts/:id/pay` contra los segmentos reales de
  /// la ruta pedida. Los `:nombre` se capturan como query params extra, así
  /// el handler los lee del mismo `Uri` que los filtros de verdad
  /// (`?take=40`) sin necesitar un segundo mecanismo.
  static Map<String, String>? _match(String patron, List<String> segmentos) {
    final partesPatron = Uri.parse(patron).pathSegments;
    if (partesPatron.length != segmentos.length) return null;
    final params = <String, String>{};
    for (var i = 0; i < partesPatron.length; i++) {
      final parte = partesPatron[i];
      if (parte.startsWith(':')) {
        params[parte.substring(1)] = segmentos[i];
      } else if (parte != segmentos[i]) {
        return null;
      }
    }
    return params;
  }
}
