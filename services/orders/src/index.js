// Service ORDERS : appelle AUTH et NOTIFICATIONS via les noms DNS Cloud Map (auth.ecs.local...).
const express = require('express');
const AWSXRay = require('aws-xray-sdk-core');
const http = AWSXRay.captureHTTPs(require('http')); // trace les appels sortants -> service map X-Ray
const xrayExpress = require('aws-xray-sdk-express');

const AUTH_URL = process.env.AUTH_URL || 'http://auth.ecs.local:3000';
const NOTIF_URL = process.env.NOTIF_URL || 'http://notifications.ecs.local:3000';
const orders = []; // démo en mémoire ; en vrai : RDS/DynamoDB

const app = express();
app.use(express.json());
app.use(xrayExpress.openSegment('orders'));

function call(method, url, headers = {}, body) {
  return new Promise((resolve, reject) => {
    const req = http.request(url, { method, headers: { 'content-type': 'application/json', ...headers } }, (r) => {
      let data = '';
      r.on('data', (c) => (data += c));
      r.on('end', () => resolve({ status: r.statusCode, body: data ? JSON.parse(data) : {} }));
    });
    req.on('error', reject);
    if (body) req.write(JSON.stringify(body));
    req.end();
  });
}

app.get('/health', (_req, res) => res.json({ status: 'ok', service: 'orders', version: process.env.APP_VERSION || 'v1' }));
app.get('/', (_req, res) => res.json({ service: 'orders', version: process.env.APP_VERSION || 'v1' }));

app.use('/api/orders', async (req, res, next) => {
  try {
    const r = await call('GET', `${AUTH_URL}/api/auth/verify`, { authorization: req.headers.authorization || '' });
    if (r.status !== 200) return res.status(401).json({ error: 'unauthorized' });
    req.user = r.body.user;
    next();
  } catch (e) { res.status(502).json({ error: 'auth unreachable', detail: e.message }); }
});

app.get('/api/orders', (req, res) => res.json(orders.filter((o) => o.user === req.user.username)));

app.post('/api/orders', async (req, res) => {
  const order = { id: orders.length + 1, user: req.user.username, item: req.body.item };
  orders.push(order);
  call('POST', `${NOTIF_URL}/api/notifications`, {}, { to: order.user, message: `Commande ${order.id} créée` }).catch(() => {});
  res.status(201).json(order);
});

app.use(xrayExpress.closeSegment());
app.listen(process.env.PORT || 3000, () => console.log('orders up'));
