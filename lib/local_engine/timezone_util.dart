import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Todo lo que traduce entre "un instante" y "qué día es para el usuario" —
/// puerto directo de `backend/src/common/timezone.util.ts`.
///
/// Allá esto se resolvía a mano con `Intl.DateTimeFormat` porque Node no
/// trae la conversión inversa (hora de pared → instante). Acá el paquete
/// `timezone` ya la resuelve — su `TZDateTime` hace exactamente esa
/// inversión, consciente de horario de verano, así que no hace falta
/// reimplementar el ida-y-vuelta de dos pasos del backend: es el mismo
/// resultado por otro camino.
///
/// [inicializarZonas] se llama una sola vez, al arrancar la app (ver
/// `bootstrap()` en `app.dart`) — antes de eso, [getLocation] no encuentra
/// ninguna zona.

class ZonedParts {
  const ZonedParts({
    required this.year,
    required this.month,
    required this.day,
    required this.hour,
    required this.minute,
    required this.second,
  });

  final int year;
  final int month; // 1-12
  final int day;
  final int hour;
  final int minute;
  final int second;
}

void inicializarZonas() => tzdata.initializeTimeZones();

tz.Location _location(String timeZone) {
  try {
    return tz.getLocation(timeZone);
  } catch (_) {
    // Mismo fallback que `DEFAULT_TIMEZONE` del backend: una zona que el
    // usuario nunca guardó (o que ya no existe en la base de zonas) no
    // puede tumbar toda pantalla que calcule una fecha.
    //
    // `tz.UTC` y no `getLocation('UTC')`: en la base de zonas esa zona se llama
    // "Etc/UTC", así que buscarla por "UTC" lanza —y lanzaba **desde dentro del
    // catch**, que es la peor forma de fallar: el rescate reventaba con el mismo
    // error que venía a evitar. Con un usuario en UTC, cualquier pantalla que
    // calculara una fecha se caía entera.
    return tz.UTC;
  }
}

/// Qué hora marca el reloj de esa zona en ese instante.
ZonedParts zonedParts(DateTime instant, String timeZone) {
  final t = tz.TZDateTime.from(instant, _location(timeZone));
  return ZonedParts(
    year: t.year,
    month: t.month,
    day: t.day,
    hour: t.hour,
    minute: t.minute,
    second: t.second,
  );
}

/// La operación inversa: de hora de pared a instante (siempre UTC, para no
/// filtrar el tipo `TZDateTime` fuera de este archivo).
DateTime instantFromZonedTime(
  String timeZone, {
  required int year,
  required int month,
  required int day,
  int hour = 0,
  int minute = 0,
  int second = 0,
}) {
  final t = tz.TZDateTime(_location(timeZone), year, month, day, hour, minute, second);
  return DateTime.fromMillisecondsSinceEpoch(t.millisecondsSinceEpoch, isUtc: true);
}

/// "2026-07-31" → el instante en que empieza ese día para el usuario.
DateTime startOfDayInZone(String date, String timeZone) {
  final partes = date.split('-').map(int.parse).toList();
  return instantFromZonedTime(timeZone, year: partes[0], month: partes[1], day: partes[2]);
}

final RegExp _soloFecha = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// Lo que manda un formulario puede ser una fecha sola ("2026-07-31") o un
/// instante completo (ISO con hora). La fecha sola se ancla al inicio de ese
/// día en la zona del usuario; el instante se respeta tal cual.
DateTime toInstant(String value, String timeZone) {
  if (_soloFecha.hasMatch(value)) return startOfDayInZone(value, timeZone);
  return DateTime.parse(value);
}

DateTime startOfMonthInZone(DateTime instant, String timeZone) {
  final p = zonedParts(instant, timeZone);
  return instantFromZonedTime(timeZone, year: p.year, month: p.month, day: 1);
}

/// El último instante del mes: el arranque del siguiente menos un
/// milisegundo — evita tener que saber cuántos días tiene el mes.
DateTime endOfMonthInZone(DateTime instant, String timeZone) {
  final p = zonedParts(instant, timeZone);
  final siguienteMes = p.month == 12 ? 1 : p.month + 1;
  final siguienteAnio = p.month == 12 ? p.year + 1 : p.year;
  final inicioSiguiente = instantFromZonedTime(
    timeZone,
    year: siguienteAnio,
    month: siguienteMes,
    day: 1,
  );
  return inicioSiguiente.subtract(const Duration(milliseconds: 1));
}

/// Mueve [count] meses desde el mes en que cae [instant], y devuelve su
/// inicio.
DateTime addMonthsInZone(DateTime instant, int count, String timeZone) {
  final p = zonedParts(instant, timeZone);
  final zeroBased = p.month - 1 + count;
  final anio = p.year + (zeroBased / 12).floor();
  final mes = (((zeroBased % 12) + 12) % 12) + 1;
  return instantFromZonedTime(timeZone, year: anio, month: mes, day: 1);
}

/// "2026-07"
String monthKeyInZone(DateTime instant, String timeZone) {
  final p = zonedParts(instant, timeZone);
  return '${p.year}-${p.month.toString().padLeft(2, '0')}';
}
