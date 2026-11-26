local constants = require("spotube.core.constants")
local http = require("spotube.core.http")
local matcher = require("spotube.matcher.matcher")
local store = require("spotube.core.store")

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
    ["User-Agent"] = constants.CLIENT_WEB_REMIX.userAgent
  }

  local res = http.post(url, payload, headers)
  local candidates = {}
  if not res or type(res) ~= "table" then
    return candidates
  end

  -- 递归寻找 videoRenderer / musicResponsiveListItemRenderer
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
        -- 尝试提取二级栏目中的艺术家和时长
        for _, col in ipairs(node.flexColumns) do
          local runs = col.musicResponsiveListItemFlexColumnRenderer and
                       col.musicResponsiveListItemFlexColumnRenderer.text and
                       col.musicResponsiveListItemFlexColumnRenderer.text.runs
          if runs and #runs > 0 then
            for _, r in ipairs(runs) do
              local t = r.text or ""
              if string.find(t, ":", 1, true) and string.len(t) <= 8 then
                -- 解析时长 MM:SS (避开正则转义缺陷)
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

--- 通过 VisionOS 协议提取直链
local function extract_player_stream(video_id)
  local url = constants.HOST_YOUTUBE .. "/youtubei/v1/player?prettyPrint=false"
  local payload = {
    context = {
      client = constants.CLIENT_VISIONOS
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
    ["Origin"] = constants.HOST_YOUTUBE,
    ["Referer"] = constants.HOST_YOUTUBE .. "/"
  }

  local res = http.post(url, payload, headers)
  if not res or type(res) ~= "table" then
    return nil, "Invalid player response"
  end

  local streaming_data = res.streamingData
  if not streaming_data or not streaming_data.adaptiveFormats then
    return nil, "No unencrypted adaptiveFormats"
  end

  local chosen = nil
  for _, fmt in ipairs(streaming_data.adaptiveFormats) do
    local mime = fmt.mimeType or ""
    if string.find(mime, "audio/") and fmt.url and string.len(fmt.url) > 0 then
      -- 优先 itag 250 (~90kbps Opus) 或 140 (~128kbps AAC)，抗限速防卡顿
      if fmt.itag == 250 or fmt.itag == 140 then
        chosen = fmt
        break
      elseif not chosen then
        chosen = fmt
      end
    end
  end

  if not chosen or not chosen.url then
    return nil, "No stream url found"
  end

  local stream_headers = {
    ["User-Agent"] = constants.CLIENT_VISIONOS.userAgent,
    ["Origin"] = constants.HOST_YOUTUBE,
    ["Referer"] = constants.HOST_YOUTUBE .. "/",
    ["Range"] = "bytes=0-",
    ["Accept"] = "*/*",
    ["Accept-Encoding"] = "identity"
  }

  return {
    url = chosen.url,
    bitRate = chosen.bitrate or 128000,
    suffix = string.find(chosen.mimeType or "", "opus") and "opus" or "m4a",
    contentType = chosen.mimeType or "audio/mp4",
    headers = stream_headers
  }
end

--- 核心流调度方法：给定 Spotify 歌曲信息，智能转接并秒级返回直链流
function stream_service.resolve_stream(track)
  if not track then return nil end

  local track_id = track.id or track.uri or (tostring(track.title) .. "-" .. tostring(track.artist))
  -- 1. 先查持久化缓存，避免重复检索
  local cached = store.get_matched_stream(track_id)
  if cached and cached.url then
    return cached
  end

  -- 2. 构造搜索关键词：Title + Artist
  local query = tostring(track.title or "")
  if track.artist and string.len(track.artist) > 0 then
    query = query .. " " .. tostring(track.artist)
  end

  -- 3. 搜索候选并进行 Spotube 置信度打分
  local candidates = search_candidates(query)
  local best_cand, score = matcher.find_best_match(track, candidates)

  if not best_cand or not best_cand.id then
    return nil, "Failed to match audio stream for track: " .. query
  end

  -- 4. 提取裸流
  local stream_res, err = extract_player_stream(best_cand.id)
  if not stream_res then
    return nil, err
  end

  -- 5. 存入缓存并返回
  store.save_matched_stream(track_id, stream_res)
  return stream_res
end

return stream_service
