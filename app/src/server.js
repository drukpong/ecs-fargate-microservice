'use strict';
const http = require('node:http');

function log(level, msg, extra = {}) {
  console.log(JSON.stringify({ ts: new Date().toISOString(), level, msg, ...extra }));
}

function readJson(req, limit = 1024 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) { reject(Object.assign(new Error('Payload too large'), { status: 413 })); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => {
      try { resolve(JSON.parse(Buffer.concat(chunks).toString() || '{}')); }
      catch { reject(Object.assign(new Error('Invalid JSON'), { status: 400 })); }
    });
    req.on('error', reject);
  });
}

function createServer() {
  const items = []; // in-memory on purpose: swap for RDS/DynamoDB later

  const server = http.createServer(async (req, res) => {
    const started = process.hrtime.bigint();
    const url = new URL(req.url, 'http://localhost');

    const send = (status, body) => {
      const payload = JSON.stringify(body);
      res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) });
      res.end(payload);
    };

    res.on('finish', () => {
      if (url.pathname === '/health') return; // keep ALB health checks out of the logs
      log('info', 'request', {
        method: req.method, path: url.pathname, status: res.statusCode,
        ms: Number(process.hrtime.bigint() - started) / 1e6,
      });
    });

    try {
      if (req.method === 'GET' && url.pathname === '/health') return send(200, { status: 'ok' });

      if (req.method === 'GET' && url.pathname === '/') {
        return send(200, {
          service: 'ecs-api',
          environment: process.env.APP_ENV || 'local',
          version: process.env.APP_VERSION || 'dev',
        });
      }

      if (req.method === 'GET' && url.pathname === '/api/items') return send(200, { items });

      if (req.method === 'POST' && url.pathname === '/api/items') {
        const body = await readJson(req);
        if (typeof body.name !== 'string' || !body.name.trim()) return send(400, { error: '"name" is required' });
        const item = { id: items.length + 1, name: body.name.trim() };
        items.push(item);
        return send(201, item);
      }

      // CPU-burning endpoint so load tests actually trigger autoscaling
      if (req.method === 'GET' && url.pathname === '/api/work') {
        const ms = Math.min(Math.max(parseInt(url.searchParams.get('ms') || '50', 10) || 50, 1), 500);
        const end = Date.now() + ms;
        while (Date.now() < end) { /* spin */ }
        return send(200, { burned_ms: ms });
      }

      return send(404, { error: 'Not found' });
    } catch (err) {
      const status = err.status || 500;
      if (status === 500) log('error', 'unhandled', { error: err.message });
      return send(status, { error: status === 500 ? 'Internal server error' : err.message });
    }
  });

  // Must exceed the ALB idle timeout (60s) or you get sporadic 502s
  server.keepAliveTimeout = 65_000;
  server.headersTimeout = 66_000;
  return server;
}

if (require.main === module) {
  const port = Number(process.env.PORT) || 3000;
  const server = createServer();
  server.listen(port, '0.0.0.0', () => log('info', 'listening', { port }));

  // ECS sends SIGTERM on deploys/scale-in: stop accepting, drain, exit.
  const shutdown = (sig) => {
    log('info', 'shutting down', { signal: sig });
    server.close(() => process.exit(0));
    server.closeIdleConnections?.();
    setTimeout(() => process.exit(1), 10_000).unref();
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

module.exports = { createServer };
