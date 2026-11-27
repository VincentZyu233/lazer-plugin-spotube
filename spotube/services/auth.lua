local store = require("spotube.core.store")

local auth = {}

--- 获取当前登录会话
function auth.session(spotify)
  local sp_dc = store.get_fresh("sp_dc")
  if not sp_dc or sp_dc == "" or string.len(tostring(sp_dc)) < 10 then
    return nil
  end

  local cached_user = store.get_fresh("sp_user")
  if cached_user and (type(cached_user) == "table" or type(cached_user) == "userdata") and cached_user.id then
    return cached_user
  end

  if spotify and type(spotify.get_me) == "function" then
    local ok, me = pcall(spotify.get_me)
    if ok and me and me.id then
      store.set("sp_user", me)
      return me
    end
  end

  return nil
end

--- 按字节边界裁剪首尾空白 (兼容 Dart lua_dardo_plus 沙箱)
function auth.trim(value)
  if value == nil then return "" end
  local str = tostring(value)
  local first = 1
  local last = string.len(str)
  while first <= last and string.byte(str, first) <= 32 do first = first + 1 end
  while last >= first and string.byte(str, last) <= 32 do last = last - 1 end
  if last < first then return "" end
  return string.sub(str, first, last)
end

--- 通过 Cookie (sp_dc) 进行登录
function auth.login_cookie(cookie_str, spotify)
  local raw_str = auth.trim(tostring(cookie_str or ""))
  local lower = string.lower(raw_str)

  -- 支持快捷指令/占位符 (-1 / local / store / storage / 空)，自动重用本地已捕获凭据
  local is_local = (lower == "-1" or lower == "local" or lower == "store" or lower == "storage" or raw_str == "")
  if is_local then
    local saved = store.get_fresh("sp_dc")
    if saved and string.len(saved) > 0 then
      raw_str = saved
    else
      error("本地暂未捕获凭据，请运行 tools/get_cookie 或直接粘贴 sp_dc", 0)
    end
  end

  local sp_dc = nil
  if host and type(host.cookie_field) == "function" then
    local ok, field = pcall(host.cookie_field, raw_str, "sp_dc")
    if ok and field and string.len(field) > 0 then
      sp_dc = field
    end
  end

  if not sp_dc then
    local needle = "sp_dc="
    local start_idx = string.find(raw_str, needle, 1, true)
    if start_idx then
      local val_start = start_idx + string.len(needle)
      local end_idx = string.find(raw_str, ";", val_start, true)
      if end_idx then
        sp_dc = string.sub(raw_str, val_start, end_idx - 1)
      else
        sp_dc = string.sub(raw_str, val_start)
      end
    else
      sp_dc = raw_str
    end
  end

  sp_dc = auth.trim(sp_dc)

  if not sp_dc or string.len(sp_dc) < 10 then
    error("未能识别有效的 sp_dc 字段，请检查复制的内容", 0)
  end

  store.set("sp_dc", sp_dc)
  store.set("sp_access_token", nil)
  store.set("sp_token_exp", nil)

  -- 尝试拉取资料并刷新
  if spotify and type(spotify.get_me) == "function" then
    local ok, me = pcall(spotify.get_me)
    if ok and me and me.id then
      store.set("sp_user", me)
      return me
    end
  end

  local default_user = {
    id = "spotify_user",
    name = "Spotify 用户",
    avatarUrl = "",
    vip = false
  }
  store.set("sp_user", default_user)
  return default_user
end

--- 退出登录
function auth.logout()
  -- 彻底清空凭据与持久化存储
  store.set("sp_dc", nil)
  store.set("sp_access_token", nil)
  store.set("sp_token_exp", nil)
  store.set("sp_user", nil)
  if type(store.clear_cache) == "function" then
    store.clear_cache()
  end

  -- 重置待确认的授权会话
  pending_sessions = {}

  -- 关闭本地 TCP 监听
  if server_listening and host and type(host.socket_server) == "function" then
    pcall(function()
      host.socket_server({
        id = SOCKET_SERVER_ID,
        operation = "close"
      })
    end)
    server_listening = false
  end

  return true
end

