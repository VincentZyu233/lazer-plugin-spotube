# 🎵 Lazer Spotube Plugin (Spotify 曲库插件)

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg?style=flat-square)](LICENSE)
[![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-brightgreen.svg?style=flat-square)](manifest.json)
[![Lazer: 2.0.210+](https://img.shields.io/badge/Lazer-2.0.210+-orange.svg?style=flat-square)](https://github.com/chuxuehaocai/Lazer)

专为 [**Lazer**](https://github.com/chuxuehaocai/Lazer) 现代跨平台音乐播放器打造的 **Spotube (Spotify) 混合架构扩展插件**。

无需注册或登录 Spotify 账号、无需购买 Premium 会员，直接将 **Spotify 全球公共曲库、官方榜单与算法精选歌单** 无缝融入 Lazer！

---

## ✨ 特性亮点

- **全球公共曲库全域检索**：
  - 深度逆向 Spotify 官方公开 Web 端点，支持单曲、艺人、专辑、公共歌单全域检索。
  - **歌单链接直接秒开**：支持在 Lazer 搜索框直接粘贴任意公开 Spotify 歌单链接（`open.spotify.com/playlist/...`）一键载入整张歌单。
- **免登录即开即用（Zero Account Burden）**：
  - 前端元数据走 Spotify 匿名访客通道，免 Cookie、免 Key、免注册。
  - 后端音频流走移动端访客流调度，免 Google 账号登录。
- **Spotube 原生置信度智能转接（Confidence Matcher）**：
  - 核心算法严格对齐 [team-spotube/spotube](https://github.com/team-spotube/spotube) 官方 `RealNewPipeAudioAPI` 实现。
  - 结合**核心标题归一化、艺人交叉比对、$\le 10s$ 录音室原版时长容差**以及 **YouTube 官方 "- Topic" 纯音频频道优先** 规则进行多重加权打分，精准消除 MV 杂音与翻唱干扰。
- **免 DRM 高保真直链流（Anti-Throttling Stream）**：
  - 智能调度未加密的 128kbps AAC / Opus 裸音频流，无需复杂的 Widevine 解密模块，保持插件仅 **数十 KB** 的极简轻量包体。
- **精准毫秒级同步歌词**：
  - 深度对接公开免鉴权同步歌词源（LRCLib），毫秒级逐行滚动，完美呈现 Lazer 流光高亮背景。

---

## 🛠 架构原理解析 (Architecture)

本插件借鉴了开源顶流播放器 **Spotube** 的经典设计，采用双轨互补分层架构：

```mermaid
flowchart LR
    subgraph UI["Lazer 宿主交互"]
        Search["全域搜索 / 粘贴歌单链接"]
        Cards["官方榜单 / 推荐歌单广场"]
        Player["原生播放引擎"]
    end

    subgraph SpotubePlugin["lazer-plugin-spotube 核心层"]
        Meta["Spotify 公开端点 (SpotAPI)<br/>获取优质元数据与专辑封面"]
        Matcher["Spotube 置信度打分算法<br/>(时长容差 + 官方 Topic 频道加权)"]
        Streamer["InnerTube 直链流调度器<br/>(免 DRM 裸流提取)"]
        Lyrics["LRCLib 逐行同步歌词"]
    end

    Search --> Meta
    Cards --> Meta
    Meta --> UI

    Player -->|resolve(song)| Matcher
    Matcher --> Streamer
    Streamer -->|128k AAC/Opus 裸流| Player
```

---

## 📦 安装与使用指南

### 方式一：Release ZIP 导入（推荐）

1. 从本仓库的 [Releases](../../releases) 下载最新的 `community.spotube.music.zip`。
2. 打开 **Lazer** → **设置** → **插件管理** → **导入 ZIP 插件**，选择下载的压缩包。
3. 列表出现「Spotube」并处于启用状态即可。
4. 在播放器音源切换列表选择 **Spotube** 即可畅游全球曲库。

### 方式二：本地构建

```bash
node tools/build.js
```
产物将自动输出至 `dist/community.spotube.music.zip`，并生成对应的 SHA-256 哈希值。

---

## 📄 开源许可证

本项目基于 **[GNU Affero General Public License v3.0 (AGPL-3.0)](LICENSE)** 协议开源，与 [Lazer](https://github.com/chuxuehaocai/Lazer) 宿主本体及 [Spotube](https://github.com/team-spotube/spotube) 生态完全对齐。
