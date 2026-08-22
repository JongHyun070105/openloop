import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineConfig, normalizePath } from 'vite';
import react from '@vitejs/plugin-react';

const flutterRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../mobile/build/web',
);
const contentTypes = {
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.wasm': 'application/wasm',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
};

function flutterAppMiddleware() {
  return {
    name: 'openloop-flutter-app',
    configureServer(server) {
      server.middlewares.use('/app', (request, response, next) => {
        if (!fs.existsSync(flutterRoot)) {
          response.statusCode = 503;
          response.setHeader('content-type', 'text/plain; charset=utf-8');
          response.end('Flutter web bundle is missing. Run flutter build web --base-href /app/.');
          return;
        }

        const requestPath = decodeURIComponent((request.url || '/').split('?')[0]);
        const relativePath = requestPath === '/' ? 'index.html' : requestPath.replace(/^\/+/, '');
        const filePath = path.resolve(flutterRoot, relativePath);
        const rootPath = normalizePath(flutterRoot);
        if (!normalizePath(filePath).startsWith(`${rootPath}/`)) {
          response.statusCode = 400;
          response.end('Invalid Flutter asset path');
          return;
        }
        if (!fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
          next();
          return;
        }

        response.statusCode = 200;
        response.setHeader(
          'content-type',
          contentTypes[path.extname(filePath).toLowerCase()] || 'application/octet-stream',
        );
        fs.createReadStream(filePath).pipe(response);
      });
    },
  };
}

export default defineConfig({
  plugins: [react(), flutterAppMiddleware()],
  server: {
    proxy: {
      // Local-only bridge. The endpoint is intentionally absent from builds
      // and only exists while `npm run dev:sim` is running on this Mac.
      '/__simulator': {
        target: 'http://127.0.0.1:4174',
        changeOrigin: true,
        rewrite: (requestPath) => requestPath.replace(/^\/__simulator/, ''),
      },
      '/api': {
        target: 'https://mrodt7pxq4.execute-api.ap-northeast-2.amazonaws.com/dev',
        changeOrigin: true,
        secure: false,
        rewrite: (requestPath) => requestPath.replace(/^\/api/, ''),
      },
      '/dev': {
        target: 'https://mrodt7pxq4.execute-api.ap-northeast-2.amazonaws.com',
        changeOrigin: true,
        secure: false,
      },
    },
  },
});
