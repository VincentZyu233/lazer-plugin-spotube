#!/usr/bin/env node
/**
 * Lazer Spotube (Spotify) Cookie / 凭据自动抓取与持久化注入工具
 * 
 * 版本号跟随 manifest.json 自动同步。
 * 功能：
 *   拉起独立的 Chrome / Edge 浏览器窗口引导登录 Spotify，
 *   通过 Chrome DevTools Protocol (CDP) 自动监听并提取 Spotify 核心凭据 (sp_dc)，
 *   自动校验并获取 Spotify 账号个人信息（昵称、头像、VIP状态），
 *   自动注入 Lazer 本地插件存储 (storage.json)，并通过本地 Socket 实时通知客户端自动完成登录，
 *   同时自动复制凭据到系统剪贴板，方便手动粘贴备用。
 * 
 * 依赖：Node.js >= 18.0 (纯原生标准库，0 第三方 npm 依赖)
 */

const fs = require('fs');
const path = require('path');
const os = require('os');
const net = require('net');
const http = require('http');
const https = require('https');
const readline = require('readline');
const { spawn, exec } = require('child_process');

const MANIFEST = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'manifest.json'), 'utf8'));
const VERSION = MANIFEST.version || '0.1.0';
const PLUGIN_ID = MANIFEST.id || 'community.spotube.music';

function parseArgs() {
  const args = process.argv.slice(2);
  const options = {
    quitAfterDone: false,
    skipStorage: false,
    backup: false,
    browserPath: null,
    port: 0,
    url: 'https://accounts.spotify.com/zh-CN/login',
    timeout: 300,
    help: false
  };

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '-q' || arg === '--quit') {
      options.quitAfterDone = true;
    } else if (arg === '-s' || arg === '--skip-storage') {
      options.skipStorage = true;
    } else if (arg === '-b' || arg === '--backup') {
      options.backup = true;
    } else if (arg === '-p' || arg === '--browser-path') {
      options.browserPath = args[++i];
    } else if (arg === '--port') {
      options.port = parseInt(args[++i], 10);
    } else if (arg === '--timeout') {
      options.timeout = parseInt(args[++i], 10);
    } else if (arg === '-h' || arg === '--help') {
      options.help = true;
    }
  }

  return options;
}

function showHelp() {
  console.log(`
======================================================================
  Lazer Spotube (Spotify) Cookie 自动抓取工具 (v${VERSION})
======================================================================

使用方法:
  node tools/get_cookie.js [参数]

参数选项:
  -b, --backup        在脚本同级目录生成 cookie_backup.json 凭据备份文件
  -s, --skip-storage  跳过自动写入 Lazer 插件本地存储
  -q, --quit          抓取 Cookie 成功后自动关闭浏览器窗口 (默认保持打开)
  -p, --browser-path  指定浏览器可执行文件路径 (默认自动探测 Chrome / Edge)
  --port <port>       指定调试端口 (默认自动分配空闲端口)
  --timeout <sec>     等待登录超时时间 (秒，默认 300)
  -h, --help          查看本帮助信息

示例:
  node tools/get_cookie.js            # 抓取并自动注入 Lazer 插件存储 + 通知 Lazer 客户端
  node tools/get_cookie.js -s         # 仅抓取并复制到剪贴板，不写入 Lazer 存储
  node tools/get_cookie.js -q         # 抓取完成后自动关闭浏览器
`);
}

