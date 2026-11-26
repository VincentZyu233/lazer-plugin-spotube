-- Spotify TOTP & Cryptographic Primitives (Compatible with all Lua sandbox dialects)
-- Completely eliminates bitwise operators (<<, >>, &, |, ~) for maximum compatibility with pure Dart Lua interpreters.
local crypto = {}

--- 纯算术模拟 32 位按位异或 (XOR)
local function bxor(a, b)
  a = math.floor(a or 0)
  b = math.floor(b or 0)
  local res = 0
  local bit = 1
  while a > 0 or b > 0 do
    local ra = a % 2
    local rb = b % 2
    if ra ~= rb then
      res = res + bit
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    bit = bit * 2
  end
  return res
end

--- 十六进制字符串转二进制字节串
local function hex_to_bin(hex)
  if not hex or type(hex) ~= "string" then return "" end
  local bytes = {}
  local len = string.len(hex)
  for i = 1, len, 2 do
    local b = tonumber(string.sub(hex, i, i + 1), 16) or 0
    table.insert(bytes, string.char(b))
  end
  return table.concat(bytes)
end

--- 二进制字节串转十六进制小写字符串
local function bin_to_hex(bin)
  if not bin or type(bin) ~= "string" then return "" end
  local out = {}
  local len = string.len(bin)
  for i = 1, len do
    local b = string.byte(bin, i)
    table.insert(out, string.format("%02x", b))
  end
  return table.concat(out)
end

--- 解码 Spotify TOTP 混淆密钥
function crypto.decode_secret(secret)
  if not secret then return "" end
  local res = {}
  local s_len = string.len(secret)
  for i = 1, s_len do
    local c = string.byte(secret, i)
    local x = ((i - 1) % 33) + 9
    table.insert(res, tostring(bxor(c, x)))
  end
  return table.concat(res)
end

--- SHA1 原生哈希计算 (优先调用宿主 host.crypto，输出原始 20 字节二进制)
function crypto.sha1_raw(msg)
  if not msg then return "" end
  if host and host.crypto then
    local ok, res = pcall(host.crypto, {
      operation = "sha1",
      input = tostring(msg),
      text = tostring(msg)
    })
    if ok and type(res) == "string" and string.len(res) == 40 then
      return hex_to_bin(res)
    end
  end
  return ""
end

--- HMAC-SHA1 原生计算 (优先调用宿主 host.crypto，输出原始 20 字节二进制)
function crypto.hmac_sha1(key, message)
  key = tostring(key or "")
  message = tostring(message or "")
  if host and host.crypto then
    local ok, res = pcall(host.crypto, {
      operation = "hmac",
      algorithm = "sha1",
      key = key,
      input = message,
      text = message
    })
    if ok and type(res) == "string" and string.len(res) == 40 then
      return hex_to_bin(res)
    end
  end
  return ""
end

--- 64 位大端打包 (Big-Endian 8-byte uint64)
local function pack_be64(val)
  local b = {}
  for i = 8, 1, -1 do
    b[i] = string.char(val % 256)
    val = math.floor(val / 256)
  end
  return table.concat(b)
end

--- 生成 Spotify 认证专用的 6 位动态 TOTP 凭据
function crypto.generate_totp(secret, timestamp, step, digits)
  step = step or 30
  digits = digits or 6
  local key = crypto.decode_secret(secret)
  local counter = math.floor((timestamp or 0) / step)
  local msg = pack_be64(counter)
  local digest = crypto.hmac_sha1(key, msg)

  if not digest or string.len(digest) < 20 then
    -- 兜底默认令牌防崩溃
    return "000000"
  end

  local offset = (string.byte(digest, 20) % 16)
  local b1 = (string.byte(digest, offset + 1) % 128)
  local b2 = string.byte(digest, offset + 2)
  local b3 = string.byte(digest, offset + 3)
  local b4 = string.byte(digest, offset + 4)

  -- 纯算术拼接 32 位大端整数 (等同于 (b1 << 24) | (b2 << 16) | (b3 << 8) | b4)
  local code = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
  local mod = 10 ^ digits
  return string.format("%0" .. tostring(digits) .. "d", code % mod)
end

return crypto
