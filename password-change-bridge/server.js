'use strict';
// Lets an SSO-authenticated lab member set a new lldap password for
// themselves — no old-password check, no email/OTP (see the deploy notes:
// Authelia's own built-in Change Password requires "session elevation",
// which sends a one-time code by email; lab members' directory email
// addresses are placeholders, not real mailboxes, so that flow can never
// complete. lldap's own web UI does self-service password change without
// email, but its frontend is a compiled WASM app that assumes it's served
// at the domain root, which conflicts with ccwebsite already owning "/" —
// so instead of exposing that whole app, this reuses lldap's own
// `lldap_set_password` binary (the exact tool an admin already uses to set
// passwords) to set only the trusted SSO user's own password.
//
// Only reachable via nginx, which gates this location behind Authelia's
// auth_request and always overwrites any client-supplied Remote-User
// header with its own verified value before forwarding — so trusting that
// header here is safe.
const http = require('http');
const crypto = require('crypto');
const { execFile } = require('child_process');

const PORT = parseInt(process.env.PORT || '8095', 10);
const LLDAP_BASE_URL = process.env.LLDAP_BASE_URL || 'http://lldap:17170';
const LLDAP_ADMIN_USERNAME = process.env.LLDAP_ADMIN_USERNAME;
const LLDAP_ADMIN_PASSWORD = process.env.LLDAP_ADMIN_PASSWORD;
const SET_PASSWORD_BIN = process.env.LLDAP_SET_PASSWORD_BIN || '/usr/local/bin/lldap_set_password';
const MIN_LENGTH = 8;

if (!LLDAP_ADMIN_USERNAME || !LLDAP_ADMIN_PASSWORD) {
  console.error('LLDAP_ADMIN_USERNAME and LLDAP_ADMIN_PASSWORD are required');
  process.exit(1);
}

function decodeHeaderUtf8(value) {
  if (!value) return value;
  return Buffer.from(value, 'latin1').toString('utf8');
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function page({ username, displayName, error, success }) {
  return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<meta name="robots" content="noindex, nofollow" />
<title>修改密码</title>
<style>
  body { font-family: -apple-system, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif; background: #f6f7f9; margin: 0; }
  main { max-width: 420px; margin: 10vh auto; background: #fff; border-radius: 12px; padding: 32px; box-shadow: 0 1px 3px rgba(0,0,0,.1); }
  h1 { font-size: 1.3rem; margin: 0 0 4px; }
  p.sub { color: #666; margin: 0 0 24px; font-size: .9rem; }
  label { display: block; font-size: .85rem; color: #333; margin: 16px 0 4px; }
  input { width: 100%; box-sizing: border-box; padding: 10px 12px; border: 1px solid #ddd; border-radius: 8px; font-size: 1rem; }
  button { margin-top: 24px; width: 100%; padding: 11px; border: 0; border-radius: 8px; background: #2563eb; color: #fff; font-size: 1rem; cursor: pointer; }
  button:hover { background: #1d4ed8; }
  .msg { padding: 10px 12px; border-radius: 8px; font-size: .9rem; margin-bottom: 16px; }
  .msg.error { background: #fef2f2; color: #b91c1c; }
  .msg.success { background: #f0fdf4; color: #15803d; }
</style>
</head>
<body>
<main>
  <h1>修改密码</h1>
  <p class="sub">当前账号：${escapeHtml(displayName || username)}（${escapeHtml(username)}）</p>
  ${error ? `<div class="msg error">${escapeHtml(error)}</div>` : ''}
  ${success ? `<div class="msg success">密码已修改，下次登录统一认证时使用新密码即可。</div>` : ''}
  <form method="post" action="">
    <label for="password">新密码（至少 ${MIN_LENGTH} 位）</label>
    <input id="password" name="password" type="password" minlength="${MIN_LENGTH}" required autofocus />
    <label for="confirm">确认新密码</label>
    <input id="confirm" name="confirm" type="password" minlength="${MIN_LENGTH}" required />
    <button type="submit">确认修改</button>
  </form>
</main>
</body>
</html>`;
}

function setPassword(username, password) {
  return new Promise((resolve, reject) => {
    execFile(
      SET_PASSWORD_BIN,
      [
        '--base-url', LLDAP_BASE_URL,
        '--admin-username', LLDAP_ADMIN_USERNAME,
        '--admin-password', LLDAP_ADMIN_PASSWORD,
        '--username', username,
        '--password', password,
      ],
      (err, stdout, stderr) => {
        if (err) return reject(new Error((stderr || stdout || err.message).trim()));
        resolve();
      }
    );
  });
}

const server = http.createServer((req, res) => {
  const username = req.headers['remote-user'];
  if (!username) {
    res.writeHead(401, { 'Content-Type': 'text/plain' }).end('missing authenticated identity');
    return;
  }
  const displayName = decodeHeaderUtf8(req.headers['remote-name']);

  if (req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(page({ username, displayName }));
    return;
  }

  if (req.method !== 'POST') {
    res.writeHead(405).end();
    return;
  }

  let body = '';
  req.on('data', (chunk) => { body += chunk; });
  req.on('end', async () => {
    const params = new URLSearchParams(body);
    const password = params.get('password') || '';
    const confirm = params.get('confirm') || '';

    if (password.length < MIN_LENGTH) {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(page({ username, displayName, error: `新密码至少需要 ${MIN_LENGTH} 位。` }));
      return;
    }
    if (password !== confirm) {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(page({ username, displayName, error: '两次输入的新密码不一致。' }));
      return;
    }

    try {
      await setPassword(username, password);
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(page({ username, displayName, success: true }));
    } catch (err) {
      console.error('[password-change-bridge] setPassword failed:', err.message);
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(page({ username, displayName, error: '修改失败，请稍后重试或联系管理员。' }));
    }
  });
});

// 0.0.0.0 by default: inside a container this must be reachable via
// podman's `-p 127.0.0.1:...` publish flag, which is what actually
// restricts external access.
const HOST = process.env.HOST || '0.0.0.0';
server.listen(PORT, HOST, () => {
  console.log(`[password-change-bridge] listening on ${HOST}:${PORT}`);
});
