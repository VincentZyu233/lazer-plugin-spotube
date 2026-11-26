# Lazer Spotube Music Plugin - Agent Instructions

## 项目定位与目标
本项目是针对 [Lazer](https://github.com/chuxuehaocai/Lazer) 音乐播放器（Flutter/Dart 原生客户端）开发的 **Spotube (Spotify) 第三方 Lua 扩展插件**（`community.spotube.music`）。
采用**混合数据流架构**：
- **元数据层**：依托 Spotify 官方 Pathfinder GraphQL 及公开 Embed 会话，提供海量全球榜单（Top 50 / Viral 50）、歌单、单曲与高清独立专辑封面。
- **媒体流层**：依托 YouTube InnerTube `VISIONOS` 客户端，免去 JS 播放器签名解密，高速直出高码率音频流（Partial Content HTTP 206）。
- **歌词层**：依托 LRCLIB 实时歌词服务，提供逐行同步歌词（`startMs`）。

插件以标准规范的 ZIP 格式打包分发，运行在 Lazer 宿主内置的独立受限 Lua 沙箱环境（基于 Dart 实现的 `lua_dardo_plus` 解释器）中。

---

## 宿主底层沙箱避坑红线 (Critical Lazer Sandbox Guidelines)

Lazer 宿主基于 Dart 的 `LuaPluginRuntime` 与 `lua_dardo_plus` 运行插件代码，存在以下**致命底层约束与黑盒缺陷**，所有开发者与 Agent 必须无条件严格遵守：

### 1. 全局标准库剥离（禁止访问 `os.*` / `io.*`）
* **宿主行为**：Lazer 在启动 VM 时执行 `lua.setGlobal(key)` 将 `'io', 'os', 'package', 'debug', 'dofile', 'loadfile', 'load', 'loadstring', 'require', 'print'` **全部置为了 `nil`**。
* **致命陷阱**：
  * 调用 `os.time()`、`os.date()` 或 `io.*` 会立即触发 `attempt to index a nil value` 崩溃。
  * 若使用 `local now = os.time and os.time() or 0`，`now` 将恒为 0，导致判断 `now < expire_time` 永久为 true，造成 Token 过期后永远不刷新并长期陷入 401 掉线！
* **规避准则**：
  * 获取当前时间戳**必须且只能使用 `host.now()` 或宿主注册的全局 `_now()`**（返回毫秒整数，等价于 `DateTime.now().millisecondsSinceEpoch`）。
  * 插件内计算缓存超时（TTL）统一采用毫秒时间差：`host.now() - at < ttl_ms`，或秒级时间差：`math.floor(host.now() / 1000)`。

### 2. Dart 解释器模式匹配缺陷（禁止使用 `%d`/`%s` 模式串）
* **解释器缺陷**：`lua_dardo_plus` 的 `string.match` 内部直接调用了 Dart 的 `RegExp(pattern).firstMatch(tail!)`，且**只返回 `group(0)`**。
* **致命陷阱**：
  * Lua 专属的字符类转义（如 `%d` 数字、`%s` 空格、`%w`、`%-`）在 Dart 正则表达式中被作为**普通字面量字符 `%` 和对应字母**处理，导致数字或空白匹配永远失败并返回 `nil`！
  * 多捕获组解构全部失效（只返回单个 `group(0)`，其余解构变量全为 `nil`）。
* **规避准则**：
  * **严禁在核心逻辑中依赖带有 Lua `%` 转义模式的 `string.match`**。
  * 数字与数值提取统一采用**纯字符字节流扫描**（`string.byte >= 48 and <= 57`）。
  * 字符串查找统一采用带 plain 标志的明文检索：`string.find(str, substr, 1, true)`。

### 3. Table 到 Dart 类型转换严格契约（List vs Map）
* **宿主转换规则**：
  * 仅当 Table 的键为**连续整数 `1..N`** 时，Dart 才会将其转换为 Dart `List`。
  * 空表 `{}` 会被解释器先转换为 Dart 空 `Map`（宿主 `_page` 会特判处理为空 List）。
  * **一旦 Table 包含非连续整数键或字符串键，Dart 立即将其转为 `Map`**。
* **致命陷阱**：在需要返回列表的方法（如 `favorites`, `playlistSongs`, `albumSongs`, `charts`, `playlists`）中，若把分页 Token、count 或 meta 信息混入同一个 Table 返回，宿主在执行 `raw is! List` 检查时会立即抛出 `MusicGatewayException(reason: 'invalid payload')`，导致界面整页报错。
* **规避准则**：
  * 列表分页方法**必须严格返回纯数组 Table**，禁止夹带任何非数字键属性。

### 4. 网络请求限制与域名白名单（`host.http`）
* **宿主限制**：
  * 单次 HTTP 请求超时由宿主硬编码为 **30 秒**。
  * 请求体与响应体限制：单次 body 超过 2MB 会被宿主抛出 `FormatException('Request too large')`。
  * 必须在 `manifest.json` 的 `network` 白名单中显式声明目标域名（如 `*.spotify.com`, `*.spotifycdn.com`, `*.googlevideo.com`, `*.youtube.com`, `lrclib.net`）。
  * 宿主强制剥离 `host`, `content-length`, `connection` 标头，不可自定义覆盖。
* **规避准则**：网络请求必须包裹在 `pcall` 中，并实现轻量超时熔断，失败时返回安全空数据，绝不阻塞调用队列。

### 5. 存储 1MB 物理天花板（`host.storage_set`）
* **宿主限制**：单个插件的 `storage.json` 总大小超过 1MB 时，宿主直接抛出 `FormatException('Storage full')`。
* **规避准则**：`host.storage_set` 仅用于持久化用户的 Token、Cookie、Session 及简单标记，**严禁将大批量歌曲列表或大型 JSON 写入 storage**。大列表缓存只能保存在 Lua 模块级局部变量中。

### 6. 并发与 Isolate 崩溃重启机制
* **宿主限制**：插件运行在独立 Isolate 的单线程事件循环中，后台调用（`scrobble`, `playStats`, `lyrics`, `song`）超时预算仅有 10 秒。一旦超时，宿主将强制终止并**重启整个 Lua VM**。
* **规避准则**：严禁死循环或阻塞式网络请求，异常需秒级退出并返回降级兜底。

---

## Spotube 专有核心规范与业务策略 (Spotube Specifics)

1. **免 TOTP 双轨鉴权与 Token 自愈机制**：
   - Spotify 旧版 TOTP 签名端点（`/api/token?reason=init`）已被官方全面下线拦截（HTTP 400）。
   - 鉴权采用从 `https://open.spotify.com/embed/playlist/...` 的 `__NEXT_DATA__` 中提取免 TOTP 的官方签发 Session AccessToken，并无缝继承 `sp_dc` 登录态 Cookie。
   - 在 GraphQL 搜索（`searchDesktop`）及 Web API 请求失败或鉴权失效时，必须执行强制刷新并自动重试一次（自愈闭环），彻底避免 1 小时 Token 过期后的长期静默失效。

2. **方案 A 独立单曲封面与原生占位契约**：
   - **歌单封面隔离原则**：在抓取榜单（如 Top 50）与歌单时，**单曲封面绝不可赋值为歌单大封面**（杜绝列表全是一模一样的 Top 50 封面）。若未提前命中独立封面缓存，一律下发 `cover = nil`，触发 Lazer 原生音符占位图标。
   - **方案 A 真实专辑原画按需提取**：
     - 通过 `open.spotify.com/embed/track/<pure_id>` 免鉴权直接抓取官方 `entity.visualIdentity.image`（官方 640×640 独立专辑原画）。
     - 在 `main.lua` 的 `song` 详情接口以及 `stream.resolve_stream` 播放开始时按需反查并落盘至本地元数据缓存，确保播放器底栏和播放列表无缝展示高清真实封面。

3. **YouTube InnerTube VisionOS 音频流通道**：
   - 音频直链解析对标 `lazer.youtube` 标准，采用 `CLIENT_VISIONOS`（Apple Vision Pro）模拟客户端：
     - 标头携带 `RealityDevice17,1`、`visitorData`、`X-Goog-Api-Format-Version: 2`。
     - 完全绕过 Google 播放器 JS 解密与 IP 风控挑战，直出高码率音频流。
     - 播放音频流必须支持 Partial Content HTTP 206 分片拉取，满足 Lazer 原生 `just_audio` / ExoPlayer 快速首帧播放与即时拖动。

4. **智能跨平台曲目匹配引擎**：
   - 提取 Spotify 单曲标题与艺术家，自动清洗版本噪声词（如 `feat.`、`Remaster`、`Official Video` 等）。
   - 采用时长距离加权（阈值 ±5 秒权重优先）与 Levenshtein 文本相似度加权匹配算法，精准过滤 YouTube 上的同名劣质短视频伴奏与现场录音。

5. **LRCLIB 同步歌词契约**：
   - 歌词行数据必须输出 `startMs` 毫秒字段（Lazer `MusicLyricLine` 强依赖）。
   - 返回结构必须严格包装为 `[ { synced = true, lines = ... } ]` 的纯数组形式，空歌词返回 `{}` 或 `[]`。
