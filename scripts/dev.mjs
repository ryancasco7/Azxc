import http from 'http';
import fs from 'fs';
import path from 'path';
import { fileURLToPath, pathToFileURL } from 'url';
import { config as loadEnv } from 'dotenv';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, '..');

loadEnv({ path: path.join(root, '.env') });

const PORT = Number(process.env.PORT) || 3000;

const MIME = {
  '.html': 'text/html',
  '.css': 'text/css',
  '.js': 'application/javascript',
  '.json': 'application/json',
  '.png': 'image/png',
  '.ico': 'image/x-icon'
};

function createResAdapter(res) {
  return {
    set statusCode(v) { res.statusCode = v; },
    get statusCode() { return res.statusCode; },
    setHeader(k, v) { res.setHeader(k, v); },
    end(body) { res.end(body); }
  };
}

async function handleApi(req, res, url) {
  const apiPath = url.pathname.replace(/^\/api\//, '');
  let filePath = path.join(root, 'api', apiPath, 'index.js');
  if (!fs.existsSync(filePath)) {
    filePath = path.join(root, 'api', `${apiPath}.js`);
  }
  if (!fs.existsSync(filePath)) {
    res.statusCode = 404;
    res.end('API not found');
    return;
  }

  let body = '';
  if (req.method === 'POST') {
    body = await new Promise((resolve) => {
      let data = '';
      req.on('data', c => data += c);
      req.on('end', () => resolve(data));
    });
  }

  const mod = await import(pathToFileURL(filePath).href);
  const handler = mod.default;
  const adapter = createResAdapter(res);

  let parsedBody = {};
  if (body) {
    try { parsedBody = JSON.parse(body); } catch { parsedBody = {}; }
  }

  const mockReq = {
    method: req.method,
    headers: req.headers,
    body: parsedBody
  };

  await handler(mockReq, adapter);
}

function serveStatic(req, res, url) {
  let filePath = path.join(root, decodeURIComponent(url.pathname === '/' ? '/index.html' : url.pathname));
  if (fs.existsSync(filePath) && fs.statSync(filePath).isDirectory()) {
    filePath = path.join(filePath, 'index.html');
  }
  if (!fs.existsSync(filePath)) {
    res.statusCode = 404;
    res.end('Not found');
    return;
  }
  const ext = path.extname(filePath);
  res.setHeader('Content-Type', MIME[ext] || 'application/octet-stream');
  if (ext === '.js' || ext === '.html') {
    res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate');
  }
  res.end(fs.readFileSync(filePath));
}

async function handleRequest(req, res) {
  const host = req.headers.host || `localhost:${PORT}`;
  const url = new URL(req.url, `http://${host}`);
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization, x-setup-secret');

  if (req.method === 'OPTIONS') {
    res.statusCode = 200;
    res.end();
    return;
  }

  try {
    if (url.pathname.startsWith('/api/')) {
      await handleApi(req, res, url);
    } else {
      serveStatic(req, res, url);
    }
  } catch (err) {
    console.error(err);
    res.statusCode = 500;
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({ error: err.message }));
  }
}

function listen(port) {
  return new Promise((resolve, reject) => {
    const server = http.createServer(handleRequest);
    server.once('error', (err) => {
      if (err.code === 'EADDRINUSE' && port < 3010) resolve(listen(port + 1));
      else reject(err);
    });
    server.listen(port, () => {
      console.log(`MathBOT dev server: http://localhost:${port}`);
      resolve(server);
    });
  });
}

await listen(PORT);
