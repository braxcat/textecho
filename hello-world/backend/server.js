const http = require('http');
const fs = require('fs');
const path = require('path');
const url = require('url');

const PORT = process.env.PORT ? Number(process.env.PORT) : 3000;
const publicDir = path.join(__dirname, '..', 'frontend');

const mimeTypes = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
};

function sendJson(res, status, payload) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(payload));
}

function safePath(requestPath) {
  const normalized = path.normalize(requestPath).replace(/^([\/\\])+/, '');
  return path.join(publicDir, normalized);
}

const server = http.createServer((req, res) => {
  const parsedUrl = url.parse(req.url || '/');
  const pathname = parsedUrl.pathname || '/';

  if (pathname === '/api/hello') {
    return sendJson(res, 200, { message: 'Hello World Cam' });
  }

  let filePath = pathname === '/' ? path.join(publicDir, 'index.html') : safePath(pathname);

  if (!filePath.startsWith(publicDir)) {
    res.writeHead(403, { 'Content-Type': 'text/plain; charset=utf-8' });
    return res.end('Forbidden');
  }

  fs.stat(filePath, (err, stat) => {
    if (err || !stat.isFile()) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      return res.end('Not Found');
    }

    const ext = path.extname(filePath).toLowerCase();
    const contentType = mimeTypes[ext] || 'application/octet-stream';

    res.writeHead(200, { 'Content-Type': contentType });
    fs.createReadStream(filePath).pipe(res);
  });
});

server.listen(PORT, () => {
  console.log(`Hello World server running at http://localhost:${PORT}`);
});
