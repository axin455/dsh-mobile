#!/usr/bin/env node
/**
 * DSH Mobile Gateway —— 本地 mock 服务。
 *
 * 只实现 PROTOCOL.md 里预览版用到的帧，用于在没有真 Host 的情况下闭环验证：
 *   配对：dsh-pair.<code> 子协议 → paired → hello
 *   重连：dsh-auth.<token> 子协议
 *   业务：ping / sessions / subscribe / message / plugin-catalog / 开关
 *
 * 不依赖任何 npm 包：WebSocket 握手与帧编解码都在本文件内实现。
 *
 * 用法：
 *   node tool/mock_gateway/server.js
 *   PORT=3081 node tool/mock_gateway/server.js
 */

const http = require('node:http');
const crypto = require('node:crypto');

const PORT = Number(process.env.PORT || 3081);
const HOST = process.env.HOST || '0.0.0.0';
const DEVICE_TOKEN = process.env.DEVICE_TOKEN || 'mock-token-abc123';
const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

// 设备码登录（模拟 DeepSeek 网页端）：deviceCode -> entry
const deviceCodes = new Map();
// 登录后签发的账号令牌 -> { account, gateway }
const accountTokens = new Map();
const ACCOUNT_DEFAULT = { nickname: 'DeepSeek 用户', balance: 42.5 };

const SESSIONS = [
  {
    sessionId: 's-mock-1',
    title: '排查网关连接',
    updatedAt: Math.floor(Date.now() / 1000) - 120,
    running: false,
    blank: false,
    cwd: '/workspace',
    agentPreset: 'standard',
  },
  {
    sessionId: 's-mock-2',
    title: 'Flutter 底栏毛玻璃参数',
    updatedAt: Math.floor(Date.now() / 1000) - 3600,
    running: false,
    blank: false,
    cwd: '/workspace',
    agentPreset: 'standard',
  },
  {
    sessionId: 's-mock-3',
    title: '新的对话',
    updatedAt: Math.floor(Date.now() / 1000) - 86400,
    running: false,
    blank: true,
    cwd: '/workspace',
    agentPreset: 'standard',
  },
];

const HISTORY = {
  's-mock-1': [
    { type: 'user/message', seq: 1, time: 100, data: { text: '手机连不上网关，帮我看看' } },
    {
      type: 'assistant/message',
      seq: 2,
      time: 101,
      data: {
        text:
          '先确认三件事：\n1. Host 上的移动网关处于「常驻开启」\n2. 设备鉴权默认开启，需要一次性配对码\n3. 手机与电脑在同一网段，端口 3081 未被防火墙拦截',
      },
    },
  ],
  's-mock-2': [
    { type: 'user/message', seq: 3, time: 200, data: { text: 'BackdropFilter 的 sigma 取多少合适？' } },
    {
      type: 'assistant/message',
      seq: 4,
      time: 201,
      data: { text: '20 是 FlClash 的起步值；再高会糊掉底下的卡片边缘，再低玻璃感不足。' },
    },
  ],
  's-mock-3': [],
};

let bundleEnabled = { 'dsh-plugin-mobile-gateway': true, 'dsh-plugin-todo': false };
const BUNDLES = [
  {
    name: 'dsh-plugin-mobile-gateway',
    version: '0.6.2',
    enabled: true,
    plugins: [
      { entryId: 'mgw.ws', name: 'WebSocket 网关', type: 'tool', enabled: true },
      { entryId: 'mgw.pair', name: '设备配对', type: 'systemPrompt', enabled: true },
    ],
  },
  {
    name: 'dsh-plugin-todo',
    version: '1.2.0',
    enabled: false,
    plugins: [{ entryId: 'todo.plan', name: '任务规划', type: 'agent', enabled: false }],
  },
];

const connections = new Set();

const recentLogs = [];

function log(...args) {
  const line = args
    .map((arg) => (typeof arg === 'string' ? arg : JSON.stringify(arg)))
    .join(' ');
  console.log(`[mock-gateway ${new Date().toISOString()}]`, ...args);
  recentLogs.push(`${new Date().toISOString()} ${line}`);
  if (recentLogs.length > 80) recentLogs.shift();
}

