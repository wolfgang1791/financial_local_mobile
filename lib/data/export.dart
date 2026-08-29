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

ExportResult buildExport({
  required List<Transaction> transacciones,
  required ExportFormat formato,
  required String periodoId,
  required String periodoLabel,
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
      bytes: _csv(filas, currency),
      filename: '$nombreBase.csv',
      mimeType: 'text/csv',
      recortado: recortado,
    ),
    ExportFormat.xlsx => ExportResult(
      bytes: _xlsx(filas, periodoLabel, currency),
      filename: '$nombreBase.xlsx',
      mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      recortado: recortado,
    ),
    ExportFormat.json => ExportResult(
      bytes: _json(filas, periodoLabel, desde, hasta, timezone, currency),
      filename: '$nombreBase.json',
      mimeType: 'application/json',
      recortado: recortado,
    ),
    ExportFormat.md => ExportResult(
      bytes: _markdown(filas, periodoLabel, desde, hasta, timezone, currency),
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

Uint8List _csv(List<Transaction> filas, String currency) {
  final buffer = StringBuffer('﻿');
  buffer.writeln(_columnas.map(_celdaSegura).join(','));
  for (final t in filas) {
    buffer.writeln(_fila(t, currency).map(_celdaSegura).join(','));
  }
  return Uint8List.fromList(utf8.encode(buffer.toString()));
}

// ── XLSX ───────────────────────────────────────

Uint8List _xlsx(List<Transaction> filas, String periodoLabel, String currency) {
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
  return Uint8List.fromList(utf8.encode(buffer.toString()));
}
