local constants = require("spotube.core.constants")

local http = {}

local function json_decode(str)
  if not str or type(str) ~= "string" or string.len(str) == 0 then
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

  local parsed_json = json_decode(res.body)
  return parsed_json or res.body
end

function http.get(url, headers)
  return http.request("GET", url, headers, nil)
end

function http.post(url, body, headers)
  return http.request("POST", url, headers, body)
end

return http
