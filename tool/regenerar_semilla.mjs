// Rehace `assets/seed/app.db` con los datos de hoy del Postgres de `backend/`.
//
// La semilla es la base que la app copia la primera vez que arranca. No se
// mantiene a mano: se regenera desde la web, que es la fuente de verdad —el
// teléfono y el servidor son dos bases sin sincronizar, y cuando hay que
// reconciliarlas gana la web—.
//
// Uso, con el Postgres levantado:
//
//   node tool/regenerar_semilla.mjs
//   SOURCE_DATABASE_URL=postgresql://... node tool/regenerar_semilla.mjs
//
// Después de correrlo hay que **subir la versión del archivo local** en
// `lib/local_db/database.dart` (`_nombreArchivo`): la app solo copia la semilla
// cuando el archivo no existe, así que sin nombre nuevo quien ya tiene la app
// instalada se queda con la base vieja para siempre.
//
// Qué hace, en orden:
//   1. Toma el esquema de la semilla anterior (es el que la app espera).
//   2. Se queda solo con las tablas que Postgres todavía tiene, así que lo que
//      se borró del servidor —la capa de consejo— no reaparece en el teléfono.
//   3. Agrega las columnas que Postgres tiene y la semilla vieja no. Es lo que
//      evita tener que tocar este script cada vez que el esquema crece.
//   4. Copia fila por fila, convirtiendo al formato que guarda sqflite: fechas
//      en milisegundos, booleanos en 0/1, decimales en número.

import { execFileSync } from 'node:child_process';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';
import fs from 'node:fs';
import path from 'node:path';

const aqui = path.dirname(fileURLToPath(import.meta.url));
const RAIZ = path.join(aqui, '..');
const SEMILLA = path.join(RAIZ, 'assets/seed/app.db');
const NUEVA = path.join(RAIZ, 'assets/seed/app.nueva.db');

const PG_URL =
  process.env.SOURCE_DATABASE_URL ??
  'postgresql://postgres:postgres@localhost:5433/financial_strategist?schema=public';

const { PrismaClient } = await import(
  path.join(RAIZ, '../backend/node_modules/@prisma/client/index.js')
);
const pg = new PrismaClient({ datasourceUrl: PG_URL });

// El tipo de cada columna nueva. La semilla guarda decimales como número,
// fechas como entero de milisegundos y booleanos como 0/1, así que lo único que
// hace falta es un tipo que no obligue a sqlite a convertir nada.
function tipoSqlite(tipoPg) {
  if (/^(numeric|decimal|double|real)/.test(tipoPg)) return 'DECIMAL';
  if (/^(timestamp|date)/.test(tipoPg)) return 'DATETIME';
  if (/^bool/.test(tipoPg)) return 'BOOLEAN';
  if (/^(integer|bigint|smallint)/.test(tipoPg)) return 'INTEGER';
  return 'TEXT';
}

// Cómo viaja cada valor. Prisma devuelve `Date`, `Decimal` y booleanos; sqflite
// espera número, número y 0/1. Un JSON se guarda como texto, que es como lo lee
// el resto de la app.
function aValorSqlite(v) {
  if (v === null || v === undefined) return null;
  if (v instanceof Date) return v.getTime();
  if (typeof v === 'boolean') return v ? 1 : 0;
  if (typeof v === 'bigint') return Number(v);
  if (typeof v === 'object' && typeof v.toNumber === 'function') return v.toNumber();
  if (typeof v === 'object') return JSON.stringify(v);
  return v;
}

function ddlDeLaSemillaVieja() {
  const vieja = new DatabaseSync(SEMILLA, { readOnly: true });
  const objetos = vieja
    .prepare(
      "SELECT type, name, tbl_name, sql FROM sqlite_master " +
        "WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'",
    )
    .all();
  vieja.close();
  return objetos;
}

async function columnasDePostgres(tabla) {
  const filas = await pg.$queryRawUnsafe(
    `SELECT column_name, data_type FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = $1`,
    tabla,
  );
  return filas;
}

