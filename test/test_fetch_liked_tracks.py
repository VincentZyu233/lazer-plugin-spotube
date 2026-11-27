"""
Fetch all actual Spotify Liked Tracks using the local user session (sp_dc).
Outputs full list to spotify_liked_tracks.md in the test directory.
"""

import asyncio
import json
import os
import sys
from datetime import datetime

# Include SpotAPI from adjacent repository
SPOTAPI_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../SpotAPI"))
if SPOTAPI_DIR not in sys.path:
    sys.path.insert(0, SPOTAPI_DIR)

from spotapi import AsyncClient, LikedTracks

# Set local proxy
os.environ["HTTP_PROXY"] = "http://127.0.0.1:7890"
os.environ["HTTPS_PROXY"] = "http://127.0.0.1:7890"

STORAGE_PATH = os.path.expandvars(
    r"%APPDATA%\dev.naominet.lazer\lua_plugin_data\community.spotube.music\storage.json"
)

async def main():
    if not os.path.exists(STORAGE_PATH):
        print(f"Error: storage.json not found at {STORAGE_PATH}")
        return

    with open(STORAGE_PATH, "r", encoding="utf-8") as f:
        storage = json.load(f)

    sp_dc = storage.get("sp_dc")
    if not sp_dc:
        print("Error: No sp_dc found in storage.json")
        return

    print(f"[*] Found sp_dc token (length: {len(sp_dc)})")
    print("[*] Connecting to Spotify Pathfinder API via SpotAPI...")

    async with await AsyncClient.from_cookies(f"sp_dc={sp_dc}") as client:
        liked_service = LikedTracks(client)
        print("[*] Fetching all pages of liked tracks...")
        all_tracks = []
        async for page in liked_service.pages(limit=50):
            for item in page:
                if item.track:
                    all_tracks.append(item)

        print(f"[+] Successfully fetched {len(all_tracks)} liked tracks from Spotify!")

        # Format into Markdown
        md_lines = [
            "# 🎵 Spotify 官方云端已赞歌曲列表 (实测验证报告)",
            "",
            f"> **验证时间**: `{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}`  ",
            f"> **登录用户凭据来源**: `{STORAGE_PATH}`  ",
            f"> **真实获取曲目总数**: **{len(all_tracks)} 首**  ",
            "",
            "---",
            "",
            "## 📋 歌曲详细清单",
            "",
            "| 序号 | 歌曲名称 | 艺术家 | 专辑 | 时长 | Spotify Track ID | 封面预览 |",
            "| :---: | :--- | :--- | :--- | :---: | :--- | :---: |"
        ]

        for idx, item in enumerate(all_tracks, start=1):
            t = item.track
            name = t.name.replace("|", "/")
            artist_names = []
            if t.artists and t.artists.items:
                for a in t.artists.items:
                    if a.profile and a.profile.name:
                        artist_names.append(a.profile.name)
            artists = ", ".join(artist_names) if artist_names else "Unknown"

            album_name = t.album_of_track.name.replace("|", "/") if t.album_of_track and t.album_of_track.name else "Unknown"
            dur_ms = t.duration.total_milliseconds if t.duration else 0
            mins = dur_ms // 60000
            secs = (dur_ms % 60000) // 1000
            dur_str = f"{mins:02d}:{secs:02d}"
            track_id = t.id or ""

            cover_url = ""
            if t.album_of_track and t.album_of_track.cover_art and t.album_of_track.cover_art.sources:
                cover_url = t.album_of_track.cover_art.sources[0].url

            img_tag = f'<img src="{cover_url}" width="48" height="48" style="border-radius:4px;" />' if cover_url else "-"
            md_lines.append(
                f"| {idx} | **{name}** | {artists} | *{album_name}* | {dur_str} | [`{track_id}`](https://open.spotify.com/track/{track_id}) | {img_tag} |"
            )

        output_md_path = os.path.join(os.path.dirname(__file__), "spotify_liked_tracks.md")
        with open(output_md_path, "w", encoding="utf-8") as f:
            f.write("\n".join(md_lines) + "\n")

        print(f"[+] Output written to: {output_md_path}")
        print("\n--- Track List ---")
        for idx, item in enumerate(all_tracks, start=1):
            t = item.track
            artist_names = [a.profile.name for a in t.artists.items if a.profile] if t.artists else []
            print(f"{idx}. {t.name} - {', '.join(artist_names)} (id: {t.id})")

if __name__ == "__main__":
    asyncio.run(main())
