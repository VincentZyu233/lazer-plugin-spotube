local auth = require("spotube.services.auth")
local spotify = require("spotube.services.spotify")
local stream = require("spotube.services.stream")
local lyrics = require("spotube.services.lyrics")

local plugin = {}

local CAPABILITIES = {
  "search",
  "lyrics",
  "playlists",
  "favorites",
  "browseAlbums",
  "homeFeed",
  "charts",
  "userPlaylists",
  "artist",
  "artistSongs",
  "artistAlbums"
}

function plugin.call(operation, args)
  args = args or {}

  if operation == "describe" then
    return {
      providers = {
        {
          id = "spotube",
          name = "Spotube",
          auth = { "qr", "cookie" },
          capabilities = CAPABILITIES,
          loginHint = "支持在浏览器中授权登录 Spotify，亦可运行 tools/get_cookie 自动秒登或直接粘贴 sp_dc 凭据。",
          cookieHint = "直接粘贴 sp_dc 的内容（如 AQB...）或整段 Cookie"
        }
      }
    }
  elseif operation == "session" then
    return auth.session(spotify)
  elseif operation == "loginCookie" then
    local cookie_str = args.cookie or args.value
    return auth.login_cookie(cookie_str, spotify)
  elseif operation == "qrKey" then
    return auth.qrKey()
  elseif operation == "qrUrl" then
    return auth.qrUrl(args)
  elseif operation == "qrCheck" then
    return auth.qrCheck(args, spotify)
  elseif operation == "logout" then
    return auth.logout()
  elseif operation == "search" then
    local query = ""
    local limit = 20
    local offset = 0
    if type(args) == "string" then
      query = args
    elseif type(args) == "table" then
      query = args.query or args.keyword or args.text or args.q or args.s or ""
      limit = tonumber(args.limit) or 20
      offset = tonumber(args.offset) or 0
    end
    local res = spotify.search(query, limit, offset)
    if res and res.artists then
      for _, art in ipairs(res.artists) do
        art.coverUrl = art.coverUrl or art.avatarUrl or art.avatar
      end
    end
    return res
  elseif operation == "userPlaylists" then
    local limit = tonumber(type(args) == "table" and args.limit) or 50
    local offset = tonumber(type(args) == "table" and args.offset) or 0
    return spotify.get_user_playlists(limit, offset)
  elseif operation == "playlists" then
    local store = require("spotube.core.store")
    local sp_dc = store.get("sp_dc")
    local limit = tonumber(type(args) == "table" and args.limit) or 50
    local offset = tonumber(type(args) == "table" and args.offset) or 0
    if sp_dc and string.len(tostring(sp_dc)) > 5 then
      local user_pls = spotify.get_user_playlists(limit, offset)
      if user_pls and #user_pls > 0 then
        return user_pls
      elseif offset > 0 then
        return {}
      end
    end
    if offset > 0 then
      return {}
    end
    local feed = spotify.get_home_feed()
    return feed.playlists or {}
  elseif operation == "artist" then
    local a_id = type(args) == "table" and (args.id or args.artistId or args.artist_id or args.name) or tostring(args or "")
    if a_id == "" and type(args) == "table" then a_id = args.name or "" end
    return spotify.get_artist(a_id)
  elseif operation == "artistSongs" then
    local a_id = type(args) == "table" and (args.id or args.artistId or args.artist_id or args.name) or tostring(args or "")
    if a_id == "" and type(args) == "table" then a_id = args.name or "" end
    local offset = tonumber(type(args) == "table" and args.offset) or 0
    local songs = spotify.get_artist_top_tracks(a_id, offset)
    return (type(songs) == "table" and (songs.list or songs)) or {}
  elseif operation == "artistAlbums" or operation == "browseAlbums" then
    local a_id = type(args) == "table" and (args.id or args.artistId or args.artist_id or args.name) or tostring(args or "")
    if a_id == "" and type(args) == "table" then a_id = args.name or "" end
    local limit = tonumber(type(args) == "table" and args.limit) or 30
    local offset = tonumber(type(args) == "table" and args.offset) or 0
    local res = spotify.get_artist_albums(a_id, limit, offset)
    return (type(res) == "table" and (res.list or res)) or {}
  elseif operation == "playlist" then
    local p_id = type(args) == "table" and (args.id or args.playlistId or args.playlist_id) or tostring(args or "")
    if p_id == "__lazer_favorites__" or string.find(p_id, "favorites", 1, true) then
      return {
        id = p_id,
        name = "我喜欢",
        title = "我喜欢",
        isFavorites = true,
        songCount = 0
      }
    end
    return spotify.get_playlist(args)
  elseif operation == "playlistSongs" then
    local p_id = type(args) == "table" and (args.id or args.playlistId or args.playlist_id) or tostring(args or "")
    if p_id == "__lazer_favorites__" or string.find(p_id, "favorites", 1, true) then
      local limit = tonumber(type(args) == "table" and args.limit) or 50
      local offset = tonumber(type(args) == "table" and args.offset) or 0
      return spotify.get_library_tracks(limit, offset)
    end
    local res = spotify.get_playlist(args)
    return (res and res.songs) or {}
  elseif operation == "album" then
    return spotify.get_album(args)
  elseif operation == "albumSongs" then
    local limit = 100
    local offset = 0
    local id = args
    if type(args) == "table" then
      id = args.id or args.albumId or args.album_id
      limit = tonumber(args.limit) or 100
      offset = tonumber(args.offset) or 0
    end
    return spotify.get_album_songs(id, limit, offset)
  elseif operation == "homeFeed" then
    local feed = spotify.get_home_feed()
    return {
      editorialPlaylists = feed.editorialPlaylists or feed.charts or {},
      recommended = feed.recommended or feed.playlists or {},
      playlists = feed.playlists or {},
      charts = feed.charts or {}
    }
  elseif operation == "charts" then
    local feed = spotify.get_home_feed()
    return feed.charts or {}
  elseif operation == "favorites" then
    local store = require("spotube.core.store")
    local limit = 50
    local offset = 0
    if type(args) == "table" then
      limit = tonumber(args.limit) or 50
      offset = tonumber(args.offset) or 0
    end
    store.set("debug_fav_invoke", { time = (host and host.now and host.now()) or 0, args = args })
    local ok, res = pcall(spotify.get_library_tracks, limit, offset)
    if not ok then
      store.set("debug_fav_error", tostring(res))
      return {}
    end
    store.set("debug_fav_result", { count = (res and #res) or 0 })
    return res or {}
  elseif operation == "setFavorite" then
    local track_id = ""
    local is_favorite = false
    if type(args) == "table" then
      track_id = args.id or args.song or args.trackId or args.track_id or ""
      is_favorite = (args.favorite == true or args.liked == true)
    else
      track_id = tostring(args or "")
      is_favorite = true
    end
    return spotify.set_favorite(track_id, is_favorite)
  elseif operation == "song" then
    local song_id = type(args) == "table" and (args.id or args.songId) or tostring(args or "")
    local detail = spotify.get_track_detail(song_id)
    if detail then
      return detail
    end
    local cached = require("spotube.core.store").get_track_meta(song_id)
    if cached then
      return cached
    end
    return {
      id = song_id,
      provider = "spotube"
    }
  elseif operation == "stream" then
    local res, err = stream.resolve_stream(args)
    if not res or type(res) ~= "table" or not res.url then
      return {
        error = {
          code = 404,
          message = err or "暂无可用音频流"
        }
      }
    end
    return res
  elseif operation == "lyrics" then
    local store = require("spotube.core.store")
    local dbg = {
      args = args,
      op = "lyrics",
      time = (host and host.now and host.now()) or 0,
      steps = {}
    }
    local function log_step(step_name, detail)
      table.insert(dbg.steps, { step = step_name, detail = detail })
      store.set("debug_lyrics_latest", dbg)
      if host and host.log then
        pcall(host.log, "info", "[spotube lyrics] " .. tostring(step_name), detail or {})
      end
    end

    log_step("1_start", { args = args })

    local song_id = type(args) == "table" and (args.id or args.songId) or tostring(args or "")
    local title = type(args) == "table" and (args.title or args.name) or nil
    local artist = type(args) == "table" and args.artist or nil
    local album = type(args) == "table" and (args.album or args.albumName) or nil
    local duration = type(args) == "table" and (args.duration or (args.durationMs and (args.durationMs / 1000))) or nil

    if (not title or title == "") and song_id and song_id ~= "" then
      local clean_id = spotify.clean_id(song_id)
      log_step("2_resolve_id", { raw_id = song_id, clean_id = clean_id })

      local meta = store.get_track_meta(clean_id)
      if meta and (meta.title or meta.name) then
        title = meta.title or meta.name
        artist = artist or meta.artist
        album = album or meta.albumName
        duration = duration or (meta.durationMs and (meta.durationMs / 1000))
        log_step("3_found_store_meta", { title = title, artist = artist, album = album, duration = duration })
      else
        log_step("3_store_meta_miss", { clean_id = clean_id })
        local detail = spotify.get_track_detail(clean_id)
        if detail and (detail.title or detail.name) then
          title = detail.title or detail.name
          artist = artist or detail.artist
          album = album or detail.albumName
          duration = duration or (detail.durationMs and (detail.durationMs / 1000))
          log_step("3_found_detail_meta", { title = title, artist = artist, album = album, duration = duration })
        else
          log_step("3_detail_meta_failed", { clean_id = clean_id })
        end
      end
    end

    if not title or title == "" then
      log_step("4_aborted_no_title", { song_id = song_id })
      return {}
    end

    log_step("4_fetching_lrclib", {
      title = title,
      artist = artist,
      album = album,
      duration = duration,
      lyrics_type = type(lyrics),
      get_lyrics_type = type(lyrics and lyrics.get_lyrics)
    })

    local ok, res_or_err = pcall(function()
      return lyrics.get_lyrics(title, artist, album, duration, log_step)
    end)

    if not ok then
      log_step("5_exception_caught", { err = tostring(res_or_err) })
      return {}
    end

    local res = res_or_err

    if not res or not res.raw_lrc or string.len(res.raw_lrc) == 0 then
      log_step("5_lrclib_no_lyrics", { has_res = (res ~= nil) })
      return {}
    end

    local out = {
      {
        synced = (res.synced == true or res.hasSynced == true),
        lines = res.lines or {},
        lrc = res.raw_lrc,
        pureMusic = false
      }
    }
    log_step("5_success", {
      synced = out[1].synced,
      lines_count = #out[1].lines,
      lrc_len = string.len(out[1].lrc)
    })
    return out
  elseif operation == "player_event" then
    return nil
  end

  return nil
end

return plugin
