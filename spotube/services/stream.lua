local constants = require("spotube.core.constants")
local http = require("spotube.core.http")
local matcher = require("spotube.matcher.matcher")
local store = require("spotube.core.store")
local spotify = require("spotube.services.spotify")

local stream_service = {}

--- 获取 YouTube 访客标识
local function ensure_visitor_data()
  local cached = store.get("yt_visitor_data")
  if cached and string.len(cached) > 0 then
    return cached
  end

  -- 尝试从本地持久化中读取
  local url = constants.HOST_MUSIC .. "/youtubei/v1/search"
  local payload = {
    context = {
      client = constants.CLIENT_WEB_REMIX
    },
    query = "music"
  }
  local headers = {
    ["Content-Type"] = "application/json",
    ["User-Agent"] = constants.CLIENT_WEB_REMIX.userAgent
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
    local chosen = nil
    for _, fmt in ipairs(res.streamingData.adaptiveFormats) do
      local mime = fmt.mimeType or ""
      if string.find(mime, "audio/") and fmt.url and string.len(fmt.url) > 0 then
        if fmt.itag == 140 or fmt.itag == 251 then
          chosen = fmt
          break
        elseif not chosen then
          chosen = fmt
        end
      end
    end

    if chosen and chosen.url then
      local mime = chosen.mimeType or "audio/mp4"
      local suffix = (string.find(mime, "opus") or string.find(mime, "webm")) and "opus" or "m4a"
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
          ["Accept-Encoding"] = "identity"
        }
      }
    end
  end

  -- 回退至极速 Piped API 解析通道
  local fallback = extract_piped_stream(video_id)
  if fallback then return fallback end

  return nil, "无法获取可播放的音频直链"
end

--- 核心流调度方法：给定 Spotify 歌曲信息或 ID，智能转接并秒级返回直链流
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

  -- 1. 尝试从本地歌曲元数据缓存补全 title 和 artist
  if title == "" or artist == "" then
    local cached_meta = store.get_track_meta(clean_id) or store.get_track_meta(track_id)
    if cached_meta then
      title = cached_meta.title or cached_meta.name or title
      artist = cached_meta.artist or (cached_meta.artists and cached_meta.artists[1] and cached_meta.artists[1].name) or artist
      durationMs = cached_meta.durationMs or durationMs
    end
  end

  -- 2. 依然缺失时，从 Spotify 实时反查单曲资料
  if (title == "" or artist == "") and clean_id ~= "" then
    local detail = spotify.get_track_detail(clean_id)
    if detail then
      title = detail.title or ""
      artist = detail.artist or ""
      durationMs = detail.durationMs or 0
    end
  end

  -- 3. 先查匹配直链缓存，避免重复检索
  local cache_key = clean_id ~= "" and clean_id or (title .. "-" .. artist)
  local cached_stream = store.get_matched_stream(cache_key)
  if cached_stream and cached_stream.url then
    return cached_stream
  end

  -- 4. 构造搜索关键词并进行候选匹配
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

  -- 5. 提取裸流
  local stream_res, err = extract_player_stream(best_cand.id)
  if not stream_res then
    return nil, err or "提取音频直链失败"
  end

  -- 6. 存入直链缓存并返回
  store.save_matched_stream(cache_key, stream_res)
  return stream_res
end

return stream_service
