// Service NOTIFICATIONS : reçoit des événements d'Orders (démo : log CloudWatch).
const express = require('express');
const xrayExpress = require('aws-xray-sdk-express');

const app = express();
app.use(express.json());
app.use(xrayExpress.openSegment('notifications'));

app.get('/health', (_req, res) => res.json({ status: 'ok', service: 'notifications' }));

app.post('/api/notifications', (req, res) => {
  // API_KEY vient de Secrets Manager (ex: clé SES/SNS/provider email)
  console.log(JSON.stringify({ event: 'notification', to: req.body.to, message: req.body.message, keyLoaded: !!process.env.API_KEY }));
  res.status(202).json({ queued: true });
});

app.use(xrayExpress.closeSegment());
app.listen(process.env.PORT || 3000, () => console.log('notifications up'));
