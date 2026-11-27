local constants = require("spotube.core.constants")
local http = require("spotube.core.http")
local matcher = require("spotube.matcher.matcher")
local store = require("spotube.core.store")
local cache = require("spotube.core.cache")
local spotify = require("spotube.services.spotify")

local stream_service = {}

--- 获取 YouTube 访客标识
local function ensure_visitor_data()
  local cached = store.get("yt_visitor_data")
  if cached and string.len(cached) > 0 then
    return cached
  end

  local url = constants.HOST_MUSIC .. "/youtubei/v1/search"
  local payload = {
    context = {
      client = constants.CLIENT_WEB_REMIX
    },
    query = "music"
  }
  local headers = {
    ["Content-Type"] = "application/json",
    ["User-Agent"] = constants.CLIENT_WEB_REMIX.userAgent,
    ["Origin"] = constants.HOST_MUSIC,
    ["Referer"] = constants.HOST_MUSIC .. "/"
  }

  local res = http.post(url, payload, headers)
  if res and type(res) == "table" and res.responseContext then
    local visitor = res.responseContext.visitorData
    if visitor then
      store.set("yt_visitor_data", visitor)
      return visitor
    end
  end
  return nil
end

--- 在 YouTube Music 检索候选音轨列表
local function search_candidates(query_text)
  if not query_text or query_text == "" then return {} end

  local visitor = ensure_visitor_data()
  local client_ctx = {}
  for k, v in pairs(constants.CLIENT_WEB_REMIX) do
    if k ~= "userAgent" then client_ctx[k] = v end
  end
  if visitor then client_ctx.visitorData = visitor end

  local payload = {
    context = { client = client_ctx },
    query = query_text,
    params = "EgWKAQIIAWoQEAMQBBAJEAoQCxAEEAUQEQ==" -- 过滤仅音频/单曲
  }

  local url = constants.HOST_MUSIC .. "/youtubei/v1/search"
  local headers = {
    ["Content-Type"] = "application/json",
    ["User-Agent"] = constants.CLIENT_WEB_REMIX.userAgent,
    ["Origin"] = constants.HOST_MUSIC,
    ["Referer"] = constants.HOST_MUSIC .. "/"
  }

  local res = http.post(url, payload, headers)
  local candidates = {}
  if not res or type(res) ~= "table" then
    return candidates
  end

  local function traverse(node)
    if type(node) ~= "table" then return end
    if node.videoId and type(node.videoId) == "string" then
      local title = ""
      local uploader = ""
      local durationMs = 0

      if node.title and node.title.runs and node.title.runs[1] then
        title = node.title.runs[1].text or ""
      end
      if node.flexColumns and type(node.flexColumns) == "table" then
        for _, col in ipairs(node.flexColumns) do
          local runs = col.musicResponsiveListItemFlexColumnRenderer and
                       col.musicResponsiveListItemFlexColumnRenderer.text and
                       col.musicResponsiveListItemFlexColumnRenderer.text.runs
          if runs and #runs > 0 then
            for _, r in ipairs(runs) do
              local t = r.text or ""
              if string.find(t, ":", 1, true) and string.len(t) <= 8 then
                local colon = string.find(t, ":", 1, true)
                if colon then
                  local m = tonumber(string.sub(t, 1, colon - 1))
                  local s = tonumber(string.sub(t, colon + 1))
                  if m and s then
                    durationMs = (m * 60 + s) * 1000
                  end
                end
              elseif string.len(t) > 1 and not string.find(t, "•", 1, true) and uploader == "" and t ~= title then
                uploader = t
              end
            end
          end
        end
      end

      table.insert(candidates, {
        id = node.videoId,
        title = title,
        uploader = uploader,
        durationMs = durationMs
      })
      if #candidates >= 6 then return end
    end

    for _, v in pairs(node) do
      if type(v) == "table" then
        traverse(v)
        if #candidates >= 6 then return end
      end
    end
  end

  traverse(res)
  return candidates
end

