// Entry point for Vercel serverless
// Dynamic import so initialization errors are caught and reported
import type { IncomingMessage, ServerResponse } from 'http';

let _handler: ((req: IncomingMessage, res: ServerResponse) => void) | null = null;
let _initError: string | null = null;
let _initialized = false;

async function init() {
  if (_initialized) return;
  _initialized = true;
  try {
    const mod = await import('../src/server.js');
    _handler = mod.default as any;
  } catch (e: any) {
    _initError = e.message;
    console.error('[api/index] Init failed:', e.message, e.stack);
  }
}

export default async function handler(req: IncomingMessage, res: ServerResponse) {
  await init();
  if (_initError || !_handler) {
    res.writeHead(500, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Backend initialization failed', detail: _initError }));
    return;
  }
  _handler(req, res);
}
