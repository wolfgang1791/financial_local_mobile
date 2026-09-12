import 'package:sqflite/sqflite.dart';

import '../local_api/current_user.dart';
import 'bundle.dart';

/// Traer al teléfono lo que pasó en la web.
///
/// Es el mismo sobre que manda el teléfono, viajando en la otra dirección — y
/// por eso lee el mismo formato—. Lo que cambia son las reglas, y cambian a
/// propósito:
///
/// **Acá la web manda.** Una fila que llega distinta se corrige con la de la
/// web, mientras que del otro lado un registro distinto se informa y se deja
/// intacto. No es una inconsistencia: la web es donde vive el dato bueno, y el
/// teléfono es una copia que se pone al día. Sin esta asimetría, una corrección
/// hecha en la web no llegaría nunca al teléfono, que es justo lo que se viene a
/// arreglar.
///
/// **No borra nada.** Una fila que está acá y no en el paquete es una de dos
/// cosas: algo que la web borró, o algo que registraste en el teléfono y
/// todavía no subiste. Ningún id distingue una de la otra, así que se cuentan y
/// se dicen —"tantas solo en el teléfono"— y quien mira decide. Borrarlas
/// "porque la web manda" se llevaría por delante lo que aún no viajó.
///
/// **El saldo no se recalcula.** Del otro lado hay que mover el saldo por cada
/// movimiento que entra, porque la web tiene su propia historia; acá la cuenta
/// llega entera, con su `currentBalance` ya hecho, y copiarla es exactamente lo
/// que se quiere. Sumar además los deltas contaría dos veces lo mismo.
class ConteoDeTabla {
  const ConteoDeTabla({
    required this.tabla,
    required this.nuevas,
    required this.actualizadas,
    required this.iguales,
    required this.soloEnElTelefono,
  });

  final String tabla;
  final int nuevas;
  final int actualizadas;
  final int iguales;

  /// Las que hay acá y el paquete no trae. No se tocan.
  final int soloEnElTelefono;

  int get cambios => nuevas + actualizadas;
}

class InformeDelPaquete {
  const InformeDelPaquete({
    required this.aplicado,
    required this.generadoEl,
    required this.porTabla,
    required this.avisos,
  });

  final bool aplicado;
  final String? generadoEl;
  final List<ConteoDeTabla> porTabla;
  final List<String> avisos;

  int get nuevas => porTabla.fold(0, (a, t) => a + t.nuevas);
  int get actualizadas => porTabla.fold(0, (a, t) => a + t.actualizadas);
  int get soloEnElTelefono => porTabla.fold(0, (a, t) => a + t.soloEnElTelefono);
  int get cambios => nuevas + actualizadas;
}

/// Lo que el paquete dice y este teléfono no puede aceptar.
class PaqueteInvalido implements Exception {
  const PaqueteInvalido(this.mensaje);
  final String mensaje;

  @override
  String toString() => mensaje;
}

/// Cómo guarda cada columna esta base, según lo que declara su esquema.
///
/// Se le pregunta a la base en vez de escribir la lista a mano: una columna que
/// el paquete traiga y acá no exista se descarta —son restos de esquema, no
/// datos— y una fecha que llega en ISO tiene que entrar como milisegundos, o el
/// registro del año pasado aparecería en 1970.
Future<({Set<String> columnas, Set<String> fechas, Set<String> booleanas})> _esquemaDe(
  Database db,
  String tabla,
) async {
  final info = await db.rawQuery('PRAGMA table_info("$tabla")');
  final columnas = <String>{};
  final fechas = <String>{};
  final booleanas = <String>{};
  for (final columna in info) {
    final nombre = columna['name'] as String;
    final tipo = ((columna['type'] as String?) ?? '').toUpperCase();
    columnas.add(nombre);
    if (tipo.contains('DATETIME') || tipo.contains('DATE')) fechas.add(nombre);
    if (tipo.contains('BOOL')) booleanas.add(nombre);
  }
  return (columnas: columnas, fechas: fechas, booleanas: booleanas);
}

/// Qué filas de las de acá son comparables con lo que trae el paquete.
///
/// El catálogo del sistema no viaja —vive igual en las dos bases, con los mismos
/// ids— así que las categorías del sistema no están en el paquete **por
/// diseño**. Contarlas como "solo en el teléfono" daba un aviso falso de cien y
/// pico filas en cada importación, y un aviso que siempre grita deja de leerse:
/// el día que de verdad haya algo sin subir, nadie lo vería.
bool _comparableConElPaquete(String tabla, Map<String, Object?> fila) =>
    tabla != 'Category' || (fila['isSystem'] as int? ?? 0) == 0;

