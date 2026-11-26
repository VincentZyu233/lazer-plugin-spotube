local constants = require("spotube.core.constants")

local http = {}

--- 快速判断字符串是否为合法的 JSON 起始 (避免将 HTML 传给 host.json_decode 导致 Dart 抛出 FormatException)
local function is_json_string(str)
  if not str or type(str) ~= "string" or string.len(str) == 0 then
    return false
  end
  for i = 1, math.min(string.len(str), 64) do
    local b = string.byte(str, i)
    if b > 32 then
      return b == 123 or b == 91 -- '{' (123) 或 '[' (91)
    end
  end
  return false
end

local function json_decode(str)
  if not str or not is_json_string(str) then
    return nil
  end
  if host and host.json_decode then
    local ok, res = pcall(host.json_decode, str)
    if ok then return res end
  end
  return nil
end

local function json_encode(tbl)
  if not tbl then return "{}" end
  if host and host.json_encode then
    local ok, res = pcall(host.json_encode, tbl)
    if ok then return res end
  end
  return "{}"
end

function http.json_decode(str)
  return json_decode(str)
end

function http.json_encode(tbl)
  return json_encode(tbl)
end

function http.request(method, url, headers, body)
  if not host or not host.http then
    return nil, "host.http is unavailable"
  end

  local req_headers = headers or {}
  if not req_headers["User-Agent"] then
    req_headers["User-Agent"] = constants.USER_AGENT_DESKTOP
  end

  local req_body = body
  if type(body) == "table" then
    req_body = json_encode(body)
    if not req_headers["Content-Type"] then
      req_headers["Content-Type"] = "application/json"
    end
  end

  local ok, res = pcall(host.http, {
    method = method or "GET",
    url = url,
    headers = req_headers,
    body = req_body
  })

  if not ok then
    return nil, "HTTP dispatch failed: " .. tostring(res)
  end

  if not res then
    return nil, "No response from host.http"
  end

  local status = res.status or res.statusCode or 200
  if status >= 400 then
    return nil, "HTTP error " .. tostring(status) .. ": " .. tostring(res.body)
  end

  if is_json_string(res.body) then
    local parsed = json_decode(res.body)
    if parsed ~= nil then
      return parsed
    end
  end

  return res.body
end

function http.get(url, headers)
  return http.request("GET", url, headers, nil)
end

function http.post(url, body, headers)
  return http.request("POST", url, headers, body)
end

return http
