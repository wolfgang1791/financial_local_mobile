import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

Future<void> main() async {
  await bootstrap();
  runApp(const ProviderScope(child: FinancialStrategistApp()));
}
