# 📦 Spotube 音乐插件更新日志 (CHANGELOG)

本文件记录了 `community.spotube.music`（Spotube 音乐网关插件）的所有关键版本演进、核心特性增加、架构演进与底层缺陷修复。

---

## 🚀 v0.1.4 (2026-11-27) - 会话注销机制修复与文档图片重构

### 🐛 缺陷修复与认证增强
- **彻底根治退出登录失效与假用户残留**：
  - 剔除 `spotube/services/auth.lua` 中在缺少凭据或网络异常时兜底回退的静态虚拟用户（`fallback_user = "VincentZyu"`），未登录或 `sp_dc` 凭据缺失时严格返回 `nil`，消除登出后左下角仍显示已登录的假状态。
  - 完善 `auth.logout()` 注销实现：同步清空 `sp_dc`、`sp_access_token`、`sp_token_exp` 和 `sp_user` 本地持久化凭据，主动调用 `store.clear_cache()` 彻底清理各层内存缓存，重置待处理会话通道，并主动切断本地自动登录监听服务（`127.0.0.1:28795`），确保退出登录彻底干净。

### 🎨 文档体验与排版重构
- **实测预览图层级重组与直列排版**：
  - 将所有实测高清截图集中归档至 `docs/images/preview/` 目录，移除双列压缩表格排版，改为自上而下的纵向平铺展示，呈现沉浸式视觉预览。
- **新增 Chrome 开发者工具 Cookie 提取全流程图文指引**：
  - 新增 `docs/images/tutorial/chrome_sp_dc.png` 实操截图，详尽阐述如何在现代浏览器（Chrome/Edge）的 Application -> Cookies 面板中秒级提取 `sp_dc` 并粘贴登录。
- **Mermaid 架构流程图渲染修复**：
  - 修正 README 中 Mermaid 流程图的边属性语法，为连线标注增加严格双引号包裹，消除不同 Markdown 解析器因空格和中文导致的 `got 'PS'` 语法报错。

---

## 🚀 v0.1.2 (2026-11-27) - Spotify 云端我喜欢的音乐 (Pathfinder GraphQL) 接入

### ✨ 重大功能特性
- **「我喜欢」云端红心曲库实时双向同步（Favorites / Liked Songs）**：
  - 深度逆向对接 Spotify 内部 Pathfinder GraphQL 协议（`fetchLibraryTracks` 端点与 clientToken 机制），实现与个人 Spotify 账号云端红心曲库的无感双向同步。
  - 自动提纯并精确解析音轨时长（`trackDuration.totalMilliseconds`）、多位艺人列表及高清封面图，并动态挂载内部 `_uri` 标识。
- **红心收藏与取消收藏契约打通（`setFavorite`）**：
  - 完整实现 Lazer 底栏与播放详情页的收藏契约，点击红心秒级向 Spotify 云端下发收藏/取消指令，曲库即时联动。

---

## 🚀 v0.1.1 (2026-11-27) - 专辑详情、歌手头像与首页推荐货架重构

### ✨ 体验优化与特性补充
- **专辑详情与整张试听（Album Details & Tracks）**：
  - 完整接入 `albumDetails` 与 `albumSongs` 契约，支持提取唱片发行年份、唱片制作公司版权信息与全盘音轨清单。
- **歌手圆形头像提取修复**：
  - 优化歌手卡片与头像提取逻辑，过滤默认占位符，支持高清歌手肖像渲染。
- **主页推荐展架结构优化**：
  - 规范化主页编辑精选与热门榜单分类货架，自适应渲染多语言榜单卡片。

---

## 🎉 v0.1.0 (2026-11-26) - 初始版本：双轨互补架构与无缝播放

### ✨ 核心功能
- **双源混合架构（Spotube = Spotify + YouTube）**：
  - 对标开源项目 Spotube，将 Spotify 官方权威元数据与 YouTube 纯净音频流无缝融合，免登录畅享全球公共曲库、算法歌单与官方榜单。
- **原生置信度智能转接（Confidence Matcher）**：
  - 严谨的标题词归一化、歌手交叉验证与 $\le 10s$ 录音室原版时长容差比对，优先挂接 YouTube 官方 "- Topic" 纯音频音轨，消除 MV 杂音。
- **LRCLIB 毫秒级逐行滚动歌词**：
  - 对接公开免鉴权同步歌词源，呈现毫秒级精准高亮与流光背景。
- **双重登录体验与自动化配套工具**：
  - 原生网页授权唤起与 Cookie 快捷导入；配套提供纯原生 Node.js 自动化助手（`tools/get_cookie.js`），支持 CDP 抓取并通过本地 Socket 自动秒登。
- **轻量独立**：纯 Lua 实现，免外部重型动态依赖，打包体积仅数十 KB。
