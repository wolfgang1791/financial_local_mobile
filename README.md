# Financial Strategist — mobile, 100% local

Un clon de `../mobile` que corre **sin red**: no habla con ningún backend,
ni siquiera uno local. Todo el motor (cuentas, movimientos, deudas, flujos
recurrentes, etc.) vive portado a Dart dentro de la propia app, y persiste
en un SQLite embebido en el teléfono (`sqflite`), no en un servidor.

## Por qué existe

Para tener una copia de la app que funciona en el celular sin depender de
que haya conexión ni de que un backend esté corriendo en ningún lado — ideal
para un demo, un vuelo, o simplemente para no depender de nada externo.

## Cómo está armado

- **`lib/local_db/database.dart`** — al primer arranque copia
  `assets/seed/app.db` (una base ya poblada con datos reales, generada desde
  `app-local/backend/scripts/migrate-from-postgres.mjs`) al directorio de
  datos de la app, y abre esa copia con `sqflite`. De ahí en más todo se lee
  y se escribe ahí — la app nunca vuelve a tocar el asset original.
- **`lib/data/api.dart`** — `ApiClient` mantiene la misma firma
  (`get/post/patch/delete(path, body)`) que la versión conectada a HTTP,
  pero ahora resuelve cada llamada localmente en vez de hacer una petición
  de red. Es la costura que permite que `lib/state/providers.dart` y casi
  todas las pantallas de `lib/screens/` sean una copia exacta de
  `../mobile` — no les importa de dónde vino la respuesta.
- **`lib/local_api/local_api_router.dart`** — el router: interpreta el
  `path` (`/accounts`, `/debts/:id/pay`, ...) igual que lo hacía Nest, y
  despacha a la lógica local correspondiente.
- **`lib/local_engine/`** — el motor financiero portado de
  `backend/src/**` a Dart puro (zona horaria, ledger, amortización,
  motor financiero, recomendaciones, flujos recurrentes, objetivos).

Sin login, sin JWT: la base ya trae un único usuario real sembrado, así que
la app entra directo — no hay "otra cuenta" a la que cambiarse porque no
hay servidor con el que autenticarse.

## Qué NO tiene (a propósito)

El chat de IA y las recomendaciones dependen en parte de OpenAI, que por
definición necesita internet. Se resolvió así:

- **El chat de Decisiones queda** — su motor (`intención → cálculo → texto`)
  es enteramente determinista en el backend original, sin OpenAI de por
  medio, así que se porta igual que el resto.
- **El informe narrado de cierre de mes** (`SpendingReport`, la prosa de
  "qué te conviene ajustar") y **las propuestas de objetivos por IA**
  (`/goals/propuestas`) se ocultan del todo en este clon — no existen en
  esta versión, ni con aviso de "necesita internet".

## Estado

