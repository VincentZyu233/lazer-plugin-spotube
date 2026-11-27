local constants = require("spotube.core.constants")
local http = require("spotube.core.http")

local lyrics_service = {}

local function url_encode(str)
  if not str or str == "" then return "" end
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

  -- 2. 第二阶：若因 album 或 duration 偏差未命中，去除 duration 与 album 再次尝试 /api/get (秒级轻量单曲接口)
  if not res or type(res) ~= "table" or (not res.syncedLyrics and not res.plainLyrics) then
    local relax_query = "track_name=" .. url_encode(title)
    if artist and string.len(artist) > 0 then
      relax_query = relax_query .. "&artist_name=" .. url_encode(artist)
    end
    local relax_url = constants.HOST_LRCLIB .. "/api/get?" .. relax_query
    local r_res = http.get(relax_url, headers)
    if r_res and type(r_res) == "table" and (r_res.syncedLyrics or r_res.plainLyrics) then
      res = r_res
    end
  end

  -- 3. 第三阶：若仍未命中或缺少时间轴，通过 /api/search 进行模糊检索兜底 (优先选取包含 syncedLyrics 的候选)
  if not res or type(res) ~= "table" or not res.syncedLyrics or string.len(tostring(res.syncedLyrics)) == 0 then
    local search_q = url_encode(title .. (artist and (" " .. artist) or ""))
    local search_url = constants.HOST_LRCLIB .. "/api/search?q=" .. search_q
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
      if not found_synced and (not res or not res.plainLyrics) then
        res = s_res[1]
      end
    end
  end

  if not res or type(res) ~= "table" then
    return nil
  end

  local raw_lrc = res.syncedLyrics or res.plainLyrics
  if not raw_lrc or string.len(raw_lrc) == 0 then
    return nil
  end

  local lines = parse_lrc(raw_lrc)

  -- 若未能解析出同步时间轴但有普通文本，按行包装为静态文本行
  if #lines == 0 and res.plainLyrics then
    for line in string.gmatch(res.plainLyrics, "[^\r\n]+") do
      local first_b = 1
      local last_b = string.len(line)
      while first_b <= last_b and string.byte(line, first_b) <= 32 do first_b = first_b + 1 end
      while last_b >= first_b and string.byte(line, last_b) <= 32 do last_b = last_b - 1 end
      if last_b >= first_b then
        table.insert(lines, {
          startMs = 0,
          time = 0,
          text = string.sub(line, first_b, last_b)
        })
      end
    end
  end

  return {
    lines = lines,
    raw_lrc = raw_lrc,
    source = "lrclib",
    synced = (res.syncedLyrics ~= nil and string.len(tostring(res.syncedLyrics)) > 0 and #lines > 0),
    hasSynced = (res.syncedLyrics ~= nil and string.len(tostring(res.syncedLyrics)) > 0 and #lines > 0)
  }
end

return lyrics_service
