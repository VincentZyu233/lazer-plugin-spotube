local store = require("spotube.core.store")

local cache = {
  _l1 = {},            -- key -> { stream = ..., video_id = ..., expire_at = number }
  _l1_order = {},      -- LRU key 访问顺序
  _max_l1_size = 64,   -- L1 内存最大容量
  DEFAULT_STREAM_TTL = 7200 -- 2 小时 (秒)
}

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

local function touch_l1_key(key)
  for i, k in ipairs(cache._l1_order) do
    if k == key then
      table.remove(cache._l1_order, i)
      break
    end
  end
  table.insert(cache._l1_order, key)
  -- 满载淘汰最早项
  while #cache._l1_order > cache._max_l1_size do
    local oldest = table.remove(cache._l1_order, 1)
    if oldest then
      cache._l1[oldest] = nil
    end
  end
end

--- 获取有效音频流 (L1 内存 -> L2 持久化两级穿透)
function cache.get_stream(track_id)
  if not track_id or track_id == "" then return nil, nil end
  local clean_id = store.clean_id(track_id)
  local now_s = current_time_seconds()

  -- 1. 检查 L1 内存缓存
  local l1_entry = cache._l1[clean_id]
  if l1_entry and l1_entry.stream and l1_entry.stream.url then
    if now_s == 0 or (l1_entry.expire_at and l1_entry.expire_at > now_s) then
      touch_l1_key(clean_id)
      return l1_entry.stream, l1_entry.video_id, "L1"
    else
      -- 已过期
      cache._l1[clean_id] = nil
    end
  end

  -- 2. 检查 L2 本地持久化缓存
  local l2_data = store.get("stream_cache:" .. clean_id)
  if l2_data and type(l2_data) == "table" and l2_data.stream and l2_data.stream.url then
    local expire_at = tonumber(l2_data.expire_at) or 0
    if now_s == 0 or expire_at > now_s then
      -- 回填 L1 内存
      cache._l1[clean_id] = {
        stream = l2_data.stream,
        video_id = l2_data.video_id,
        expire_at = expire_at
      }
      touch_l1_key(clean_id)
      return l2_data.stream, l2_data.video_id, "L2"
    else
      -- 过期删除
      store.set("stream_cache:" .. clean_id, nil)
    end
  end

  return nil, nil, nil
end

--- 写入音频流 (同时更新 L1、L2 及 VideoID 映射)
function cache.set_stream(track_id, stream_res, video_id, ttl)
  if not track_id or not stream_res or not stream_res.url then return end
  local clean_id = store.clean_id(track_id)
  local now_s = current_time_seconds()
  local effective_ttl = tonumber(ttl) or cache.DEFAULT_STREAM_TTL
  local expire_at = (now_s > 0 and (now_s + effective_ttl)) or (1795730121 + effective_ttl)

  -- 更新 L1 内存
  cache._l1[clean_id] = {
    stream = stream_res,
    video_id = video_id,
    expire_at = expire_at
  }
  touch_l1_key(clean_id)

  -- 更新 L2 持久化存储
  store.set("stream_cache:" .. clean_id, {
    stream = stream_res,
    video_id = video_id,
    expire_at = expire_at
  })

  -- 永久记住此曲目与 YouTube Video ID 最佳映射
  if video_id and string.len(tostring(video_id)) > 3 then
    cache.set_matched_vid(clean_id, video_id)
  end
end

--- 获取已记忆的最佳匹配 Video ID
function cache.get_matched_vid(track_id)
  if not track_id or track_id == "" then return nil end
  local clean_id = store.clean_id(track_id)
  local vid = store.get("matched_vid:" .. clean_id)
  if vid and string.len(tostring(vid)) > 3 then
    return tostring(vid)
  end
  return nil
end

--- 持久化记录最佳匹配 Video ID
function cache.set_matched_vid(track_id, video_id)
  if not track_id or not video_id then return end
  local clean_id = store.clean_id(track_id)
  store.set("matched_vid:" .. clean_id, tostring(video_id))
end

--- 强制清理指定曲目的缓存 (用于播放失败或直链 403 时的降级重试)
function cache.invalidate(track_id)
  if not track_id or track_id == "" then return end
  local clean_id = store.clean_id(track_id)
  cache._l1[clean_id] = nil
  store.set("stream_cache:" .. clean_id, nil)
end

return cache
