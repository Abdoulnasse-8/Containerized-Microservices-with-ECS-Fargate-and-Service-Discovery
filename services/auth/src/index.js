// Service AUTH : login + sessions partagées dans ElastiCache Redis.
// Les conteneurs sont stateless : n'importe quelle instance retrouve la session via Redis.
const express = require('express');
const crypto = require('crypto');
const { createClient } = require('redis');
const AWSXRay = require('aws-xray-sdk-core');
const xrayExpress = require('aws-xray-sdk-express');

const app = express();
app.use(express.json());
app.use(xrayExpress.openSegment('auth'));

const redis = createClient({ url: `redis://${process.env.REDIS_HOST}:${process.env.REDIS_PORT || 6379}` });
redis.on('error', (e) => console.error('redis error', e.message));
redis.connect();

// Health check utilisé par l'ALB (ne dépend pas de Redis pour éviter les faux négatifs)
app.get('/health', (_req, res) => res.json({ status: 'ok', service: 'auth' }));

app.post('/api/auth/login', async (req, res) => {
  const { username, password } = req.body || {};
  // Démo : le mot de passe attendu vient de Secrets Manager (injecté en variable d'env, jamais dans le code)
  if (!username || password !== process.env.DEMO_PASSWORD) return res.status(401).json({ error: 'invalid credentials' });
  const token = crypto.randomUUID();
  await redis.set(`session:${token}`, JSON.stringify({ username }), { EX: 3600 });
  res.json({ token });
});

app.get('/api/auth/verify', async (req, res) => {
  const token = (req.headers.authorization || '').replace('Bearer ', '');
  const session = token && (await redis.get(`session:${token}`));
  if (!session) return res.status(401).json({ valid: false });
  res.json({ valid: true, user: JSON.parse(session) });
});

app.use(xrayExpress.closeSegment());
app.listen(process.env.PORT || 3000, () => console.log('auth up'));
