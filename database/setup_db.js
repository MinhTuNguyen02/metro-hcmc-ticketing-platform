import { createRequire } from 'module';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const require = createRequire(import.meta.url);
const { Client } = require(path.join(__dirname, '../metroHcmc---web-service/node_modules/pg'));

const DB_CONFIG = {
  host: process.env.PG_HOST || 'localhost',
  port: parseInt(process.env.PG_PORT || '5432', 10),
  user: process.env.PG_USER || 'postgres',
  password: process.env.PG_PASSWORD || '123456',
};

const TARGET_DB = process.env.PG_DATABASE || 'metro_hcmc';

async function setup() {
  console.log('🚀 Starting Metro HCMC Database Setup...');
  console.log(`📡 Connecting to PostgreSQL at ${DB_CONFIG.host}:${DB_CONFIG.port} as ${DB_CONFIG.user}...`);

  // Step 1: Ensure Target Database Exists
  const rootClient = new Client({
    ...DB_CONFIG,
    database: 'postgres',
  });

  try {
    await rootClient.connect();
    const checkDbRes = await rootClient.query(
      'SELECT 1 FROM pg_database WHERE datname = $1',
      [TARGET_DB]
    );

    if (checkDbRes.rows.length === 0) {
      console.log(`📦 Database "${TARGET_DB}" does not exist. Creating it now...`);
      await rootClient.query(`CREATE DATABASE "${TARGET_DB}" WITH ENCODING 'UTF8'`);
      console.log(`✅ Database "${TARGET_DB}" created successfully.`);
    } else {
      console.log(`ℹ️ Database "${TARGET_DB}" already exists.`);
    }
  } catch (err) {
    console.error('❌ Error checking/creating database:', err.message);
    process.exit(1);
  } finally {
    await rootClient.end();
  }

  // Step 2: Connect to TARGET_DB and run init.sql
  const dbClient = new Client({
    ...DB_CONFIG,
    database: TARGET_DB,
  });

  try {
    await dbClient.connect();
    console.log(`🔌 Connected to "${TARGET_DB}". Executing init.sql...`);

    const sqlPath = path.join(__dirname, 'init.sql');
    const sqlContent = fs.readFileSync(sqlPath, 'utf8');

    await dbClient.query(sqlContent);
    console.log('✅ Executed init.sql successfully!');

    // Step 3: Verify created tables and counts
    const tablesRes = await dbClient.query(`
      SELECT table_name 
      FROM information_schema.tables 
      WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
      ORDER BY table_name;
    `);
    console.log('\n📊 Created Tables in public schema:');
    console.log(tablesRes.rows.map(r => '  - ' + r.table_name).join('\n'));

    // Verify functions
    const funcRes = await dbClient.query(`
      SELECT routine_schema, routine_name 
      FROM information_schema.routines 
      WHERE routine_schema IN ('api', 'internal', 'batch')
      ORDER BY routine_schema, routine_name;
    `);
    console.log(`\n⚙️ Created Functions count: ${funcRes.rows.length}`);
    const grouped = {};
    for (const r of funcRes.rows) {
      grouped[r.routine_schema] = (grouped[r.routine_schema] || 0) + 1;
    }
    console.log('  Functions by schema:', grouped);

    // Verify seed data
    const linesRes = await dbClient.query('SELECT COUNT(*) FROM lines');
    const stationsRes = await dbClient.query('SELECT COUNT(*) FROM stations');
    const productsRes = await dbClient.query('SELECT COUNT(*) FROM ticket_products');
    const usersRes = await dbClient.query('SELECT role, count(*) FROM users GROUP BY role');

    console.log('\n🌱 Seeded Data:');
    console.log(`  - Lines: ${linesRes.rows[0].count}`);
    console.log(`  - Stations: ${stationsRes.rows[0].count}`);
    console.log(`  - Ticket Products: ${productsRes.rows[0].count}`);
    console.log('  - Users:', usersRes.rows.map(r => `${r.role}: ${r.count}`).join(', '));

    console.log('\n🎉 ALL DATABASE OBJECTS, FUNCTIONS, TRIGGERS, AND SEED DATA ARE READY!');
  } catch (err) {
    console.error('❌ Error executing init script:', err.message);
    process.exit(1);
  } finally {
    await dbClient.end();
  }
}

setup();