Object? _paraGuardar(Object? valor, String columna, Set<String> fechas, Set<String> booleanas) {
  if (valor == null) return null;
  if (booleanas.contains(columna)) {
    if (valor is bool) return valor ? 1 : 0;
    if (valor is num) return valor == 0 ? 0 : 1;
  }
  if (fechas.contains(columna) && valor is String) {
    return DateTime.parse(valor).toUtc().millisecondsSinceEpoch;
  }
  if (valor is bool) return valor ? 1 : 0;
  return valor;
}

/// Si dos valores dicen lo mismo. Los decimales se comparan redondeados: el
/// mismo importe puede volver como 87.32 o 87.32000000000001 según por dónde
/// pasó, y tratarlo como un cambio haría "actualizar" filas idénticas en cada
/// importación.
bool _igual(Object? mio, Object? suyo) {
  if (mio is num && suyo is num) {
    return (mio - suyo).abs() < 0.000001 ||
        double.parse(mio.toStringAsFixed(2)) == double.parse(suyo.toStringAsFixed(2));
  }
  return mio == suyo;
}

Future<InformeDelPaquete> aplicarPaqueteDeLaWeb(
  Database db,
  Map<String, dynamic> paquete, {
  required bool ensayo,
}) async {
  if (paquete['formato'] != formatoDelPaquete) {
    throw const PaqueteInvalido(
      'Ese archivo no es un paquete de Financial Strategist. En la web: '
      'Movimientos → Importar del teléfono → Descargar el paquete.',
    );
  }
  if (paquete['version'] != versionDelPaquete) {
    throw PaqueteInvalido(
      'El paquete es de la versión ${paquete['version']} y esta app entiende la '
      '$versionDelPaquete. Actualiza la app y vuelve a bajarlo.',
    );
  }
  final userId = await currentUserId(db);
  if (paquete['userId'] != null && paquete['userId'] != userId) {
    throw const PaqueteInvalido(
      'Ese paquete es de otra cuenta. Solo puedes traer tus propios datos.',
    );
  }

  final tablas = (paquete['tablas'] as Map<String, dynamic>?) ?? const {};
  final conteos = <ConteoDeTabla>[];
  // Qué escribir, resuelto antes de tocar nada: así el ensayo y la aplicación
  // salen exactamente del mismo cálculo y no pueden decir cosas distintas.
  final inserciones = <({String tabla, Map<String, Object?> fila})>[];
  final actualizaciones = <({String tabla, String id, Map<String, Object?> fila})>[];

  for (final tabla in tablasDelPaquete) {
    final filas = (tablas[tabla] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    final esquema = await _esquemaDe(db, tabla);
    final locales = {for (final fila in await db.query(tabla)) fila['id'] as String: fila};

    var nuevas = 0;
    var actualizadas = 0;
    var iguales = 0;
    final idsDelPaquete = <String>{};

    for (final fila in filas) {
      final id = fila['id'] as String?;
      if (id == null) continue;
      idsDelPaquete.add(id);

      final valores = <String, Object?>{};
      for (final entrada in fila.entries) {
        if (!esquema.columnas.contains(entrada.key)) continue;
        valores[entrada.key] = _paraGuardar(
          entrada.value,
          entrada.key,
          esquema.fechas,
          esquema.booleanas,
        );
      }

      final local = locales[id];
      if (local == null) {
        nuevas++;
        inserciones.add((tabla: tabla, fila: valores));
        continue;
      }

      final cambio = valores.entries.any((e) => !_igual(local[e.key], e.value));
      if (!cambio) {
        iguales++;
        continue;
      }
      actualizadas++;
      actualizaciones.add((tabla: tabla, id: id, fila: valores));
    }

    conteos.add(
      ConteoDeTabla(
        tabla: tabla,
        nuevas: nuevas,
        actualizadas: actualizadas,
        iguales: iguales,
        soloEnElTelefono: locales.entries
            .where((e) => !idsDelPaquete.contains(e.key) && _comparableConElPaquete(tabla, e.value))
            .length,
      ),
    );
  }

  final informe = InformeDelPaquete(
    aplicado: false,
    generadoEl: paquete['generadoEl'] as String?,
    porTabla: conteos,
    avisos: [
      if (conteos.any((c) => c.soloEnElTelefono > 0))
        'Hay registros que están acá y no en el paquete: o los borraste en la web, o los '
            'anotaste en el teléfono y todavía no los subiste. No se tocan.',
    ],
  );
  if (ensayo) return informe;

  // Todo junto o nada: a medias quedarían movimientos sin su cuenta, o cuentas
  // con un saldo que ya no corresponde a sus filas.
  await db.transaction((txn) async {
    for (final i in inserciones) {
      await txn.insert(i.tabla, i.fila);
    }
    for (final a in actualizaciones) {
      await txn.update(a.tabla, a.fila, where: 'id = ?', whereArgs: [a.id]);
    }
  });

  return InformeDelPaquete(
    aplicado: true,
    generadoEl: informe.generadoEl,
    porTabla: informe.porTabla,
    avisos: informe.avisos,
  );
}