function detectBrowser() {
  const platform = os.platform();

  if (platform === 'win32') {
    const prefixes = [
      process.env.LOCALAPPDATA,
      process.env['PROGRAMFILES'],
      process.env['PROGRAMFILES(X86)']
    ].filter(Boolean);

    const candidates = [];
    for (const prefix of prefixes) {
      candidates.push(
        path.join(prefix, 'Google', 'Chrome', 'Application', 'chrome.exe'),
        path.join(prefix, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
        path.join(prefix, 'BraveSoftware', 'Brave-Browser', 'Application', 'brave.exe')
      );
    }

    for (const p of candidates) {
      if (fs.existsSync(p)) return p;
    }
  } else if (platform === 'darwin') {
    const candidates = [
      '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
      '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
      path.join(os.homedir(), 'Applications/Google Chrome.app/Contents/MacOS/Google Chrome')
    ];

    for (const p of candidates) {
      if (fs.existsSync(p)) return p;
    }
  } else if (platform === 'linux') {
    const binaries = [
      'google-chrome',
      'google-chrome-stable',
      'chromium',
      'chromium-browser',
      'microsoft-edge',
      'brave-browser'
    ];

    for (const b of binaries) {
      try {
        const out = require('child_process').execSync(`which ${b} 2>/dev/null`).toString().trim();
        if (out && fs.existsSync(out)) return out;
      } catch (_) {}
    }
  }

  return null;
}

function getFreePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.listen(0, '127.0.0.1', () => {
      const port = srv.address().port;
      srv.close(() => resolve(port));
    });
    srv.on('error', reject);
  });
}

function copyToClipboard(text) {
  const platform = os.platform();

  return new Promise((resolve) => {
    if (platform === 'win32') {
      const ps = spawn('powershell.exe', ['-NoProfile', '-Command', '$input | Set-Clipboard']);
      ps.stdin.write(text);
      ps.stdin.end();
      ps.on('close', (code) => {
        if (code === 0) return resolve(true);
        const clip = spawn('clip.exe');
        clip.stdin.write(text);
        clip.stdin.end();
        clip.on('close', () => resolve(true));
      });
      ps.on('error', () => {
        const clip = spawn('clip.exe');
        clip.stdin.write(text);
        clip.stdin.end();
        clip.on('close', () => resolve(true));
      });
    } else if (platform === 'darwin') {
      const pbcopy = spawn('pbcopy');
      pbcopy.stdin.write(text);
      pbcopy.stdin.end();
      pbcopy.on('close', () => resolve(true));
      pbcopy.on('error', () => resolve(false));
    } else {
      const xclip = spawn('xclip', ['-selection', 'clipboard']);
      xclip.stdin.write(text);
      xclip.stdin.end();
      xclip.on('close', (code) => {
        if (code === 0) return resolve(true);
        const wl = spawn('wl-copy');
        wl.stdin.write(text);
        wl.stdin.end();
        wl.on('close', () => resolve(true));
        wl.on('error', () => resolve(false));
      });
      xclip.on('error', () => {
        const wl = spawn('wl-copy');
        wl.stdin.write(text);
        wl.stdin.end();
        wl.on('close', () => resolve(true));
        wl.on('error', () => resolve(false));
      });
    }
  });
}

function resolveLazerStoragePaths() {
  const platform = os.platform();
  const home = os.homedir();
  const candidates = [];

  if (platform === 'win32') {
    const appData = process.env.APPDATA || path.join(home, 'AppData', 'Roaming');
    candidates.push(
      path.join(appData, 'dev.naominet', 'lazer_nextgen', 'lua_plugin_data', PLUGIN_ID, 'storage.json'),
      path.join(appData, 'dev.naominet', 'lazer_nextgen', 'lua_plugins', PLUGIN_ID, 'storage.json'),
      path.join(appData, 'dev.naominet.lazer', 'lua_plugin_data', PLUGIN_ID, 'storage.json')
    );
    // 检查本地可用的便携版路径
    const portableWin = 'D:\\Downloads\\lazer\\win\\lua_plugin_data\\' + PLUGIN_ID + '\\storage.json';
    const devFlutterWin = 'E:\\SSoftwareFiles\\LazerNextgenFlutter\\lua_plugin_data\\' + PLUGIN_ID + '\\storage.json';
    candidates.push(portableWin, devFlutterWin);
  } else if (platform === 'darwin') {
    candidates.push(
      path.join(home, 'Library', 'Application Support', 'dev.naominet.lazer', 'lua_plugin_data', PLUGIN_ID, 'storage.json'),
      path.join(home, 'Library', 'Application Support', 'dev.naominet', 'lazer_nextgen', 'lua_plugin_data', PLUGIN_ID, 'storage.json')
    );
  } else {
    const xdgData = process.env.XDG_DATA_HOME || path.join(home, '.local', 'share');
    candidates.push(
      path.join(xdgData, 'dev.naominet.lazer', 'lua_plugin_data', PLUGIN_ID, 'storage.json'),
      path.join(xdgData, 'dev.naominet', 'lazer_nextgen', 'lua_plugin_data', PLUGIN_ID, 'storage.json')
    );
  }

  return candidates;
}

