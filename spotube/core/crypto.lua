-- Spotify TOTP & Cryptographic Primitives
-- Fully compliant with Dart lua_dardo_plus sandbox and Lua 5.3+ standards
local crypto = {}

--- 32 位循环左移
local function rol(val, n)
  return (((val << n) | (val >> (32 - n))) & 4294967295)
end

--- 纯 Lua 实现的标准 SHA-1 哈希算法
-- 彻底避开 0x 十六进制字面量与字符串 # 运算符，兼容 Dart lua_dardo_plus
function crypto.sha1_hex(msg)
  if not msg then return "" end
  msg = tostring(msg)

  local msg_len = string.len(msg)
  local bytes = {}
  for i = 1, msg_len do
    bytes[i] = string.byte(msg, i)
  end

  local len = #bytes
  local bit_len = len * 8

  bytes[#bytes + 1] = 128
  while (#bytes % 64) ~= 56 do
    bytes[#bytes + 1] = 0
  end

  for i = 7, 0, -1 do
    bytes[#bytes + 1] = ((bit_len >> (i * 8)) & 255)
  end

  local h0 = 1732584193
  local h1 = 4023233417
  local h2 = 2562383102
  local h3 = 271733878
  local h4 = 3285377520

  local num_chunks = math.floor(#bytes / 64)
  for chunk = 0, num_chunks - 1 do
    local offset = chunk * 64
    local w = {}
    for i = 0, 15 do
      local idx = offset + i * 4
      w[i] = (bytes[idx + 1] << 24) | (bytes[idx + 2] << 16) | (bytes[idx + 3] << 8) | bytes[idx + 4]
    end

    for i = 16, 79 do
      w[i] = rol(w[i - 3] ~ w[i - 8] ~ w[i - 14] ~ w[i - 16], 1)
    end

    local a, b, c, d, e = h0, h1, h2, h3, h4

    for i = 0, 79 do
      local f, k
      if i <= 19 then
        f = (b & c) | ((~b) & d)
        k = 1518500249
      elseif i <= 39 then
        f = b ~ c ~ d
        k = 1859775393
      elseif i <= 59 then
        f = (b & c) | (b & d) | (c & d)
        k = 2400959708
      else
        f = b ~ c ~ d
        k = 3395469782
      end

      local temp = (rol(a, 5) + f + e + k + w[i]) & 4294967295
      e = d
      d = c
      c = rol(b, 30)
      b = a
      a = temp
    end

    h0 = (h0 + a) & 4294967295
    h1 = (h1 + b) & 4294967295
    h2 = (h2 + c) & 4294967295
    h3 = (h3 + d) & 4294967295
    h4 = (h4 + e) & 4294967295
  end

  return string.format("%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4)
end

--- 十六进制字符串转二进制字节串
function crypto.hex_to_bin(hex)
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
function crypto.bin_to_hex(bin)
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
    table.insert(res, tostring(c ~ x))
  end
  return table.concat(res)
end

--- HMAC-SHA1 计算 (输出原始 20 字节二进制串)
function crypto.hmac_sha1(key, msg)
  key = tostring(key or "")
  msg = tostring(msg or "")

  -- 优先尝试宿主原生 crypto 能力
  if host and host.crypto then
    local ok, res = pcall(host.crypto, {
      operation = "hmac",
      algorithm = "sha1",
      key = key,
      input = msg,
      text = msg
    })
    if ok and type(res) == "string" and string.len(res) == 40 then
      return crypto.hex_to_bin(res)
    end
  end

  -- 纯 Lua 高可靠回退 (RFC 2104)
  if string.len(key) > 64 then
    key = crypto.hex_to_bin(crypto.sha1_hex(key))
  end

  local k_ipad = {}
  local k_opad = {}
  for i = 1, 64 do
    local b = 0
    if i <= string.len(key) then
      b = string.byte(key, i)
    end
    k_ipad[i] = string.char(b ~ 54)  -- 0x36 = 54
    k_opad[i] = string.char(b ~ 92)  -- 0x5c = 92
  end

  local inner = table.concat(k_ipad) .. msg
  local inner_hash = crypto.hex_to_bin(crypto.sha1_hex(inner))
  local outer = table.concat(k_opad) .. inner_hash
  return crypto.hex_to_bin(crypto.sha1_hex(outer))
end

--- 生成 Spotify 认证专用的 6 位动态 TOTP 凭据
function crypto.generate_totp(secret, timestamp, step, digits)
  step = step or 30
  digits = digits or 6
  local key = crypto.decode_secret(secret)
  local counter = math.floor((timestamp or 0) / step)

  local b = {}
  local val = counter
  for i = 8, 1, -1 do
    b[i] = string.char(val % 256)
    val = math.floor(val / 256)
  end
  local msg = table.concat(b)

  local digest = crypto.hmac_sha1(key, msg)
  if not digest or string.len(digest) < 20 then
    return "000000"
  end

  local offset = (string.byte(digest, 20) & 15)
  local b1 = (string.byte(digest, offset + 1) & 127)
  local b2 = string.byte(digest, offset + 2)
  local b3 = string.byte(digest, offset + 3)
  local b4 = string.byte(digest, offset + 4)

  local code = (b1 << 24) | (b2 << 16) | (b3 << 8) | b4
  local mod = 10 ^ digits
  return string.format("%0" .. tostring(digits) .. "d", code % mod)
end

return crypto

