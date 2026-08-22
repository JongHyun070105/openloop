#!/usr/bin/env node

/**
 * Development-only high-performance iOS Simulator MJPEG & input bridge.
 * Uses ScreenCaptureKit and CoreGraphics for 30 FPS real-time capture and sub-millisecond input.
 */
import { execFile, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { mkdtemp, rm } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const args = new Map();
for (let index = 2; index < process.argv.length; index += 1) {
  const value = process.argv[index];
  if (!value.startsWith('--')) continue;
  args.set(value.slice(2), process.argv[index + 1]?.startsWith('--') ? '' : process.argv[++index] || '');
}

const port = Number(args.get('port') || process.env.SIM_STREAM_PORT || 4174);
const udid = args.get('udid') || process.env.SIMULATOR_UDID || 'booted';
const boundary = 'openloop-frame';
const clients = new Set();
let latestFrame = null;
let stopped = false;
let bridgeProcess = null;

const workspace = await mkdtemp(join(tmpdir(), 'openloop-sim-stream-'));
const scriptDirectory = fileURLToPath(new URL('.', import.meta.url));

async function compileSimBridge() {
  const bridgeBinary = join(workspace, 'sim-bridge');
  const sourcePath = join(scriptDirectory, 'sim-bridge.swift');
  console.log('[sim-stream] Compiling high-performance ScreenCaptureKit bridge...');
  await execFileAsync('swiftc', [
    '-O',
    sourcePath,
    '-o',
    bridgeBinary,
    '-framework', 'ScreenCaptureKit',
    '-framework', 'Cocoa',
    '-framework', 'CoreMedia',
    '-framework', 'CoreVideo',
    '-framework', 'CoreImage',
    '-framework', 'CoreGraphics',
  ]);
  return bridgeBinary;
}

function startBridgeProcess(binaryPath) {
  bridgeProcess = spawn(binaryPath, [], {
    stdio: ['pipe', 'pipe', 'inherit'],
  });

  let buffer = Buffer.alloc(0);
  const boundaryMarker = Buffer.from(`--${boundary}`);

  bridgeProcess.stdout.on('data', (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);

    while (true) {
      const boundaryIndex = buffer.indexOf(boundaryMarker);
      if (boundaryIndex === -1) break;

      const nextBoundaryIndex = buffer.indexOf(boundaryMarker, boundaryIndex + boundaryMarker.length);
      if (nextBoundaryIndex === -1) break;

      const frameBlock = buffer.subarray(boundaryIndex, nextBoundaryIndex);
      buffer = buffer.subarray(nextBoundaryIndex);

      const headerEndIndex = frameBlock.indexOf(Buffer.from('\r\n\r\n'));
      if (headerEndIndex !== -1) {
        const jpegData = frameBlock.subarray(headerEndIndex + 4);
        const cleanJpeg = jpegData[jpegData.length - 2] === 0x0d && jpegData[jpegData.length - 1] === 0x0a
          ? jpegData.subarray(0, jpegData.length - 2)
          : jpegData;

        latestFrame = cleanJpeg;

        for (const client of clients) {
          if (client.writableEnded) {
            clients.delete(client);
          } else {
            writeFrame(client, cleanJpeg);
          }
        }
      }
    }
  });

  bridgeProcess.on('exit', (code) => {
    if (!stopped) {
      console.warn(`[sim-stream] Native bridge exited with code ${code}, restarting in 1s...`);
      setTimeout(() => startBridgeProcess(binaryPath), 1000);
    }
  });
}

function writeFrame(response, frame) {
  if (!frame || response.writableEnded) return;
  response.write(`--${boundary}\r\nContent-Type: image/jpeg\r\nContent-Length: ${frame.length}\r\nCache-Control: no-store\r\n\r\n`);
  response.write(frame);
  response.write('\r\n');
}

try {
  const binary = await compileSimBridge();
  startBridgeProcess(binary);
} catch (err) {
  console.error('[sim-stream] Could not start native ScreenCaptureKit bridge:', err.message);
}