function autoInjectToLazerStorage(spDc, profile) {
  const paths = resolveLazerStoragePaths();
  let written = [];

  for (const storageFile of paths) {
    try {
      const storageDir = path.dirname(storageFile);
      if (!fs.existsSync(storageDir)) {
        fs.mkdirSync(storageDir, { recursive: true });
      }

      let data = {};
      if (fs.existsSync(storageFile)) {
        try {
          data = JSON.parse(fs.readFileSync(storageFile, 'utf8'));
        } catch (_) {}
      }

      data.sp_dc = spDc;
      if (profile) {
        if (profile.accessToken) data.sp_access_token = profile.accessToken;
        if (profile.accessTokenExpirationTimestampMs) {
          data.sp_token_exp = Math.floor(profile.accessTokenExpirationTimestampMs / 1000);
        }
        if (profile.user) data.sp_user = profile.user;
      }
      data.auth_time = Date.now();

      fs.writeFileSync(storageFile, JSON.stringify(data, null, 2), 'utf8');
      written.push(storageFile);
    } catch (_) {}
  }

  return written;
}

function notifyLazerSocket(spDc) {
  return new Promise((resolve) => {
    const client = net.connect({ host: '127.0.0.1', port: 28795 }, () => {
      client.write(JSON.stringify({ op: 'auth', sp_dc: spDc }) + '\n');
      client.end();
      resolve(true);
    });
    client.on('error', () => resolve(false));
    client.setTimeout(1000, () => {
      client.destroy();
      resolve(false);
    });
  });
}

function fetchSpotifyUserProfile(spDc) {
  return new Promise((resolve) => {
    const tokenUrl = 'https://open.spotify.com/get_access_token?reason=transport&productType=web_player';
    const req = https.get(tokenUrl, {
      headers: {
        'Cookie': `sp_dc=${spDc}`,
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36'
      }
    }, (res) => {
      let body = '';
      res.on('data', chunk => body += chunk);
      res.on('end', () => {
        try {
          const data = JSON.parse(body);
          if (data && data.accessToken) {
            const meReq = https.get('https://api.spotify.com/v1/me', {
              headers: {
                'Authorization': `Bearer ${data.accessToken}`,
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36'
              }
            }, (meRes) => {
              let meBody = '';
              meRes.on('data', c => meBody += c);
              meRes.on('end', () => {
                try {
                  const me = JSON.parse(meBody);
                  let avatar = '';
                  if (me.images && me.images.length > 0 && me.images[0].url) {
                    avatar = me.images[0].url;
                  }
                  resolve({
                    accessToken: data.accessToken,
                    accessTokenExpirationTimestampMs: data.accessTokenExpirationTimestampMs,
                    user: {
                      id: me.id || 'spotify_user',
                      name: me.display_name || me.id || 'Spotify 用户',
                      avatarUrl: avatar,
                      vip: (me.product === 'premium')
                    }
                  });
                } catch (_) {
                  resolve({
                    accessToken: data.accessToken,
                    accessTokenExpirationTimestampMs: data.accessTokenExpirationTimestampMs,
                    user: { id: 'spotify_user', name: 'Spotify 用户', avatarUrl: '', vip: false }
                  });
                }
              });
            });
            meReq.on('error', () => resolve(null));
            return;
          }
        } catch (_) {}
        resolve(null);
      });
    });
    req.on('error', () => resolve(null));
  });
}

