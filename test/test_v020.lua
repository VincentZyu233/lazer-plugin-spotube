-- Mock Host 环境
local mock_storage = {}
_G.host = {
  storage = {
    get = function(k) return mock_storage[k] end,
    set = function(k, v) mock_storage[k] = v end
  },
  now = function() return os.time() * 1000 end,
  log = function(...) end
}

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format("[FAIL] %s: expected %s, got %s", msg or "", tostring(expected), tostring(actual)))
  end
end

print(">>> [Test 1] 验证 manifest.json 格式与 capabilities")
local f = io.open("manifest.json", "r")
assert(f, "manifest.json 必须存在")
local content = f:read("*a")
f:close()

assert(string.find(content, '"version": "0.2.0"'), "manifest 版本号应为 0.2.0")
assert(string.find(content, '"userPlaylists"'), "manifest 应包含 userPlaylists")
assert(string.find(content, '"artist"'), "manifest 应包含 artist")
assert(string.find(content, '"artistSongs"'), "manifest 应包含 artistSongs")
assert(string.find(content, '"artistAlbums"'), "manifest 应包含 artistAlbums")
print("  ✓ manifest 校验通过")

print(">>> [Test 2] 验证 main.lua describe 契约")
local plugin = require("main")
local desc = plugin.call("describe")
assert(desc and desc.providers and #desc.providers > 0, "describe 必须返回 providers")
local prov = desc.providers[1]
assert_eq(prov.id, "spotube", "provider id 必须为 spotube")

local caps_map = {}
for _, c in ipairs(prov.capabilities) do
  caps_map[c] = true
end
assert(caps_map["userPlaylists"], "capabilities 必须包含 userPlaylists")
assert(caps_map["artist"], "capabilities 必须包含 artist")
assert(caps_map["artistSongs"], "capabilities 必须包含 artistSongs")
assert(caps_map["artistAlbums"], "capabilities 必须包含 artistAlbums")
print("  ✓ describe 契约与 capabilities 校验通过")

print(">>> [Test 3] 验证 cache.lua 双层缓存与 VideoID 记忆系统")
local cache = require("spotube.core.cache")

-- 测试 3.1: 写入与 L1 读取
local test_stream = {
  url = "https://rr1---sn-test.googlevideo.com/videoplayback?id=test",
  bitRate = 160000,
  suffix = "m4a"
}
cache.set_stream("track_test_1", test_stream, "yt_vid_abc", 7200)

local hit_stream, hit_vid, tier = cache.get_stream("track_test_1")
assert(hit_stream ~= nil, "L1 必须命中")
assert_eq(hit_stream.url, test_stream.url, "L1 返回 URL 必须一致")
assert_eq(hit_vid, "yt_vid_abc", "L1 对应 video_id 必须一致")
assert_eq(tier, "L1", "命中层级应为 L1")

-- 测试 3.2: 模拟 L1 失效，测试 L2 回填
cache._l1["track_test_1"] = nil -- 清除 L1
local hit_stream_l2, hit_vid_l2, tier_l2 = cache.get_stream("track_test_1")
assert(hit_stream_l2 ~= nil, "L2 必须命中")
assert_eq(hit_vid_l2, "yt_vid_abc", "L2 对应 video_id 必须一致")
assert_eq(tier_l2, "L2", "命中层级应为 L2")
-- 此时 L1 应已被自动回填
local hit_stream_re_l1, _, tier_re_l1 = cache.get_stream("track_test_1")
assert_eq(tier_re_l1, "L1", "L2 命中后应自动回填至 L1")

-- 测试 3.3: TTL 过期测试
cache.set_stream("track_test_expired", test_stream, "vid_expired", -10) -- 过去10秒已过期
local exp_stream, _, _ = cache.get_stream("track_test_expired")
assert_eq(exp_stream, nil, "过期条目不应命中")

-- 测试 3.4: 永久记住 Video ID
local remembered_vid = cache.get_matched_vid("track_test_1")
assert_eq(remembered_vid, "yt_vid_abc", "VideoID 必须被持久化记忆")

-- 测试 3.5: invalidate 主动清理
cache.invalidate("track_test_1")
local after_invalid_stream = cache.get_stream("track_test_1")
assert_eq(after_invalid_stream, nil, "invalidate 后流缓存必须为空")
-- 但永久 VideoID 依然保留以备重新拉取
assert_eq(cache.get_matched_vid("track_test_1"), "yt_vid_abc", "invalidate 不应破坏 VideoID 记忆")

print("  ✓ cache 双层缓存与 VideoID 记忆系统全部测试通过")

print(">>> ALL v0.2.0 P0 FEATURE TESTS PASSED SUCCESSFULLY!")
