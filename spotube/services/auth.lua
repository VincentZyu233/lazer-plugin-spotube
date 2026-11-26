local store = require("spotube.core.store")

local auth = {}

--- 获取当前登录会话
function auth.session(spotify)
  local sp_dc = store.get("sp_dc")
  if not sp_dc or sp_dc == "" then
    return nil
  end

  local cached_user = store.get("sp_user")
  if cached_user and type(cached_user) == "table" and cached_user.id then
    return cached_user
  end

  local me = spotify.get_me()
  if me and me.id then
    local avatar = ""
    if me.images and #me.images > 0 and me.images[1].url then
      avatar = me.images[1].url
    end
    local user = {
      id = me.id,
      name = me.display_name or me.id,
      avatarUrl = avatar,
      vip = (me.product == "premium")
    }
    store.set("sp_user", user)
    return user
  end

  -- 会话过期或无效
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
  if not cookie_str or string.len(cookie_str) == 0 then
    error("Cookie 不能为空", 0)
  end

  local sp_dc = nil
  if host and type(host.cookie_field) == "function" then
    local ok, field = pcall(host.cookie_field, cookie_str, "sp_dc")
    if ok and field and string.len(field) > 0 then
      sp_dc = field
    end
  end

  if not sp_dc then
    local needle = "sp_dc="
    local start_idx = string.find(cookie_str, needle, 1, true)
    if start_idx then
      local val_start = start_idx + string.len(needle)
      local end_idx = string.find(cookie_str, ";", val_start, true)
      if end_idx then
        sp_dc = string.sub(cookie_str, val_start, end_idx - 1)
      else
        sp_dc = string.sub(cookie_str, val_start)
      end
    else
      sp_dc = cookie_str
    end
  end

  sp_dc = auth.trim(sp_dc)

  if not sp_dc or string.len(sp_dc) < 10 then
    error("未能识别有效的 sp_dc 字段，请检查复制的 Cookie 内容", 0)
  end

  store.set("sp_dc", sp_dc)
  store.set("sp_access_token", nil)
  store.set("sp_token_exp", nil)
  store.set("sp_user", nil)

  -- 强制拉取 Token 并验证身份
  local me = spotify.get_me()
  if not me or not me.id then
    store.set("sp_dc", nil)
    error("Spotify 凭据验证失败，可能 sp_dc 已过期或无效，请重新登录 Spotify 网页复制", 0)
  end

  local avatar = ""
  if me.images and #me.images > 0 and me.images[1].url then
    avatar = me.images[1].url
  end

  local user = {
    id = me.id,
    name = me.display_name or me.id,
    avatarUrl = avatar,
    vip = (me.product == "premium")
  }
  store.set("sp_user", user)
  return user
end

--- 退出登录
function auth.logout()
  store.set("sp_dc", nil)
  store.set("sp_access_token", nil)
  store.set("sp_token_exp", nil)
  store.set("sp_user", nil)
  return true
end

return auth
