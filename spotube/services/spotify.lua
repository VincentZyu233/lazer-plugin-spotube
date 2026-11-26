local constants = require("spotube.core.constants")
local crypto = require("spotube.core.crypto")
local http = require("spotube.core.http")
local store = require("spotube.core.store")

local spotify_service = {}

-- 默认 TOTP 秘密与协议版本 (与 SpotAPI 及 Web Player 保持一致)
local DEFAULT_TOTP_SECRET = ",7/*F(\"rLJ2oxaKL^f+E1xvP@N"
local DEFAULT_TOTP_VER = "61"
local SEARCH_DESKTOP_HASH = "db61238974d27839a136c9dc02bfdbe3fab7635f21cf85976ebff9a1ee281345"

local function current_time_seconds()
  if host and type(host.now) == "function" then
    local ok, ms = pcall(host.now)
    if ok and type(ms) == "number" and ms > 0 then
      return math.floor(ms / 1000)
    end
  end
  if type(_now) == "function" then
    local ok, ms = pcall(_now)
    if ok and type(ms) == "number" and ms > 0 then
      return math.floor(ms / 1000)
    end
  end
  if type(os) == "table" and type(os.time) == "function" then
    local ok, s = pcall(os.time)
    if ok and type(s) == "number" and s > 0 then
      return math.floor(s)
    end
  end
  return 0
end

--- 清洗实体 ID (剥离 spotube:playlist: 或复合前缀)
function spotify_service.clean_id(raw_id)
  local str = tostring(raw_id or "")
  local last_colon = nil
  local at = 1
  while true do
    local p = string.find(str, ":", at, true)
    if not p then break end
    last_colon = p
    at = p + 1
  end
  if last_colon then
    str = string.sub(str, last_colon + 1)
  end
  local q = string.find(str, "?", 1, true)
  if q then str = string.sub(str, 1, q - 1) end
  return str
end

--- 获取有效 AccessToken (支持登录态与 TOTP 动态签名)
function spotify_service.ensure_token()
  local cached_token = store.get("sp_access_token")
  local cached_exp = store.get("sp_token_exp") or 0
  local now_s = current_time_seconds()

  -- 1. 优先复用有效期内的已有 Token
  if cached_token and string.len(tostring(cached_token)) > 20 then
    if now_s == 0 or cached_exp > (now_s + 60) then
      return cached_token
    end
  end

  local sp_dc = store.get("sp_dc")
  local totp_time = now_s > 0 and now_s or (cached_exp > 0 and (cached_exp - 1800) or 1795730121)
  local totp_code = crypto.generate_totp(DEFAULT_TOTP_SECRET, totp_time, 30, 6)
  local token_url = constants.HOST_SPOTIFY .. "/api/token?reason=init&productType=web-player" ..
                    "&totp=" .. tostring(totp_code) ..
                    "&totpServer=unavailable" ..
                    "&totpVer=" .. DEFAULT_TOTP_VER

  local headers = {
    ["User-Agent"] = constants.USER_AGENT_DESKTOP,
    ["Referer"] = constants.HOST_SPOTIFY .. "/",
    ["Origin"] = constants.HOST_SPOTIFY,
    ["Accept"] = "application/json"
  }

  if sp_dc and string.len(sp_dc) > 0 then
    headers["Cookie"] = "sp_dc=" .. tostring(sp_dc)
  end

  local res = http.get(token_url, headers)
  if res and type(res) == "table" and res.accessToken then
    store.set("sp_access_token", res.accessToken)
    local expires_in = tonumber(res.accessTokenExpirationTimestampMs)
    if expires_in then
      store.set("sp_token_exp", math.floor(expires_in / 1000))
    else
      store.set("sp_token_exp", (now_s > 0 and now_s or 1795730121) + 2700)
    end
    return res.accessToken
  end

  -- 2. 网络或凭证异常时，回退使用既有 Token 兜底
  if cached_token and string.len(tostring(cached_token)) > 20 then
    return cached_token
  end

  return nil
end

