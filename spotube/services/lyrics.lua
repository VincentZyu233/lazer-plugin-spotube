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

--- 从 LRCLib 抓取高精度同步歌词
function lyrics_service.get_lyrics(title, artist, album, duration_s)
  if not title or string.len(title) == 0 then
    return nil
  end

  local query_params = "track_name=" .. url_encode(title)
  if artist and string.len(artist) > 0 then
    query_params = query_params .. "&artist_name=" .. url_encode(artist)
  end
  if duration_s and tonumber(duration_s) then
    query_params = query_params .. "&duration=" .. tostring(math.floor(tonumber(duration_s)))
  end

  local url = constants.HOST_LRCLIB .. "/api/get?" .. query_params
  local res = http.get(url, {
    ["User-Agent"] = "Lazer-Spotube-Plugin/0.1.0 (https://github.com/VincentZyu233/lazer-plugin-spotube)"
  })

  -- 若精确匹配未命中，通过 /api/search 进行模糊兜底检索
  if not res or type(res) ~= "table" or (not res.syncedLyrics and not res.plainLyrics) then
    local search_q = url_encode(title .. (artist and (" " .. artist) or ""))
    local search_url = constants.HOST_LRCLIB .. "/api/search?q=" .. search_q
    local s_res = http.get(search_url, {
      ["User-Agent"] = "Lazer-Spotube-Plugin/0.1.0 (https://github.com/VincentZyu233/lazer-plugin-spotube)"
    })
    if s_res and type(s_res) == "table" and #s_res > 0 then
      for _, it in ipairs(s_res) do
        if it.syncedLyrics and string.len(it.syncedLyrics) > 0 then
          res = it
          break
        end
      end
      if not res or not res.syncedLyrics then
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

  -- 解析逐行歌词为 Lazer 标准 lines 数组 (包含 startMs 供 Lazer 实时渲染)
  local lines = {}
  for line in string.gmatch(raw_lrc, "[^\r\n]+") do
    local parsed = false
    if string.sub(line, 1, 1) == "[" then
      local close_idx = string.find(line, "]", 2, true)
      if close_idx then
        local tag = string.sub(line, 2, close_idx - 1)
        local text = string.sub(line, close_idx + 1)
        local colon = string.find(tag, ":", 1, true)
        if colon then
          local m_str = string.sub(tag, 1, colon - 1)
          local rest = string.sub(tag, colon + 1)
          local s_str = rest
          local ms_str = "0"
          local dot = string.find(rest, ".", 1, true)
          if dot then
            s_str = string.sub(rest, 1, dot - 1)
            ms_str = string.sub(rest, dot + 1)
          end
          local m = tonumber(m_str)
          local s = tonumber(s_str)
          local ms = tonumber(ms_str)
          if m and s then
            local time_ms = (m * 60 + s) * 1000 + (ms or 0) * 10
            table.insert(lines, {
              startMs = time_ms,
              time = time_ms,
              text = text or ""
            })
            parsed = true
          end
        end
      end
    end

    if not parsed then
      -- 纯文本行
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
    source = "lrclib",
    synced = res.syncedLyrics ~= nil,
    hasSynced = res.syncedLyrics ~= nil
  }
end

return lyrics_service
