# 🎵 Lazer Spotube Plugin (Spotify 曲库插件)

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg?style=flat-square)](LICENSE)
[![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-brightgreen.svg?style=flat-square)](manifest.json)
[![Lazer: 2.0.210+](https://img.shields.io/badge/Lazer-2.0.210+-orange.svg?style=flat-square)](https://github.com/chuxuehaocai/Lazer)

专为 [**Lazer**](https://github.com/chuxuehaocai/Lazer) 现代跨平台音乐播放器打造的 **Spotube (Spotify) 混合架构扩展插件**。

支持免登录访客体验，更深度支持**浏览器联动登录**与**全自动凭据注入工具**，直接将 **Spotify 全球曲库、官方榜单、个人歌单与算法精选** 无缝融入 Lazer！

---

## ✨ 特性亮点

- **浏览器一键联动登录（Dual-Mode Auth）**：
  - **原生网页/扫码授权**：在 Lazer 登录弹窗中点击【在浏览器中打开授权页】直接唤起系统默认浏览器登录 Spotify。
  - **全自动凭据抓取与实时注入（tools/get_cookie.js）**：配套提供跨平台纯原生 Node.js 自动化助手，运行即可拉起浏览器窗口完成登录，通过 CDP 协议自动提取 `sp_dc` 凭据，通过本地 Socket (`127.0.0.1:28795`) 实时通知 Lazer 客户端秒速完成登录并自动关闭弹窗！
  - **传统 Cookie 模式**：亦可直接在 Cookie 标签页粘贴 `sp_dc` 的值完成快速鉴权。
- **全球公共曲库全域检索**：
  - 深度逆向 Spotify 官方端点，支持单曲、艺人、专辑、公共歌单全域检索。
  - **歌单链接直接秒开**：支持在 Lazer 搜索框直接粘贴任意公开 Spotify 歌单链接（`open.spotify.com/playlist/...`）一键载入整张歌单。
- **Spotube 原生置信度智能转接（Confidence Matcher）**：
  - 核心算法严格对齐 [team-spotube/spotube](https://github.com/team-spotube/spotube) 官方实现。
  - 结合**核心标题归一化、艺人交叉比对、$\le 10s$ 录音室原版时长容差**以及 **YouTube 官方 "- Topic" 纯音频频道优先** 规则进行多重加权打分，精准消除 MV 杂音与翻唱干扰。
- **免 DRM 高保真直链流（Anti-Throttling Stream）**：
  - 智能调度未加密的 128kbps AAC / Opus 裸音频流，无需复杂的 Widevine 解密模块，保持插件仅 **数十 KB** 的极简轻量包体。
- **精准毫秒级同步歌词**：
  - 深度对接公开免鉴权同步歌词源（LRCLib），毫秒级逐行滚动，完美呈现 Lazer 流光高亮背景。

---

## 🔐 登录体验与配套工具 (Authentication)

Spotify 采用严格的 HttpOnly Cookie (`sp_dc`) 进行 Web 播放鉴权。本插件提供两种极简的登录体验：

### 方案 A：Lazer 客户端原生浏览器授权联动
1. 在 Lazer 左侧进入 **登录** → 音乐平台选择 **Spotube**；
2. 弹窗内会展示登录二维码以及【在浏览器中打开授权页】按钮；
3. 点击按钮在浏览器中登录 Spotify；配合 `tools/get_cookie.js` 助手，插件会在检测到凭据后自动完成登录交接并关闭弹窗！

### 方案 B：一键助手自动注入 (默认推荐)
1. 进入插件目录下的 `tools/` 文件夹；
2. 在终端或控制台直接运行：
   ```bash
   node tools/get_cookie.js
   ```
3. 脚本会自动拉起独立的浏览器窗口引导登录；登录成功后，脚本会自动提取 `sp_dc`、解析用户身份、注入到 Lazer 插件存储，并通知 Lazer 客户端自动完成登录！

---

## 🛠 架构原理解析 (Architecture)

本插件借鉴了开源播放器 **Spotube** 的经典设计，采用双轨互补分层架构：

```mermaid
flowchart LR
    subgraph UI["Lazer 宿主交互"]
        Search["全域搜索 / 粘贴歌单链接"]
        Cards["官方榜单 / 推荐歌单广场"]
        Player["原生播放引擎"]
        AuthModal["原生登录弹窗<br/>(扫码/浏览器授权/Cookie)"]
    end

    subgraph SpotubePlugin["lazer-plugin-spotube 核心层"]
        Meta["Spotify 官方端点<br/>(sp_dc 登录态 / TOTP 动态签名)"]
        Matcher["Spotube 置信度打分算法<br/>(时长容差 + 官方 Topic 频道加权)"]
        Streamer["InnerTube 直链流调度器<br/>(免 DRM 裸流提取)"]
        Lyrics["LRCLib 逐行同步歌词"]
        AuthServer["本地 Socket 服务<br/>(127.0.0.1:28795 登录态握手)"]
    end

    subgraph Tools["配套桌面工具"]
        GetCookie["tools/get_cookie.js<br/>CDP 浏览器凭据自动监听"]
    end

    Search --> Meta
    Cards --> Meta
    Meta --> UI

    Player -->|resolve(song)| Matcher
    Matcher --> Streamer
    Streamer -->|128k AAC/Opus 裸流| Player

    AuthModal <-->|本地 Socket 握手| AuthServer
    GetCookie -->|CDP 监听捕获| AuthServer
```

---

## 📦 安装与构建指南

### 本地构建与打包

```bash
node tools/build.js
```
产物将自动输出至 `dist/community.spotube.music.zip`，并生成对应的 SHA-256 哈希值。

---

## 📄 开源许可证

本项目基于 **[GNU Affero General Public License v3.0 (AGPL-3.0)](LICENSE)** 协议开源，与 [Lazer](https://github.com/chuxuehaocai/Lazer) 宿主本体及 [Spotube](https://github.com/team-spotube/spotube) 生态完全对齐。
