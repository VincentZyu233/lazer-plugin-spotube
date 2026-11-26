local constants = require("spotube.core.constants")
local http = require("spotube.core.http")

local lyrics_service = {}

--- 从 LRCLib 抓取高精度同步歌词
function lyrics_service.get_lyrics(title, artist, album, duration_s)
  if not title or string.len(title) == 0 then
    return nil
  end

  local query_params = "track_name=" .. tostring(title)
  if artist and string.len(artist) > 0 then
    query_params = query_params .. "&artist_name=" .. tostring(artist)
  end
  if duration_s and tonumber(duration_s) then
    query_params = query_params .. "&duration=" .. tostring(math.floor(tonumber(duration_s)))
  end

  local url = constants.HOST_LRCLIB .. "/api/get?" .. query_params
  local res = http.get(url, {
    ["User-Agent"] = "Lazer-Spotube-Plugin/0.1.0 (https://github.com/VincentZyu233/lazer-plugin-spotube)"
  })

  if not res or type(res) ~= "table" then
    return nil
  end

  local raw_lrc = res.syncedLyrics or res.plainLyrics
  if not raw_lrc or string.len(raw_lrc) == 0 then
    return nil
  end

  -- 解析逐行歌词为 Lazer 标准 lines 数组 (避开 lua_dardo_plus 正则缺陷)
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
          time = 0,
          text = string.sub(line, first_b, last_b)
        })
      end
    end
  end

  return {
    lines = lines,
    source = "lrclib",
    hasSynced = res.syncedLyrics ~= nil
  }
end

return lyrics_service
