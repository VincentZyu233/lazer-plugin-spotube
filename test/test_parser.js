const fs = require('fs');

// 读取刚获取的 kyu-kurarin 歌词
const resultTxt = fs.readFileSync('D:/aaaStuffsaaa/from_git/github/lazer-plugin-spotube/test/lyrics_api_result.txt', 'utf8');

// 提取 kyu-kurarin 的完整歌词
const match = resultTxt.match(/【完整歌词内容】:\s*\n([\s\S]+?)(?=\n----------------------------------------------------|\n$)/);
if (!match) {
  console.log('No lyric matched');
  process.exit(1);
}

const raw_lrc = match[1].trim();
console.log('Raw LRC lines count:', raw_lrc.split('\n').length);
console.log('First 5 lines:');
raw_lrc.split('\n').slice(0, 5).forEach((l, i) => console.log(i + 1, JSON.stringify(l)));

// 模拟 Lua 的 parse_lrc 逐行解析
function safe_sub(s, i, j) {
  if (!s) return "";
  const len = s.length;
  if (len === 0) return "";
  if (i < 1) i = 1;
  if (i > len) return "";
  if (j && j < i) return "";
  if (j && j > len) j = len;
  if (j) return s.substring(i - 1, j);
  return s.substring(i - 1);
}

const lines = [];
for (const line of raw_lrc.split(/\r?\n/)) {
  const line_len = line.length;
  if (line_len >= 3 && safe_sub(line, 1, 1) === "[") {
    const rightBracket = line.indexOf("]", 1) + 1; // 1-based
    if (rightBracket && rightBracket > 2) {
      const timePart = safe_sub(line, 2, rightBracket - 1);
      const colonPos = timePart.indexOf(":") + 1; // 1-based
      if (colonPos && colonPos > 1) {
        const minStr = safe_sub(timePart, 1, colonPos - 1);
        const min = parseInt(minStr, 10);
        if (!isNaN(min)) {
          const rest = safe_sub(timePart, colonPos + 1);
          const dotPos = rest.indexOf(".") !== -1 ? rest.indexOf(".") + 1 : (rest.indexOf(":") !== -1 ? rest.indexOf(":") + 1 : 0);
          let sec = 0, ms = 0;
          if (dotPos) {
            sec = parseInt(safe_sub(rest, 1, dotPos - 1), 10) || 0;
            const msStr = safe_sub(rest, dotPos + 1);
            let msVal = parseInt(msStr, 10) || 0;
            if (msStr.length === 2) msVal *= 10;
            else if (msStr.length === 1) msVal *= 100;
            ms = msVal;
          } else {
            sec = parseInt(rest, 10) || 0;
          }
          const startMs = min * 60000 + sec * 1000 + ms;
          let cleanText = "";
          if (rightBracket < line_len) {
            const text = safe_sub(line, rightBracket + 1);
            cleanText = text.trim();
          }
          lines.push({ text: cleanText, startMs, time: startMs });
        }
      }
    }
  }
}

console.log('Parsed lines count:', lines.length);
if (lines.length > 0) {
  console.log('Sample parsed line 0:', lines[0]);
  console.log('Sample parsed line 1:', lines[1]);
}
