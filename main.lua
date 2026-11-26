local spotify = require("spotube.services.spotify")
local stream = require("spotube.services.stream")
local lyrics = require("spotube.services.lyrics")

local M = {}

function M.describe()
  return {
    id = "community.spotube.music",
    name = "Spotube",
    version = "0.1.0",
    description = "基于 Spotube 架构打造的 Spotify 全球曲库插件：免登录畅享 Spotify 官方歌单与算法推荐，智能调度高保真无加密音频流。",
    provider = "spotube",
    apiVersion = 1,
    capabilities = {
      "search",
      "lyrics",
      "playlists",
      "browseAlbums",
      "homeFeed",
      "charts"
    }
  }
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

function M.playlistSongs(args)
  local playlist_id = args and (args.id or args.playlistId)
  if not playlist_id then
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
  -- Lazer 在点歌时传入 track 信息（包含 id, title, artist, duration 等）
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
    -- 若无精确时间轴，返回状态码 70 让宿主重试或优雅占位
    return { lines = {} }
  end
  return res
end

--- 插件统一分发网关
function call(operation, args)
  local fn = M[operation]
  if not fn then
    error("Unsupported operation: " .. tostring(operation), 0)
  end
  return fn(args)
end

return {
  call = call,
  describe = M.describe
}