function sendFrame(socket, opcode, payload) {
  if (socket.destroyed) return;
  const len = payload.length;
  let header;
  if (len < 126) {
    header = Buffer.from([0x80 | opcode, len]);
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(len), 2);
  }
  socket.write(Buffer.concat([header, payload]));
}

function sendJson(socket, frame) {
  sendFrame(socket, 0x1, Buffer.from(JSON.stringify(frame), 'utf8'));
}

function decodeFrame(buffer) {
  if (buffer.length < 2) return null;
  const opcode = buffer[0] & 0x0f;
  const masked = (buffer[1] & 0x80) === 0x80;
  let length = buffer[1] & 0x7f;
  let offset = 2;
  if (length === 126) {
    if (buffer.length < 4) return null;
    length = buffer.readUInt16BE(2);
    offset = 4;
  } else if (length === 127) {
    if (buffer.length < 10) return null;
    length = Number(buffer.readBigUInt64BE(2));
    offset = 10;
  }
  const maskLength = masked ? 4 : 0;
  if (buffer.length < offset + maskLength + length) return null;
  const mask = masked ? buffer.subarray(offset, offset + 4) : null;
  const data = buffer.subarray(offset + maskLength, offset + maskLength + length);
  if (mask) {
    for (let i = 0; i < data.length; i++) data[i] ^= mask[i % 4];
  }
  return { opcode, data: Buffer.from(data), total: offset + maskLength + length };
}

function attachSocket(socket) {
  const state = { buffer: Buffer.alloc(0), sessionId: null, streamId: null, subscriptionId: null, turn: 0 };
  connections.add(state);

  socket.on('data', (chunk) => {
    state.buffer = Buffer.concat([state.buffer, chunk]);
    for (;;) {
      const frame = decodeFrame(state.buffer);
      if (!frame) return;
      state.buffer = state.buffer.subarray(frame.total);
      if (frame.opcode === 0x8) {
        sendFrame(socket, 0x8, Buffer.alloc(0));
        socket.end();
        return;
      }
      if (frame.opcode === 0x9) {
        sendFrame(socket, 0xa, frame.data);
        continue;
      }
      if (frame.opcode !== 0x1) continue;
      let message;
      try {
        message = JSON.parse(frame.data.toString('utf8'));
      } catch {
        continue;
      }
      handleMessage(socket, state, message);
    }
  });

  socket.on('close', () => connections.delete(state));
  socket.on('error', () => connections.delete(state));
  return state;
}

function clientOf(state) {
  return state;
}

function sendSessions(socket) {
  sendJson(socket, {
    kind: 'sessions',
    items: SESSIONS.map((session) => ({
      sessionId: session.sessionId,
      updatedAt: session.updatedAt,
      running: session.running,
      blank: session.blank,
      cwd: session.cwd,
      agentPreset: session.agentPreset,
      projections: { asOfSeq: 10, values: { title: session.title } },
    })),
  });
}

function sendCatalog(socket, requestId) {
  sendJson(socket, {
    kind: 'plugin-catalog',
    requestId,
    managementAvailable: true,
    settingsWritable: true,
    bundles: BUNDLES.map((bundle) => ({
      name: bundle.name,
      version: bundle.version,
      enabled: bundleEnabled[bundle.name],
      plugins: bundle.plugins.map((entry) => ({
        ...entry,
        enabled: bundleEnabled[bundle.name] && entry.enabled,
      })),
    })),
    plugins: [],
    officialItems: [],
  });
}

