import 'dart:convert';
import 'dart:typed_data';

import 'package:excel/excel.dart' as xl;

import 'models.dart';
import 'payment_method.dart';

enum ExportFormat { csv, xlsx, json, md }

/// El tope de filas del backend (`movimientos/exportar/route.ts`). Se corta
/// acá y no en el servidor, pero la regla es la misma: nunca en silencio —
/// [ExportResult.recortado] es lo que deja avisar.
const _topeFilas = 1000;

class ExportResult {
  const ExportResult({
    required this.bytes,
    required this.filename,
    required this.mimeType,
    required this.recortado,
  });

  final Uint8List bytes;
  final String filename;
  final String mimeType;

  /// Si había más de 1000 movimientos y el archivo no los trae todos.
  final bool recortado;
}

/// La foto de lo que tienes y lo que debes, a hoy.
///
/// Va con los movimientos y no en otra descarga porque contestan la misma
/// pregunta a dos escalas: el periodo dice qué pasó, y esto dice en qué te dejó.
/// Un archivo de movimientos sin saldos obliga a reconstruirlos sumando, que es
/// justo el trabajo que la app hace por ti.
///
/// **No es del periodo, es de hoy.** Los saldos de un mes cerrado no se pueden
/// reconstruir cuenta por cuenta —los hitos guardan el total— así que
/// inventarlos sería peor que decir cuándo se tomó la foto.
class PatrimonioLinea {
  const PatrimonioLinea({
    required this.grupo,
    required this.tipo,
    required this.nombre,
    required this.saldo,
    required this.moneda,
    required this.enPatrimonio,
    required this.detalle,
  });

  final String grupo;
  final String tipo;
  final String nombre;

  /// Firmado: lo que tienes en positivo, lo que debes en negativo. Sin signo,
  /// quien sume la columna obtiene un número que no es ninguna cifra que exista.
  final double saldo;
  final String moneda;
  final String enPatrimonio;
  final String detalle;

  List<String> get celdas => [
    grupo,
    tipo,
    nombre,
    saldo.toStringAsFixed(2),
    moneda,
    enPatrimonio,
    detalle,
  ];
}

class PatrimonioTotal {
  const PatrimonioTotal({
    required this.moneda,
    required this.activos,
    required this.pasivos,
    required this.neto,
    required this.enPatrimonio,
  });

  final String moneda;
  final double activos;
  final double pasivos;
  final double neto;

  /// De los activos, los que el usuario está contando. Una cuenta oculta sigue
  /// siendo suya —por eso viaja en el archivo— pero no entra en el patrimonio
  /// que muestra la app, y las dos cifras tienen que poder verse.
  final double enPatrimonio;
}

class Patrimonio {
  const Patrimonio({required this.tomadaEl, required this.lineas, required this.totales});

  final String tomadaEl;
  final List<PatrimonioLinea> lineas;

  /// Un total por moneda. Sumar soles con dólares daría un número que no es
  /// plata de nada: es la misma regla que la app ya aplica en las deudas.
  final List<PatrimonioTotal> totales;
}

const _columnasPatrimonio = [
  'Grupo',
  'Tipo',
  'Nombre',
  'Saldo',
  'Moneda',
  'Cuenta en tu patrimonio',
  'Detalle',
];

/// La tasa se guarda como fracción —0.14 es 14%— igual que en el resto de la
/// app. Escribirla tal cual daría "TEA 0.14%": una tasa de préstamo que parece
/// regalada.
String _porcentaje(double? valor) =>
    valor == null || valor == 0 ? '' : '${(valor * 100).toStringAsFixed(2)}%';

double _round2(double n) => (n * 100).round() / 100;

