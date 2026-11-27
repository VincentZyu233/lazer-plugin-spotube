/**
 * LRCLIB 上游歌词 API 验证脚本
 * 验证 Spotube 所使用的官方上游 LRCLIB (https://lrclib.net) 对歌曲歌词的真实获取情况
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
          resolve({ status: res.statusCode, body, mode: 'direct' });
        });
      });
      req.on('error', (err) => reject(err));
      req.on('timeout', () => { req.destroy(); reject(new Error('Direct timeout')); });
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
                resolve({ status: sres.statusCode, body, mode: 'proxy (' + proxyUrl + ')' });
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

  const outputLines = [];
  outputLines.push('====================================================');
  outputLines.push('LRCLIB (https://lrclib.net) 歌词接口测试验证输出报告');
  outputLines.push('测试时间: ' + new Date().toISOString());
  outputLines.push('====================================================\n');

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
        
        console.log(`     结果: ID=${data.id}, 包含同步歌词(syncedLyrics)=${hasSynced}, 纯文本(plainLyrics)=${hasPlain}`);
        if (hasSynced) {
          const lrcLines = data.syncedLyrics.trim().split('\n');
          console.log(`     歌词行数: ${lrcLines.length} 行`);
          console.log(`     歌词前 2 行:`);
          lrcLines.slice(0, 2).forEach(l => console.log(`       ${l}`));
        }

        outputLines.push(`----------------------------------------------------`);
        outputLines.push(`歌曲 [${i + 1}]: ${t.name} - ${t.artist}`);
        outputLines.push(`请求 URL: ${url}`);
        outputLines.push(`响应状态码: ${res.status}`);
        outputLines.push(`网络耗时: ${elapsed} ms (${res.mode})`);
        outputLines.push(`LRCLIB ID: ${data.id}`);
        outputLines.push(`歌曲名: ${data.trackName}`);
        outputLines.push(`歌手: ${data.artistName}`);
        outputLines.push(`专辑: ${data.albumName || 'N/A'}`);
        outputLines.push(`是否含有精准时间轴(syncedLyrics): ${hasSynced}`);
        outputLines.push(`是否含有普通歌词(plainLyrics): ${hasPlain}`);
        outputLines.push(`\n【完整歌词内容】:\n`);
        outputLines.push(data.syncedLyrics || data.plainLyrics || '(无歌词内容)');
        outputLines.push(`\n`);
      } else {
        outputLines.push(`----------------------------------------------------`);
        outputLines.push(`歌曲 [${i + 1}]: ${t.name} - ${t.artist}`);
        outputLines.push(`请求失败或未返回 JSON: ${res.status}`);
        outputLines.push(res.body);
        outputLines.push(`\n`);
      }
    } catch (err) {
      console.error(`     请求异常:`, err.message);
      outputLines.push(`歌曲 [${i + 1}]: ${t.name} - ${t.artist} 请求异常: ${err.message}\n`);
    }
    console.log('');
  }

  const outputPath = path.join(__dirname, 'lyrics_api_result.txt');
  fs.writeFileSync(outputPath, outputLines.join('\n'), 'utf8');
  console.log('====================================================');
  console.log(`验证完成！完整输出已保存至同级文件:`);
  console.log(`[FILE] ${outputPath}`);
  console.log('====================================================');
}

run();
