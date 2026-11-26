local constants = require("spotube.core.constants")
local http = require("spotube.core.http")
local store = require("spotube.core.store")

local spotify_service = {}

--- 获取游客匿名 AccessToken
function spotify_service.ensure_token()
  local cached_token = store.get("sp_access_token")
  local cached_exp = store.get("sp_token_exp") or 0
  local now_s = os.time()

  if cached_token and cached_exp > (now_s + 60) then
    return cached_token
  end

  local token_url = constants.HOST_SPOTIFY .. "/api/token"
  local headers = {
    ["User-Agent"] = constants.USER_AGENT_DESKTOP,
    ["Referer"] = constants.HOST_SPOTIFY .. "/",
    ["Accept"] = "application/json"
  }

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

--- 从 Spotify 链接或 URI 提取纯 ID 和类型
function spotify_service.parse_link(url_or_id)
  if not url_or_id then return nil, nil end
  -- 匹配 spotify:playlist:xxxx 或 open.spotify.com/playlist/xxxx
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

--- 搜索单曲与歌单
function spotify_service.search(query_text, limit, offset)
  if not query_text or string.len(query_text) == 0 then
    return { songs = {}, playlists = {}, albums = {} }
  end

  local lim = limit or 20
  local off = offset or 0

  -- 检查是否直接粘贴了 Spotify 歌单链接
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

  -- 标准搜索请求
  local token = spotify_service.ensure_token()
  local search_url = "https://api.spotify.com/v1/search?q=" .. tostring(query_text) ..
                     "&type=track,playlist,album&limit=" .. tostring(lim) .. "&offset=" .. tostring(off)
  local headers = {
    ["User-Agent"] = constants.USER_AGENT_DESKTOP,
    ["Authorization"] = "Bearer " .. tostring(token)
  }

  local res = http.get(search_url, headers)
  local songs = {}
  local playlists = {}
  local albums = {}

  if res and type(res) == "table" then
    -- 解析单曲
    if res.tracks and res.tracks.items then
      for _, item in ipairs(res.tracks.items) do
        local artist_names = {}
        if item.artists then
          for _, a in ipairs(item.artists) do table.insert(artist_names, a.name or "") end
        end
        local cover_url = nil
        if item.album and item.album.images and item.album.images[1] then
          cover_url = item.album.images[1].url
        end

        table.insert(songs, {
          id = item.id or item.uri,
          title = item.name or "",
          artist = table.concat(artist_names, " / "),
          album = (item.album and item.album.name) or "",
          cover = cover_url,
          duration = math.floor((item.duration_ms or 0) / 1000),
          durationMs = item.duration_ms or 0,
          provider = "spotube"
        })
      end
    end

    -- 解析歌单
    if res.playlists and res.playlists.items then
      for _, pl in ipairs(res.playlists.items) do
        if pl and pl.id then
          local pl_cover = pl.images and pl.images[1] and pl.images[1].url
          table.insert(playlists, {
            id = pl.id,
            title = pl.name or "Spotify Playlist",
            cover = pl_cover,
            trackCount = pl.tracks and pl.tracks.total or 0,
            provider = "spotube"
          })
        end
      end
    end

    -- 解析专辑
    if res.albums and res.albums.items then
      for _, alb in ipairs(res.albums.items) do
        if alb and alb.id then
          local alb_cover = alb.images and alb.images[1] and alb.images[1].url
          local artist_names = {}
          if alb.artists then
            for _, a in ipairs(alb.artists) do table.insert(artist_names, a.name or "") end
          end
          table.insert(albums, {
            id = alb.id,
            title = alb.name or "",
            artist = table.concat(artist_names, " / "),
            cover = alb_cover,
            trackCount = alb.total_tracks or 0,
            provider = "spotube"
          })
        end
      end
    end
  end

  return {
    songs = songs,
    playlists = playlists,
    albums = albums
  }
end

--- 获取指定歌单的完整曲目
function spotify_service.get_playlist(playlist_id)
  local token = spotify_service.ensure_token()
  local url = "https://api.spotify.com/v1/playlists/" .. tostring(playlist_id)
  local headers = {
    ["User-Agent"] = constants.USER_AGENT_DESKTOP,
    ["Authorization"] = "Bearer " .. tostring(token)
  }

  local res = http.get(url, headers)
  if not res or type(res) ~= "table" then
    return { songs = {} }
  end

  local songs = {}
  if res.tracks and res.tracks.items then
    for _, wrap in ipairs(res.tracks.items) do
      local item = wrap.track or wrap
      if item and item.id and item.name then
        local artist_names = {}
        if item.artists then
          for _, a in ipairs(item.artists) do table.insert(artist_names, a.name or "") end
        end
        local cover_url = nil
        if item.album and item.album.images and item.album.images[1] then
          cover_url = item.album.images[1].url
        end

        table.insert(songs, {
          id = item.id,
          title = item.name or "",
          artist = table.concat(artist_names, " / "),
          album = (item.album and item.album.name) or "",
          cover = cover_url,
          duration = math.floor((item.duration_ms or 0) / 1000),
          durationMs = item.duration_ms or 0,
          provider = "spotube"
        })
      end
    end
  end

  local cover = res.images and res.images[1] and res.images[1].url
  return {
    id = res.id or playlist_id,
    title = res.name or "Spotify Playlist",
    cover = cover,
    songs = songs
  }
end

--- 首页发现流 (Featured & Global Charts)
function spotify_service.get_home_feed()
  local token = spotify_service.ensure_token()
  -- Spotify 精选播放列表
  local url = "https://api.spotify.com/v1/browse/featured-playlists?limit=12"
  local headers = {
    ["User-Agent"] = constants.USER_AGENT_DESKTOP,
    ["Authorization"] = "Bearer " .. tostring(token)
  }

  local res = http.get(url, headers)
  local playlists = {}
  if res and type(res) == "table" and res.playlists and res.playlists.items then
    for _, pl in ipairs(res.playlists.items) do
      if pl and pl.id then
        table.insert(playlists, {
          id = pl.id,
          title = pl.name or "精选歌单",
          cover = pl.images and pl.images[1] and pl.images[1].url,
          trackCount = pl.tracks and pl.tracks.total or 0,
          provider = "spotube"
        })
      end
    end
  end

  -- 全球热门榜单预置
  local featured_charts = {
    {
      id = "37i9dQZEVXbMDoHDwVN2tF",
      title = "Top 50 - Global (全球热门 Top 50)",
      cover = "https://charts-images.scdn.co/assets/locale_en/regional/daily/region_global_default.jpg",
      provider = "spotube"
    },
    {
      id = "37i9dQZEVXbLiRSasKsNU9",
      title = "Viral 50 - Global (全球热播趋势 50)",
      cover = "https://charts-images.scdn.co/assets/locale_en/viral/daily/region_global_default.jpg",
      provider = "spotube"
    },
    {
      id = "37i9dQZF1DXcBWIGoYBM5M",
      title = "Today's Top Hits",
      cover = "https://i.scdn.co/image/ab67706f000000025f190e38a4d4678d8a7c2e9a",
      provider = "spotube"
    }
  }

  return {
    playlists = playlists,
    charts = featured_charts
  }
end

return spotify_service
