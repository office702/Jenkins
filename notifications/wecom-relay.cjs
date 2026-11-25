const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { WSClient } = require('@wecom/aibot-node-sdk');

process.umask(0o077);

const socketPath = path.join(__dirname, 'notify.sock');
const pairPath = path.join(__dirname, 'pair-code');
const groupPath = path.join(__dirname, 'group.json');
const credentials = JSON.parse(fs.readFileSync(path.join(__dirname, 'bot.json'), 'utf8'));
let chatId = fs.existsSync(groupPath) ? JSON.parse(fs.readFileSync(groupPath, 'utf8')).chatid : '';
const pairCode = chatId ? '' : fs.readFileSync(pairPath, 'utf8').trim();
if (!chatId && !/^\d{6}$/.test(pairCode)) {
  throw new Error('Expected a six-digit group binding code');
}

const quiet = () => {};
const client = new WSClient({
  botId: credentials.botId,
  secret: credentials.secret,
  maxReconnectAttempts: -1,
  logger: { debug: quiet, info: quiet, warn: quiet, error: quiet },
});

let authenticated = false;
client.on('authenticated', () => {
  authenticated = true;
  console.log('WeCom authenticated');
});
client.on('disconnected', () => {
  authenticated = false;
  console.log('WeCom disconnected');
});
client.on('error', (error) => {
  console.error('WeCom connection error', error.name);
});
client.on('message.text', ({ body }) => {
  if (chatId || body?.chattype !== 'group' || typeof body.chatid !== 'string' || !body.chatid) {
    return;
  }
  const content = body.text?.content?.trim().replace(/\s+/g, ' ');
  const command = `Jenkins绑定 ${pairCode}`;
  if (content !== command && !content?.endsWith(` ${command}`)) {
    return;
  }
  try {
    const pending = `${groupPath}.${process.pid}.tmp`;
    fs.writeFileSync(pending, JSON.stringify({ chatid: body.chatid }), { mode: 0o600 });
    fs.renameSync(pending, groupPath);
    chatId = body.chatid;
    fs.rmSync(pairPath, { force: true });
    console.log('WeCom group bound');
  } catch (error) {
    console.error('WeCom group binding file error', error.code);
  }
});

function respond(res, code, body) {
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}

const maxBytes = 4096;
const server = http.createServer({ requestTimeout: 10000 }, async (req, res) => {
  if (req.method === 'GET' && req.url === '/status') {
    respond(res, 200, { authenticated, group_bound: Boolean(chatId) });
    return;
  }
  if (req.method !== 'POST' || req.url !== '/notify') {
    respond(res, 404, { ok: false });
    return;
  }
  if (!authenticated || !chatId) {
    respond(res, 503, { ok: false, error: 'Bot or group not ready' });
    return;
  }

  const chunks = [];
  let bytes = 0;
  try {
    for await (const chunk of req.iterator({ destroyOnReturn: false })) {
      bytes += chunk.length;
      if (bytes > maxBytes) {
        respond(res, 413, { ok: false });
        return;
      }
      chunks.push(chunk);
    }
  } catch (error) {
    console.error('WeCom relay request interrupted', error.code);
    return;
  }
  const content = Buffer.concat(chunks).toString('utf8').trim();
  if (!content) {
    respond(res, 400, { ok: false });
    return;
  }

  try {
    const result = await client.sendMessage(chatId, { msgtype: 'markdown', markdown: { content } });
    if (result.errcode !== 0) {
      console.error('WeCom rejected delivery', Number(result.errcode));
      respond(res, 502, { ok: false });
      return;
    }
    respond(res, 200, { ok: true });
  } catch (error) {
    console.error('WeCom delivery failed', error.name || Number(error.errcode));
    respond(res, 502, { ok: false });
  }
});

if (fs.existsSync(socketPath) && fs.lstatSync(socketPath).isSocket()) {
  fs.unlinkSync(socketPath);
}
server.listen(socketPath, () => {
  fs.chmodSync(socketPath, 0o600);
  client.connect();
});
