/**
 * LRCLIB 上游歌词 API 验证脚本
 * 验证 Spotube 所使用的官方上游 LRCLIB (https://lrclib.net) 对歌曲歌词的真实获取情况
 * 输出格式: Markdown (.md)
 */

const https = require('https');
const http = require('http');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');

const tracks = [
  {
    name: 'kyu-kurarin',
    artist: 'Iyowa',
    duration: 217
  },
  {
    name: 'Living Millennium',
    artist: 'Iyowa',
    duration: 200
  },
  {
    name: 'Heat abnormal',
    artist: 'Iyowa',
    duration: 240
  }
];

function fetchWithProxy(targetUrl) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(targetUrl);
    const proxyUrl = process.env.HTTPS_PROXY || process.env.HTTP_PROXY || 'http://127.0.0.1:7890';
    
    // 优先尝试代理，若连接被拒则回退直连
    const tryDirect = () => {
      const req = https.get(targetUrl, {
        headers: {
          'User-Agent': 'Spotube/v6.0.0 (https://github.com/KRTirtho/spotube)'
        },
        timeout: 10000
      }, (res) => {
        let body = '';
        res.on('data', chunk => body += chunk);
        res.on('end', () => {
          resolve({ status: res.statusCode, body, mode: '直连' });
        });
      });
      req.on('error', (err) => reject(err));
      req.on('timeout', () => { req.destroy(); reject(new Error('直连超时')); });
    };

    if (proxyUrl) {
      try {
        const proxy = new URL(proxyUrl);
        const req = http.request({
          host: proxy.hostname,
          port: proxy.port,
          method: 'CONNECT',
          path: `${parsed.hostname}:443`
        });

        req.on('connect', (res, socket) => {
          if (res.statusCode === 200) {
            const agent = new https.Agent({ socket });
            const sreq = https.get(targetUrl, {
              agent,
              headers: {
                'User-Agent': 'Spotube/v6.0.0 (https://github.com/KRTirtho/spotube)',
                'Host': parsed.hostname
              },
              timeout: 10000
            }, (sres) => {
              let body = '';
              sres.on('data', chunk => body += chunk);
              sres.on('end', () => {
                resolve({ status: sres.statusCode, body, mode: `代理 (${proxyUrl})` });
              });
            });
            sreq.on('error', reject);
          } else {
            tryDirect();
          }
        });

        req.on('error', () => {
          tryDirect();
        });

        req.setTimeout(4000, () => {
          req.destroy();
          tryDirect();
        });
        req.end();
      } catch (e) {
        tryDirect();
      }
    } else {
      tryDirect();
    }
  });
}