Patrimonio buildPatrimonio({
  required List<Account> cuentas,
  required List<Debt> deudas,
  required String tomadaEl,
}) {
  final lineas = <PatrimonioLinea>[];

  for (final c in cuentas) {
    if (c.esDeCredito) {
      // Una tarjeta del día a día: su saldo es lo que debes, no lo que tienes.
      // Las que respaldan una deuda no llegan hasta acá —`/accounts` las deja
      // fuera— y viajan más abajo con su deuda, que es donde está su detalle.
      lineas.add(
        PatrimonioLinea(
          grupo: 'Pasivo',
          tipo: c.type == 'LOAN' ? 'Préstamo' : 'Tarjeta de crédito',
          nombre: c.name,
          saldo: -c.balance,
          moneda: c.currency,
          enPatrimonio: 'No',
          detalle: c.creditLimit == null ? '' : 'Cupo ${c.creditLimit!.toStringAsFixed(2)}',
        ),
      );
      continue;
    }
    lineas.add(
      PatrimonioLinea(
        grupo: 'Activo',
        tipo: gruposDeCuenta.firstWhere((g) => g.$1 == grupoDeCuenta(c.type)).$2,
        nombre: c.name,
        saldo: c.balance,
        moneda: c.currency,
        enPatrimonio: c.isHidden ? 'No' : 'Sí',
        detalle: c.isPrimary ? 'Cuenta principal' : '',
      ),
    );
  }

  for (final d in deudas) {
    // Una deuda cancelada ya no se debe: está fuera de todo cálculo del motor y
    // meterla acá inflaría el pasivo con algo que no existe.
    if (!d.isActive) continue;
    final detalle = [
      if (_porcentaje(d.interestRateAnnual).isNotEmpty) 'TEA ${_porcentaje(d.interestRateAnnual)}',
      if (d.installmentAmount != 0) 'cuota ${d.installmentAmount.toStringAsFixed(2)}',
      if (d.termMonths != null) '${d.termMonths} meses',
      if (d.projection?.monthsLeft != null) 'faltan ${d.projection!.monthsLeft}',
    ].join(' · ');
    lineas.add(
      PatrimonioLinea(
        grupo: 'Pasivo',
        // "Deuda:" delante porque el mismo rótulo lo usa una tarjeta del día a
        // día: sin eso, dos filas que dicen "Tarjeta de crédito" son una que
        // pagas entera cada mes y otra con cuotas, tasa y plazo.
        tipo: 'Deuda: ${d.debtKind?.label ?? 'Deuda'}',
        nombre: d.name,
        saldo: -d.balance,
        moneda: d.currency,
        enPatrimonio: 'No',
        detalle: detalle,
      ),
    );
  }

  final monedas = lineas.map((l) => l.moneda).toSet().toList()..sort();
  final totales = [
    for (final moneda in monedas)
      () {
        final suyas = lineas.where((l) => l.moneda == moneda);
        final activos = suyas
            .where((l) => l.grupo == 'Activo')
            .fold<double>(0, (a, l) => a + l.saldo);
        final pasivos = suyas
            .where((l) => l.grupo == 'Pasivo')
            .fold<double>(0, (a, l) => a + l.saldo);
        return PatrimonioTotal(
          moneda: moneda,
          activos: _round2(activos),
          pasivos: _round2(pasivos),
          neto: _round2(activos + pasivos),
          enPatrimonio: _round2(
            suyas
                .where((l) => l.grupo == 'Activo' && l.enPatrimonio == 'Sí')
                .fold<double>(0, (a, l) => a + l.saldo),
          ),
        );
      }(),
  ];

  return Patrimonio(tomadaEl: tomadaEl, lineas: lineas, totales: totales);
}

ExportResult buildExport({
  required List<Transaction> transacciones,
  required ExportFormat formato,
  required String periodoId,
  required String periodoLabel,

  /// La foto de saldos que acompaña a los movimientos. Nula solo si todavía no
  /// cargaron las cuentas: el archivo sale igual, con lo que sí se sabe.
  Patrimonio? patrimonio,
  // Nulos cuando el export no tiene recorte de fecha — el historial
  // completo, sin el filtro "Este mes" — en vez de forzar un rango que no
  // existe.
  DateTime? desde,
  DateTime? hasta,
  required String timezone,
  required String currency,
}) {
  final ordenadas = [...transacciones]..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
  final recortado = ordenadas.length > _topeFilas;
  final filas = recortado ? ordenadas.take(_topeFilas).toList() : ordenadas;
  final sufijo =
      '${DateTime.now().year}${_dosDigitos(DateTime.now().month)}${_dosDigitos(DateTime.now().day)}';
  final nombreBase = 'movimientos-$periodoId-$sufijo';

  return switch (formato) {
    ExportFormat.csv => ExportResult(
      bytes: _csv(filas, currency, patrimonio),
      filename: '$nombreBase.csv',
      mimeType: 'text/csv',
      recortado: recortado,
    ),
    ExportFormat.xlsx => ExportResult(
      bytes: _xlsx(filas, periodoLabel, currency, patrimonio),
      filename: '$nombreBase.xlsx',
      mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      recortado: recortado,
    ),
    ExportFormat.json => ExportResult(
      bytes: _json(filas, periodoLabel, desde, hasta, timezone, currency, patrimonio),
      filename: '$nombreBase.json',
      mimeType: 'application/json',
      recortado: recortado,
    ),
    ExportFormat.md => ExportResult(
      bytes: _markdown(filas, periodoLabel, desde, hasta, timezone, currency, patrimonio),
      filename: '$nombreBase.md',
      mimeType: 'text/markdown',
      recortado: recortado,
    ),
  };
}

