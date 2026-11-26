-- Spotify TOTP & Cryptographic Primitives (RFC 3174 SHA1 + RFC 2104 HMAC)
local crypto = {}

local function rol(val, n)
  return ((val << n) | (val >> (32 - n))) & 4294967295
end

function crypto.sha1_raw(msg)
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
  local function to_be(h)
    return string.char((h >> 24) & 255, (h >> 16) & 255, (h >> 8) & 255, h & 255)
  end
  return to_be(h0) .. to_be(h1) .. to_be(h2) .. to_be(h3) .. to_be(h4)
end

function crypto.hmac_sha1(key, message)
  local k_len = string.len(key)
  if k_len > 64 then
    key = crypto.sha1_raw(key)
    k_len = string.len(key)
  end
  if k_len < 64 then
    key = key .. string.rep("\0", 64 - k_len)
  end
  local o_key_pad = {}
  local i_key_pad = {}
  for i = 1, 64 do
    local b = string.byte(key, i)
    o_key_pad[i] = string.char(b ~ 92)
    i_key_pad[i] = string.char(b ~ 54)
  end
  local inner = crypto.sha1_raw(table.concat(i_key_pad) .. message)
  return crypto.sha1_raw(table.concat(o_key_pad) .. inner)
end

function crypto.decode_secret(secret)
  local res = {}
  local s_len = string.len(secret)
  for i = 1, s_len do
    local c = string.byte(secret, i)
    local x = ((i - 1) % 33) + 9
    table.insert(res, tostring(c ~ x))
  end
  return table.concat(res)
end

local function pack_be64(val)
  local b = {}
  for i = 8, 1, -1 do
    b[i] = string.char(val % 256)
    val = math.floor(val / 256)
  end
  return table.concat(b)
end

--- 生成 Spotify 认证专用的 6 位 TOTP
function crypto.generate_totp(secret, timestamp, step, digits)
  step = step or 30
  digits = digits or 6
  local key = crypto.decode_secret(secret)
  local counter = math.floor(timestamp / step)
  local msg = pack_be64(counter)
  local digest = crypto.hmac_sha1(key, msg)
  local offset = string.byte(digest, 20) & 15
  local b1 = string.byte(digest, offset + 1) & 127
  local b2 = string.byte(digest, offset + 2)
  local b3 = string.byte(digest, offset + 3)
  local b4 = string.byte(digest, offset + 4)
  local code = (b1 << 24) | (b2 << 16) | (b3 << 8) | b4
  local mod = 10 ^ digits
  return string.format("%0" .. tostring(digits) .. "d", code % mod)
end

return crypto