const server = createServer(async (request, response) => {
  const url = new URL(request.url || '/', `http://${request.headers.host || 'localhost'}`);
  
  if (url.pathname === '/health') {
    response.writeHead(200, {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'access-control-allow-origin': '*',
    });
    response.end(JSON.stringify({ ok: true, udid, fps: 30, clients: clients.size, hasFrame: Boolean(latestFrame) }));
    return;
  }
  
  if (url.pathname === '/snapshot.jpg') {
    if (latestFrame) {
      response.writeHead(200, {
        'content-type': 'image/jpeg',
        'cache-control': 'no-store, no-cache, must-revalidate',
        pragma: 'no-cache',
        'access-control-allow-origin': '*',
      });
      response.end(latestFrame);
    } else {
      response.writeHead(503, { 'content-type': 'text/plain; charset=utf-8', 'access-control-allow-origin': '*' });
      response.end('Simulator frame not ready yet');
    }
    return;
  }
  
  if (url.pathname === '/stream') {
    response.writeHead(200, {
      'content-type': `multipart/x-mixed-replace; boundary=${boundary}`,
      'cache-control': 'no-store, no-cache, must-revalidate',
      pragma: 'no-cache',
      connection: 'keep-alive',
      'access-control-allow-origin': '*',
    });
    clients.add(response);
    if (latestFrame) {
      writeFrame(response, latestFrame);
    }
    request.on('close', () => clients.delete(response));
    return;
  }
  
  if (url.pathname === '/input' && request.method === 'POST') {
    let body = '';
    request.setEncoding('utf8');
    request.on('data', (chunk) => {
      body += chunk;
      if (body.length > 16_384) request.destroy();
    });
    request.on('end', async () => {
      try {
        const payload = JSON.parse(body);
        const type = payload?.type;

        if (type === 'tap') {
          bridgeProcess?.stdin?.write(`tap ${payload.x} ${payload.y}\n`);
        } else if (type === 'swipe') {
          bridgeProcess?.stdin?.write(`swipe ${payload.x} ${payload.y} ${payload.toX} ${payload.toY}\n`);
        } else if (type === 'shortcut') {
          const action = payload.action;
          if (action === 'photos') {
            await execFileAsync('xcrun', ['simctl', 'launch', udid, 'com.apple.mobileslideshow']);
          } else if (action === 'app') {
            await execFileAsync('xcrun', ['simctl', 'launch', udid, 'com.openloop.openloopMobile']);
          } else if (action === 'home') {
            await execFileAsync('osascript', ['-e', 'tell application "System Events" to tell process "Simulator" to keystroke "h" using {command down, shift down}']);
          }
        }

        response.writeHead(204, { 'cache-control': 'no-store', 'access-control-allow-origin': '*' });
        response.end();
      } catch (error) {
        response.writeHead(400, { 'content-type': 'application/json; charset=utf-8', 'access-control-allow-origin': '*' });
        response.end(JSON.stringify({ error: error?.message || 'Simulator input failed' }));
      }
    });
    return;
  }

  if (request.method === 'OPTIONS') {
    response.writeHead(204, {
      'access-control-allow-origin': '*',
      'access-control-allow-methods': 'GET, POST, OPTIONS',
      'access-control-allow-headers': 'content-type',
    });
    response.end();
    return;
  }
  
  response.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
  response.end('OpenLoop Simulator Stream\n\nGET /health\nGET /snapshot.jpg\nGET /stream\nPOST /input\n');
});

async function shutdown() {
  if (stopped) return;
  stopped = true;
  if (bridgeProcess) {
    bridgeProcess.stdin.end();
    bridgeProcess.kill('SIGTERM');
  }
  for (const client of clients) client.end();
  clients.clear();
  await new Promise((resolve) => server.close(resolve));
  await rm(workspace, { recursive: true, force: true });
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
server.listen(port, '127.0.0.1', () => {
  console.log(`[sim-stream] http://127.0.0.1:${port}/stream`);
  console.log(`[sim-stream] device=${udid} fps=30 (ScreenCaptureKit HW-Accelerated)`);
});