async function main() {
  console.log(`Origen:  ${PG_URL.replace(/:[^:@/]+@/, ':***@')}`);
  console.log(`Destino: ${path.relative(RAIZ, SEMILLA)}\n`);

  const tablasPg = (
    await pg.$queryRawUnsafe(
      `SELECT table_name FROM information_schema.tables
       WHERE table_schema = 'public' AND table_name <> '_prisma_migrations'`,
    )
  ).map((f) => f.table_name);

  const objetos = ddlDeLaSemillaVieja();
  const tablasViejas = objetos.filter((o) => o.type === 'table').map((o) => o.tbl_name);
  const seVan = tablasViejas.filter(
    (t) => !tablasPg.includes(t) && t !== '_prisma_migrations',
  );
  if (seVan.length) console.log(`Ya no existen en la web, no se copian: ${seVan.join(', ')}\n`);

  if (fs.existsSync(NUEVA)) fs.unlinkSync(NUEVA);
  const nueva = new DatabaseSync(NUEVA);
  // Las llaves foráneas, apagadas mientras se copia: las tablas viajan en el
  // orden en que las nombra Postgres, no en orden de dependencia, y una hija
  // antes que su padre haría fallar la copia sin que haya nada mal en los datos.
  // Al final se comprueban todas juntas.
  nueva.exec('PRAGMA foreign_keys = OFF');

  // El esquema, tal cual lo espera la app. `_prisma_migrations` viaja también:
  // es lo que hace que la base del teléfono se pueda comparar con la de la web.
  for (const o of objetos) {
    if (o.type === 'table' && !tablasPg.includes(o.tbl_name) && o.tbl_name !== '_prisma_migrations')
      continue;
    if (o.type !== 'table' && !tablasPg.includes(o.tbl_name) && o.tbl_name !== '_prisma_migrations')
      continue;
    nueva.exec(o.sql);
  }

  let total = 0;
  for (const tabla of tablasPg) {
    if (!tablasViejas.includes(tabla)) {
      console.log(`  ${tabla}: la semilla vieja no la tiene — se salta (revisa el esquema)`);
      continue;
    }

    // Las columnas que crecieron del lado del servidor. Se agregan solas: es lo
    // que evita que este script haya que editarlo en cada migración.
    const enSqlite = nueva
      .prepare(`PRAGMA table_info("${tabla}")`)
      .all()
      .map((c) => c.name);
    const enPg = await columnasDePostgres(tabla);
    for (const c of enPg) {
      if (!enSqlite.includes(c.column_name)) {
        nueva.exec(`ALTER TABLE "${tabla}" ADD COLUMN "${c.column_name}" ${tipoSqlite(c.data_type)}`);
        console.log(`  ${tabla}: + columna ${c.column_name}`);
      }
    }

    const filas = await pg.$queryRawUnsafe(`SELECT * FROM "${tabla}"`);
    if (filas.length > 0) {
      const columnas = Object.keys(filas[0]);
      const marcas = columnas.map(() => '?').join(', ');
      const insert = nueva.prepare(
        `INSERT INTO "${tabla}" (${columnas.map((c) => `"${c}"`).join(', ')}) VALUES (${marcas})`,
      );
      for (const fila of filas) insert.run(...columnas.map((c) => aValorSqlite(fila[c])));
    }
    console.log(`  ${tabla}: ${filas.length} filas`);
    total += filas.length;
  }

  // Ahora sí: si algo quedó apuntando a una fila que no vino, se dice acá y no
  // en el teléfono de alguien.
  const rotas = nueva.prepare('PRAGMA foreign_key_check').all();
  if (rotas.length > 0) {
    nueva.close();
    console.error(`\n${rotas.length} filas con llave foránea rota:`);
    for (const r of rotas.slice(0, 10)) console.error('  ', r);
    process.exitCode = 1;
    return;
  }

  nueva.close();
  fs.renameSync(NUEVA, SEMILLA);

  // `VACUUM` no es cosmética: la semilla viaja dentro del paquete de la app.
  try {
    execFileSync('sqlite3', [SEMILLA, 'VACUUM;']);
  } catch {
    // Sin el cliente de sqlite a mano, la base sirve igual: solo pesa más.
  }

  const kb = Math.round(fs.statSync(SEMILLA).size / 1024);
  console.log(`\n${total} filas · ${kb} KB`);
  console.log('Acuérdate de subir la versión en lib/local_db/database.dart');
}

await main().finally(() => pg.$disconnect());