async function run() {
  console.log('====================================================');
  console.log('   LRCLIB (https://lrclib.net) 上游歌词抓取验证');
  console.log('====================================================\n');

  const rows = [];
  const details = [];

  for (let i = 0; i < tracks.length; i++) {
    const t = tracks[i];
    const query = `track_name=${encodeURIComponent(t.name)}&artist_name=${encodeURIComponent(t.artist)}&duration=${t.duration}`;
    const url = `https://lrclib.net/api/get?${query}`;
    
    console.log(`[${i + 1}/${tracks.length}] 请求: ${t.name} - ${t.artist} (${t.duration}s)`);
    console.log(`     URL: ${url}`);
    
    const startTime = Date.now();
    try {
      const res = await fetchWithProxy(url);
      const elapsed = Date.now() - startTime;
      console.log(`     响应状态: ${res.status} (${res.mode}, 耗时: ${elapsed}ms)`);
      
      let data = null;
      try {
        data = JSON.parse(res.body);
      } catch (e) {
        console.error('     JSON 解析失败:', e.message);
      }

      if (data) {
        const hasSynced = Boolean(data.syncedLyrics && data.syncedLyrics.trim().length > 0);
        const hasPlain = Boolean(data.plainLyrics && data.plainLyrics.trim().length > 0);
        const lineCount = hasSynced ? data.syncedLyrics.trim().split('\n').length : (hasPlain ? data.plainLyrics.trim().split('\n').length : 0);
        
        console.log(`     结果: ID=${data.id}, 包含同步歌词(syncedLyrics)=${hasSynced}, 纯文本(plainLyrics)=${hasPlain}, 行数: ${lineCount}`);

        rows.push(`| **${t.name}** | ${t.artist} | ${t.duration}s | **${res.status}** | ${elapsed} ms | ${hasSynced ? '✅ 同步歌词 (Synced)' : (hasPlain ? 'ℹ️ 纯文本 (Plain)' : '❌ 无')} | ${lineCount} 行 |`);

        details.push(`### ${i + 1}. ${t.name} - ${t.artist}\n`);
        details.push(`- **请求地址**: \`${url}\``);
        details.push(`- **HTTP 状态**: \`${res.status}\``);
        details.push(`- **网络耗时**: \`${elapsed} ms\` (${res.mode})`);
        details.push(`- **LRCLIB ID**: \`${data.id}\``);
        details.push(`- **曲目信息**: ${data.trackName} / ${data.artistName} (专辑: *${data.albumName || 'N/A'}*)`);
        details.push(`- **同步时间轴 (\`syncedLyrics\`)**: ${hasSynced ? '✅ 存在' : '❌ 未提供'}`);
        details.push(`- **纯文本歌词 (\`plainLyrics\`)**: ${hasPlain ? '✅ 存在' : '❌ 未提供'}`);
        details.push(`- **歌词总行数**: ${lineCount} 行\n`);
        details.push(`#### 完整歌词内容\n`);
        details.push('```lrc');
        details.push(data.syncedLyrics || data.plainLyrics || '(无歌词内容)');
        details.push('```\n');
      } else {
        rows.push(`| **${t.name}** | ${t.artist} | ${t.duration}s | **${res.status}** | ${elapsed} ms | ❌ 解析失败 | 0 行 |`);
        details.push(`### ${i + 1}. ${t.name} - ${t.artist} (请求失败)\n`);
        details.push(`- **请求地址**: \`${url}\``);
        details.push(`- **HTTP 状态**: \`${res.status}\``);
        details.push(`- **响应内容**:\n\`\`\`\n${res.body}\n\`\`\`\n`);
      }
    } catch (err) {
      console.error(`     请求异常:`, err.message);
      rows.push(`| **${t.name}** | ${t.artist} | ${t.duration}s | **ERROR** | - | ❌ 请求异常: ${err.message} | 0 行 |`);
      details.push(`### ${i + 1}. ${t.name} - ${t.artist} (异常)\n- **错误信息**: ${err.message}\n`);
    }
    console.log('');
  }

  const mdContent = [
    '# LRCLIB 上游歌词 API 验证测试报告',
    '',
    `> **测试时间**: \`${new Date().toISOString()}\`  `,
    `> **上游接口**: \`https://lrclib.net/api/get\` (Spotube 官方同款上游源)  `,
    `> **客户端标识**: \`Spotube/v6.0.0 (https://github.com/KRTirtho/spotube)\`  `,
    '',
    '## 📊 测试结果汇总',
    '',
    '| 歌曲名 | 歌手 | 时长 | 响应状态 | 网络耗时 | 歌词类型 | 行数 |',
    '| :--- | :--- | :--- | :--- | :--- | :--- | :--- |',
    ...rows,
    '',
    '---',
    '',
    '## 📝 歌曲详细信息与歌词正文',
    '',
    ...details
  ].join('\n');

  // 删除旧的 .txt 文件
  const txtPath = path.join(__dirname, 'lyrics_api_result.txt');
  if (fs.existsSync(txtPath)) {
    fs.unlinkSync(txtPath);
    console.log(`[Clean] 已删除旧文本文件: ${txtPath}`);
  }

  // 写入新的 .md 文件
  const mdPath = path.join(__dirname, 'lyrics_api_result.md');
  fs.writeFileSync(mdPath, mdContent, 'utf8');
  console.log('====================================================');
  console.log(`验证完成！Markdown 报告已生成至:`);
  console.log(`[FILE] ${mdPath}`);
  console.log('====================================================');
}

run();
