'use strict';

/*
 * Cloud-side terminal bridge for dropbear `tty-fwd`.
 *
 * Two sides are connected here:
 *
 *   1. Device terminal stream (raw bytes):
 *      The device runs `tty-fwd ... -B 127.0.0.1:<TCP_PORT> tunnel@thishost`.
 *      dbclient netcat mode makes the SSH server open a TCP connection to
 *      127.0.0.1:<TCP_PORT> on this host, carrying the PTY stdin/stdout.
 *      So this process LISTENS on <TCP_PORT> and each accepted socket is one
 *      device terminal.
 *
 *   2. Browser (xterm.js over WebSocket):
 *      The browser loads index.html and opens ws://thishost:<HTTP_PORT>/ws.
 *
 * A device socket and a browser WebSocket are paired FIFO and piped both ways.
 * Raw bytes only - there is no resize/control channel back to the device PTY
 * (a known limitation; the PTY size is whatever tty-fwd allocated).
 */

const http = require('http');
const net = require('net');
const fs = require('fs');
const path = require('path');
const { WebSocketServer } = require('ws');

function parseArgs(argv) {
  const opts = { http: 8080, tcp: 9000, host: '127.0.0.1' };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--http') opts.http = parseInt(argv[++i], 10);
    else if (a === '--tcp') opts.tcp = parseInt(argv[++i], 10);
    else if (a === '--host') opts.host = argv[++i];
    else if (a === '-h' || a === '--help') {
      console.log(
        'Usage: node server.js [--http 8080] [--tcp 9000] [--host 127.0.0.1]\n' +
        '  --http  port for the browser UI + WebSocket\n' +
        '  --tcp   port the device terminal stream connects to (dropbear -B target)\n' +
        '  --host  bind address for the TCP listener (default 127.0.0.1)'
      );
      process.exit(0);
    }
  }
  return opts;
}

const opts = parseArgs(process.argv);

/* FIFO pairing queues. */
const waitingDevices = []; // net.Socket
const waitingClients = []; // ws

function pair(device, ws) {
  let active = true;

  const onDeviceData = (buf) => {
    if (ws.readyState === ws.OPEN) ws.send(buf);
  };
  const onDeviceEnd = () => {
    console.log('[pair] device closed');
    teardown(true);
  };
  const onWsMessage = (data) => {
    const buf = Buffer.isBuffer(data) ? data : Buffer.from(data);
    if (!device.destroyed) device.write(buf);
  };
  const onWsEnd = () => {
    console.log('[pair] browser closed');
    /* Keep the device TCP stream alive so tty-fwd survives page refresh. */
    teardown(false);
  };

  function teardown(deviceGone) {
    if (!active) return;
    active = false;
    device.removeListener('data', onDeviceData);
    device.removeListener('close', onDeviceEnd);
    device.removeListener('error', onDeviceEnd);
    ws.removeListener('message', onWsMessage);
    ws.removeListener('close', onWsEnd);
    ws.removeListener('error', onWsEnd);
    if (deviceGone) {
      try { ws.close(); } catch (_) {}
    } else if (!device.destroyed) {
      console.log('[pair] device back in queue (browser refresh OK)');
      enqueueDevice(device);
    }
  }

  console.log('[pair] device <-> browser connected');
  device.on('data', onDeviceData);
  device.on('close', onDeviceEnd);
  device.on('error', onDeviceEnd);
  ws.on('message', onWsMessage);
  ws.on('close', onWsEnd);
  ws.on('error', onWsEnd);
}

function enqueueDevice(socket) {
  const ws = waitingClients.shift();
  if (ws) pair(socket, ws);
  else {
    waitingDevices.push(socket);
    socket.on('close', () => {
      const idx = waitingDevices.indexOf(socket);
      if (idx >= 0) waitingDevices.splice(idx, 1);
    });
  }
}

function enqueueClient(ws) {
  const device = waitingDevices.shift();
  if (device) pair(device, ws);
  else {
    waitingClients.push(ws);
    ws.on('close', () => {
      const idx = waitingClients.indexOf(ws);
      if (idx >= 0) waitingClients.splice(idx, 1);
    });
    if (ws.readyState === ws.OPEN) {
      ws.send(Buffer.from('\r\n[cloud-terminal] waiting for a device to connect...\r\n'));
    }
  }
}

/* ---- Device terminal listener (raw TCP) -------------------------------- */
const tcpServer = net.createServer((socket) => {
  socket.setNoDelay(true);
  console.log(`[tcp] device connected from ${socket.remoteAddress}:${socket.remotePort}`);
  enqueueDevice(socket);
});
tcpServer.listen(opts.tcp, opts.host, () => {
  console.log(`[tcp] listening on ${opts.host}:${opts.tcp} (dropbear -B target)`);
});

/* ---- Browser UI + WebSocket -------------------------------------------- */
const indexPath = path.join(__dirname, 'public', 'index.html');

const httpServer = http.createServer((req, res) => {
  if (req.url === '/' || req.url === '/index.html') {
    fs.readFile(indexPath, (err, body) => {
      if (err) { res.writeHead(500); res.end('index.html missing'); return; }
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(body);
    });
    return;
  }
  res.writeHead(404);
  res.end('not found');
});

const wss = new WebSocketServer({ server: httpServer, path: '/ws' });
wss.on('connection', (ws) => {
  console.log('[ws] browser connected');
  enqueueClient(ws);
});

httpServer.listen(opts.http, () => {
  console.log(`[http] terminal UI on http://localhost:${opts.http}/`);
});