function handleMessage(socket, state, message) {
  const type = message.type;
  switch (type) {
    case 'ping':
      sendJson(socket, { kind: 'pong', at: Date.now() });
      break;
    case 'sessions':
      sendSessions(socket);
      break;
    case 'subscribe': {
      const sessionId = message.sessionId || 's-mock-1';
      state.sessionId = sessionId;
      state.subscriptionId = crypto.randomUUID();
      state.streamId = crypto.randomUUID();
      sendJson(socket, {
        kind: 'subscribed',
        sessionId,
        assistantStream: message.assistantStream === true,
        subscriptionId: state.subscriptionId,
      });
      sendJson(socket, {
        kind: 'session-snapshot',
        sessionId,
        subscriptionId: state.subscriptionId,
        streamId: state.streamId,
        historyFormatVersion: 4,
        cursor: 10,
        replace: true,
        view: 'conversation',
        events: HISTORY[sessionId] || [],
        bytes: 0,
        hasMore: false,
        projections: { asOfSeq: 10, values: {} },
      });
      break;
    }
    case 'message': {
      const sessionId = message.sessionId || 's-mock-1';
      if (!state.sessionId) {
        state.sessionId = sessionId;
        state.subscriptionId = crypto.randomUUID();
        state.streamId = crypto.randomUUID();
      }
      sendJson(socket, { kind: 'sent', sessionId, clientTimeZone: 'Asia/Shanghai' });
      simulateReply(socket, state, sessionId, String(message.text || ''));
      break;
    }
    case 'plugin-catalog':
      sendCatalog(socket, message.requestId);
      break;
    case 'plugin-bundle-set-enabled': {
      bundleEnabled[message.name] = message.enabled === true;
      sendJson(socket, {
        kind: 'plugin-bundle-set-enabled',
        requestId: message.requestId,
        result: { application: 'applied', changed: true },
      });
      log('bundle', message.name, '→', message.enabled);
      break;
    }
    case 'plugin-entry-set-enabled':
      sendJson(socket, {
        kind: 'plugin-entry-set-enabled',
        requestId: message.requestId,
        result: { application: 'applied', changed: true },
      });
      break;
    case 'session-rename':
      sendJson(socket, {
        kind: 'session-renamed',
        sessionId: message.sessionId,
        title: message.title,
        seq: 11,
      });
      break;
    case 'session-archive':
      sendJson(socket, {
        kind: 'session-archives',
        archivedSessionIds: [message.sessionId],
      });
      break;
    case 'history':
      sendJson(socket, {
        kind: 'history',
        sessionId: message.sessionId,
        events: HISTORY[message.sessionId] || [],
        historyFormatVersion: 4,
        cursor: 10,
        bytes: 0,
        view: 'conversation',
        hasMore: false,
      });
      break;
    default:
      log('未处理的请求帧:', type);
  }
}

function simulateReply(socket, state, sessionId, prompt) {
  const attemptId = `${sessionId}:${++state.turn}`;
  const streamId = state.streamId || crypto.randomUUID();
  const subscriptionId = state.subscriptionId || crypto.randomUUID();

  sendJson(socket, {
    kind: 'assistant-stream',
    sessionId,
    subscriptionId,
    streamId,
    frame: {
      type: 'start',
      attemptId,
      revision: state.turn,
      startedAfterSeq: 10,
      turn: state.turn,
      step: 0,
    },
  });

  const reply = `收到：${prompt}\n\n（这是 mock gateway 的流式回复，用于验证 assistant-stream 逐字追加、自动滚动和断线提示。）`;
  let index = 0;
  const tick = setInterval(() => {
    if (socket.destroyed) {
      clearInterval(tick);
      return;
    }
    if (index >= reply.length) {
      clearInterval(tick);
      const seq = 20 + state.turn;
      sendJson(socket, {
        kind: 'assistant-stream',
        sessionId,
        subscriptionId,
        streamId,
        frame: {
          type: 'end',
          attemptId,
          revision: state.turn,
          index: index,
          turn: state.turn,
          step: 0,
          outcome: { kind: 'committed', eventType: 'assistant/message', seq },
        },
      });
      sendJson(socket, {
        kind: 'event',
        sessionId,
        seq,
        time: Math.floor(Date.now() / 1000),
        event: {
          type: 'assistant/message',
          turn: state.turn,
          step: 0,
          text: reply,
          reasoning: '',
          toolCalls: [],
        },
      });
      return;
    }
    const delta = reply.slice(index, index + 2);
    index += 2;
    sendJson(socket, {
      kind: 'assistant-stream',
      sessionId,
      subscriptionId,
      streamId,
      frame: {
        type: 'chunk',
        attemptId,
        revision: state.turn,
        index,
        time: index,
        turn: state.turn,
        step: 0,
        chunk: { type: 'text-delta', index: 0, text: delta },
      },
    });
  }, 60);
}

function json(res, status, body) {
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  });
  res.end(JSON.stringify(body));
}