class SimpleWebSocket {
  constructor(wsUrl) {
    this.url = new URL(wsUrl);
    this.socket = null;
    this.buffer = Buffer.alloc(0);
    this.onmessage = null;
    this.onopen = null;
    this.onclose = null;
    this.onerror = null;
  }

  connect() {
    return new Promise((resolve, reject) => {
      const key = Buffer.from(Math.random().toString()).toString('base64');
      const req = http.request({
        hostname: this.url.hostname,
        port: this.url.port,
        path: this.url.pathname + this.url.search,
        headers: {
          'Connection': 'Upgrade',
          'Upgrade': 'websocket',
          'Sec-WebSocket-Version': '13',
          'Sec-WebSocket-Key': key
        }
      });

      req.on('upgrade', (res, socket) => {
        this.socket = socket;
        this._setupSocket();
        if (this.onopen) this.onopen();
        resolve();
      });

      req.on('error', (err) => {
        if (this.onerror) this.onerror(err);
        reject(err);
      });

      req.end();
    });
  }

  _setupSocket() {
    this.socket.on('data', (chunk) => {
      this.buffer = Buffer.concat([this.buffer, chunk]);
      this._parseFrames();
    });
    this.socket.on('close', () => {
      if (this.onclose) this.onclose();
    });
    this.socket.on('error', (err) => {
      if (this.onerror) this.onerror(err);
    });
  }

  _parseFrames() {
    while (this.buffer.length >= 2) {
      const b1 = this.buffer[0];
      const b2 = this.buffer[1];
      const opcode = b1 & 0x0f;
      let len = b2 & 0x7f;
      let offset = 2;

      if (len === 126) {
        if (this.buffer.length < 4) return;
        len = this.buffer.readUInt16BE(2);
        offset = 4;
      } else if (len === 127) {
        if (this.buffer.length < 10) return;
        len = Number(this.buffer.readBigUInt64BE(2));
        offset = 10;
      }

      if (this.buffer.length < offset + len) return;

      const payload = this.buffer.slice(offset, offset + len);
      this.buffer = this.buffer.slice(offset + len);

      if (opcode === 1) {
        if (this.onmessage) this.onmessage(payload.toString('utf8'));
      } else if (opcode === 8) {
        this.close();
      }
    }
  }

  send(data) {
    if (!this.socket || this.socket.destroyed) return;
    const payload = Buffer.from(data, 'utf8');
    const len = payload.length;
    let header;

    if (len <= 125) {
      header = Buffer.from([0x81, 0x80 | len]);
    } else if (len <= 65535) {
      header = Buffer.alloc(4);
      header[0] = 0x81;
      header[1] = 0x80 | 126;
      header.writeUInt16BE(len, 2);
    } else {
      header = Buffer.alloc(10);
      header[0] = 0x81;
      header[1] = 0x80 | 127;
      header.writeBigUInt64BE(BigInt(len), 2);
    }

    const mask = Buffer.from([0x12, 0x34, 0x56, 0x78]);
    const masked = Buffer.alloc(len);
    for (let i = 0; i < len; i++) {
      masked[i] = payload[i] ^ mask[i % 4];
    }

    this.socket.write(Buffer.concat([header, mask, masked]));
  }

  close() {
    if (this.socket && !this.socket.destroyed) {
      this.socket.end();
    }
  }
}

class CDPClient {
  constructor(wsUrl) {
    this.ws = new SimpleWebSocket(wsUrl);
    this.nextId = 1;
    this.callbacks = new Map();

    this.ws.onmessage = (msg) => {
      try {
        const data = JSON.parse(msg);
        if (data.id && this.callbacks.has(data.id)) {
          const { resolve, reject } = this.callbacks.get(data.id);
          this.callbacks.delete(data.id);
          if (data.error) reject(new Error(data.error.message || JSON.stringify(data.error)));
          else resolve(data.result);
        }
      } catch (_) {}
    };
  }

