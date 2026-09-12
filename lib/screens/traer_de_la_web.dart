import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../data/bundle_import.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../local_db/database.dart';
import '../state/providers.dart';
import '../ui/buttons.dart';
import '../ui/modal.dart';

/// Traer al teléfono lo que pasó en la web.
///
/// **Cómo llega el archivo.** No hay selector de archivos en esta app y añadir
/// uno significa un plugin nativo más; en su lugar se lee la carpeta de
/// documentos de la propia app, que en iOS aparece en Archivos y en Android es
/// accesible desde cualquier gestor. El usuario copia ahí el `.json` que bajó de
/// la web y esto busca el más reciente. Es un paso manual más, a cambio de no
/// arrastrar una dependencia nativa por algo que se hace una vez cada tanto.
///
/// **Dos pasos, como en la web.** Primero el ensayo —qué entraría, qué se
/// corregiría, qué hay acá que la web no tiene— y después aplicar. Sobre datos
/// de dinero, ver antes de escribir no es una cortesía.
Future<void> abrirTraerDeLaWeb(BuildContext context, WidgetRef ref) async {
  final archivo = await _elPaqueteMasReciente();
  if (!context.mounted) return;

  if (archivo == null) {
    final carpeta = (await getApplicationDocumentsDirectory()).path;
    if (!context.mounted) return;
    await showFeedback(
      context,
      title: 'No encuentro el paquete',
      message:
          'Baja el archivo desde la web (Movimientos → Importar del teléfono → '
          'Descargar el paquete) y cópialo en la carpeta de la app.\n\n$carpeta',
      tone: FeedbackTone.aviso,
    );
    return;
  }

  final db = await LocalDatabase.open();
  InformeDelPaquete ensayo;
  try {
    final paquete = jsonDecode(await archivo.readAsString()) as Map<String, dynamic>;
    ensayo = await aplicarPaqueteDeLaWeb(db, paquete, ensayo: true);
  } on PaqueteInvalido catch (e) {
    if (!context.mounted) return;
    await showFeedback(
      context,
      title: 'Ese archivo no sirve',
      message: e.mensaje,
      tone: FeedbackTone.error,
    );
    return;
  } catch (_) {
    if (!context.mounted) return;
    await showFeedback(
      context,
      title: 'No pude leerlo',
      message: 'El archivo no es un JSON válido. Vuelve a bajarlo de la web.',
      tone: FeedbackTone.error,
    );
    return;
  }

  if (!context.mounted) return;
  final confirmar = await showAppModal<bool>(
    context,
    title: 'Traer lo de la web',
    subtitle: _nombreCorto(archivo),
    builder: (context) => _Resumen(informe: ensayo),
  );
  if (confirmar != true || !context.mounted) return;

  final paquete = jsonDecode(await archivo.readAsString()) as Map<String, dynamic>;
  final hecho = await aplicarPaqueteDeLaWeb(db, paquete, ensayo: false);

  // Todo lo que se mira en pantalla sale de la base que acaba de cambiar.
  ref
    ..invalidate(cashPositionProvider)
    ..invalidate(accountsProvider)
    ..invalidate(recentTransactionsProvider)
    ..invalidate(debtsProvider)
    ..invalidate(recurringFlowsProvider);

  if (!context.mounted) return;
  await showFeedback(
    context,
    title: 'Listo',
    message: hecho.cambios == 0
        ? 'No había nada que traer: el teléfono ya estaba al día.'
        : 'Entraron ${hecho.nuevas} registros nuevos y se corrigieron '
              '${hecho.actualizadas}.',
    tone: FeedbackTone.exito,
  );
}

/// El `.json` más nuevo de la carpeta de la app.
///
/// El más reciente y no "el que se llame así": el nombre lo pone el navegador al
/// bajarlo y puede venir con un (1) detrás, o renombrado a mano. La fecha de
/// modificación no miente.
Future<File?> _elPaqueteMasReciente() async {
  final carpeta = await getApplicationDocumentsDirectory();
  final candidatos = <File>[];
  await for (final entrada in carpeta.list()) {
    if (entrada is File && entrada.path.toLowerCase().endsWith('.json')) {
      candidatos.add(entrada);
    }
  }
  if (candidatos.isEmpty) return null;
  candidatos.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
  return candidatos.first;
}

String _nombreCorto(File archivo) => archivo.uri.pathSegments.last;

class _Resumen extends StatelessWidget {
  const _Resumen({required this.informe});

  final InformeDelPaquete informe;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final conCambios = informe.porTabla.where((t) => t.cambios > 0).toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          informe.cambios == 0
              ? 'El teléfono ya está al día: no hay nada que traer.'
              : '${informe.nuevas} registros nuevos y ${informe.actualizadas} '
                    'que se corrigen con lo de la web.',
          style: AppText.body(colors.foreground),
        ),
        if (conCambios.isNotEmpty) ...[
          const SizedBox(height: Spacing.md),
          for (final t in conCambios)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      t.tabla,
                      style: AppText.small(colors.oliveInk.withValues(alpha: 0.75)),
                    ),
                  ),
                  Text(
                    [
                      if (t.nuevas > 0) '+${t.nuevas}',
                      if (t.actualizadas > 0) '~${t.actualizadas}',
                    ].join('  '),
                    style: AppText.money(colors.foreground, size: 12.5),
                  ),
                ],
              ),
            ),
        ],
        // Lo que hay acá y la web no trae. Se dice siempre que exista: es lo
        // único que este proceso no puede resolver solo.
        if (informe.soloEnElTelefono > 0) ...[
          const SizedBox(height: Spacing.md),
          Text(
            '${informe.soloEnElTelefono} registros están solo en el teléfono. No se tocan: '
            'o los borraste en la web, o los anotaste acá y todavía no los subiste.',
            style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.6)),
          ),
        ],
        const SizedBox(height: Spacing.lg),
        AppButton(
          label: informe.cambios == 0 ? 'Entendido' : 'Traerlo',
          onPressed: () => Navigator.of(context).pop(informe.cambios > 0),
        ),
      ],
    );
  }
}
