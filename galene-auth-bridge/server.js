'use strict';
// Mints short-lived JWTs asserting the SSO-authenticated identity so galene
// (configured with a matching group `authServer`/`authKeys`) locks each
// participant's in-meeting display name to their real, Authelia-verified
// username. Only reachable via nginx, which gates this location behind
// Authelia's auth_request and forwards the verified identity as the
// Remote-User header — this service trusts that header unconditionally,
// so it must never be exposed except through that proxy path.
const http = require('http');
const crypto = require('crypto');

const SECRET = process.env.GALENE_JWT_SECRET;
const HOST_LABEL = process.env.GALENE_AUD_HOST || 'sdic.sjtu.edu.cn';
const PORT = parseInt(process.env.PORT || '8090', 10);

if (!SECRET) {
  console.error('GALENE_JWT_SECRET is required');
  process.exit(1);
}

function base64url(input) {
  return Buffer.from(input).toString('base64url');
}

function signJWT(payload) {
  const header = { alg: 'HS256', typ: 'JWT' };
  const headerB64 = base64url(JSON.stringify(header));
  const payloadB64 = base64url(JSON.stringify(payload));
  const signingInput = `${headerB64}.${payloadB64}`;
  const sig = crypto.createHmac('sha256', Buffer.from(SECRET, 'base64url')).update(signingInput).digest('base64url');
  return `${signingInput}.${sig}`;
}

function extractGroup(locationHref) {
  if (typeof locationHref !== 'string') return null;
  const m = locationHref.match(/\/group\/([^/?#]+)\/?/);
  return m ? decodeURIComponent(m[1]) : null;
}

// Node's HTTP parser decodes header values as latin1 (one byte per char),
// per historical HTTP spec assumptions — a non-ASCII value like a Chinese
// display name arrives as mojibake unless re-decoded as the UTF-8 it
// actually is. Re-encoding back to latin1 bytes recovers the original
// wire bytes exactly (latin1 is a 1:1 byte<->codepoint mapping for 0-255).
function decodeHeaderUtf8(value) {
  if (!value) return value;
  return Buffer.from(value, 'latin1').toString('utf8');
}

const server = http.createServer((req, res) => {
  if (req.method !== 'POST') {
    res.writeHead(405).end();
    return;
  }

  const remoteUser = req.headers['remote-user'];
  if (!remoteUser) {
    res.writeHead(401, { 'Content-Type': 'text/plain' }).end('missing authenticated identity');
    return;
  }
  // Accounts are named by pinyin initials, not the name lab members
  // actually go by — show the real display name in the meeting instead.
  // Falls back to the username if a display name wasn't set/forwarded.
  const displayName = decodeHeaderUtf8(req.headers['remote-name']);
  const participantName = displayName || remoteUser;

  let body = '';
  req.on('data', (chunk) => { body += chunk; });
  req.on('end', () => {
    let parsed;
    try {
      parsed = JSON.parse(body || '{}');
    } catch (e) {
      res.writeHead(400).end('invalid json');
      return;
    }

    const group = extractGroup(parsed.location);
    if (!group) {
      res.writeHead(400).end('could not determine group from location');
      return;
    }

    const now = Math.floor(Date.now() / 1000);
    const token = signJWT({
      sub: participantName,
      aud: [`https://${HOST_LABEL}/group/${group}/`],
      iat: now,
      exp: now + 60,
      permissions: ['present'],
    });

    res.writeHead(200, { 'Content-Type': 'application/jwt' });
    res.end(token);
  });
});

// 0.0.0.0 by default: inside a container this must be reachable via
// podman's `-p 127.0.0.1:...` publish flag, which is what actually
// restricts external access. Override HOST=127.0.0.1 only for a bare
// `node server.js` run on an otherwise-unfirewalled host.
const HOST = process.env.HOST || '0.0.0.0';
server.listen(PORT, HOST, () => {
  console.log(`[galene-auth-bridge] listening on ${HOST}:${PORT}`);
});
