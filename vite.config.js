import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react-swc';
import apiHandler from './api/router.js';

function readBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', (chunk) => { raw += chunk; });
    req.on('end', () => {
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch (error) {
        reject(error);
      }
    });
    req.on('error', reject);
  });
}

function makeVercelResponse(res) {
  res.status = (statusCode) => {
    res.statusCode = statusCode;
    return res;
  };
  res.json = (payload) => {
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.end(JSON.stringify(payload));
    return res;
  };
  return res;
}

function localApiPlugin() {
  return {
    name: 'summer-lottery-local-api',
    configureServer(server) {
      server.middlewares.use(async (req, res, next) => {
        if (!String(req.url || '').startsWith('/api/')) {
          next();
          return;
        }
        try {
          req.body = ['GET', 'HEAD', 'OPTIONS'].includes(req.method) ? {} : await readBody(req);
          await apiHandler(req, makeVercelResponse(res));
        } catch (error) {
          res.statusCode = 500;
          res.setHeader('Content-Type', 'application/json; charset=utf-8');
          res.end(JSON.stringify({ success: false, error: { code: 'dev_api_error', message: error.message } }));
        }
      });
    },
  };
}

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '');
  Object.entries(env).forEach(([key, value]) => {
    if (typeof process.env[key] === 'undefined') process.env[key] = value;
  });

  return {
    plugins: [react(), localApiPlugin()],
    server: { port: 5175 },
    preview: { port: 4175 },
  };
});
