import 'package:flutter/services.dart' show FilteringTextInputFormatter, TextInputType;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api.dart';
import '../data/models.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../state/providers.dart';
import '../ui/buttons.dart';
import '../ui/fields.dart';
import '../ui/modal.dart';
import '../ui/surface.dart';

/// Lo único que la app pregunta, y una sola vez.
///
/// Dos datos: en qué moneda piensa y cuánto tiene hoy. El resto se deduce —el
/// nombre y el correo los da Google, la zona la reporta el dispositivo— y las
/// categorías vienen sembradas. El monto no es un dato suelto: entra al
/// ledger como saldo inicial y queda como el punto desde el que se
/// reconstruye toda la historia del patrimonio. Réplica de
/// `frontend/src/app/bienvenida/page.tsx`.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _monto = TextEditingController();
  final _nombre = TextEditingController(text: 'Efectivo');
  String _moneda = 'PEN';
  bool _guardando = false;
  String? _error;

  @override
  void dispose() {
    _monto.dispose();
    _nombre.dispose();
    super.dispose();
  }

  double get _montoValido => double.tryParse(_monto.text.replaceAll(',', '')) ?? 0;

  Future<void> _empezar() async {
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      final api = ref.read(apiProvider);
      // La moneda va en las dos partes y significan cosas distintas: en la
      // cuenta es en qué está ese dinero, en el usuario es en qué quiere leer
      // los totales. Hoy coinciden.
      await api.patch('/users/me', {'currency': _moneda});
      await api.post('/accounts', {
        'name': _nombre.text.trim().isEmpty ? 'Efectivo' : _nombre.text.trim(),
        'type': 'CASH',
        'currentBalance': _montoValido,
        'currency': _moneda,
        'openedAt': DateTime.now().toIso8601String(),
      });
      // Se relee la sesión entera en vez de apagar el aviso a mano: así el
      // usuario también llega con la moneda nueva ya puesta, no con la vieja
      // hasta el próximo arranque.
      ref.invalidate(sessionProvider);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'No llegué al servidor. Inténtalo otra vez.');
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  Future<void> _cambiarDeCuenta() async {
    await ref.read(sessionProvider.notifier).signOut();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final user = ref.watch(userProvider);
    final monedas = ref.watch(currenciesProvider);

    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Spacing.xxl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('UN SOLO PASO', style: AppText.kicker(colors.sageInk.withValues(alpha: 0.8))),
                const SizedBox(height: Spacing.sm),
                Text('Hola, ${user.firstName}', style: AppText.display(colors.foreground)),
                const SizedBox(height: Spacing.md),
                Text(
                  'Para empezar necesitamos saber con cuánto cuentas hoy. Ese monto '
                  'queda como tu punto de partida: desde ahí medimos cómo evoluciona '
                  'tu patrimonio. Después lo puedes corregir cuando quieras.',
                  style: AppText.body(colors.oliveInk.withValues(alpha: 0.8)),
                ),
                const SizedBox(height: Spacing.section),
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const FieldLabel('¿Cuánto tienes hoy?'),
                      FieldBox(
                        child: Row(
                          children: [
                            Text(
                              _moneda == 'USD' ? r'$' : 'S/',
                              style: AppText.money(colors.oliveInk.withValues(alpha: 0.6)),
                            ),
                            const SizedBox(width: Spacing.sm),
                            Expanded(
                              child: AppTextField(
                                controller: _monto,
                                autofocus: true,
                                placeholder: '0.00',
                                style: AppText.money(
                                  colors.foreground,
                                  size: 20,
                                  weight: FontWeight.w600,
                                ),
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                inputFormatters: [
                                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                                ],
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: Spacing.lg),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const FieldLabel('Moneda'),
                                FieldSelector(
                                  texto: _moneda,
                                  onTap: () async {
                                    final lista = monedas.valueOrNull ?? const <Currency>[];
                                    if (lista.isEmpty) return;
                                    final elegida = await showAppModal<Currency>(
                                      context,
                                      title: 'Elige la moneda',
                                      builder: (context) => Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment: CrossAxisAlignment.stretch,
                                        children: [
                                          for (final c in lista)
                                            FieldOption(
                                              titulo: '${c.code} · ${c.name}',
                                              onTap: () => Navigator.of(context).pop(c),
                                            ),
                                        ],
                                      ),
                                    );
                                    if (elegida != null) setState(() => _moneda = elegida.code);
                                  },
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: Spacing.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const FieldLabel('¿Dónde está?'),
                                FieldBox(
                                  child: AppTextField(controller: _nombre, placeholder: 'Efectivo'),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: Spacing.md),
                        Text(_error!, style: AppText.small(colors.danger)),
                      ],
                      const SizedBox(height: Spacing.xl),
                      AppButton(
                        label: 'Empezar',
                        busy: _guardando,
                        onPressed: _guardando ? null : _empezar,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: Spacing.lg),
                Text(
                  'Si tienes más de una cuenta, agrega las demás después desde la '
                  'tarjeta de patrimonio. Las deudas van en su propia sección.',
                  style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.55)),
                ),
                const SizedBox(height: Spacing.lg),
                GestureDetector(
                  onTap: _cambiarDeCuenta,
                  child: Text.rich(
                    TextSpan(
                      text: 'Entraste como ${user.email}. ',
                      style: AppText.tiny(colors.oliveInk.withValues(alpha: 0.55)),
                      children: [
                        TextSpan(
                          text: 'Cambiar de cuenta',
                          style: AppText.tiny(
                            colors.sageInk,
                          ).copyWith(decoration: TextDecoration.underline),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
