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
    local playlist_id = type(args) == "table" and (args.id or args.playlistId) or tostring(args or "")
    return spotify.get_playlist(playlist_id)
  elseif operation == "playlistSongs" then
    local playlist_id = type(args) == "table" and (args.id or args.playlistId) or tostring(args or "")
    if not playlist_id or playlist_id == "" then
      return { songs = {} }
    end
    local res = spotify.get_playlist(playlist_id)
    return res.songs or {}
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
    local song_id = args.id or args.songId
    return {
      id = song_id,
      provider = "spotube"
    }
  elseif operation == "stream" then
    local res, err = stream.resolve_stream(args)
    if not res then
      error(err or "Failed to resolve stream", 0)
    end
    return res
  elseif operation == "lyrics" then
    local title = args.title or args.name
    local artist = args.artist
    local album = args.album
    local duration = args.duration or (args.durationMs and (args.durationMs / 1000))
    local res = lyrics.get_lyrics(title, artist, album, duration)
    if not res or not res.lines or #res.lines == 0 then
      return { lines = {} }
    end
    return res
  elseif operation == "player_event" then
    return nil
  end

  return nil
end

return plugin
