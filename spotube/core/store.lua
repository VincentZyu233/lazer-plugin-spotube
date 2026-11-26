local store = {
  _cache = {}
}

function store.get(key)
  if store._cache[key] ~= nil then
    return store._cache[key]
  end
  if host and host.storage and host.storage.get then
    local ok, val = pcall(host.storage.get, key)
    if ok and val ~= nil then
      store._cache[key] = val
      return val
    end
  end
  return nil
end

function store.set(key, val)
  store._cache[key] = val
  if host and host.storage and host.storage.set then
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