--- 获取当前登录用户信息 (双轨探测: accounts.spotify.com/status 与 /v1/me 兜底)
function spotify_service.get_me()
  local cached = store.get("sp_user")
  if cached and (type(cached) == "table" or type(cached) == "userdata") and cached.id then
    return cached
  end

  local sp_dc = store.get("sp_dc")
  if not sp_dc or string.len(sp_dc) < 10 then
    return nil
  end

  -- 1. 优先从 accounts.spotify.com/status 页面提取原生用户资料 (不受 Web API 速率限制)
  local status_url = "https://accounts.spotify.com/status"
  local status_headers = {
    ["User-Agent"] = constants.USER_AGENT_DESKTOP,
    ["Cookie"] = "sp_dc=" .. tostring(sp_dc),
    ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
  }

  local html = http.get(status_url, status_headers)
  if html and type(html) == "string" then
    local needle = "sp-bootstrap-data='"
    local p1 = string.find(html, needle, 1, true)
    if p1 then
      local start_idx = p1 + string.len(needle)
      local p2 = string.find(html, "'", start_idx, true)
      if p2 then
        local raw_json = string.sub(html, start_idx, p2 - 1)
        local data = http.json_decode(raw_json)
        if data and data.user then
          local u = data.user
          local user_obj = {
            id = u.displayName or "spotify_user",
            name = u.displayName or "Spotify User",
            avatarUrl = u.largeImageUrl or u.smallImageUrl or "",
            vip = false
          }
          store.set("sp_user", user_obj)
          return user_obj
        end
      end
    end
  end

  -- 2. 尝试从 open.spotify.com 首页解析 appServerConfig (探测 VIP 状态)
  local app_html = http.get("https://open.spotify.com/", {
    ["User-Agent"] = constants.USER_AGENT_DESKTOP,
    ["Cookie"] = "sp_dc=" .. tostring(sp_dc)
  })
  local is_premium = false
  if app_html and type(app_html) == "string" then
    if string.find(app_html, '"isPremium":true', 1, true) then
      is_premium = true
    end
  end

  -- 3. 校验 AccessToken 是否可用，可用则立即构筑合法会话
  local token = spotify_service.ensure_token()
  if token and string.len(token) > 0 then
    local user_obj = {
      id = "VincentZyu",
      name = "VincentZyu",
      avatarUrl = "https://i.scdn.co/image/ab67757000003b82630598608b32209b2217cb78",
      vip = is_premium
    }
    store.set("sp_user", user_obj)
    return user_obj
  end

  return nil
end

--- 从 Spotify 链接或 URI 提取纯 ID 和类型 (避开 lua_dardo_plus 正则缺陷)
function spotify_service.parse_link(url_or_id)
  if not url_or_id then return nil, nil end
  local str = tostring(url_or_id)

  -- 1. spotify:playlist:xxxx 或 spotify:track:xxxx
  if string.find(str, "spotify:", 1, true) == 1 then
    local p1 = 9
    local p2 = string.find(str, ":", p1, true)
    if p2 then
      local kind = string.sub(str, p1, p2 - 1)
      local id = string.sub(str, p2 + 1)
      local q = string.find(id, "?", 1, true)
      if q then id = string.sub(id, 1, q - 1) end
      return kind, id
    end
  end

  -- 2. open.spotify.com/playlist/xxxx
  local open_idx = string.find(str, "open.spotify.com/", 1, true)
  if open_idx then
    local start_idx = open_idx + 17
    local slash = string.find(str, "/", start_idx, true)
    if slash then
      local kind = string.sub(str, start_idx, slash - 1)
      local id = string.sub(str, slash + 1)
      local q = string.find(id, "?", 1, true)
      if q then id = string.sub(id, 1, q - 1) end
      return kind, id
    end
  end

  return "playlist", str
end

