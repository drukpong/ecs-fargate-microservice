'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { createServer } = require('./server');

let server;
let base;

test.before(async () => {
  server = createServer();
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${server.address().port}`;
});

test.after(() => {
  server.closeAllConnections?.();
  server.close();
});

test('GET /health returns ok', async () => {
  const res = await fetch(`${base}/health`);
  assert.strictEqual(res.status, 200);
  assert.deepStrictEqual(await res.json(), { status: 'ok' });
});

test('POST then GET /api/items', async () => {
  const post = await fetch(`${base}/api/items`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: 'widget' }),
  });
  assert.strictEqual(post.status, 201);
  const list = await (await fetch(`${base}/api/items`)).json();
  assert.strictEqual(list.items[0].name, 'widget');
});

test('POST /api/items validates input', async () => {
  const res = await fetch(`${base}/api/items`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}',
  });
  assert.strictEqual(res.status, 400);
});

test('unknown route returns 404', async () => {
  assert.strictEqual((await fetch(`${base}/nope`)).status, 404);
});