  async connect() {
    await this.ws.connect();
  }

  send(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = this.nextId++;
      this.callbacks.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }

  close() {
    this.ws.close();
  }
}

async function getCDPTarget(port) {
  for (let i = 0; i < 30; i++) {
    try {
      const data = await new Promise((resolve, reject) => {
        const req = http.get(`http://127.0.0.1:${port}/json`, (res) => {
          let body = '';
          res.on('data', chunk => body += chunk);
          res.on('end', () => {
            try { resolve(JSON.parse(body)); } catch (e) { reject(e); }
          });
        });
        req.on('error', reject);
        req.setTimeout(1000, () => req.destroy());
      });

      if (Array.isArray(data) && data.length > 0) {
        const page = data.find(t => t.type === 'page' && t.webSocketDebuggerUrl) || data[0];
        if (page && page.webSocketDebuggerUrl) return page;
      }
    } catch (_) {}
    await new Promise(r => setTimeout(r, 500));
  }
  return null;
}

async function main() {
  const options = parseArgs();

  if (options.help) {
    showHelp();
    return;
  }

  console.log(`
======================================================================
  Lazer Spotube (Spotify) Cookie 自动抓取与持久化工具 (v${VERSION})
======================================================================
`);

  const browserPath = options.browserPath || detectBrowser();
  if (!browserPath || !fs.existsSync(browserPath)) {
    console.error(`[!] 错误: 未能在系统中自动找到可用的 Chromium 浏览器 (Chrome / Edge / Brave)。`);
    console.error(`    请使用 -p 或 --browser-path 手动指定浏览器可执行文件路径。\n`);
    process.exit(1);
  }

  console.log(`[*] 使用浏览器: ${browserPath}`);

  const port = options.port || await getFreePort();
  console.log(`[*] 浏览器调试端口: ${port}`);

  const profileDir = path.join(os.tmpdir(), `lazer_spotube_browser_${port}`);
  if (!fs.existsSync(profileDir)) fs.mkdirSync(profileDir, { recursive: true });

  console.log(`[*] 临时用户配置目录: ${profileDir}`);
  console.log(`[*] 启动浏览器中...`);

  const browserProcess = spawn(browserPath, [
    `--remote-debugging-port=${port}`,
    `--user-data-dir=${profileDir}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--window-size=1080,780',
    options.url
  ], {
    detached: false,
    stdio: 'ignore'
  });

  browserProcess.on('error', (err) => {
    console.error(`[!] 启动浏览器失败:`, err);
    process.exit(1);
  });

  console.log(`[*] 正在建立 CDP 协议通信通道...`);
  const target = await getCDPTarget(port);
  if (!target) {
    console.error(`[!] 无法连接到浏览器的 DevTools 端口。`);
    try { browserProcess.kill(); } catch (_) {}
    process.exit(1);
  }

  console.log(`[*] 成功连接至浏览器会话: ${target.title || target.url}`);
  const cdp = new CDPClient(target.webSocketDebuggerUrl);
  await cdp.connect();

  await cdp.send('Network.enable');
  await cdp.send('Page.enable');

  console.log(`\n======================================================================`);
  console.log(`  👉 请在弹出的浏览器窗口中完成 Spotify 登录 (账号密码/Google/Apple 均可)`);
  console.log(`======================================================================\n`);
  console.log(`[*] 正在实时监听 Cookie 状态变化 (超时时间: ${options.timeout}s)...`);

  const startTime = Date.now();
  let capturedSpDc = null;

  while ((Date.now() - startTime) < options.timeout * 1000) {
    try {
      const res = await cdp.send('Network.getCookies', {
        urls: [
          'https://open.spotify.com',
          'https://spotify.com',
          'https://accounts.spotify.com'
        ]
      });

      if (res && Array.isArray(res.cookies)) {
        const spDcCookie = res.cookies.find(c => c.name === 'sp_dc');
        if (spDcCookie && spDcCookie.value && spDcCookie.value.length >= 15) {
          capturedSpDc = spDcCookie.value;
          break;
        }
      }
    } catch (_) {}

    await new Promise(r => setTimeout(r, 1500));
  }

  if (!capturedSpDc) {
    console.error(`\n[!] 等待登录超时 (${options.timeout}s)，未能提取到 sp_dc 凭据。`);
    cdp.close();
    if (options.quitAfterDone) browserProcess.kill();
    process.exit(1);
  }

  console.log(`\n======================================================================`);
  console.log(`  🎉 成功捕获 Spotify 登录凭据 (sp_dc)！`);
  console.log(`======================================================================`);

  console.log(`[*] 正在请求 Spotify 官方端点校验凭据并解析账号资料...`);
  const profile = await fetchSpotifyUserProfile(capturedSpDc);

  if (profile && profile.user) {
    console.log(`\n  👤 用户昵称: ${profile.user.name}`);
    console.log(`  🆔 用户 ID:   ${profile.user.id}`);
    console.log(`  💎 VIP 状态:  ${profile.user.vip ? 'Spotify Premium 尊享会员' : '免费普通账户'}`);
  } else {
    console.log(`  ⚠️ 身份验证响应异常，将保留纯凭据继续尝试登录。`);
  }

  // 1. 自动写入 Lazer 插件存储
  if (!options.skipStorage) {
    const injectedPaths = autoInjectToLazerStorage(capturedSpDc, profile);
    if (injectedPaths.length > 0) {
      console.log(`\n[+] 已自动持久化注入 Lazer 本地存储：`);
      for (const p of injectedPaths) {
        console.log(`    📁 ${p}`);
      }
    } else {
      console.log(`\n[!] 未能找到 Lazer 默认数据目录，跳过文件写入。`);
    }
  }

  // 2. 尝试通过本地 Socket 广播通知 Lazer 客户端 (针对 QR / 网页授权模式)
  console.log(`[*] 正在尝试通知 Lazer 客户端完成登录态交接 (127.0.0.1:28795)...`);
  const notified = await notifyLazerSocket(capturedSpDc);
  if (notified) {
    console.log(`[+] ⚡ 成功通知运行中的 Lazer 客户端！Lazer 登录弹窗已自动刷新并完成登录！`);
  } else {
    console.log(`[*] Lazer 客户端当前未在等待 Socket 通知（若 Lazer 正开着登录框，可切换至 Cookie 标签粘贴，或重启 Lazer 直接进入登录态）。`);
  }

  // 3. 复制到系统剪贴板
  const copied = await copyToClipboard(capturedSpDc);
  if (copied) {
    console.log(`[+] 📋 已自动复制 sp_dc 凭据至系统剪贴板！`);
  }

  // 4. 生成本地备份
  if (options.backup) {
    const backupPath = path.join(__dirname, 'cookie_backup.json');
    const backupData = {
      sp_dc: capturedSpDc,
      profile: profile || null,
      saved_at: new Date().toISOString()
    };
    fs.writeFileSync(backupPath, JSON.stringify(backupData, null, 2), 'utf8');
    console.log(`[+] 💾 已在 tools 目录下生成凭据备份: ${backupPath}`);
  }

  console.log(`\n======================================================================`);
  console.log(`  🚀 登录就绪！你现在可以直接返回 Lazer 开始畅听歌曲与榜单。`);
  console.log(`======================================================================\n`);

  cdp.close();

  if (options.quitAfterDone) {
    console.log(`[*] 已指定 -q 参数，正在关闭浏览器...`);
    try { browserProcess.kill(); } catch (_) {}
  } else {
    console.log(`[*] 浏览器窗口已保留，如需关闭请手动关闭即可。`);
  }

  process.exit(0);
}

main().catch(err => {
  console.error(`[!] 致命错误:`, err);
  process.exit(1);
});
