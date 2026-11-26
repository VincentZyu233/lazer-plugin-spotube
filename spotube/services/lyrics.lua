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

  -- 解析逐行歌词为 Lazer 标准 lines 数组
  local lines = {}
  for line in string.gmatch(raw_lrc, "[^\r\n]+") do
    local m, s, ms, text = string.match(line, "%[(%d+):(%d+)%.(%d+)%](.*)")
    if m and s and ms then
      local time_ms = (tonumber(m) * 60 + tonumber(s)) * 1000 + tonumber(ms) * 10
      table.insert(lines, {
        time = time_ms,
        text = text or ""
      })
    else
      -- 纯文本行
      local plain_text = string.gsub(line, "%b[]", "")
      if string.len(plain_text) > 0 then
        table.insert(lines, {
          time = 0,
          text = plain_text
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
