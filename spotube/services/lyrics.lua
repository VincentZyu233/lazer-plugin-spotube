local constants = require("spotube.core.constants")
local http = require("spotube.core.http")

local lyrics_service = {}

local function url_encode(str)
  if not str or str == "" then return "" end
  if _url_encode then
    local ok, res = pcall(_url_encode, str)
    if ok and res then return res end
  end
  if host and host.url_encode then
    local ok, res = pcall(host.url_encode, str)
    if ok and res then return res end
  end
  local s = string.gsub(str, "([^%w%-_%.~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  return s
end

-- 提取首要歌手（剥离多歌手拼接、feat、ft 等，对齐 Spotube 检索规范）
local function get_primary_artist(artist_str)
  if not artist_str or artist_str == "" then return "" end
  local first = string.match(artist_str, "^([^,;/&、]+)")
  if not first then first = artist_str end
  first = string.gsub(first, "%s*[fF]eat%..*$", "")
  first = string.gsub(first, "%s*[fF]t%..*$", "")
  first = string.match(first, "^%s*(.-)%s*$") or first
  return first
end

-- 清洗歌曲标题（剥离 (feat. ...), [feat. ...], - Remastered 等副标题）
local function get_clean_title(title_str)
  if not title_str or title_str == "" then return "" end
  local s = string.gsub(title_str, "%s*%(feat%..-%)$", "")
  s = string.gsub(s, "%s*%[feat%..-%]$", "")
  s = string.gsub(s, "%s*%(ft%..-%)$", "")
  s = string.gsub(s, "%s*%[ft%..-%]$", "")
  s = string.gsub(s, "%s*%-.*[rR]emaster.*$", "")
  s = string.gsub(s, "%s*%(.*[rR]emaster.*%)$", "")
  s = string.match(s, "^%s*(.-)%s*$") or s
  return s
end

-- 解析标准 LRC 文本为带有高精度时间轴的行 (对齐 Lazer MusicLyricLine 要求: text 与 startMs)
local function parse_lrc(raw_lrc)
  if not raw_lrc or raw_lrc == "" then return {} end
  local lines = {}

  for line in string.gmatch(raw_lrc, "[^\r\n]+") do
    if string.sub(line, 1, 1) == "[" then
      local rightBracket = string.find(line, "]", 2, true)
      if rightBracket then
        local timePart = string.sub(line, 2, rightBracket - 1)
        local colonPos = string.find(timePart, ":", 1, true)
        if colonPos then
          local minStr = string.sub(timePart, 1, colonPos - 1)
          local min = tonumber(minStr)
          if min then
            local rest = string.sub(timePart, colonPos + 1)
            local dotPos = string.find(rest, ".", 1, true) or string.find(rest, ":", 1, true)
            local sec, ms = 0, 0
            if dotPos then
              sec = tonumber(string.sub(rest, 1, dotPos - 1)) or 0
              local msStr = string.sub(rest, dotPos + 1)
              local msVal = tonumber(msStr) or 0
              local msLen = string.len(msStr)
              if msLen == 2 then
                msVal = msVal * 10
              elseif msLen == 1 then
                msVal = msVal * 100
              end
              ms = msVal
            else
              sec = tonumber(rest) or 0
            end
            local startMs = min * 60000 + sec * 1000 + ms
            local text = string.sub(line, rightBracket + 1)
            local firstNonSpace = 1
            local lastNonSpace = string.len(text)
            while firstNonSpace <= lastNonSpace and string.byte(text, firstNonSpace) <= 32 do
              firstNonSpace = firstNonSpace + 1
            end
            while lastNonSpace >= firstNonSpace and string.byte(text, lastNonSpace) <= 32 do
              lastNonSpace = lastNonSpace - 1
            end
            local cleanText = (lastNonSpace >= firstNonSpace) and string.sub(text, firstNonSpace, lastNonSpace) or ""
            table.insert(lines, {
              text = cleanText,
              startMs = startMs,
              time = startMs
            })
          end
        end
      end
    end
  end

  return lines
end

--- 从 LRCLib 抓取高精度同步歌词 (100% 对齐 Spotube 官方内置 RealLRCLibLyricsAPI 实现)
function lyrics_service.get_lyrics(title, artist, album, duration_s, log_step)
  if log_step then
    pcall(log_step, "lrclib_0_entry", {
      title = tostring(title),
      artist = tostring(artist),
      duration = tostring(duration_s)
    })
  end

  local function log(msg, data)
    if log_step then
      pcall(log_step, "lrclib_" .. msg, data)
    end
  end

  if not title or string.len(title) == 0 then
    log("no_title", {})
    return nil
  end

  local headers = {
    ["User-Agent"] = "Spotube/v6.0.0 (https://github.com/KRTirtho/spotube)"
  }

  local primary_artist = get_primary_artist(artist)
  local clean_title = get_clean_title(title)
  local query_title = (clean_title and clean_title ~= "") and clean_title or title

  log("query_prep", {
    query_title = query_title,
    primary_artist = primary_artist,
    clean_title = clean_title,
    duration_s = duration_s
  })

  local res = nil

  -- 1. 第一阶：精确单曲匹配 /api/get (clean_title + primary_artist + duration)
  local q1 = "track_name=" .. url_encode(query_title)
  if primary_artist and string.len(primary_artist) > 0 then
    q1 = q1 .. "&artist_name=" .. url_encode(primary_artist)
  end
  if duration_s and tonumber(duration_s) and tonumber(duration_s) > 0 then
    q1 = q1 .. "&duration=" .. tostring(math.floor(tonumber(duration_s)))
  end

  local u1 = constants.HOST_LRCLIB .. "/api/get?" .. q1
  log("stage1_request", { url = u1 })
  local ok1, r1, err1 = pcall(http.get, u1, headers)
  log("stage1_response", {
    call_ok = ok1,
    is_table = (ok1 and type(r1) == "table"),
    has_synced = (ok1 and type(r1) == "table" and r1.syncedLyrics ~= nil and string.len(tostring(r1.syncedLyrics)) > 0),
    err = (not ok1 and tostring(r1)) or err1
  })
  if ok1 and r1 and type(r1) == "table" then
    res = r1
  end

  -- 2. 第二阶：若精确匹配未命中或缺少 syncedLyrics，去除 duration 再次尝试 /api/get (宽容模式)
  if not res or not res.syncedLyrics or string.len(tostring(res.syncedLyrics)) == 0 then
    local q2 = "track_name=" .. url_encode(query_title)
    if primary_artist and string.len(primary_artist) > 0 then
      q2 = q2 .. "&artist_name=" .. url_encode(primary_artist)
    end
    local u2 = constants.HOST_LRCLIB .. "/api/get?" .. q2
    log("stage2_request", { url = u2 })
    local ok2, r2, err2 = pcall(http.get, u2, headers)
    log("stage2_response", {
      call_ok = ok2,
      is_table = (ok2 and type(r2) == "table"),
      has_synced = (ok2 and type(r2) == "table" and r2.syncedLyrics ~= nil and string.len(tostring(r2.syncedLyrics)) > 0),
      err = (not ok2 and tostring(r2)) or err2
    })
    if ok2 and r2 and type(r2) == "table" and r2.syncedLyrics and string.len(tostring(r2.syncedLyrics)) > 0 then
      res = r2
    elseif not res and ok2 and r2 and type(r2) == "table" then
      res = r2
    end
  end

  -- 3. 第三阶：若仍未命中 syncedLyrics，通过 /api/search 进行全局检索 (clean_title + primary_artist)
  if not res or not res.syncedLyrics or string.len(tostring(res.syncedLyrics)) == 0 then
    local search_terms = query_title .. (primary_artist ~= "" and (" " .. primary_artist) or "")
    local s_url = constants.HOST_LRCLIB .. "/api/search?q=" .. url_encode(search_terms)
    log("stage3_request", { url = s_url })
    local ok3, s_res, err3 = pcall(http.get, s_url, headers)
    log("stage3_response", {
      call_ok = ok3,
      is_table = (ok3 and type(s_res) == "table"),
      count = (ok3 and type(s_res) == "table" and #s_res) or 0,
      err = (not ok3 and tostring(s_res)) or err3
    })
    if ok3 and s_res and type(s_res) == "table" and #s_res > 0 then
      local found_synced = false
      for _, it in ipairs(s_res) do
        if it.syncedLyrics and string.len(tostring(it.syncedLyrics)) > 0 then
          res = it
          found_synced = true
          break
        end
      end
      if not found_synced and (not res or not res.plainLyrics) then
        res = s_res[1]
      end
    end
  end

  -- 4. 第四阶：若检索 title + artist 仍未找到任何结果，使用 query_title 单独发起检索
  if not res or not res.syncedLyrics or string.len(tostring(res.syncedLyrics)) == 0 then
    local s_url2 = constants.HOST_LRCLIB .. "/api/search?q=" .. url_encode(query_title)
    log("stage4_request", { url = s_url2 })
    local ok4, s_res2, err4 = pcall(http.get, s_url2, headers)
    log("stage4_response", {
      call_ok = ok4,
      is_table = (ok4 and type(s_res2) == "table"),
      count = (ok4 and type(s_res2) == "table" and #s_res2) or 0,
      err = (not ok4 and tostring(s_res2)) or err4
    })
    if ok4 and s_res2 and type(s_res2) == "table" and #s_res2 > 0 then
      for _, it in ipairs(s_res2) do
        if it.syncedLyrics and string.len(tostring(it.syncedLyrics)) > 0 then
          res = it
          break
        end
      end
      if not res and s_res2[1] then
        res = s_res2[1]
      end
    end
  end

  if not res or type(res) ~= "table" then
    log("no_result_found", {})
    return nil
  end

  local is_synced = (res.syncedLyrics ~= nil and string.len(tostring(res.syncedLyrics)) > 0)
  local raw_lrc = nil
  local lines = {}

  if is_synced then
    raw_lrc = res.syncedLyrics
    lines = parse_lrc(raw_lrc)
    if #lines == 0 then
      is_synced = false
    end
  end

  -- 若未能获取到同步时间轴，对普通文本按步进时间戳进行标准 LRC 格式化
  -- 关键保障：Lazer 宿主在 _parsePlainLrc 中严格校验 [mm:ss.xx]，无时间戳的行会被完全丢弃！
  -- 格式化为 stepped LRC 确保 Lazer 能够完整解析每一行并正常呈现滚动/纯文本歌词视图
  if not is_synced and res.plainLyrics and string.len(res.plainLyrics) > 0 then
    log("formatting_plain_lyrics_to_stepped", { len = string.len(res.plainLyrics) })
    local plain_lines = {}
    for line in string.gmatch(res.plainLyrics, "[^\r\n]+") do
      local fb = 1
      local lb = string.len(line)
      while fb <= lb and string.byte(line, fb) <= 32 do fb = fb + 1 end
      while lb >= fb and string.byte(line, lb) <= 32 do lb = lb - 1 end
      if lb >= fb then
        table.insert(plain_lines, string.sub(line, fb, lb))
      end
    end

    if #plain_lines > 0 then
      local total_sec = tonumber(duration_s) or 180
      local step_ms = math.max(2500, math.floor((total_sec * 1000) / #plain_lines))
      local cur_ms = 0
      local lrc_buf = {}
      for _, text in ipairs(plain_lines) do
        local m = math.floor(cur_ms / 60000)
        local s = math.floor((cur_ms % 60000) / 1000)
        local ms = math.floor((cur_ms % 1000) / 10)
        local stamp = string.format("[%02d:%02d.%02d]", m, s, ms)
        table.insert(lrc_buf, stamp .. text)
        table.insert(lines, {
          startMs = cur_ms,
          time = cur_ms,
          text = text
        })
        cur_ms = cur_ms + step_ms
      end
      raw_lrc = table.concat(lrc_buf, "\n")
    end
  end

  if not raw_lrc or string.len(raw_lrc) == 0 then
    log("no_raw_lrc_generated", {})
    return nil
  end

  log("final_lrc_ready", {
    is_synced = is_synced,
    lines_count = #lines,
    raw_lrc_len = string.len(raw_lrc)
  })

  return {
    lines = lines,
    raw_lrc = raw_lrc,
    source = "lrclib",
    synced = is_synced,
    hasSynced = is_synced
  }
end

return lyrics_service