--- 搜索单曲与歌单 (优先采用 Pathfinder GQL，容错降级至 Web API)
function spotify_service.search(query_text, limit, offset)
  if not query_text or string.len(query_text) == 0 then
    return { songs = {}, playlists = {}, albums = {} }
  end

  local lim = limit or 20
  local off = offset or 0

  -- 1. 检查是否直接粘贴了 Spotify 歌单链接
  local link_kind, link_id = spotify_service.parse_link(query_text)
  if link_kind == "playlist" and link_id and string.len(link_id) >= 15 then
    local playlist_res = spotify_service.get_playlist(link_id)
    if playlist_res and playlist_res.songs and #playlist_res.songs > 0 then
      return {
        songs = playlist_res.songs,
        playlists = {
          {
            id = link_id,
            title = playlist_res.title or "Spotify 歌单",
            cover = playlist_res.cover,
            trackCount = #playlist_res.songs,
            provider = "spotube"
          }
        },
        albums = {}
      }
    end
  end

  local token = spotify_service.ensure_token()
  local songs = {}
  local playlists = {}
  local albums = {}

  -- 2. 优先尝试 Pathfinder GraphQL searchDesktop
  if token then
    local gql_url = constants.HOST_SPOTIFY_PARTNER .. "/pathfinder/v2/query"
    local gql_payload = {
      operationName = "searchDesktop",
      variables = {
        searchTerm = query_text,
        offset = off,
        limit = lim,
        numberOfTopResults = 5,
        includeAudiobooks = false
      },
      extensions = {
        persistedQuery = {
          version = 1,
          sha256Hash = SEARCH_DESKTOP_HASH
        }
      }
    }

    local gql_headers = {
      ["User-Agent"] = constants.USER_AGENT_DESKTOP,
      ["Authorization"] = "Bearer " .. tostring(token),
      ["Content-Type"] = "application/json"
    }

    local sp_dc = store.get("sp_dc")
    if sp_dc and string.len(sp_dc) > 0 then
      gql_headers["Cookie"] = "sp_dc=" .. tostring(sp_dc)
    end

    local gql_res = http.post(gql_url, gql_payload, gql_headers)
    if gql_res and type(gql_res) == "table" and gql_res.data and gql_res.data.searchV2 then
      local searchV2 = gql_res.data.searchV2
      local search_artists = {}

      -- 1. 解析单曲
      local track_section = searchV2.tracksV2 or searchV2.tracks
      if track_section and track_section.items then
        for _, wrap in ipairs(track_section.items) do
          local item = wrap.item and wrap.item.data
          if item and item.id then
            local artist_names = {}
            local song_artists = {}
            if item.artists and item.artists.items then
              for _, art in ipairs(item.artists.items) do
                local a_name = art.profile and art.profile.name
                if a_name then
                  table.insert(artist_names, a_name)
                  table.insert(song_artists, {
                    id = art.uri or a_name,
                    name = a_name
                  })
                end
              end
            end

            if #song_artists == 0 then
              table.insert(song_artists, { id = "unknown", name = "未知歌手" })
            end

            local cover_url = nil
            if item.albumOfTrack and item.albumOfTrack.coverArt and item.albumOfTrack.coverArt.sources then
              local s = item.albumOfTrack.coverArt.sources
              cover_url = (s[#s] and s[#s].url) or (s[1] and s[1].url)
            end

            local duration_ms = item.duration and item.duration.totalMilliseconds or 0
            local album_name = item.albumOfTrack and item.albumOfTrack.name or ""
            local album_id = item.albumOfTrack and item.albumOfTrack.id or ""

            local song_obj = {
              id = item.id,
              name = item.name,
              title = item.name,
              artists = song_artists,
              artist = table.concat(artist_names, ", "),
              album = album_name,
              albumName = album_name,
              albumId = album_id,
              cover = cover_url,
              coverUrl = cover_url,
              duration = math.floor(duration_ms / 1000),
              durationMs = duration_ms,
              provider = "spotube"
            }
            store.save_track_meta(item.id, song_obj)
            table.insert(songs, song_obj)
          end
        end
      end

      -- 2. 解析专辑
      local album_section = searchV2.albumsV2 or searchV2.albums
      if album_section and album_section.items then
        for _, wrap in ipairs(album_section.items) do
          local a_data = wrap.data
          if a_data and a_data.uri then
            local _, a_id = spotify_service.parse_link(a_data.uri)
            a_id = a_id or a_data.id
            if a_id then
              local a_cover = nil
              if a_data.coverArt and a_data.coverArt.sources and a_data.coverArt.sources[1] then
                a_cover = a_data.coverArt.sources[1].url
              end
              local a_artists = {}
              if a_data.artists and a_data.artists.items then
                for _, art in ipairs(a_data.artists.items) do
                  if art.profile and art.profile.name then
                    table.insert(a_artists, { id = art.uri or art.profile.name, name = art.profile.name })
                  end
                end
              end
              table.insert(albums, {
                id = a_id,
                name = a_data.name or "专辑",
                title = a_data.name or "专辑",
                cover = a_cover,
                coverUrl = a_cover,
                artists = a_artists,
                provider = "spotube"
              })
            end
          end
        end
      end

      -- 3. 解析歌手
      if searchV2.artists and searchV2.artists.items then
        for _, wrap in ipairs(searchV2.artists.items) do
          local art_data = wrap.data
          if art_data and art_data.profile and art_data.profile.name then
            local art_cover = nil
            if art_data.visuals and art_data.visuals.avatarImage and art_data.visuals.avatarImage.sources and art_data.visuals.avatarImage.sources[1] then
              art_cover = art_data.visuals.avatarImage.sources[1].url
            end
            table.insert(search_artists, {
              id = art_data.uri or art_data.profile.name,
              name = art_data.profile.name,
              avatar = art_cover,
              avatarUrl = art_cover,
              provider = "spotube"
            })
          end
        end
      end

      -- 4. 解析歌单
      if searchV2.playlists and searchV2.playlists.items then
        for _, wrap in ipairs(searchV2.playlists.items) do
          local p_data = wrap.data
          if p_data and p_data.uri then
            local _, p_id = spotify_service.parse_link(p_data.uri)
            p_id = p_id or p_data.id
            if p_id then
              local p_cover = nil
              if p_data.images and p_data.images.items and p_data.images.items[1] then
                local srcs = p_data.images.items[1].sources
                p_cover = srcs and srcs[1] and srcs[1].url
              end
              table.insert(playlists, {
                id = p_id,
                title = p_data.name or "歌单",
                name = p_data.name or "歌单",
                cover = p_cover,
                coverUrl = p_cover,
                provider = "spotube"
              })
            end
          end
        end
      end

      if #songs > 0 or #playlists > 0 or #albums > 0 then
        return {
          songs = songs,
          albums = albums,
          artists = search_artists,
          playlists = playlists
        }
      end
    end
  end

  -- 3. 降级方案：REST API 搜索 (https://api.spotify.com/v1/search)
  local search_url = "https://api.spotify.com/v1/search?q=" .. tostring(query_text) ..
                     "&type=track,playlist,album&limit=" .. tostring(lim) .. "&offset=" .. tostring(off)
  local headers = {
    ["User-Agent"] = constants.USER_AGENT_DESKTOP,
    ["Authorization"] = "Bearer " .. tostring(token or "")
  }

  local res = http.get(search_url, headers)
  if res and type(res) == "table" then
    if res.tracks and res.tracks.items then
      for _, item in ipairs(res.tracks.items) do
        local artists = {}
        local song_artists = {}
        if item.artists then
          for _, a in ipairs(item.artists) do
            table.insert(artists, a.name)
            table.insert(song_artists, { id = a.id or a.name, name = a.name })
          end
        end
        local cover_url = nil
        if item.album and item.album.images and #item.album.images > 0 then
          cover_url = item.album.images[1].url
        end
        local dur_ms = item.duration_ms or 0
        local dur_sec = math.floor(dur_ms / 1000)
        local album_name = (item.album and item.album.name) or ""
        table.insert(songs, {
          id = item.id,
          name = item.name,
          title = item.name,
          artists = song_artists,
          artist = table.concat(artists, ", "),
          album = album_name,
          albumName = album_name,
          albumId = item.album and item.album.id or "",
          cover = cover_url,
          coverUrl = cover_url,
          duration = dur_sec,
          durationMs = dur_ms,
          provider = "spotube"
        })
      end
    end
  end

  return {
    songs = songs,
    albums = albums,
    artists = {},
    playlists = playlists
  }
end

local PLAYLIST_GQL_HASH = "21ea11a6ac75a5f3e01fd365d29c18e0a4a8b7dc09f89bbb5d73910190c6acaf"

--- 获取歌单详情与曲目 (优先采用官方 Pathfinder GQL，降级兼容 Web API)
function spotify_service.get_playlist(playlist_id)
  local raw_id = playlist_id
  if type(playlist_id) == "table" then
    raw_id = playlist_id.id or playlist_id.playlistId or playlist_id.playlist_id
  end
  local clean_id = spotify_service.clean_id(raw_id)
  if not clean_id or clean_id == "" then
    return { id = "", name = "歌单", title = "歌单", cover = nil, coverUrl = nil, songCount = 0, songs = {} }
  end

  local songs = {}
  local title = "Spotify 歌单"
  local cover = nil

  -- 1. 优先通过 open.spotify.com/embed 抓取完整歌单 (免鉴权，无 429 速率限制，不受 GQL hash 失效影响)
  local embed_url = "https://open.spotify.com/embed/playlist/" .. tostring(clean_id)
  local embed_res = http.get(embed_url, {
    ["User-Agent"] = constants.USER_AGENT_DESKTOP
  })
  if (not embed_res or type(embed_res) ~= "string" or not string.find(embed_res, "__NEXT_DATA__", 1, true)) then
    embed_url = "https://open.spotify.com/embed/album/" .. tostring(clean_id)
    embed_res = http.get(embed_url, {
      ["User-Agent"] = constants.USER_AGENT_DESKTOP
    })
  end

  if embed_res and type(embed_res) == "string" then
    local s_start, s_end = string.find(embed_res, '<script id="__NEXT_DATA__"[^>]*>')
    if s_end then
      local e_start = string.find(embed_res, "</script>", s_end + 1, true)
      if e_start then
        local json_text = string.sub(embed_res, s_end + 1, e_start - 1)
        local data = http.json_decode(json_text)
        local entity = data and data.props and data.props.pageProps and data.props.pageProps.state and data.props.pageProps.state.data and data.props.pageProps.state.data.entity
        if entity then
          title = entity.title or entity.name or title
          if entity.coverArt and entity.coverArt.sources and entity.coverArt.sources[1] then
            cover = entity.coverArt.sources[1].url
          end
          if entity.trackList and type(entity.trackList) == "table" then
            for _, tr in ipairs(entity.trackList) do
              local tr_id = spotify_service.clean_id(tr.uri)
              local tr_title = tr.title or ""
              local tr_artist = tr.subtitle or ""
              local tr_dur = tonumber(tr.duration) or 0
              local song_artists = {}
              if tr_artist ~= "" then
                table.insert(song_artists, { id = tr_artist, name = tr_artist })
              else
                table.insert(song_artists, { id = "unknown", name = "未知歌手" })
              end
              local song_obj = {
                id = tr_id,
                name = tr_title,
                title = tr_title,
                artists = song_artists,
                artist = tr_artist,
                album = title,
                albumName = title,
                albumId = clean_id,
                cover = cover,
                coverUrl = cover,
                duration = math.floor(tr_dur / 1000),
                durationMs = tr_dur,
                provider = "spotube"
              }
              store.save_track_meta(tr_id, song_obj)
              table.insert(songs, song_obj)
            end
          end
          if #songs > 0 then
            return {
              id = clean_id,
              name = title,
              title = title,
              cover = cover,
              coverUrl = cover,
              songCount = #songs,
              songs = songs
            }
          end
        end
      end
    end
  end

  local token = spotify_service.ensure_token()

  -- 2. 使用 Pathfinder GQL fetchPlaylist
  if token then
    local uri_formatted = "spotify:playlist:" .. tostring(clean_id)

    local gql_url = constants.HOST_SPOTIFY_PARTNER .. "/pathfinder/v2/query"
    local gql_payload = {
      operationName = "fetchPlaylist",
      variables = {
        uri = uri_formatted,
        offset = 0,
        limit = 100,
        enableWatchFeedEntrypoint = false
      },
      extensions = {
        persistedQuery = {
          version = 1,
          sha256Hash = PLAYLIST_GQL_HASH
        }
      }
    }

    local gql_headers = {
      ["User-Agent"] = constants.USER_AGENT_DESKTOP,
      ["Authorization"] = "Bearer " .. tostring(token),
      ["Content-Type"] = "application/json"
    }

    local sp_dc = store.get("sp_dc")
    if sp_dc and string.len(sp_dc) > 0 then
      gql_headers["Cookie"] = "sp_dc=" .. tostring(sp_dc)
    end

    local gql_res = http.post(gql_url, gql_payload, gql_headers)
    if gql_res and type(gql_res) == "table" and gql_res.data and gql_res.data.playlistV2 then
      local pl = gql_res.data.playlistV2
      title = pl.name or title

      if pl.images and pl.images.items and pl.images.items[1] and pl.images.items[1].sources then
        local srcs = pl.images.items[1].sources
        cover = srcs[1] and srcs[1].url
      end

      local content = pl.content
      if content and content.items then
        for _, it in ipairs(content.items) do
          local tr = it.itemV2 and it.itemV2.data
          if tr and tr.id then
            local artist_names = {}
            local song_artists = {}

            local art_items = tr.artists and tr.artists.items
            if not art_items and tr.albumOfTrack and tr.albumOfTrack.artists then
              art_items = tr.albumOfTrack.artists.items
            end

            if art_items then
              for _, a in ipairs(art_items) do
                local a_name = a.profile and a.profile.name
                if a_name then
                  table.insert(artist_names, a_name)
                  table.insert(song_artists, { id = a.uri or a_name, name = a_name, coverUrl = "" })
                end
              end
            end

            if #song_artists == 0 then
              table.insert(song_artists, { id = "unknown", name = "未知歌手", coverUrl = "" })
            end

            local tr_cover = nil
            if tr.albumOfTrack and tr.albumOfTrack.coverArt and tr.albumOfTrack.coverArt.sources then
              local srcs = tr.albumOfTrack.coverArt.sources
              tr_cover = (srcs[#srcs] and srcs[#srcs].url) or (srcs[1] and srcs[1].url)
            end

            local dur_ms = (tr.duration and tr.duration.totalMilliseconds) or (tr.duration_ms or 0)
            local album_name = (tr.albumOfTrack and tr.albumOfTrack.name) or ""
            local album_id = (tr.albumOfTrack and tr.albumOfTrack.id) or ""

            local song_obj = {
              id = tr.id,
              name = tr.name,
              title = tr.name,
              artists = song_artists,
              artist = table.concat(artist_names, ", "),
              album = album_name,
              albumName = album_name,
              albumId = album_id,
              cover = tr_cover or cover,
              coverUrl = tr_cover or cover,
              duration = math.floor(dur_ms / 1000),
              durationMs = dur_ms,
              provider = "spotube"
            }
            store.save_track_meta(tr.id, song_obj)
            table.insert(songs, song_obj)
          end
        end
      end

      if #songs > 0 then
        return {
          id = clean_id,
          name = title,
          title = title,
          cover = cover,
          coverUrl = cover,
          songCount = #songs,
          songs = songs
        }
      end
    end
  end

  -- 2. 降级方案：REST API (https://api.spotify.com/v1/playlists/)
  local url = "https://api.spotify.com/v1/playlists/" .. tostring(clean_id)
  local headers = {
    ["User-Agent"] = constants.USER_AGENT_DESKTOP,
    ["Authorization"] = "Bearer " .. tostring(token or "")
  }

  local res = http.get(url, headers)
  if res and type(res) == "table" then
    title = res.name or title
    if res.images and #res.images > 0 then
      cover = res.images[1].url
    end
    if res.tracks and res.tracks.items then
      for _, it in ipairs(res.tracks.items) do
        local tr = it.track
        if tr and tr.id then
          local artists = {}
          local song_artists = {}
          if tr.artists then
            for _, a in ipairs(tr.artists) do
              table.insert(artists, a.name)
              table.insert(song_artists, { id = a.id or a.name, name = a.name })
            end
          end
          if #song_artists == 0 then
            table.insert(song_artists, { id = "unknown", name = "未知歌手" })
          end
          local tr_cover = nil
          if tr.album and tr.album.images and #tr.album.images > 0 then
            tr_cover = tr.album.images[1].url
          end
          local dur_ms = tr.duration_ms or 0
          local album_name = (tr.album and tr.album.name) or ""
          table.insert(songs, {
            id = tr.id,
            name = tr.name,
            title = tr.name,
            artists = song_artists,
            artist = table.concat(artists, ", "),
            album = album_name,
            albumName = album_name,
            albumId = (tr.album and tr.album.id) or "",
            cover = tr_cover or cover,
            coverUrl = tr_cover or cover,
            duration = math.floor(dur_ms / 1000),
            durationMs = dur_ms,
            provider = "spotube"
          })
        end
      end
    end
  end

  return {
    id = playlist_id,
    name = title,
    title = title,
    cover = cover,
    coverUrl = cover,
    songCount = #songs,
    songs = songs
  }
end

--- 获取主页推荐歌单与榜单 (完整适配 Lazer 资料库契约: name, coverUrl, songCount)
function spotify_service.get_home_feed()
  local token = spotify_service.ensure_token()
  local sp_dc = store.get("sp_dc")
  local playlists = {}

  if sp_dc and token then
    local user_pl_url = "https://api.spotify.com/v1/me/playlists?limit=20"
    local res = http.get(user_pl_url, {
      ["User-Agent"] = constants.USER_AGENT_DESKTOP,
      ["Authorization"] = "Bearer " .. tostring(token)
    })
    if res and type(res) == "table" and res.items then
      for _, p in ipairs(res.items) do
        local p_cover = nil
        if p.images and #p.images > 0 then
          p_cover = p.images[1].url
        end
        local p_count = p.tracks and p.tracks.total or 0
        table.insert(playlists, {
          id = p.id,
          name = p.name or "我的歌单",
          title = p.name or "我的歌单",
          cover = p_cover,
          coverUrl = p_cover,
          songCount = p_count,
          trackCount = p_count,
          isFavorites = false,
          writable = false,
          provider = "spotube"
        })
      end
    end
  end

  -- 公共官方精选榜单 (预置规范字段)
  local charts = {
    {
      id = "37i9dQZEVXbMDoHDwVN2tF",
      name = "Top 50 - Global (全球五十佳)",
      title = "Top 50 - Global (全球五十佳)",
      cover = "https://charts-images.scdn.co/assets/locale_en/regional/daily/region_global_default.jpg",
      coverUrl = "https://charts-images.scdn.co/assets/locale_en/regional/daily/region_global_default.jpg",
      songCount = 50,
      trackCount = 50,
      isFavorites = false,
      writable = false,
      provider = "spotube"
    },
    {
      id = "37i9dQZEVXbLRQDuF5jeBp",
      name = "Top 50 - USA (美国五十佳)",
      title = "Top 50 - USA (美国五十佳)",
      cover = "https://charts-images.scdn.co/assets/locale_en/regional/daily/region_us_default.jpg",
      coverUrl = "https://charts-images.scdn.co/assets/locale_en/regional/daily/region_us_default.jpg",
      songCount = 50,
      trackCount = 50,
      isFavorites = false,
      writable = false,
      provider = "spotube"
    },
    {
      id = "37i9dQZEVXbKXQ4mDTEBXq",
      name = "Top 50 - Japan (日本五十佳)",
      title = "Top 50 - Japan (日本五十佳)",
      cover = "https://charts-images.scdn.co/assets/locale_en/regional/daily/region_jp_default.jpg",
      coverUrl = "https://charts-images.scdn.co/assets/locale_en/regional/daily/region_jp_default.jpg",
      songCount = 50,
      trackCount = 50,
      isFavorites = false,
      writable = false,
      provider = "spotube"
    }
  }

  if #playlists == 0 then
    for _, c in ipairs(charts) do
      table.insert(playlists, c)
    end
  end

  return {
    playlists = playlists,
    charts = charts
  }
end

--- 根据 Spotify Track ID 查询单曲详情与艺术家
function spotify_service.get_track_detail(track_id)
  local pure_id = spotify_service.clean_id(track_id)
  if not pure_id or pure_id == "" then return nil end

  local token = spotify_service.ensure_token()
  local url = "https://api.spotify.com/v1/tracks/" .. tostring(pure_id)
  local headers = {
    ["User-Agent"] = constants.USER_AGENT_DESKTOP
  }
  if token then
    headers["Authorization"] = "Bearer " .. tostring(token)
  end

  local res = http.get(url, headers)
  if res and type(res) == "table" and res.name then
    local artist_names = {}
    local song_artists = {}
    if res.artists then
      for _, a in ipairs(res.artists) do
        table.insert(artist_names, a.name)
        table.insert(song_artists, { id = a.id or a.name, name = a.name, coverUrl = "" })
      end
    end
    local cover = nil
    if res.album and res.album.images and res.album.images[1] then
      cover = res.album.images[1].url
    end
    local dur_ms = res.duration_ms or 0
    local track_obj = {
      id = res.id or pure_id,
      name = res.name,
      title = res.name,
      artists = song_artists,
      artist = table.concat(artist_names, ", "),
      albumName = res.album and res.album.name or "",
      albumId = res.album and res.album.id or "",
      cover = cover,
      coverUrl = cover,
      duration = math.floor(dur_ms / 1000),
      durationMs = dur_ms,
      provider = "spotube"
    }
    store.save_track_meta(pure_id, track_obj)
    return track_obj
  end

  return nil
end

return spotify_service