String _dosDigitos(int n) => n.toString().padLeft(2, '0');

const _columnas = [
  'fecha',
  'hora',
  'detalle',
  'categoría',
  'subcategoría',
  'tipo',
  'naturaleza',
  'monto',
  'moneda',
  'saldoPrevio',
  'medioDePago',
];

String _naturaleza(String kind) => switch (kind) {
  'OPENING_BALANCE' => 'Saldo inicial',
  'ADJUSTMENT' => 'Ajuste',
  'TRANSFER' => 'Transferencia',
  _ => 'Movimiento',
};

String _categoriaPadre(Transaction t) => t.category?.parentName ?? t.category?.name ?? '';
String _subcategoria(Transaction t) =>
    t.category?.parentName != null ? (t.category?.name ?? '') : '';

List<String> _fila(Transaction t, String currency) {
  final local = t.occurredAt.toLocal();
  final monto = t.isExpense ? -t.amount : t.amount;
  return [
    '${local.year}-${_dosDigitos(local.month)}-${_dosDigitos(local.day)}',
    '${_dosDigitos(local.hour)}:${_dosDigitos(local.minute)}',
    t.detail,
    _categoriaPadre(t),
    _subcategoria(t),
    t.isExpense ? 'Gasto' : 'Ingreso',
    _naturaleza(t.kind),
    monto.toStringAsFixed(2),
    currency,
    t.balanceBefore?.toStringAsFixed(2) ?? '',
    MediosDePago.etiqueta(t.paymentMethod) ?? '',
  ];
}

// ── CSV ────────────────────────────────────────

/// Neutraliza inyección de fórmulas: una celda que Excel abriría como fórmula
/// (empieza con `=+-@`) se antepone con `'` para que se lea como texto. Sin
/// esto, un detalle escrito como "=cmd|..." es una fórmula viva en cuanto
/// alguien abre el archivo.
String _celdaSegura(String v) {
  final riesgosa = v.isNotEmpty && RegExp(r'^[=+\-@]').hasMatch(v);
  final segura = riesgosa ? "'$v" : v;
  if (segura.contains(',') || segura.contains('"') || segura.contains('\n')) {
    return '"${segura.replaceAll('"', '""')}"';
  }
  return segura;
}

Uint8List _csv(List<Transaction> filas, String currency, Patrimonio? patrimonio) {
  final buffer = StringBuffer('﻿');
  buffer.writeln(_columnas.map(_celdaSegura).join(','));
  for (final t in filas) {
    buffer.writeln(_fila(t, currency).map(_celdaSegura).join(','));
  }

  // La foto de saldos va en un segundo bloque del mismo archivo, separado por
  // una línea en blanco: son dos tablas con columnas distintas y mezclarlas en
  // una sola dejaría media planilla vacía en cada fila. Un archivo aparte
  // obligaría a compartir dos veces lo que se pidió una.
  if (patrimonio != null) {
    buffer
      ..writeln()
      ..writeln(_celdaSegura('Activos y pasivos al ${patrimonio.tomadaEl}'))
      ..writeln(_columnasPatrimonio.map(_celdaSegura).join(','));
    for (final l in patrimonio.lineas) {
      buffer.writeln(l.celdas.map(_celdaSegura).join(','));
    }
    buffer
      ..writeln()
      ..writeln(
        [
          'Moneda',
          'Activos',
          'Pasivos',
          'Neto',
          'Cuenta en tu patrimonio',
        ].map(_celdaSegura).join(','),
      );
    for (final t in patrimonio.totales) {
      buffer.writeln(
        [
          t.moneda,
          t.activos.toStringAsFixed(2),
          t.pasivos.toStringAsFixed(2),
          t.neto.toStringAsFixed(2),
          t.enPatrimonio.toStringAsFixed(2),
        ].map(_celdaSegura).join(','),
      );
    }
  }
  return Uint8List.fromList(utf8.encode(buffer.toString()));
}

// ── XLSX ───────────────────────────────────────