function readBody(req) {
  return new Promise((resolve) => {
    let text = '';
    req.on('data', (chunk) => {
      text += chunk;
      if (text.length > 1e6) req.destroy();
    });
    req.on('end', () => {
      try {
        resolve(text ? JSON.parse(text) : {});
      } catch {
        resolve({});
      }
    });
    req.on('error', () => resolve({}));
  });
}

function hostOf(req) {
  return req.headers.host || `127.0.0.1:${PORT}`;
}

/// mock 场景下允许账号令牌跨服务重启继续使用（内存 Map 会丢，但格式可校验）。
function sessionFor(token, host) {
  if (!token) return null;
  const known = accountTokens.get(token);
  if (known) return known;
  if (!/^acct-[0-9a-f]{16,}$/.test(token)) return null;
  const session = {
    account: { ...ACCOUNT_DEFAULT },
    gateway: { wsUrl: `ws://${host}/ws/mobile` },
    createdAt: Date.now(),
  };
  accountTokens.set(token, session);
  return session;
}

function createDeviceCode(host) {
  const deviceCode = crypto.randomBytes(18).toString('base64url');
  const userCode = String(100000 + Math.floor(Math.random() * 900000));
  const now = Date.now();
  const entry = {
    deviceCode,
    userCode,
    host,
    verifyUrl: `http://${host}/login?code=${deviceCode}`,
    createdAt: now,
    expiresAt: now + 5 * 60 * 1000,
    status: 'pending',
    token: null,
    account: null,
    gateway: null,
  };
  deviceCodes.set(deviceCode, entry);
  return entry;
}

function authorizeDevice(entry, account) {
  const token = `acct-${crypto.randomBytes(24).toString('hex')}`;
  entry.status = 'authorized';
  entry.token = token;
  entry.account = account;
  entry.gateway = { wsUrl: `ws://${entry.host}/ws/mobile` };
  accountTokens.set(token, {
    account,
    gateway: entry.gateway,
    createdAt: Date.now(),
  });
  log('设备登录成功:', entry.userCode, account.nickname, `¥${account.balance}`);
  return entry;
}

function loginPageHtml(entry) {
  const code = entry.deviceCode;
  const userCode = entry.userCode;
  return `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>DSH · 登录 DeepSeek</title>
<style>
  :root{color-scheme:dark}
  *{box-sizing:border-box}
  body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
    background:radial-gradient(120% 90% at 50% 0%,#1b2440 0%,#0b0e13 55%,#07090c 100%);
    font-family:-apple-system,"Segoe UI",Roboto,"PingFang SC","Microsoft YaHei",sans-serif;color:#e8ecf4}
  .card{width:min(92vw,380px);background:#151a22;border:1px solid #232b38;border-radius:22px;
    padding:28px 24px;box-shadow:0 24px 60px rgba(0,0,0,.45)}
  .logo{width:44px;height:44px;border-radius:12px;background:#4d6bfe;color:#fff;font-weight:700;
    display:flex;align-items:center;justify-content:center;font-size:22px;margin-bottom:18px}
  h1{font-size:22px;margin:0 0 6px}
  .sub{color:#8b96a8;font-size:13px;margin:0 0 20px;line-height:1.6}
  .code{background:#0f141b;border:1px solid #232b38;border-radius:12px;padding:12px 14px;
    font-size:13px;color:#8b96a8;display:flex;justify-content:space-between;align-items:center;margin-bottom:18px}
  .code b{color:#e8ecf4;letter-spacing:3px;font-size:18px}
  button{width:100%;border:0;border-radius:12px;padding:13px 0;font-size:15px;font-weight:600;
    cursor:pointer;background:#4d6bfe;color:#fff;transition:filter .15s}
  button:hover{filter:brightness(1.08)}
  button:disabled{opacity:.5;cursor:default}
  .divider{display:flex;align-items:center;gap:10px;color:#5a6577;font-size:12px;margin:20px 0 14px}
  .divider::before,.divider::after{content:"";height:1px;background:#232b38;flex:1}
  .phone{display:flex;gap:8px}
  .phone input{flex:1;min-width:0;background:#0f141b;border:1px solid #232b38;border-radius:12px;
    padding:12px 14px;color:#e8ecf4;font-size:15px;outline:none}
  .phone input:focus{border-color:#4d6bfe}
  .phone button{width:auto;padding:12px 16px;background:#232b38;color:#cdd6e4}
  #msg{margin:16px 0 0;font-size:13px;line-height:1.6;color:#4ddb8c;min-height:18px}
  .foot{color:#5a6577;font-size:12px;margin:14px 0 0;line-height:1.6}
  .warn{color:#ffb44d}
</style></head>
<body><div class="card">
  <div class="logo">D</div>
  <h1>登录 DSH</h1>
  <p class="sub">确认后，手机端会直接使用 DeepSeek 账号余额进行对话。</p>
  <div class="code"><span>设备编号</span><b>${userCode}</b></div>
  <button id="confirm">确认登录</button>
  <div class="divider"><span>或使用手机号</span></div>
  <div class="phone">
    <input id="phone" placeholder="手机号" inputmode="numeric" autocomplete="tel">
    <button id="phoneBtn">登录</button>
  </div>
  <p id="msg"></p>
  <p class="foot">登录成功后回到 App，它会自动完成登录并刷新余额。本页面只用于预览版演示。</p>
</div>
<script>
  const code = ${JSON.stringify(code)};
  const msg = document.getElementById('msg');
  function lock(text) {
    msg.className = '';
    msg.textContent = text;
    for (const id of ['confirm', 'phoneBtn']) document.getElementById(id).disabled = true;
  }
  async function post(path, body) {
    const res = await fetch(path, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || ('HTTP ' + res.status));
    return data;
  }
  function done(data) {
    lock('登录成功，余额 ¥' + (data.balance || 0).toFixed(2) + '，请回到 App。');
  }
  document.getElementById('confirm').onclick = async () => {
    try { done(await post('/login/confirm', { code })); }
    catch (error) { msg.className = 'warn'; msg.textContent = '登录失败：' + error.message; }
  };
  document.getElementById('phoneBtn').onclick = async () => {
    const phone = document.getElementById('phone').value.trim();
    if (!/^1\\d{10}$/.test(phone)) { msg.className = 'warn'; msg.textContent = '请输入 11 位手机号'; return; }
    try { done(await post('/login/phone', { code, phone })); }
    catch (error) { msg.className = 'warn'; msg.textContent = '登录失败：' + error.message; }
  };
</script>
</body></html>`;
}