local pending_sessions = {}
local SOCKET_SERVER_ID = "spotube_auth_server"
local SOCKET_HOST = "127.0.0.1"
local SOCKET_PORT = 28795
local server_listening = false

local function current_time_seconds()
  if host and type(host.now) == "function" then
    local ok, ms = pcall(host.now)
    if ok and type(ms) == "number" then
      return math.floor(ms / 1000)
    end
  end
  return 0
end

--- 获取扫码/网页登录 Key (Lazer 契约: qrKey)
function auth.qrKey()
  local now_s = current_time_seconds()
  local key = "SP_" .. tostring(now_s)
  if host and type(host.random_hex) == "function" then
    local ok, hex = pcall(host.random_hex, 4)
    if ok and hex then
      key = "SP_" .. tostring(hex)
    end
  end

  pending_sessions[key] = {
    start_time = now_s,
    expires_at = now_s + 300
  }

  -- 尝试拉起本地 TCP socket 监听服务，供 tools/get_cookie 自动回调通知
  if host and type(host.socket_server) == "function" and not server_listening then
    local ok, res = pcall(function()
      return host.socket_server({
        id = SOCKET_SERVER_ID,
        operation = "listen",
        host = SOCKET_HOST,
        port = SOCKET_PORT
      })
    end)
    if ok and res then
      server_listening = true
    end
  end

  return key
end

--- 获取扫码/网页登录授权 URL (Lazer 契约: qrUrl)
function auth.qrUrl(args)
  local key = tostring(args and args.key or "")
  local url = "https://accounts.spotify.com/zh-CN/login"

  if args and args.rich then
    return {
      url = url,
      actionUrl = url,
      hint = "登录后按 F12 复制 sp_dc 点击下方【使用 Cookie 登录】，或运行 node tools/get_cookie.js 自动秒登",
    }
  end

  return url
end

--- 轮询扫码/网页登录授权状态 (Lazer 契约: qrCheck)
-- 契约状态码：801=等待授权确认, 802=已扫描/处理中, 803=登录成功, 800=会话过期或失效
function auth.qrCheck(args, spotify)
  local key = tostring(args and args.key or "")
  local sess = pending_sessions[key]
  local now_s = current_time_seconds()

  if sess and now_s > sess.expires_at then
    pending_sessions[key] = nil
    return 800
  end

  -- 1. 检查本地 TCP 监听是否接收到来自 tools/get_cookie 或浏览器的凭据推送
  if server_listening and host and type(host.socket_server) == "function" then
    local ok_acc, client = pcall(function()
      return host.socket_server({
        id = SOCKET_SERVER_ID,
        operation = "accept",
        timeout = 20
      })
    end)
    if ok_acc and client and type(client) == "table" and client.id then
      local ok_recv, raw_data = pcall(function()
        return host.socket_server({
          id = SOCKET_SERVER_ID,
          operation = "receive",
          clientId = client.id,
          timeout = 500,
          format = "utf8"
        })
      end)
      pcall(function()
        host.socket_server({
          id = SOCKET_SERVER_ID,
          operation = "close_client",
          clientId = client.id
        })
      end)

      if ok_recv and raw_data and type(raw_data) == "string" and string.len(raw_data) > 0 then
        local extracted_dc = nil
        local parse_ok, payload = pcall(host.json_decode, raw_data)
        if parse_ok and type(payload) == "table" and payload.sp_dc then
          extracted_dc = tostring(payload.sp_dc)
        elseif string.find(raw_data, "sp_dc", 1, true) then
          extracted_dc = raw_data
        end

        if extracted_dc then
          local login_ok, user = pcall(auth.login_cookie, extracted_dc, spotify)
          if login_ok and user and user.id then
            pending_sessions[key] = nil
            pcall(function()
              host.socket_server({
                id = SOCKET_SERVER_ID,
                operation = "close"
              })
            end)
            server_listening = false
            return 803
          end
        end
      end
    end
  end

  -- 2. 检查 store 存储中是否已有有效会话 (如外部脚本已注入或热更新)
  local sp_dc = store.get_fresh("sp_dc")
  if sp_dc and string.len(tostring(sp_dc)) > 10 then
    local user = auth.session(spotify)
    if user and user.id then
      pending_sessions[key] = nil
      return 803
    end
  end

  return 801
end

return auth
