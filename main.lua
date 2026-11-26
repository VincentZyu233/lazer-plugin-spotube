local auth = require("spotube.services.auth")
local spotify = require("spotube.services.spotify")
local stream = require("spotube.services.stream")
local lyrics = require("spotube.services.lyrics")

local M = {}

local CAPABILITIES = {
  "search",
  "lyrics",
  "playlists",
  "browseAlbums",
  "homeFeed",
  "charts"
}

function M.describe()
  return {
    providers = {
      {
        id = "spotube",
        name = "Spotube",
        auth = { "cookie" },
        capabilities = CAPABILITIES,
        loginHint = "在浏览器中登录 open.spotify.com，按 F12 -> 应用程序(Application) -> Cookie 复制 sp_dc 的值粘贴至此处即可（支持免费和会员账号）。",
        cookieHint = "直接粘贴 sp_dc 的内容（如 AQB...）或整段 Cookie"
      }
    }
  }
end

function M.session()
  return auth.session(spotify)
end

function M.loginCookie(args)
  local cookie_str = args and (args.cookie or args.value)
  return auth.login_cookie(cookie_str, spotify)
end

function M.logout()
  return auth.logout()
end

function M.search(args)
  local query = (args and args.query) or ""
  local limit = (args and args.limit) or 20
  local offset = (args and args.offset) or 0
  return spotify.search(query, limit, offset)
end

function M.playlists(args)
  local feed = spotify.get_home_feed()
  return feed.playlists or {}
end

function M.playlist(args)
  local playlist_id = type(args) == "table" and (args.id or args.playlistId) or tostring(args or "")
  return spotify.get_playlist(playlist_id)
end

function M.playlistSongs(args)
  local playlist_id = type(args) == "table" and (args.id or args.playlistId) or tostring(args or "")
  if not playlist_id or playlist_id == "" then
    return { songs = {} }
  end
  local res = spotify.get_playlist(playlist_id)
  return res.songs or {}
end

function M.homeFeed(args)
  local feed = spotify.get_home_feed()
  return {
    featuredPlaylists = feed.playlists,
    charts = feed.charts
  }
end

function M.charts(args)
  local feed = spotify.get_home_feed()
  return feed.charts or {}
end

function M.song(args)
  local song_id = args and (args.id or args.songId)
  return {
    id = song_id,
    provider = "spotube"
  }
end

function M.stream(args)
  local track = args or {}
  local res, err = stream.resolve_stream(track)
  if not res then
    error(err or "Failed to resolve stream", 0)
  end
  return res
end

function M.lyrics(args)
  local title = args and (args.title or args.name)
  local artist = args and args.artist
  local album = args and args.album
  local duration = args and (args.duration or args.durationMs and (args.durationMs / 1000))

  local res = lyrics.get_lyrics(title, artist, album, duration)
  if not res or not res.lines or #res.lines == 0 then
    return { lines = {} }
  end
  return res
end

function M.player_event(args)
  -- 静默接收宿主广播事件
  return nil
end

--- 插件统一分发网关
function call(operation, args)
  local fn = M[operation]
  if fn then
    return fn(args)
  end
  -- 对于未知或可选操作，返回 nil 而非抛出 error，避免宿主日志爆红
  return nil
end

return {
  call = call,
  describe = M.describe
}