const server = http.createServer(async (req, res) => {
  const host = hostOf(req);
  const url = new URL(req.url, `http://${host}`);
  const path = url.pathname;

  if (path.startsWith('/auth') && !path.startsWith('/auth/device/')) {
    log('http', req.method, path);
  }

  if (path === '/health') {
    json(res, 200, {
      ok: true,
      sessions: SESSIONS.length,
      accounts: accountTokens.size,
    });
    return;
  }

  if (path === '/debug') {
    json(res, 200, {
      logs: recentLogs,
      devices: [...deviceCodes.values()].map((entry) => ({
        deviceCode: entry.deviceCode,
        userCode: entry.userCode,
        status: entry.status,
        ageSeconds: Math.round((Date.now() - entry.createdAt) / 1000),
        expiresInSeconds: Math.round((entry.expiresAt - Date.now()) / 1000),
      })),
    });
    return;
  }

  if (path === '/pair') {
    // 方便测试：输出一条合法的 Base64URL 配对载荷（version 2）。
    const payload = {
      version: 2,
      publicUrl: `ws://${host}/ws/mobile`,
      pairingCode: 'TESTPAIR',
      expiresAt: Date.now() + 5 * 60 * 1000,
    };
    const text = Buffer.from(JSON.stringify(payload), 'utf8').toString('base64url');
    json(res, 200, { qrPayload: text, payload });
    return;
  }

  if (req.method === 'POST' && path === '/auth/device') {
    const entry = createDeviceCode(host);
    log('新设备码:', entry.userCode, entry.verifyUrl);
    json(res, 200, {
      deviceCode: entry.deviceCode,
      userCode: entry.userCode,
      verifyUrl: entry.verifyUrl,
      expiresIn: Math.round((entry.expiresAt - Date.now()) / 1000),
    });
    return;
  }

  if (req.method === 'GET' && path.startsWith('/auth/device/')) {
    const code = path.slice('/auth/device/'.length);
    const entry = deviceCodes.get(code);
    if (!entry) {
      json(res, 404, { status: 'unknown' });
      return;
    }
    if (entry.status !== 'authorized' && Date.now() > entry.expiresAt) {
      entry.status = 'expired';
    }
    if (entry.status === 'authorized') {
      json(res, 200, {
        status: 'authorized',
        token: entry.token,
        account: entry.account,
        gateway: entry.gateway,
      });
      return;
    }
    json(res, 200, { status: entry.status });
    return;
  }

  if (req.method === 'GET' && path === '/auth/me') {
    const token = url.searchParams.get('token') || '';
    const session = sessionFor(token, host);
    if (!session) {
      json(res, 401, { error: 'invalid token' });
      return;
    }
    // 每次刷新余额时略微变化，方便验证刷新链路。
    session.account.balance = Math.max(
      0,
      Number((session.account.balance - Math.random() * 0.3).toFixed(2)),
    );
    json(res, 200, {
      nickname: session.account.nickname,
      balance: session.account.balance,
    });
    return;
  }

  if (req.method === 'GET' && path === '/login') {
    const code = url.searchParams.get('code') || '';
    const entry = deviceCodes.get(code);
    if (!entry) {
      res.writeHead(404, { 'content-type': 'text/html; charset=utf-8' });
      res.end('<h1 style="color:#e8ecf4;background:#0b0e13;padding:40px;font-family:sans-serif">登录二维码已失效，请回 App 刷新</h1>');
      return;
    }
    if (entry.status !== 'authorized' && Date.now() > entry.expiresAt) entry.status = 'expired';
    if (entry.status === 'expired') {
      res.writeHead(410, { 'content-type': 'text/html; charset=utf-8' });
      res.end('<h1 style="color:#e8ecf4;background:#0b0e13;padding:40px;font-family:sans-serif">登录二维码已过期，请回 App 刷新</h1>');
      return;
    }
    res.writeHead(200, {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
    });
    res.end(loginPageHtml(entry));
    return;
  }

  if (req.method === 'POST' && (path === '/login/confirm' || path === '/login/phone')) {
    const body = await readBody(req);
    const entry = deviceCodes.get(String(body.code || ''));
    if (!entry) {
      json(res, 404, { error: '登录二维码已失效' });
      return;
    }
    if (entry.status !== 'authorized' && Date.now() > entry.expiresAt) entry.status = 'expired';
    if (entry.status === 'expired') {
      json(res, 410, { error: '登录二维码已过期' });
      return;
    }
    const phone = String(body.phone || '').trim();
    const account = phone
      ? { nickname: `DeepSeek ${phone.slice(-4)}`, balance: ACCOUNT_DEFAULT.balance }
      : { ...ACCOUNT_DEFAULT };
    authorizeDevice(entry, account);
    json(res, 200, {
      ok: true,
      nickname: entry.account.nickname,
      balance: entry.account.balance,
    });
    return;
  }

  // 模拟一个 OpenAI 兼容接口：用于验证「API Key 登录 → 直连对话」整条链路。
  if (path === '/v1/models') {
    const key = (req.headers.authorization || '').replace(/^Bearer\s+/i, '').trim();
    if (!key) {
      json(res, 401, { error: { message: '缺少 API Key' } });
      return;
    }
    json(res, 200, {
      object: 'list',
      data: [{ id: 'mock-chat', object: 'model', owned_by: 'mock' }],
    });
    return;
  }

  if (req.method === 'POST' && path === '/v1/chat/completions') {
    const key = (req.headers.authorization || '').replace(/^Bearer\s+/i, '').trim();
    if (!key) {
      json(res, 401, { error: { message: '缺少 API Key' } });
      return;
    }
    const body = await readBody(req);
    const messages = Array.isArray(body.messages) ? body.messages : [];
    const prompt = String(messages[messages.length - 1]?.content || '');
    log('openai', req.method, path, 'model=' + (body.model || '?'), 'key=' + key.slice(-4));

    res.writeHead(200, {
      'content-type': 'text/event-stream; charset=utf-8',
      'cache-control': 'no-store',
      connection: 'keep-alive',
    });
    const reply = `收到：${prompt}\n\n（这是 mock OpenAI 兼容接口的流式回复，用于验证 API Key 直连、逐字追加与自动滚动。）`;
    let index = 0;
    const timer = setInterval(() => {
      if (index >= reply.length) {
        clearInterval(timer);
        res.write(`data: ${JSON.stringify({ choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] })}\n\n`);
        res.end('data: [DONE]\n\n');
        return;
      }
      const delta = reply.slice(index, index + 2);
      index += 2;
      res.write(
        `data: ${JSON.stringify({
          id: 'mock-chatcmpl',
          object: 'chat.completion.chunk',
          choices: [{ index: 0, delta: { content: delta }, finish_reason: null }],
        })}\n\n`,
      );
    }, 40);
    req.on('close', () => clearInterval(timer));
    return;
  }

  res.writeHead(404);
  res.end();
});