Uint8List _xlsx(
  List<Transaction> filas,
  String periodoLabel,
  String currency,
  Patrimonio? patrimonio,
) {
  final libro = xl.Excel.createExcel();
  final original = libro.getDefaultSheet();
  final hoja =
      libro['Movimientos de $periodoLabel'.length > 31
          ? 'Movimientos'
          : 'Movimientos de $periodoLabel'];
  if (original != null && original != hoja.sheetName) libro.delete(original);

  hoja.appendRow([for (final c in _columnas) xl.TextCellValue(c)]);
  for (final t in filas) {
    final local = t.occurredAt.toLocal();
    final monto = t.isExpense ? -t.amount : t.amount;
    hoja.appendRow([
      xl.TextCellValue('${local.year}-${_dosDigitos(local.month)}-${_dosDigitos(local.day)}'),
      xl.TextCellValue('${_dosDigitos(local.hour)}:${_dosDigitos(local.minute)}'),
      xl.TextCellValue(t.detail),
      xl.TextCellValue(_categoriaPadre(t)),
      xl.TextCellValue(_subcategoria(t)),
      xl.TextCellValue(t.isExpense ? 'Gasto' : 'Ingreso'),
      xl.TextCellValue(_naturaleza(t.kind)),
      xl.DoubleCellValue(monto),
      xl.TextCellValue(currency),
      t.balanceBefore == null ? null : xl.DoubleCellValue(t.balanceBefore!),
      xl.TextCellValue(MediosDePago.etiqueta(t.paymentMethod) ?? ''),
    ]);
  }

  // Los saldos, en su propia hoja. En una hoja de cálculo eso es lo natural: dos
  // tablas con columnas distintas en la misma hoja se ordenan juntas, y ordenar
  // por "fecha" descolocaría los saldos.
  if (patrimonio != null) {
    final hojaPatrimonio = libro['Activos y pasivos'];
    hojaPatrimonio.appendRow([for (final c in _columnasPatrimonio) xl.TextCellValue(c)]);
    for (final l in patrimonio.lineas) {
      hojaPatrimonio.appendRow([
        xl.TextCellValue(l.grupo),
        xl.TextCellValue(l.tipo),
        xl.TextCellValue(l.nombre),
        xl.DoubleCellValue(l.saldo),
        xl.TextCellValue(l.moneda),
        xl.TextCellValue(l.enPatrimonio),
        xl.TextCellValue(l.detalle),
      ]);
    }
    hojaPatrimonio.appendRow([]);
    hojaPatrimonio.appendRow([
      xl.TextCellValue('Totales al ${patrimonio.tomadaEl}'),
      xl.TextCellValue('Activos'),
      xl.TextCellValue('Pasivos'),
      xl.TextCellValue('Neto'),
      xl.TextCellValue('Moneda'),
      xl.TextCellValue('Cuenta en tu patrimonio'),
    ]);
    for (final t in patrimonio.totales) {
      hojaPatrimonio.appendRow([
        null,
        xl.DoubleCellValue(t.activos),
        xl.DoubleCellValue(t.pasivos),
        xl.DoubleCellValue(t.neto),
        xl.TextCellValue(t.moneda),
        xl.DoubleCellValue(t.enPatrimonio),
      ]);
    }
  }

  final bytes = libro.save();
  return Uint8List.fromList(bytes ?? const []);
}

// ── JSON ───────────────────────────────────────

Uint8List _json(
  List<Transaction> filas,
  String periodoLabel,
  DateTime? desde,
  DateTime? hasta,
  String timezone,
  String currency,
  Patrimonio? patrimonio,
) {
  final cuerpo = {
    'periodo': periodoLabel,
    'desde': desde?.toIso8601String(),
    'hasta': hasta?.toIso8601String(),
    'timezone': timezone,
    'moneda': currency,
    'nota': 'Los montos vienen con signo: negativo es gasto, positivo es ingreso.',
    'movimientos': [
      for (final t in filas)
        {
          'fecha': t.occurredAt.toLocal().toIso8601String(),
          'detalle': t.detail,
          'categoria': _categoriaPadre(t),
          'subcategoria': _subcategoria(t),
          'tipo': t.isExpense ? 'Gasto' : 'Ingreso',
          'naturaleza': _naturaleza(t.kind),
          'monto': t.isExpense ? -t.amount : t.amount,
          'moneda': currency,
          'saldoPrevio': t.balanceBefore,
          'medioDePago': MediosDePago.etiqueta(t.paymentMethod),
        },
    ],
    // La foto de hoy, no la del periodo: se dice en `tomadaEl` para que nadie la
    // lea como el saldo con el que cerró el mes que está mirando.
    if (patrimonio != null)
      'patrimonio': {
        'tomadaEl': patrimonio.tomadaEl,
        'lineas': [
          for (final l in patrimonio.lineas)
            {
              'grupo': l.grupo,
              'tipo': l.tipo,
              'nombre': l.nombre,
              'saldo': l.saldo,
              'moneda': l.moneda,
              'enPatrimonio': l.enPatrimonio,
              'detalle': l.detalle,
            },
        ],
        'totales': [
          for (final t in patrimonio.totales)
            {
              'moneda': t.moneda,
              'activos': t.activos,
              'pasivos': t.pasivos,
              'neto': t.neto,
              'enPatrimonio': t.enPatrimonio,
            },
        ],
      },
  };
  return Uint8List.fromList(utf8.encode(jsonEncode(cuerpo)));
}