--- 从公共 Piped / Invidious 网关直接提取原生音频流 (极速稳定兜底)
local function extract_piped_stream(video_id)
  local endpoints = {
    "https://api.piped.private.coffee/streams/" .. tostring(video_id),
    "https://pipedapi.kavin.rocks/streams/" .. tostring(video_id)
  }

  for _, u in ipairs(endpoints) do
    local res = http.get(u, {
      ["User-Agent"] = constants.USER_AGENT_DESKTOP,
      ["Accept"] = "application/json"
    })
    if res and type(res) == "table" and res.audioStreams and #res.audioStreams > 0 then
      local best = nil
      for _, st in ipairs(res.audioStreams) do
        if st.url and string.len(st.url) > 0 then
          if not best or (st.bitrate or 0) > (best.bitrate or 0) then
            best = st
          end
        end
      end
      if best and best.url then
        return {
          url = best.url,
          bitRate = best.bitrate or 128000,
          suffix = best.format == "WEBM" and "opus" or "m4a",
          contentType = best.mimeType or "audio/mp4",
          size = best.contentLength or 0,
          transcoded = false,
          headers = {
            ["User-Agent"] = constants.USER_AGENT_DESKTOP,
            ["Range"] = "bytes=0-",
            ["Accept"] = "*/*"
          }
        }
      end
    end
  end
  return nil
end

--- 通过 VisionOS 协议提取 YouTube 原生免加密直链
local function extract_player_stream(video_id)
  local visitor = ensure_visitor_data()
  local client_ctx = {}
  for k, v in pairs(constants.CLIENT_VISIONOS) do
    if k ~= "userAgent" then client_ctx[k] = v end
  end
  if visitor and string.len(visitor) > 0 then
    client_ctx.visitorData = visitor
  end

  local url = constants.HOST_YOUTUBE .. "/youtubei/v1/player?prettyPrint=false"
  local payload = {
    context = {
      client = client_ctx
    },
    videoId = video_id,
    playbackContext = {
      contentPlaybackContext = {
        html5Preference = "HTML5_PREF_WANTS",
        signatureTimestamp = 20760
      }
    },
    contentCheckOk = true,
    racyCheckOk = true
  }

  local headers = {
    ["Content-Type"] = "application/json",
    ["User-Agent"] = constants.CLIENT_VISIONOS.userAgent,
    ["X-Goog-Api-Format-Version"] = "2",
    ["Origin"] = constants.HOST_YOUTUBE,
    ["X-Origin"] = constants.HOST_YOUTUBE,
    ["Referer"] = constants.HOST_YOUTUBE .. "/",
    ["X-YouTube-Client-Name"] = "101",
    ["X-YouTube-Client-Version"] = "1.02"
  }
  if visitor and string.len(visitor) > 0 then
    headers["X-Goog-Visitor-Id"] = visitor
  end

  local res = http.post(url, payload, headers)
  if res and type(res) == "table" and res.streamingData and res.streamingData.adaptiveFormats then
    local itag_map = {}
    local webm_list = {}
    local m4a_list = {}

    for _, fmt in ipairs(res.streamingData.adaptiveFormats) do
      local mime = fmt.mimeType or ""
      if string.find(mime, "audio/") and fmt.url and string.len(fmt.url) > 0 then
        local itag = tonumber(fmt.itag)
        if itag then itag_map[itag] = fmt end
        if string.find(mime, "webm") or string.find(mime, "opus") then
          table.insert(webm_list, fmt)
        else
          table.insert(m4a_list, fmt)
        end
      end
    end

    local chosen = itag_map[251] or itag_map[140] or itag_map[250] or itag_map[249] or itag_map[139] or webm_list[1] or m4a_list[1]

    if chosen and chosen.url then
      local mime = chosen.mimeType or "audio/webm; codecs=\"opus\""
      local suffix = (string.find(mime, "opus") or string.find(mime, "webm")) and "webm" or "m4a"
      return {
        url = chosen.url,
        bitRate = chosen.bitrate or 128000,
        suffix = suffix,
        contentType = mime,
        size = tonumber(chosen.contentLength) or 0,
        transcoded = false,
        headers = {
          ["User-Agent"] = constants.CLIENT_VISIONOS.userAgent,
          ["Origin"] = constants.HOST_YOUTUBE,
          ["Referer"] = constants.HOST_YOUTUBE .. "/",
          ["Range"] = "bytes=0-",
          ["Accept"] = "*/*",
          ["Accept-Encoding"] = "identity",
          ["Connection"] = "keep-alive"
        }
      }
    end
  end

  -- 回退至极速 Piped API 解析通道
  local fallback = extract_piped_stream(video_id)
  if fallback then return fallback end

  return nil, "无法获取可播放的音频直链"
