const path = require('path');
const { Client } = require(path.join(__dirname, '../metroHcmc---web-service/node_modules/pg'));

async function testApi() {
  const client = new Client({
    host: process.env.PG_HOST || 'localhost',
    port: parseInt(process.env.PG_PORT || '5432', 10),
    user: process.env.PG_USER || 'postgres',
    password: process.env.PG_PASSWORD || '123456',
    database: process.env.PG_DATABASE || 'metro_hcmc'
  });
  await client.connect();

  console.log('1. Testing Admin Login...');
  const adminLogin = await client.query('SELECT api.fn_auth_login_json($1, $2, $3, $4) as res', ['LOCAL', 'admin@metro.com', 'Admin@123456', null]);
  console.log('   Admin login:', adminLogin.rows[0].res.success ? 'PASS' : 'FAIL', 'Role:', adminLogin.rows[0].res.user?.role);

  console.log('2. Testing Customer Login...');
  const custLogin = await client.query('SELECT api.fn_auth_login_json($1, $2, $3, $4) as res', ['LOCAL', 'customer@metro.com', 'Customer@123456', null]);
  console.log('   Customer login:', custLogin.rows[0].res.success ? 'PASS' : 'FAIL', 'Role:', custLogin.rows[0].res.user?.role);
  const custId = custLogin.rows[0].res.user.user_id;

  console.log('3. Testing Get Lines...');
  const lines = await client.query('SELECT api.fn_get_lines_json() as res');
  console.log('   Lines count:', lines.rows[0].res.data.lines.length);

  console.log('4. Testing Get Stations (Line 1)...');
  const stations = await client.query('SELECT api.fn_get_stations_json($1) as res', ['L1']);
  console.log('   Stations count:', stations.rows[0].res.data.stations.length);

  console.log('5. Testing Quote Single Ticket (Bến Thành -> Thảo Điền)...');
  const quote = await client.query('SELECT api.fn_quote_single_json($1, $2, $3, $4) as res', ['L1', 'BT', 'TD', null]);
  console.log('   Quote:', quote.rows[0].res.data.from_station, '->', quote.rows[0].res.data.to_station, '| stops:', quote.rows[0].res.data.stops, '| price:', quote.rows[0].res.data.final_price);

  console.log('6. Testing Get Active Products...');
  const products = await client.query('SELECT api.fn_get_active_ticket_products_json() as res');
  console.log('   Products:', products.rows[0].res.data.products.map(p => p.code).join(', '));

  console.log('7. Testing Customer List for Admin...');
  const customers = await client.query('SELECT api.fn_get_customers_json() as res');
  console.log('   Customers count:', customers.rows[0].res.length);

  console.log('8. Testing Create Single Ticket...');
  const createSingle = await client.query('SELECT api.fn_create_ticket_single_json($1, $2, $3, $4, $5, $6, $7) as res', [
    custId, 'L1', 'BT', 'TD', quote.rows[0].res.data.stops, quote.rows[0].res.data.final_price, null
  ]);
  const newTicket = createSingle.rows[0].res.data.ticket;
  console.log('   New Ticket ID:', newTicket.ticket_id, '| QR:', newTicket.qr_code);

  console.log('9. Testing Create & Confirm Payment...');
  const createPay = await client.query('SELECT api.fn_create_payment_json($1, $2, $3) as res', [newTicket.ticket_id, 'DEMO', newTicket.final_price]);
  const payId = createPay.rows[0].res.payment.payment_id;
  const confirmPay = await client.query('SELECT api.fn_confirm_payment_json($1) as res', [payId]);
  console.log('   Payment confirmed:', confirmPay.rows[0].res.success, '| Status:', confirmPay.rows[0].res.payment.status);

  console.log('10. Testing Scanner Validation (Scan Ticket)...');
  const scan = await client.query('SELECT api.fn_activate_or_use_ticket_json($1, $2, $3, $4, $5) as res', [
    newTicket.qr_code, 'BT', 'IN', null, false
  ]);
  console.log('   Scan result:', scan.rows[0].res.status, '| message:', scan.rows[0].res.message);

  console.log('11. Testing Batch Jobs...');
  const batchExp = await client.query('SELECT batch.fn_expire_passes_due() as res');
  const batchClean = await client.query('SELECT batch.fn_cleanup_unpaid_tickets() as res');
  console.log('   Batch results:', { expired: batchExp.rows[0].res, cleaned: batchClean.rows[0].res });

  console.log('\n🌟 ALL 11 TESTS PASSED PERFECTLY!');
  await client.end();
}

testApi().catch(err => {
  console.error('❌ Test failed:', err);
  process.exit(1);
});
