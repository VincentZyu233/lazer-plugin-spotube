local auth = require("spotube.services.auth")
local spotify = require("spotube.services.spotify")
local stream = require("spotube.services.stream")
local lyrics = require("spotube.services.lyrics")

local plugin = {}

local CAPABILITIES = {
  "search",
  "lyrics",
  "playlists",
  "browseAlbums",
  "homeFeed",
  "charts"
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
    return spotify.search(query, limit, offset)
  elseif operation == "playlists" then
    local feed = spotify.get_home_feed()
    return feed.playlists or {}
  elseif operation == "playlist" then
    return spotify.get_playlist(args)
  elseif operation == "playlistSongs" then
    local res = spotify.get_playlist(args)
    return (res and res.songs) or {}
  elseif operation == "homeFeed" then
    local feed = spotify.get_home_feed()
    return {
      featuredPlaylists = feed.playlists,
      charts = feed.charts
    }
  elseif operation == "charts" then
    local feed = spotify.get_home_feed()
    return feed.charts or {}
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
    local title = args.title or args.name
    local artist = args.artist
    local album = args.album
    local duration = args.duration or (args.durationMs and (args.durationMs / 1000))
    local song_id = args.id or args.songId

    -- Lazer 宿主在播放页通常只传递 song_id，需自愈补全歌曲标题与歌手
    if (not title or title == "") and song_id then
      local clean_id = spotify.clean_id(song_id)
      local meta = require("spotube.core.store").get_track_meta(clean_id)
      if meta and (meta.title or meta.name) then
        title = meta.title or meta.name
        artist = artist or meta.artist
        album = album or meta.albumName
        duration = duration or (meta.durationMs and (meta.durationMs / 1000))
      else
        local detail = spotify.get_track_detail(clean_id)
        if detail and (detail.title or detail.name) then
          title = detail.title or detail.name
          artist = artist or detail.artist
          album = album or detail.albumName
          duration = duration or (detail.durationMs and (detail.durationMs / 1000))
        end
      end
    end

    local res = lyrics.get_lyrics(title, artist, album, duration)
    if not res or not res.lines or #res.lines == 0 then
      return {}
    end
    return {
      {
        synced = (res.synced == true or res.hasSynced == true),
        lines = res.lines,
        lrc = res.raw_lrc
      }
    }
  elseif operation == "player_event" then
    return nil
  end

  return nil
end

return plugin