server.on('upgrade', (req, socket) => {
  const key = req.headers['sec-websocket-key'];
  const rawProtocols = (req.headers['sec-websocket-protocol'] || '')
    .split(',')
    .map((value) => value.trim())
    .filter(Boolean);

  if (!key) {
    socket.write('HTTP/1.1 400 Bad Request\r\n\r\n');
    socket.destroy();
    return;
  }

  const hasMobile = rawProtocols.includes('dsh-mobile-v1');
  const pairProto = rawProtocols.find((p) => p.startsWith('dsh-pair.'));
  const authProto = rawProtocols.find((p) => p.startsWith('dsh-auth.'));
  const deviceProto = rawProtocols.find((p) => p.startsWith('dsh-device.'));

  const authToken = authProto ? authProto.slice('dsh-auth.'.length) : '';
  const accountSession = sessionFor(authToken, hostOf(req));
  const authorized =
    (pairProto && pairProto.slice('dsh-pair.'.length).length > 0) ||
    authToken === DEVICE_TOKEN ||
    !!accountSession;

  if (!hasMobile || !authorized) {
    log('拒绝握手:', { hasMobile, pair: !!pairProto, auth: !!authProto });
    socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
    socket.destroy();
    return;
  }

  const accept = crypto
    .createHash('sha1')
    .update(key + WS_GUID)
    .digest('base64');

  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
      'Upgrade: websocket\r\n' +
      'Connection: Upgrade\r\n' +
      `Sec-WebSocket-Accept: ${accept}\r\n` +
      'Sec-WebSocket-Protocol: dsh-mobile-v1\r\n\r\n',
  );

  const state = attachSocket(socket);
  state.account = accountSession ? accountSession.account : null;
  log('连接建立:', {
    pairing: !!pairProto,
    account: accountSession ? accountSession.account.nickname : '(未登录)',
    device: deviceProto || '(未声明)',
  });

  if (pairProto) {
    const deviceName = (req.headers['sec-websocket-protocol'] || '')
      .split(',')
      .map((v) => v.trim())
      .find((v) => v.startsWith('dsh-device-name.'));
    let name = 'Android';
    if (deviceName) {
      try {
        name = Buffer.from(deviceName.slice('dsh-device-name.'.length), 'base64url').toString('utf8');
      } catch {
        name = 'Android';
      }
    }
    sendJson(socket, {
      kind: 'paired',
      token: DEVICE_TOKEN,
      device: { id: deviceProto ? deviceProto.slice('dsh-device.'.length) : 'mock-device', name, createdAt: Date.now() },
    });
  }

  sendJson(socket, {
    kind: 'hello',
    protocol: 3,
    capabilities: [
      'assistant-stream-v1',
      'history-format-version',
      'session-archive',
      'session-rename',
      'plugin-management-v1',
    ],
    authenticated: true,
    account: accountSession ? accountSession.account : null,
    device: {
      id: deviceProto ? deviceProto.slice('dsh-device.'.length) : 'mock-device',
      name: accountSession ? accountSession.account.nickname : 'Android',
    },
    port: PORT,
    clients: connections.size,
  });
  sendSessions(socket);
});

server.listen(PORT, HOST, () => {
  log(`mock gateway 监听 ws://${HOST}:${PORT}/ws/mobile`);
  log(`模拟器请用 ws://10.0.2.2:${PORT}/ws/mobile，配对码任意（如 TESTPAIR）`);
  log(`GET http://127.0.0.1:${PORT}/pair 可拿到一条合法配对载荷`);
  log('按 Ctrl+C 退出');
});

process.on('SIGINT', () => {
  log('退出');
  process.exit(0);
});
