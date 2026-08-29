import 'routes/accounts_routes.dart';
import 'routes/categories_routes.dart';
import 'routes/currencies_routes.dart';
import 'routes/debts_routes.dart';
import 'routes/diagnostico_routes.dart';
import 'routes/financial_engine_routes.dart';
import 'routes/recurring_flows_routes.dart';
import 'routes/transactions_routes.dart';
import 'routes/users_routes.dart';

/// Registra todas las rutas del clon local, una sola vez. Cada fase agrega
/// su propio `register*Routes()` acá — es el único lugar que sabe la lista
/// completa, así ninguna pantalla necesita saber que este archivo existe.
bool _registradas = false;

void registerAllRoutes() {
  if (_registradas) return;
  _registradas = true;

  registerAccountsRoutes();
  registerCategoriesRoutes();
  registerCurrenciesRoutes();
  registerTransactionsRoutes();
  registerDebtsRoutes();
  registerDiagnosticoRoutes();
  registerRecurringFlowsRoutes();
  registerFinancialEngineRoutes();
  registerUsersRoutes();
}