end

--- 核心流调度方法：给定 Spotify 歌曲信息或 ID，结合双层缓存与 VideoID 记忆秒级返回直链流
function stream_service.resolve_stream(args)
  if not args then return nil, "Missing stream arguments" end

  local track_id = ""
  local title = ""
  local artist = ""
  local durationMs = 0

  if type(args) == "string" then
    track_id = args
  elseif type(args) == "table" then
    track_id = args.id or args.songId or ""
    title = args.title or args.name or ""
    artist = args.artist or (args.artists and args.artists[1] and args.artists[1].name) or ""
    durationMs = tonumber(args.durationMs) or 0
  end

  local clean_id = store.clean_id(track_id)
  local cache_key = clean_id ~= "" and clean_id or (title .. "-" .. artist)

  -- 1. [L1/L2 双层缓存] 优先检查 2 小时有效期的直接流缓存 (切歌 0 延迟秒开)
  local cached_stream, cached_vid, cache_tier = cache.get_stream(cache_key)
  if cached_stream and cached_stream.url then
    return cached_stream
  end

  -- 2. 尝试从本地歌曲元数据缓存补全 title 和 artist
  if title == "" or artist == "" then
    local cached_meta = store.get_track_meta(clean_id) or store.get_track_meta(track_id)
    if cached_meta then
      title = cached_meta.title or cached_meta.name or title
      artist = cached_meta.artist or (cached_meta.artists and cached_meta.artists[1] and cached_meta.artists[1].name) or artist
      durationMs = cached_meta.durationMs or durationMs
    end
  end

  -- 3. 补全曲目信息与真实专辑封面
  local track_detail = nil
  if clean_id ~= "" then
    track_detail = spotify.get_track_detail(clean_id)
    if track_detail then
      if title == "" then title = track_detail.title or "" end
      if artist == "" then artist = track_detail.artist or "" end
      if durationMs == 0 then durationMs = track_detail.durationMs or 0 end
    end
  end

  -- 4. [L3 永久记忆] 检查是否有此前已完成匹配验证的 YouTube Video ID
  local remembered_vid = cache.get_matched_vid(cache_key)
  if remembered_vid and string.len(remembered_vid) > 3 then
    local direct_stream, direct_err = extract_player_stream(remembered_vid)
    if direct_stream and direct_stream.url then
      if track_detail and track_detail.coverUrl then
        direct_stream.cover = track_detail.coverUrl
        direct_stream.coverUrl = track_detail.coverUrl
      end
      -- 存入 2 小时双层缓存并返回
      cache.set_stream(cache_key, direct_stream, remembered_vid, 7200)
      return direct_stream
    else
      -- 若已失效的 VideoID 提取失败，清除记忆并重新搜索
      cache.set_matched_vid(cache_key, nil)
    end
  end

  -- 5. 构造搜索关键词并进行候选匹配 (首次播放全新曲目)
  local query = title
  if artist and string.len(artist) > 0 and not string.find(query, artist, 1, true) then
    query = query .. " " .. artist
  end

  if query == "" then
    return nil, "无法确定曲目标题与艺术家"
  end

  local candidates = search_candidates(query)
  local best_cand = nil

  if candidates and #candidates > 0 then
    best_cand = matcher.find_best_match({
      id = clean_id,
      title = title,
      artist = artist,
      durationMs = durationMs
    }, candidates)
    best_cand = best_cand or candidates[1]
  end

  if not best_cand or not best_cand.id then
    return nil, "YouTube 未能匹配到对应曲目: " .. query
  end

  -- 6. 提取音频裸流
  local stream_res, err = extract_player_stream(best_cand.id)
  if not stream_res then
    return nil, err or "提取音频直链失败"
  end

  if track_detail and track_detail.coverUrl then
    stream_res.cover = track_detail.coverUrl
    stream_res.coverUrl = track_detail.coverUrl
  elseif best_cand and best_cand.cover then
    stream_res.cover = best_cand.cover
    stream_res.coverUrl = best_cand.cover
  end

  -- 7. 写入 L1 内存 + L2 本地持久化 (TTL 2小时) 并持久化记住 VideoID
  cache.set_stream(cache_key, stream_res, best_cand.id, 7200)
  return stream_res
end

return stream_service
