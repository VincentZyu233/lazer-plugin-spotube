@echo off
chcp 65001 >nul
title Spotube (Spotify) Login Helper
echo ======================================================================
echo   Spotube (Spotify) Lazer 凭据自动获取与注入助手
echo ======================================================================
echo.
echo 正在拉起独立浏览器窗口引导登录 Spotify...
echo.
node "%~dp0get_cookie.js" %*
echo.
pause