En construcción por fases (ver el plan). Cada fase deja pantallas
funcionando de punta a punta contra la base local; lo que todavía no se
portó responde con un error claro ("esta parte del clon local todavía no
está portada") en vez de fallar como si fuera un problema de red.

- ✅ **Fase 0** — arranque, base sembrada, sesión sin login.
- ✅ **Fase 1** — zona horaria, ledger (`balanceBefore`), `/accounts`,
  `/categories`, `/categories/in-use`, `/currencies`, `/currencies/rates`,
  `/transactions` (lectura). Verificado contra el backend real —
  `test/local_api/routes_golden_test.dart`.
- ✅ **Fase 2** — amortización, `/recurring-flows`, `/debts` (lectura),
  `/debts/kinds`.
- ✅ **Fase 3** — movimientos y flujos recurrentes: escritura completa.
- ✅ **Fase 4** — motor financiero (`/financial-engine/*`), Panorama.
- ✅ **Fase 5** — pago de cuotas de deuda (`/debts/:id/pay`), la más
  riesgosa: verificada contra los pagos ya guardados en la base sembrada.
- ✅ **Fase 6a** — motor de recomendaciones (`/recommendations`).
- ✅ **Fase 6b** — chat de Decisiones (`/spending/chat`), enteramente
  determinista: `conversation-intent.ts`, `debt-scenario.ts` y
  `conversation-narrator.ts` portados tal cual. `PANORAMA`/`GASTO` leen el
  último `SpendingReport` ya sembrado en la base en vez de regenerarlo — ver
  la nota en `lib/local_api/routes/spending_routes.dart`. Verificado con
  valores de oro contra los datos reales sembrados —
  `test/local_api/spending_chat_golden_test.dart`,
  `test/local_engine/conversation_intent_test.dart`.
- ⏳ **Fase 7** — objetivos (motor determinista, sin propuestas por IA).
- ⏳ **Fase 8** — limpieza final de lo que depende de IA + pulido.

## Requisitos

- Flutter (el mismo SDK que usa `../mobile` — `flutter --version` para
  confirmar).
- Nada de backend, base de datos, ni variables de entorno: todo lo que la
  app necesita viaja adentro de la propia app (`assets/seed/app.db`).

## Cómo correrla (desarrollo)

```bash
flutter pub get
flutter run                 # elige el simulador/dispositivo conectado
```

No hace falta backend corriendo, ni `--dart-define=API_URL=...`: todo vive
en el propio teléfono/simulador. El primer arranque copia
`assets/seed/app.db` al almacenamiento de la app (puede tardar un segundo
más que los siguientes).

## Cómo compilarla (build)

```bash
# Android — un .apk instalable
flutter build apk --release

# Android — el .aab que pide Play Store
flutter build appbundle --release

# iOS — necesita Xcode y una cuenta de Apple Developer para firmar
flutter build ios --release
open ios/Runner.xcworkspace   # firmar/archivar desde Xcode

# macOS / el resto de plataformas de escritorio, si están habilitadas
flutter build macos --release
```

El `.apk`/`.aab`/`.ipa` resultante queda en `build/app/outputs/` (Android) o
se archiva desde Xcode (iOS) — son artefactos normales de Flutter, no hay
nada especial que este clon les agregue.

**Ícono**: el mismo "FS" blanco sobre `#0a0a0a` que usa la web (favicon,
`icon-192`/`512`, apple-icon) — un solo origen en `assets/icon/icon.png`,
bajado a cada tamaño/plataforma con `flutter_launcher_icons`. Si el ícono
cambia, se reemplaza ese PNG y se corre `dart run flutter_launcher_icons`
de nuevo; no se regenera solo en cada build.

⚠️ **Mismo `applicationId`/`bundle id` que `../mobile`**
(`com.financialstrategist.financial_strategist` / iOS
`com.financialstrategist.financialStrategist`), porque se copió tal cual.
Instalar esta build en un dispositivo que ya tiene la app conectada
**la reemplaza** — no conviven como dos apps distintas. Para tenerlas
juntas en el mismo dispositivo, cambiar el `applicationId` en
`android/app/build.gradle.kts` y el `PRODUCT_BUNDLE_IDENTIFIER` en Xcode
(pestaña Signing & Capabilities del target `Runner`) antes de compilar.

## Verificación

```bash
flutter analyze   # estático, sin dispositivo
flutter test      # incluye los valores de oro contra el backend real
```

`test/local_api/routes_golden_test.dart` compara la salida del router local
contra cifras reales pedidas al backend NestJS vivo (mismo usuario, mismos
movimientos) — si el motor portado se desvía del original, es el primer
lugar donde se nota.

## Refrescar los datos sembrados

Esta copia no se sincroniza sola con la app conectada. Para traer datos más
recientes:

```bash
cd ../app-local/backend
rm -f prisma/dev.db && npx prisma migrate deploy
node --env-file=.env scripts/migrate-from-postgres.mjs
cp prisma/dev.db ../../mobile-local/assets/seed/app.db
```

Y desinstalar/reinstalar la app en el simulador (o borrar sus datos), para
que la copie de nuevo al primer arranque — una vez copiada, la app no
vuelve a mirar el asset.
