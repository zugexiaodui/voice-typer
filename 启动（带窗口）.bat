@echo off
chcp 65001 >nul
setlocal
title voice-typer

cls
echo.
echo   ==========================================================
echo    voice-typer   全局语音输入（本地识别，音频不出本机）
echo   ==========================================================
echo.
echo    本窗口必须保持打开（可最小化，不要关闭）
echo.
echo    录音      按 settings.json 里配置的快捷键
echo    设置      在右下角托盘图标上点一下
echo    退出      托盘图标右键 - 退出，或按 Ctrl+C
echo.
echo   ----------------------------------------------------------
echo    正在加载识别模型，约 2 秒...
echo   ----------------------------------------------------------
echo.

pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0voice-typer.ps1" %*
set RC=%ERRORLEVEL%

rem ── 程序退出后本窗口要跟着关掉 ──
rem 以前这里是无条件 pause，所以点了「退出」之后窗口还会一直等着按键，
rem 必须手动关。现在只有启动失败才停一下（20 秒后自动关），正常退出直接关窗。
if not "%RC%"=="0" (
  echo.
  echo   ----------------------------------------------------------
  echo    [启动失败]  退出码 = %RC%
  echo    错误日志: %TEMP%\voice-typer-error.log
  echo   ----------------------------------------------------------
  echo.
  echo    本窗口 20 秒后自动关闭...
  timeout /t 20 >nul 2>nul
)
endlocal
