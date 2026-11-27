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
function lyrics_service.get_lyrics(title, artist, album, duration_s)
  if not title or string.len(title) == 0 then
    return nil
  end

  local headers = {
    ["User-Agent"] = "Spotube/v6.0.0 (https://github.com/KRTirtho/spotube)"
  }

  local res = nil

  -- 1. 第一阶：精确匹配 /api/get (track_name + artist_name + duration)
  local query_params = "track_name=" .. url_encode(title)
  if artist and string.len(artist) > 0 then
    query_params = query_params .. "&artist_name=" .. url_encode(artist)
  end
  if album and string.len(album) > 0 then
    query_params = query_params .. "&album_name=" .. url_encode(album)
  end
  if duration_s and tonumber(duration_s) and tonumber(duration_s) > 0 then
    query_params = query_params .. "&duration=" .. tostring(math.floor(tonumber(duration_s)))
  end

  local url = constants.HOST_LRCLIB .. "/api/get?" .. query_params
  res = http.get(url, headers)

  -- 2. 若精确匹配未命中，或精确匹配仅返回普通文本而缺少 syncedLyrics (如 Living Millennium 与 Kyu-kurarin 官方记录)：
  -- 严格对齐 Spotube 官方逻辑，通过 /api/search 进行全局检索，优先筛选包含同步时间轴的优质候选
  if not res or type(res) ~= "table" or not res.syncedLyrics or string.len(tostring(res.syncedLyrics)) == 0 then
    local search_terms = title
    if artist and string.len(artist) > 0 then
      search_terms = search_terms .. " " .. artist
    end
    local search_url = constants.HOST_LRCLIB .. "/api/search?q=" .. url_encode(search_terms)
    local s_res = http.get(search_url, headers)
    if s_res and type(s_res) == "table" and #s_res > 0 then
      local found_synced = false
      for _, it in ipairs(s_res) do
        if it.syncedLyrics and string.len(tostring(it.syncedLyrics)) > 0 then
          res = it
          found_synced = true
          break
        end
      end
      if not found_synced and (not res or type(res) ~= "table" or not res.plainLyrics) then
        res = s_res[1]
      end
    end
  end

  if not res or type(res) ~= "table" then
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
    return nil
  end

  return {
    lines = lines,
    raw_lrc = raw_lrc,
    source = "lrclib",
    synced = is_synced,
    hasSynced = is_synced
  }
end

return lyrics_service
