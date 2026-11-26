local constants = require("spotube.core.constants")
local crypto = require("spotube.core.crypto")
local http = require("spotube.core.http")
local store = require("spotube.core.store")

local spotify_service = {}

-- 默认 TOTP 秘密与协议版本 (与 SpotAPI 及 Web Player 保持一致)
local DEFAULT_TOTP_SECRET = ",7/*F(\"rLJ2oxaKL^f+E1xvP@N"
local DEFAULT_TOTP_VER = "61"
local SEARCH_DESKTOP_HASH = "db61238974d27839a136c9dc02bfdbe3fab7635f21cf85976ebff9a1ee281345"

--- 获取有效 AccessToken (支持登录态与 TOTP 动态签名)
function spotify_service.ensure_token()
  local cached_token = store.get("sp_access_token")
  local cached_exp = store.get("sp_token_exp") or 0
  local now_s = os.time()

  if cached_token and cached_exp > (now_s + 60) then
    return cached_token
  end

  local sp_dc = store.get("sp_dc")
  local totp_code = crypto.generate_totp(DEFAULT_TOTP_SECRET, now_s, 30, 6)
  local token_url = constants.HOST_SPOTIFY .. "/api/token?reason=transport&productType=web-player" ..
                    "&totp=" .. tostring(totp_code) ..
                    "&totpServer=" .. tostring(totp_code) ..
                    "&totpVer=" .. DEFAULT_TOTP_VER

  local headers = {
    ["User-Agent"] = constants.USER_AGENT_DESKTOP,
    ["Referer"] = constants.HOST_SPOTIFY .. "/",
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
      store.set("sp_token_exp", now_s + 3600)
    end
    return res.accessToken
  end

  return nil
end

--- 获取当前登录用户信息 (/v1/me)
function spotify_service.get_me()
  local token = spotify_service.ensure_token()
  if not token then return nil end

  local me_url = "https://api.spotify.com/v1/me"
  local headers = {
    ["User-Agent"] = constants.USER_AGENT_DESKTOP,
    ["Authorization"] = "Bearer " .. tostring(token)
  }

  local res = http.get(me_url, headers)
  if res and type(res) == "table" and res.id then
    return res
  end
  return nil
end

--- 从 Spotify 链接或 URI 提取纯 ID 和类型
function spotify_service.parse_link(url_or_id)
  if not url_or_id then return nil, nil end
  local kind, id = string.match(url_or_id, "spotify:(%a+):([%w%d]+)")
  if not kind or not id then
    kind, id = string.match(url_or_id, "open%.spotify%.com/(%a+)/([%w%d]+)")
  end
  if not kind or not id then
    id = url_or_id
    kind = "playlist"
  end
  return kind, id
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

      -- 解析单曲
      local track_section = searchV2.tracksV2 or searchV2.tracks
      if track_section and track_section.items then
        for _, wrap in ipairs(track_section.items) do
          local item = wrap.item and wrap.item.data
          if item and item.id then
            local artist_names = {}
            if item.artists and item.artists.items then
              for _, art in ipairs(item.artists.items) do
                local a_name = art.profile and art.profile.name
                if a_name then table.insert(artist_names, a_name) end
              end
            end

            local cover_url = nil
            if item.albumOfTrack and item.albumOfTrack.coverArt and item.albumOfTrack.coverArt.sources then
              local s = item.albumOfTrack.coverArt.sources
              cover_url = (s[#s] and s[#s].url) or (s[1] and s[1].url)
            end

            local duration_ms = item.duration and item.duration.totalMilliseconds or 0
            table.insert(songs, {
              id = item.id,
              name = item.name,
              title = item.name,
              artist = table.concat(artist_names, ", "),
              album = item.albumOfTrack and item.albumOfTrack.name or "",
              cover = cover_url,
              duration = math.floor(duration_ms / 1000),
              durationMs = duration_ms,
              provider = "spotube"
            })
          end
        end
      end

      -- 解析歌单
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
                provider = "spotube"
              })
            end
          end
        end
      end

      if #songs > 0 or #playlists > 0 then
        return {
          songs = songs,
          playlists = playlists,
          albums = albums
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
        if item.artists then
          for _, a in ipairs(item.artists) do
            table.insert(artists, a.name)
          end
        end
        local cover_url = nil
        if item.album and item.album.images and #item.album.images > 0 then
          cover_url = item.album.images[1].url
        end
        local dur_sec = math.floor((item.duration_ms or 0) / 1000)
        table.insert(songs, {
          id = item.id,
          name = item.name,
          title = item.name,
          artist = table.concat(artists, ", "),
          album = (item.album and item.album.name) or "",
          cover = cover_url,
          duration = dur_sec,
          durationMs = item.duration_ms or (dur_sec * 1000),
          provider = "spotube"
        })
      end
    end
  end

  return {
    songs = songs,
    playlists = playlists,
    albums = albums
  }
end

--- 获取歌单详情与曲目
function spotify_service.get_playlist(playlist_id)
  if not playlist_id then return { songs = {} } end
  local token = spotify_service.ensure_token()

  local url = "https://api.spotify.com/v1/playlists/" .. tostring(playlist_id)
  local headers = {
    ["User-Agent"] = constants.USER_AGENT_DESKTOP,
    ["Authorization"] = "Bearer " .. tostring(token or "")
  }

  local res = http.get(url, headers)
  local songs = {}
  local title = "Spotify 歌单"
  local cover = nil

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
          if tr.artists then
            for _, a in ipairs(tr.artists) do
              table.insert(artists, a.name)
            end
          end
          local tr_cover = nil
          if tr.album and tr.album.images and #tr.album.images > 0 then
            tr_cover = tr.album.images[1].url
          end
          table.insert(songs, {
            id = tr.id,
            name = tr.name,
            title = tr.name,
            artist = table.concat(artists, ", "),
            album = (tr.album and tr.album.name) or "",
            cover = tr_cover or cover,
            duration = math.floor((tr.duration_ms or 0) / 1000),
            durationMs = tr.duration_ms or 0,
            provider = "spotube"
          })
        end
      end
    end
  end

  return {
    id = playlist_id,
    title = title,
    cover = cover,
    songs = songs
  }
end

--- 获取主页推荐歌单与榜单
function spotify_service.get_home_feed()
  -- 若用户已登录，优先返回用户歌单
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
        table.insert(playlists, {
          id = p.id,
          title = p.name or "我的歌单",
          cover = p_cover,
          trackCount = p.tracks and p.tracks.total or 0,
          provider = "spotube"
        })
      end
    end
  end

  -- 公共官方精选榜单
  local charts = {
    {
      id = "37i9dQZEVXbMDoHDwVN2tF",
      title = "Top 50 - Global (全球五十佳)",
      cover = "https://charts-images.scdn.co/assets/locale_en/regional/daily/region_global_default.jpg",
      provider = "spotube"
    },
    {
      id = "37i9dQZEVXbLRQDuF5jeBp",
      title = "Top 50 - USA (美国五十佳)",
      cover = "https://charts-images.scdn.co/assets/locale_en/regional/daily/region_us_default.jpg",
      provider = "spotube"
    },
    {
      id = "37i9dQZEVXbKXQ4mDTEBXq",
      title = "Top 50 - Japan (日本五十佳)",
      cover = "https://charts-images.scdn.co/assets/locale_en/regional/daily/region_jp_default.jpg",
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

return spotify_service