// ── Markdown ───────────────────────────────────

/// Una celda de tabla Markdown no admite `|` ni saltos de línea sin partir la
/// fila — y acá no hay comillas que la salven, como sí las hay en el CSV. Se
/// cambian por un espacio: el detalle se sigue leyendo, solo pierde el
/// caracter que habría abierto una columna de más.
String _celdaMd(String v) => v.replaceAll(RegExp(r'[|\r\n]'), ' ').trim();

/// Para leer tal cual —pegado en una nota, un mensaje— y no para procesar:
/// quien necesita sumar columnas tiene el CSV o el Excel, que son los que se
/// abren en una hoja de cálculo.
Uint8List _markdown(
  List<Transaction> filas,
  String periodoLabel,
  DateTime? desde,
  DateTime? hasta,
  String timezone,
  String currency,
  Patrimonio? patrimonio,
) {
  final buffer = StringBuffer()
    ..writeln('# Movimientos — $periodoLabel')
    ..writeln()
    ..writeln('- **Generado el:** ${DateTime.now().toIso8601String()}')
    ..writeln('- **Periodo:** $periodoLabel');
  if (desde != null) buffer.writeln('- **Desde:** ${desde.toIso8601String()}');
  if (hasta != null) buffer.writeln('- **Hasta:** ${hasta.toIso8601String()}');
  buffer
    ..writeln('- **Zona horaria:** $timezone')
    ..writeln('- **Moneda:** $currency')
    ..writeln('- **Convención:** montos firmados · gasto negativo · ingreso positivo')
    ..writeln('- **Total:** ${filas.length} ${filas.length == 1 ? "movimiento" : "movimientos"}')
    ..writeln()
    ..writeln('| ${_columnas.join(' | ')} |')
    ..writeln('| ${_columnas.map((_) => '---').join(' | ')} |');
  for (final t in filas) {
    buffer.writeln('| ${_fila(t, currency).map(_celdaMd).join(' | ')} |');
  }

  if (patrimonio != null) {
    buffer
      ..writeln()
      ..writeln('## Activos y pasivos — al ${patrimonio.tomadaEl}')
      ..writeln()
      // Se dice en voz alta: el periodo de arriba y esta foto no son lo mismo, y
      // confundirlos es leer el saldo de hoy como el del mes que se mira.
      ..writeln(
        'Saldos de hoy, no del periodo. Lo que tienes en positivo y lo que debes '
        'en negativo.',
      )
      ..writeln()
      ..writeln('| ${_columnasPatrimonio.join(' | ')} |')
      ..writeln('| ${_columnasPatrimonio.map((_) => '---').join(' | ')} |');
    for (final l in patrimonio.lineas) {
      buffer.writeln('| ${l.celdas.map(_celdaMd).join(' | ')} |');
    }
    buffer
      ..writeln()
      ..writeln('| Moneda | Activos | Pasivos | Neto | Cuenta en tu patrimonio |')
      ..writeln('| --- | --- | --- | --- | --- |');
    for (final t in patrimonio.totales) {
      buffer.writeln(
        '| ${t.moneda} | ${t.activos.toStringAsFixed(2)} | ${t.pasivos.toStringAsFixed(2)} '
        '| ${t.neto.toStringAsFixed(2)} | ${t.enPatrimonio.toStringAsFixed(2)} |',
      );
    }
  }
  return Uint8List.fromList(utf8.encode(buffer.toString()));
}

/// La foto de saldos con los datos que ya tiene la pantalla.
///
/// Vive acá y no en cada pantalla porque las dos que exportan —Panorama y el
/// historial— tienen que producir exactamente el mismo bloque: dos copias de
/// esta media docena de líneas es cómo un archivo termina diciendo una cosa y el
/// otro otra.
Patrimonio patrimonioDeHoy({required List<Account> cuentas, required List<Debt> deudas}) {
  final hoy = DateTime.now();
  return buildPatrimonio(
    cuentas: cuentas,
    deudas: deudas,
    tomadaEl: '${hoy.year}-${_dosDigitos(hoy.month)}-${_dosDigitos(hoy.day)}',
  );
}
