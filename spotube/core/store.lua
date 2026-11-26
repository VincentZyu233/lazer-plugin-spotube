local store = {
  _cache = {},
  _track_meta = {}
}

function store.clean_id(raw_id)
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

function store.save_track_meta(track_id, meta)
  if not track_id or not meta then return end
  local cid = store.clean_id(track_id)
  store._track_meta[tostring(track_id)] = meta
  store._track_meta[cid] = meta
end

function store.get_track_meta(track_id)
  if not track_id then return nil end
  local cid = store.clean_id(track_id)
  return store._track_meta[cid] or store._track_meta[tostring(track_id)]
end

function store.get(key)
  if store._cache[key] ~= nil then
    return store._cache[key]
  end
  if host and host.storage_get then
    local ok, val = pcall(host.storage_get, key)
    if ok and val ~= nil then
      store._cache[key] = val
      return val
    end
  elseif host and host.storage and host.storage.get then
    local ok, val = pcall(host.storage.get, key)
    if ok and val ~= nil then
      store._cache[key] = val
      return val
    end
  end
  return nil
end

function store.get_fresh(key)
  if host and host.storage_get then
    local ok, val = pcall(host.storage_get, key)
    if ok and val ~= nil then
      store._cache[key] = val
      return val
    end
  elseif host and host.storage and host.storage.get then
    local ok, val = pcall(host.storage.get, key)
    if ok and val ~= nil then
      store._cache[key] = val
      return val
    end
  end
  store._cache[key] = nil
  return nil
end

function store.set(key, val)
  store._cache[key] = val
  if host and host.storage_set then
    pcall(host.storage_set, key, val)
  elseif host and host.storage and host.storage.set then
    pcall(host.storage.set, key, val)
  end
end

function store.get_matched_stream(track_id)
  if not track_id then return nil end
  return store.get("match:" .. tostring(track_id))
end

function store.save_matched_stream(track_id, stream_info)
  if not track_id or not stream_info then return end
  store.set("match:" .. tostring(track_id), stream_info)
end

return store
