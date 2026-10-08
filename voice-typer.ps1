#Requires -Version 7.0
<#
  voice-typer — Windows 全局语音输入
  ══════════════════════════════════════════════════════════════
  在任意程序里按快捷键说话，本地 SenseVoice 识别后自动粘贴到光标处。
  音频完全不出本机。快捷键可在托盘「设置」里自定义。

  命令行参数（都可省略，会与 settings.json 合并）：
    -ShowSettings   启动后直接打开设置窗口
    -NoPaste        只显示识别结果，不自动粘贴
    -Test           自检后退出
    -HotkeyTest     只测试热键，8 秒后退出
#>
[CmdletBinding()]
param(
  [switch]$ShowSettings,
  [switch]$NoPaste,
  [switch]$Test,
  [switch]$HotkeyTest,
  [switch]$Notify,           # 强制弹一次启动气泡（静默启动时用，让你知道它起来了）
  [switch]$SettingsOnly,     # 只打开设置窗口，不注册热键（供"已在运行"时唤起）
  [switch]$StreamTest,       # 用真实音频验证流式提交逻辑
  [switch]$CorrectTest,      # 验证收尾 AI 校验（真实调用 API）
  [switch]$EngineTest,       # 验证当前配置的识别引擎（启动+VAD+识别）
  [int]$RestartAfter = 0     # 供"已在运行"实例用：杀掉指定 PID 的旧实例后接管
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

$AppDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:CrashLog = Join-Path $env:TEMP 'voice-typer-error.log'

function Say {
  param([string]$Text, [string]$Color = 'Gray')
  Write-Host ("[{0}] {1}" -f (Get-Date).ToString('HH:mm:ss'), $Text) -ForegroundColor $Color
}

# ═══════════════════════ 接力模式：先请走旧实例 ═══════════════════════
# 供"已在运行"提示框里的重启用：杀掉旧进程 → 等它释放互斥锁 → 自己接管
if ($RestartAfter -gt 0) {
  Say "正在结束旧实例 (PID $RestartAfter)…" DarkGray
  try { Stop-Process -Id $RestartAfter -Force -ErrorAction Stop } catch { }
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 150
    if (-not (Get-Process -Id $RestartAfter -ErrorAction SilentlyContinue)) { break }
  }
  # 顺带清理旧实例可能留下的识别子进程
  Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'worker\.mjs' } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
  Start-Sleep -Milliseconds 400
  Say '旧实例已结束，重新启动中…' Green
}

trap {
  $detail = @(
    "时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "错误: $($_.Exception.Message)",
    "位置: $($_.InvocationInfo.PositionMessage)",
    "堆栈: $($_.ScriptStackTrace)"
  ) -join "`r`n"
  try { Add-Content -Path $script:CrashLog -Value $detail -Encoding utf8 } catch { }
  Write-Host ''
  Write-Host '══════════ 启动失败 ══════════' -ForegroundColor Red
  Write-Host $detail -ForegroundColor Red
  Write-Host "详情已写入: $script:CrashLog" -ForegroundColor Yellow
  Write-Host '══════════════════════════════' -ForegroundColor Red
  exit 1
}

# ═══════════════════════ 原生互操作 ═══════════════════════
if (-not ('VTNative' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class VTNative {
  [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
  static extern int mciSendString(string cmd, StringBuilder ret, int len, IntPtr hwnd);
  public static string Mci(string cmd) {
    var sb = new StringBuilder(512);
    int rc = mciSendString(cmd, sb, sb.Capacity, IntPtr.Zero);
    if (rc != 0) throw new Exception("MCI 失败(" + rc + "): " + cmd);
    return sb.ToString();
  }

  [DllImport("user32.dll", SetLastError = true)]
  public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
  [DllImport("user32.dll", SetLastError = true)]
  public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

  [StructLayout(LayoutKind.Sequential)]
  public struct MSG {
    public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam;
    public uint time; public int ptX; public int ptY;
  }
  [DllImport("user32.dll")] public static extern bool GetMessage(out MSG m, IntPtr h, uint a, uint b);
  [DllImport("user32.dll")] public static extern bool PeekMessage(out MSG m, IntPtr h, uint min, uint max, uint remove);
  [DllImport("user32.dll")] public static extern bool TranslateMessage(ref MSG m);
  [DllImport("user32.dll")] public static extern IntPtr DispatchMessage(ref MSG m);
  [DllImport("user32.dll")] public static extern void PostQuitMessage(int code);

  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);

  [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
  static extern IntPtr GetWindowLongPtr64(IntPtr h, int i);
  [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
  static extern int GetWindowLong32(IntPtr h, int i);
  [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
  static extern IntPtr SetWindowLongPtr64(IntPtr h, int i, IntPtr v);
  [DllImport("user32.dll", EntryPoint = "SetWindowLongW")]
  static extern int SetWindowLong32(IntPtr h, int i, int v);
  public static IntPtr GetWindowLongPtrSafe(IntPtr h, int i) {
    return IntPtr.Size == 8 ? GetWindowLongPtr64(h, i) : (IntPtr)GetWindowLong32(h, i);
  }
  public static IntPtr SetWindowLongPtrSafe(IntPtr h, int i, IntPtr v) {
    return IntPtr.Size == 8 ? SetWindowLongPtr64(h, i, v) : (IntPtr)SetWindowLong32(h, i, v.ToInt32());
  }
  [DllImport("user32.dll")]
  public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
}
'@
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ═══════════════════════ 子模块 ═══════════════════════
. (Join-Path $AppDir 'config.ps1')
. (Join-Path $AppDir 'icons.ps1')      # SVG 路径渲染器，必须早于 floating.ps1
. (Join-Path $AppDir 'gui.ps1')
. (Join-Path $AppDir 'floating.ps1')

# ═══════════════════════ 全局配置 ═══════════════════════
$script:Cfg = Get-Config

# ── 流式相关的固定阈值（必须定义在任何使用点之前：测试块、定时器、动作函数都会用到）──
$script:MinCommitDelaySec = 5.0       # 录音满 5 秒才允许首次上屏（再短模型会对截断语音编词）
$script:MinCommitChars    = 2         # 至少这么多新字才值得粘贴一次

# 纠错等待期间会跑消息泵（让悬浮按钮外圈转起来），那时热键会重入。
# 这个标志用来挡住"上一条还在处理，又开一段录音"。
$script:Busy = $false

# ═══════════════════════ 仅设置模式 ═══════════════════════
if ($SettingsOnly) {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  . (Join-Path $AppDir 'config.ps1')
  . (Join-Path $AppDir 'gui.ps1')
  $script:OnSettingsSaved = {
    param($c)
    Save-Config -Config $c | Out-Null
    [System.Windows.Forms.MessageBox]::Show(
      '设置已保存。' + "`r`n`r`n" + '请退出并重新启动 voice-typer 使其生效。',
      'voice-typer', 'OK', 'Information') | Out-Null
  }
  Show-SettingsDialog -Config (Get-Config)
  exit 0
}

# ═══════════════════════ 单实例保护 ═══════════════════════
# 没有这道检查的话，重复启动会静默失败（热键被占用），用户看不到任何反馈。
if (-not $Test -and -not $HotkeyTest -and -not $StreamTest -and -not $SettingsOnly -and -not $CorrectTest -and -not $EngineTest) {
  $script:SingleMutex = [System.Threading.Mutex]::new($false, 'Global\voice-typer-single-instance')
  if (-not $script:SingleMutex.WaitOne(0)) {
    Write-Host ''
    Write-Host '  voice-typer 已经在运行了。' -ForegroundColor Yellow
    Write-Host ''
    try {
      Add-Type -AssemblyName System.Windows.Forms
      Add-Type -AssemblyName System.Drawing
      $r = [System.Windows.Forms.MessageBox]::Show(
        "voice-typer 已经在运行了。`r`n`r`n" +
        "用法：`r`n" +
        "    · 按快捷键开始/停止说话`r`n" +
        "    · 或点击屏幕上那个圆形悬浮按钮`r`n`r`n" +
        "找不到它？点「打开设置」可以调整快捷键和悬浮按钮。",
        'voice-typer 已在运行',
        [System.Windows.Forms.MessageBoxButtons]::OKCancel,
        [System.Windows.Forms.MessageBoxIcon]::Information)
      if ($r -eq [System.Windows.Forms.DialogResult]::OK) {
        # 杀掉旧实例并用相同参数重新启动，这样设置能立即生效（单实例不会冲突）
        $pw = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
        if (-not (Test-Path $pw)) { $pw = 'pwsh' }
        $me = Join-Path $AppDir 'voice-typer.ps1'

        $old = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
               Where-Object { $_.CommandLine -match 'voice-typer\.ps1' -and $_.ProcessId -ne $PID }
        $oldPid = if ($old) { @($old)[0].ProcessId } else { 0 }

        if ($oldPid -gt 0) {
          Start-Process -FilePath $pw -ArgumentList @(
            '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', "`"$me`"", '-RestartAfter', "$oldPid"
          ) -WindowStyle Hidden
        }
      }
    } catch {
      Write-Host '  (提示框显示失败，但程序确实在运行)' -ForegroundColor DarkGray
    }
    Write-Host ''
    exit 0
  }
}

# ═══════════════════════ 悬浮提示窗（不抢焦点）═══════════════════════
$script:Overlay = $null

function Show-Overlay {
  param([string]$Text)
  if (-not $script:Cfg.showOverlay) { return }
  if ([string]::IsNullOrEmpty($Text)) { $Text = '正在聆听…' }

  if (-not $script:Overlay) {
    $f = [System.Windows.Forms.Form]::new()
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $f.StartPosition   = [System.Windows.Forms.FormStartPosition]::Manual
    $f.TopMost         = $true
    $f.ShowInTaskbar   = $false
    $f.BackColor       = [System.Drawing.Color]::FromArgb(26, 28, 33)
    $f.Opacity         = 0.94
    $f.Padding         = [System.Windows.Forms.Padding]::new(16, 10, 16, 10)

    $lbl = [System.Windows.Forms.Label]::new()
    $lbl.Dock      = [System.Windows.Forms.DockStyle]::Fill
    $lbl.ForeColor = [System.Drawing.Color]::FromArgb(235, 237, 240)
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    $lbl.Font      = [System.Drawing.Font]::new('Microsoft YaHei UI', 11)
    $lbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $f.Controls.Add($lbl)

    if ($f.IsHandleCreated -eq $false) { [void]$f.Handle }
    $GWL_EXSTYLE = -20
    try {
      $cur = [VTNative]::GetWindowLongPtrSafe($f.Handle, $GWL_EXSTYLE)
      [void][VTNative]::SetWindowLongPtrSafe($f.Handle, $GWL_EXSTYLE,
        ($cur -bor 0x08000000 -bor 0x00000080))   # NOACTIVATE | TOOLWINDOW
    } catch { }
    $script:Overlay = [pscustomobject]@{ Form = $f; Label = $lbl }
  }

  $script:Overlay.Label.Text = $Text
  $font = [System.Drawing.Font]::new('Microsoft YaHei UI', 11)
  $sz = [System.Windows.Forms.TextRenderer]::MeasureText(
    $Text, $font, [System.Drawing.Size]::new(720, 800),
    [System.Windows.Forms.TextFormatFlags]::WordBreak)
  $w = [Math]::Min(748, [Math]::Max(300, $sz.Width + 36))
  $h = [Math]::Min(170, [Math]::Max(50, $sz.Height + 22))

  $scr = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $script:Overlay.Form.Bounds = [System.Drawing.Rectangle]::new(
    [int]($scr.Left + ($scr.Width - $w) / 2),
    [int]($scr.Bottom - $h - 80), $w, $h)

  if (-not $script:Overlay.Form.Visible) {
    $script:Overlay.Form.Show()
    try { [void][VTNative]::SetWindowPos($script:Overlay.Form.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x0010 -bor 0x0040) } catch { }
  }
  [System.Windows.Forms.Application]::DoEvents()
}

function Hide-Overlay {
  if ($script:Overlay -and $script:Overlay.Form.Visible) { $script:Overlay.Form.Hide() }
}

# ═══════════════════════ 录音（MCI）═══════════════════════
$script:RecAlias = 'vtRec'
$script:RecFile = Join-Path $env:TEMP 'voice-typer-rec.wav'
$script:RecStart = $null

function Start-Recording {
  Remove-Item $script:RecFile -Force -ErrorAction SilentlyContinue
  [VTNative]::Mci("open new type waveaudio alias $script:RecAlias") | Out-Null
  [VTNative]::Mci("set $script:RecAlias bitspersample 16 samplespersec 16000 channels 1 bytespersec 32000 alignment 2") | Out-Null
  [VTNative]::Mci("set $script:RecAlias time format milliseconds") | Out-Null
  [VTNative]::Mci("record $script:RecAlias") | Out-Null
  $script:RecStart = Get-Date
}

function Stop-Recording {
  param([switch]$Silent)
  try {
    [VTNative]::Mci("stop $script:RecAlias") | Out-Null
    [VTNative]::Mci("save $script:RecAlias `"$script:RecFile`"") | Out-Null
  } catch { if (-not $Silent) { throw } }
  finally { try { [VTNative]::Mci("close $script:RecAlias") | Out-Null } catch { } }
}

# 把当前已录音频落盘，然后继续录（MCI 会把新数据追加到末尾）
function Flush-RecordedAudio {
  [VTNative]::Mci("stop $script:RecAlias") | Out-Null
  [VTNative]::Mci("save $script:RecAlias `"$script:RecFile`"") | Out-Null
  [VTNative]::Mci("record $script:RecAlias") | Out-Null
  if (Test-Path $script:RecFile) { return (Get-Item $script:RecFile).Length }
  return 0
}

# ═══════════════════════ 常驻识别进程 ═══════════════════════
$script:Worker = $null
$script:Mid = 0
$script:WorkerLog = Join-Path $env:TEMP 'voice-typer-worker.log'

function Get-NodeExe {
  $cands = @('C:\Program Files\nodejs\node.exe', (Join-Path ${env:ProgramFiles} 'nodejs\node.exe'))
  if ($env:DSH_HOME) { $cands += (Join-Path $env:DSH_HOME 'dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe') }
  foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
  $cmd = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  throw '找不到 node.exe'
}

# ─────────── 引擎抽象层 ───────────
# 两个引擎用完全相同的 JSON 行协议，所以这里只决定"用哪个解释器 + 哪个脚本 + 什么环境变量"。
# 这样切换引擎不需要改动任何业务逻辑。

function Get-PythonExe {
  # Qwen3 引擎用独立 venv，避免污染系统 Python
  $venvPy = Join-Path $AppDir '.venv-qwen3\Scripts\python.exe'
  if (Test-Path $venvPy) { return $venvPy }
  $cands = @(
    (Join-Path $env:DSH_HOME 'dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe')
  )
  foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
  $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  throw '找不到 python.exe（Qwen3 引擎需要 Python）。请先创建 .venv-qwen3 环境'
}

function Get-Qwen3ModelDir {
  if ($script:Cfg.qwen3ModelDir -and (Test-Path $script:Cfg.qwen3ModelDir)) { return $script:Cfg.qwen3ModelDir }
  $base = Join-Path $AppDir 'models'
  if (Test-Path $base) {
    $d = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
         Where-Object { Test-Path (Join-Path $_.FullName 'encoder.int8.onnx') } |
         Select-Object -First 1
    if ($d) { return $d.FullName }
  }
  throw "找不到 Qwen3-ASR 模型。请放到 $base 下，或在设置里指定 qwen3ModelDir"
}

function Get-EngineLabel {
  if ($script:Cfg.engine -eq 'qwen3') { return 'Qwen3-ASR-0.6B' }
  return 'SenseVoice'
}

function Stop-Worker {
  if ($script:Worker -and -not $script:Worker.HasExited) {
    try { $script:Worker.StandardInput.WriteLine('{"cmd":"exit"}'); $script:Worker.StandardInput.Flush() } catch { }
    Start-Sleep -Milliseconds 250
    if (-not $script:Worker.HasExited) { try { $script:Worker.Kill() } catch { } }
  }
  $script:Worker = $null
}

function Start-Worker {
  if ($script:Worker -and -not $script:Worker.HasExited) { return }
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.RedirectStandardInput  = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $false     # stderr 走日志文件，避免管道写满卡死
  $psi.UseShellExecute        = $false
  $psi.CreateNoWindow         = $true
  $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)

  # 两个引擎共用的环境变量
  $psi.EnvironmentVariables['VT_THREADS']         = "$($script:Cfg.threads)"
  $psi.EnvironmentVariables['VT_IDLE_MS']         = "$([int]$script:Cfg.idleSec * 1000)"
  $psi.EnvironmentVariables['VT_LOG']             = $script:WorkerLog
  $psi.EnvironmentVariables['VT_VAD_THRESHOLD']   = "$($script:Cfg.vadThreshold)"
  $psi.EnvironmentVariables['VT_VAD_MIN_SILENCE'] = "$($script:Cfg.vadMinSilence)"
  $psi.EnvironmentVariables['VT_VAD_MAX_SPEECH']  = "$($script:Cfg.vadMaxSpeech)"

  if ($script:Cfg.engine -eq 'qwen3') {
    $py = Get-PythonExe
    $modelDir = Get-Qwen3ModelDir
    $psi.FileName  = $py
    $psi.Arguments = '"' + (Join-Path $AppDir 'worker_qwen3.py') + '"'
    $psi.EnvironmentVariables['VT_QWEN3_MODEL_DIR'] = $modelDir
    if ($script:Cfg.qwen3Hotwords) {
      $psi.EnvironmentVariables['VT_QWEN3_HOTWORDS'] = "$($script:Cfg.qwen3Hotwords)"
    }
    # Qwen3 加载更重（约 950MB），给足时间
    $readyTimeoutMs = 60000
  }
  else {
    $psi.FileName  = Get-NodeExe
    $psi.Arguments = '"' + (Join-Path $AppDir 'worker.mjs') + '"'
    $psi.EnvironmentVariables['VT_PRELOAD_LANG'] = "$($script:Cfg.lang)"
    $readyTimeoutMs = 30000
  }

  $script:Worker = [System.Diagnostics.Process]::Start($psi)

  # 等 ready 行。注意：不能用 ReadLineAsync().Wait() ——
  # 在 PowerShell 里 .Wait() 会和同步上下文互锁造成死锁（表现为脚本永久卡住）。
  # 改用 ReadLineAsync + 轮询，安全且能设超时。
  # Qwen3 首次要加载约 950MB 模型（实测 3.5 秒），SenseVoice 约 1.4 秒。
  $task = $script:Worker.StandardOutput.ReadLineAsync()
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while (-not $task.IsCompleted) {
    if ($script:Worker.HasExited) {
      Stop-Worker
      throw "识别进程启动即退出（引擎 $($script:Cfg.engine)）—— 请检查模型与依赖"
    }
    if ($sw.ElapsedMilliseconds -gt $readyTimeoutMs) {
      Stop-Worker
      throw "识别进程启动超时（$([int]($readyTimeoutMs/1000)) 秒，引擎 $($script:Cfg.engine)）"
    }
    Start-Sleep -Milliseconds 50
  }
  $ready = $task.Result
  if (-not $ready) {
    Stop-Worker
    throw "识别进程未返回就绪信息（引擎 $($script:Cfg.engine)）"
  }
  $script:EngineReady = $true
}

function Invoke-Recognition {
  param([string]$WavPath, [int]$TimeoutSec = 120, [switch]$Vad)
  Start-Worker
  $script:Mid++
  $id = $script:Mid
  $req = @{ id = $id; wav = $WavPath; lang = $script:Cfg.lang }
  if ($Vad) { $req.vad = $true }
  $json = $req | ConvertTo-Json -Compress
  $script:Worker.StandardInput.WriteLine($json)
  $script:Worker.StandardInput.Flush()
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    $line = $script:Worker.StandardOutput.ReadLine()
    if ($null -eq $line) { throw '识别进程意外退出' }
    if (-not $line.Trim()) { continue }
    try { $o = $line | ConvertFrom-Json } catch { continue }
    if ($o.PSObject.Properties.Name -contains 'ready') { continue }
    if ($o.id -ne $id) { continue }
    if ($o.ok) {
      $segs = @()
      if ($Vad -and $o.PSObject.Properties.Name -contains 'segments' -and $o.segments) {
        foreach ($sg in $o.segments) {
          # Closed：段落是否已确认说完（末尾那段为 false）。
          # Node 版没有这个字段（靠"去掉最后一段"实现），缺失时默认 true 以保持兼容。
          $closed = $true
          if ($sg.PSObject.Properties.Name -contains 'closed') { $closed = [bool]$sg.closed }
          $segs += [pscustomobject]@{ Text = [string]$sg.t; Dur = [double]$sg.dur; Closed = $closed }
        }
      }
      # 【务必统一返回 {Text, Segments} 对象】
      # 以前不传 -Vad 时这里返回裸字符串，调用方写 $res.Text 就会静默拿到空值，
      # 表现为"识别不出来内容"。返回类型不一致是这类 bug 的温床，不要再改回去。
      return [pscustomobject]@{ Text = [string]$o.text; Segments = $segs }
    }
    throw "识别失败: $($o.error)"
  }
  throw '识别超时'
}

# ═══════════════════════ 收尾 AI 校验 ═══════════════════════
# 只在"这次语音结束之后"跑一次，用 deepseek-flash 非推理模式做保守纠错。
# 任何失败（超时/断网/无凭证/被护栏拦下）都原样返回，绝不因为纠错失败而丢字。
function Invoke-Correction {
  param([string]$Text)
  if (-not $script:Cfg.correct) { return $Text }
  if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
  if ($Text.Length -lt 4) { return $Text }
  # 重入保护：下面等 API 的时候会跑消息泵，热键/悬浮按钮点击会重入到这里。
  # 不挡的话会在"上一句还在纠错"时又开一段录音。
  if ($script:Busy) { return $Text }
  $script:Busy = $true

  # ── 进入「AI 校验中」：按钮变紫 + 外圈转圈 ──
  # 官方约 1 秒还好，中转站要等 4~8 秒。这几秒里按钮要是纹丝不动，
  # 用户会以为程序卡死了（或者以为没在纠错），所以必须有明确的"在忙"反馈。
  Set-FloatState -State 'correcting'

  $inF  = Join-Path $env:TEMP 'voice-typer-correct-in.txt'
  $outF = Join-Path $env:TEMP 'voice-typer-correct-out.txt'
  try {
    [System.IO.File]::WriteAllText($inF, $Text, [System.Text.UTF8Encoding]::new($false))
    Remove-Item $outF -Force -ErrorAction SilentlyContinue

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = Get-NodeExe
    $psi.Arguments              = '"' + (Join-Path $AppDir 'corrector.mjs') + '" "' + $inF + '" "' + $outF + '"'
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding  = [System.Text.UTF8Encoding]::new($false)
    # 纠错进程自己不做流式 key 传递；由它从 DSH 凭证文件读取，避免密钥进日志
    $psi.EnvironmentVariables['VT_CORRECT_MODEL']      = "$($script:Cfg.correctModel)"
    $psi.EnvironmentVariables['VT_CORRECT_TIMEOUT_MS'] = "$($script:Cfg.correctTimeoutMs)"
    # 服务来源可切换（留空即官方）
    if ($script:Cfg.correctBaseUrl) {
      $psi.EnvironmentVariables['VT_CORRECT_BASE_URL'] = "$($script:Cfg.correctBaseUrl)"
    }
    if ($script:Cfg.correctApiFormat) {
      $psi.EnvironmentVariables['VT_CORRECT_API_FORMAT'] = "$($script:Cfg.correctApiFormat)"
    }
    if ($script:Cfg.correctKeyName) {
      $psi.EnvironmentVariables['VT_CORRECT_KEY_NAME'] = "$($script:Cfg.correctKeyName)"
    }
    # 关思考的参数发不发（DeepSeek 系要发；GPT 这类发了会被中转站卡死）
    $thinkP = [string]$script:Cfg.correctThinkParams
    if ($thinkP) {
      $psi.EnvironmentVariables['VT_CORRECT_THINK_PARAMS'] = $thinkP
    }
    # 提示词模式：proofread 保守校对 / instruct AI 指令优化
    $pmode = [string]$script:Cfg.correctMode
    if ($pmode) {
      $psi.EnvironmentVariables['VT_CORRECT_MODE'] = $pmode
    }
    $maxTok = [int]$script:Cfg.correctMaxTokens
    if ($maxTok -gt 0) {
      $psi.EnvironmentVariables['VT_CORRECT_MAX_TOKENS'] = "$maxTok"
    }
    if ($script:Cfg.correctGlossary) {
      $psi.EnvironmentVariables['VT_CORRECT_GLOSSARY'] = "$($script:Cfg.correctGlossary)"
    }
    if ($script:Cfg.correctFillers) {
      $psi.EnvironmentVariables['VT_CORRECT_FILLERS'] = "$($script:Cfg.correctFillers)"
    }

    $p = [System.Diagnostics.Process]::Start($psi)
    # 用异步读替代 ReadToEnd：后者会一直阻塞到子进程退出，把 UI 线程堵死，
    # 那样就没法跑消息泵了（见下面）。
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $deadline = [datetime]::Now.AddMilliseconds(([int]$script:Cfg.correctTimeoutMs) + 3000)
    # 等待期间跑消息泵。脉冲定时器是 WinForms Timer，归属于 UI 线程；
    # Stop-Dictation 是在消息循环里被同步调用的，不泵消息的话这个定时器
    # 一次都触发不了 —— 外圈的弧会僵在原处，比不转更像卡死。
    while (-not $p.HasExited -and [datetime]::Now -lt $deadline) {
      [System.Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 20
    }
    if (-not $p.HasExited) {
      try { $p.Kill() } catch { }
      Say '  纠错超时，使用原文' Yellow
      return $Text
    }
    $null = $p.WaitForExit(2000)
    $errTxt = $errTask.Result
    $tag = ($errTxt.Trim() -split "`n" | Select-Object -Last 1)
    $corrected = if (Test-Path $outF) { [System.IO.File]::ReadAllText($outF, [System.Text.UTF8Encoding]::new($false)) } else { '' }
    if ([string]::IsNullOrWhiteSpace($corrected)) { Say '  纠错无输出，使用原文' Yellow; return $Text }

    if ($corrected.Trim() -eq $Text.Trim()) {
      Say '  校验完成：无需修改' DarkGray
    } else {
      Say ("  校验修正：{0}" -f $corrected.Trim()) Magenta
    }
    if ($tag) { Say ("  $tag") DarkGray }
    return $corrected.Trim()
  } catch {
    Say ("  纠错失败（$($_.Exception.Message)），使用原文") Yellow
    return $Text
  } finally {
    Remove-Item $inF, $outF -Force -ErrorAction SilentlyContinue
    # 离开校验状态，回到识别阶段的橙色；紧接着流程会切到 ok → idle。
    # 放在 finally 里是为了覆盖上面每一个 return 分支（超时/无输出/失败）。
    Set-FloatState -State 'working'
    $script:Busy = $false
  }
}

# ═══════════════════════ 粘贴 ═══════════════════════
function Insert-Text {
  param([string]$Text, [IntPtr]$Target, [switch]$NoRestore)
  if ([string]::IsNullOrWhiteSpace($Text)) { return }
  if ($NoPaste -or -not $script:Cfg.autoPaste) { return }
  if ($Target -ne [IntPtr]::Zero -and [VTNative]::GetForegroundWindow() -ne $Target) {
    $t1 = [VTNative]::GetWindowThreadProcessId([VTNative]::GetForegroundWindow(), [IntPtr]::Zero)
    $t2 = [VTNative]::GetWindowThreadProcessId($Target, [IntPtr]::Zero)
    $me = [VTNative]::GetCurrentThreadId()
    [void][VTNative]::AttachThreadInput($me, $t1, $true)
    [void][VTNative]::AttachThreadInput($me, $t2, $true)
    [void][VTNative]::SetForegroundWindow($Target)
    [void][VTNative]::AttachThreadInput($me, $t1, $false)
    [void][VTNative]::AttachThreadInput($me, $t2, $false)
    Start-Sleep -Milliseconds 120
  }
  $saved = $null
  if (-not $NoRestore) { try { $saved = [System.Windows.Forms.Clipboard]::GetText() } catch { } }
  [System.Windows.Forms.Clipboard]::SetText($Text)
  Start-Sleep -Milliseconds 70
  [System.Windows.Forms.SendKeys]::SendWait('^v')
  Start-Sleep -Milliseconds 260
  # 流式提交时跳过还原：一轮要粘好几次，反复还原既慢又会让剪贴板闪烁
  if (-not $NoRestore -and -not [string]::IsNullOrEmpty($saved)) {
    try { [System.Windows.Forms.Clipboard]::SetText($saved) } catch { }
  }
}

# ═══════════════════════ 热键管理 ═══════════════════════
$ID_TOGGLE = 1
$ID_CANCEL = 2
$MOD_NOREPEAT = 0x4000
$script:RegToggle = $false
$script:RegCancel = $false

function Unregister-AllHotkeys {
  if ($script:RegToggle) { [void][VTNative]::UnregisterHotKey([IntPtr]::Zero, $ID_TOGGLE); $script:RegToggle = $false }
  Unregister-CancelHotkey
}

# ── 取消键只在录音期间注册 ──
# Esc 是全局热键时会把整个系统的 Esc 都抢走，静止时绝不能占着它。
function Register-CancelHotkey {
  if ($script:RegCancel) { return }
  if (-not $script:Cfg.hotkeyCancel) { return }
  $c = ConvertTo-HotkeyParts -Text $script:Cfg.hotkeyCancel
  if (-not $c) { return }
  $script:RegCancel = [VTNative]::RegisterHotKey([IntPtr]::Zero, $ID_CANCEL,
                        [uint32]($c.Mods -bor $MOD_NOREPEAT), [uint32]$c.Vk)
}

function Unregister-CancelHotkey {
  if ($script:RegCancel) {
    [void][VTNative]::UnregisterHotKey([IntPtr]::Zero, $ID_CANCEL)
    $script:RegCancel = $false
  }
}

function Register-AllHotkeys {
  param([switch]$Quiet)
  Unregister-AllHotkeys
  $ok = $true

  $t = ConvertTo-HotkeyParts -Text $script:Cfg.hotkeyToggle
  if (-not $t) {
    if (-not $Quiet) { Say "录音快捷键「$($script:Cfg.hotkeyToggle)」无法解析" Red }
    $ok = $false
  } else {
    $script:RegToggle = [VTNative]::RegisterHotKey([IntPtr]::Zero, $ID_TOGGLE, [uint32]($t.Mods -bor $MOD_NOREPEAT), [uint32]$t.Vk)
    if (-not $script:RegToggle) {
      if (-not $Quiet) { Say "录音快捷键 $($t.Text) 注册失败 —— 可能被其他程序占用，请在托盘「设置」里换一个" Red }
      $ok = $false
    } elseif (-not $Quiet) { Say "录音快捷键: $($t.Text)" Green }
  }

  # 注意：取消键（默认 Esc）不在这里注册，只在录音开始后注册
  if (-not $Quiet -and $script:Cfg.hotkeyCancel) {
    Say "取消键: $($script:Cfg.hotkeyCancel)（仅在录音期间生效，不占用系统按键）" DarkGray
  }
  return $ok
}

# ═══════════════════════ 自检 ═══════════════════════
if ($Test) {
  Say '── 自检 ──' Cyan
  Say ("配置文件 : $script:ConfigPath") DarkGray
  Say ("录音快捷键: $($script:Cfg.hotkeyToggle)") DarkGray
  Say ("识别语言  : $($script:Cfg.lang)    线程: $($script:Cfg.threads)") DarkGray

  $t = ConvertTo-HotkeyParts -Text $script:Cfg.hotkeyToggle
  if ($t) { Say ("快捷键解析 : Mods=$($t.Mods) Vk=0x$('{0:X2}' -f $t.Vk)  规范化=「$($t.Text)」") Green }
  else { Say '快捷键解析失败！' Red }

  # 关键回归检查：静止时绝不能占着取消键（Esc 被全局占用会导致全系统 Esc 失灵）
  Say '检查取消键是否被误占用…' DarkGray
  $cancel = ConvertTo-HotkeyParts -Text $script:Cfg.hotkeyCancel
  if ($cancel) {
    $probeId = 9001
    $free = [VTNative]::RegisterHotKey([IntPtr]::Zero, $probeId,
              [uint32]($cancel.Mods -bor $MOD_NOREPEAT), [uint32]$cancel.Vk)
    if ($free) {
      [void][VTNative]::UnregisterHotKey([IntPtr]::Zero, $probeId)
      Say ("  取消键 $($cancel.Text) 当前空闲 ✅（只在录音期间才会占用）") Green
    } else {
      Say ("  ⚠️ 取消键 $($cancel.Text) 已被占用，可能是另一个 voice-typer 实例在运行") Yellow
    }
  } else { Say '  未设置取消键' DarkGray }

  Say '启动识别进程…' DarkGray
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  Start-Worker
  Say ("模型就绪 {0} ms" -f $sw.ElapsedMilliseconds) Green

  $wav = Join-Path $AppDir 'test.wav'
  if (Test-Path $wav) {
    $sw.Restart(); $text = (Invoke-Recognition -WavPath $wav).Text; $sw.Stop()
    Say ("识别: {0}  ({1} ms)" -f $text, $sw.ElapsedMilliseconds) Green
  } else {
    Say '实录 2 秒麦克风…' DarkGray
    Start-Recording; Start-Sleep -Milliseconds 2000; Stop-Recording
    $sw.Restart(); $text = (Invoke-Recognition -WavPath $script:RecFile).Text; $sw.Stop()
    Say ("话筒识别: 「{0}」  ({1} ms)" -f $text, $sw.ElapsedMilliseconds) Green
  }

  Say '测试托盘图标与设置窗口…' DarkGray
  Start-Tray -Config $script:Cfg
  Say '托盘已创建（图标应出现在任务栏右下角）' Green
  $ic = New-AppIcon
  Say ("图标尺寸: {0}x{1}" -f $ic.Width, $ic.Height) DarkGray
  Stop-Tray

  Say '测试悬浮按钮与各状态绘制…' DarkGray
  Start-FloatButton
  if ($script:FloatBtn) {
    Say ("悬浮按钮已创建: {0}x{1} @ ({2},{3})" -f `
      $script:FloatBtn.Form.Width, $script:FloatBtn.Form.Height,
      $script:FloatBtn.Form.Left, $script:FloatBtn.Form.Top) Green

    # 扩展样式：应是不抢焦点 + 不进 Alt+Tab；首选方案还会带 WS_EX_LAYERED
    $ex = [VTLayered]::GetWindowLong($script:FloatBtn.Form.Handle, [VTLayered]::GWL_EXSTYLE)
    $noAct = [bool]($ex -band [VTLayered]::WS_EX_NOACTIVATE)
    $thru  = [bool]($ex -band [VTLayered]::WS_EX_TRANSPARENT)
    $lyr   = [bool]($ex -band [VTLayered]::WS_EX_LAYERED)
    Say ("  窗体类型={0}  不抢焦点={1}  点击穿透={2}  分层窗口={3}" -f `
        $script:FloatBtn.Form.GetType().Name, $noAct, $thru, $lyr) `
        $(if ($noAct -and -not $thru) { 'Green' } else { 'Red' })

    # 圆外透明是怎么实现的（决定边缘好不好看）
    if ($script:FloatIsLayered) {
      Say '  透明方式: 分层窗口 + 逐像素 Alpha（边缘平滑，无黑边）' Green
    } else {
      Say '  透明方式: 圆形窗口区域（1 位掩码，无抗锯齿 —— 边缘会有锯齿和黑边）' Yellow
    }

    # 逐状态渲染并验证圆外真透明
    foreach ($st in @('idle', 'recording', 'working', 'ok')) {
      try {
        $bm = New-FloatBitmap -Size 46 -State $st -Pulse 0.5
        $ca = $bm.GetPixel(1, 1).A
        $cc = $bm.GetPixel(23, 23).A
        $bm.Dispose()
        if ($ca -eq 0 -and $cc -gt 200) { Say "  状态 $st 渲染正常（圆外透明、圆内不透明）" Green }
        else { Say "  状态 $st Alpha 异常: 角=$ca 心=$cc" Red }
      } catch {
        Say "  状态 $st 渲染失败: $($_.Exception.Message)" Red
      }
    }
    Update-FloatPulse
    Say '呼吸动画函数正常' Green
    Apply-FloatSize
    Say ("调整尺寸为 {$($script:Cfg.floatSize)}px 正常") Green
    Start-Sleep -Milliseconds 900        # 让你能看到按钮
    Stop-FloatButton
    Say '悬浮按钮测试完成' Green
  } else { Say '悬浮按钮创建失败！' Red }

  Stop-Worker
  Say '自检完成' Cyan
  exit 0
}

# ═══════════════════════ 流式逻辑验证 ═══════════════════════
if ($StreamTest) {
  Say '── 流式切段逻辑验证 ──' Cyan
  $wav = Join-Path $AppDir 'test.wav'
  if (-not (Test-Path $wav)) { Say "缺少测试音频 $wav" Red; exit 1 }

  # 构造"语音 + 静音 + 语音 + 静音 + 语音"的合成音频，用来验证停顿检测与切段
  $b = [System.IO.File]::ReadAllBytes($wav)
  $hdr = 44
  $srcPcm = $b.Length - $hdr
  $silenceMs = 700
  $silenceBytes = [int]($silenceMs * 32.0)
  $silence = New-Object byte[] $silenceBytes          # 全零 = 绝对静音

  $parts = @()
  foreach ($i in 1..3) { $parts += ,@('speech', $srcPcm) ; if ($i -lt 3) { $parts += ,@('silence', $silenceBytes) } }
  $totalPcm = 0
  foreach ($p in $parts) { $totalPcm += $p[1] }

  $long = New-Object byte[] ($hdr + $totalPcm)
  [Array]::Copy($b, 0, $long, 0, $hdr)
  [BitConverter]::GetBytes([int](36 + $totalPcm)).CopyTo($long, 4)
  [BitConverter]::GetBytes([int]$totalPcm).CopyTo($long, 40)
  $off = $hdr
  foreach ($p in $parts) {
    if ($p[0] -eq 'speech') { [Array]::Copy($b, $hdr, $long, $off, $p[1]) }
    # 静音区已经是 0，不用写
    $off += $p[1]
  }

  $script:RecFile = Join-Path $env:TEMP 'vt-streamtest.wav'
  [System.IO.File]::WriteAllBytes($script:RecFile, $long)
  Say ("构造合成音频: 3 段语音 + 2 处 {0}ms 静音，共 {1:N1} 秒" -f `
        $silenceMs, ($totalPcm / 32000.0)) DarkGray

  Say '启动识别进程…' DarkGray
  Start-Worker
  Say '模型就绪' Green

  # 模拟流式：音频每 1.5 秒增长一次，每轮都对"目前全部音频"跑 VAD 识别，
  # 并按"新全文是否以已上屏内容开头"决定是否追加 —— 与真实 tick 逻辑一致。
  $s = [pscustomobject]@{ Start = Get-Date; Text = ''; LastFull = ''; SegCount = 0; CommittedSegs = 0; Committed = 0 }
  $tmp = Join-Path $env:TEMP 'vt-streamtest-grow.wav'
  $round = 0
  $grown = 0
  $stepBytes = 48000                     # 1.5 秒
  $commits = 0

  Say ''
  Say '模拟流式推进（每轮音频增长 1.5 秒，对全部音频跑 VAD）:' DarkGray
  while ($grown -lt $totalPcm) {
    $round++
    $grown = [Math]::Min($totalPcm, $grown + $stepBytes)

    # 门槛按"已录到的音频时长"判定 —— 真实逻辑用的是录音经过的时间，二者等价
    if (($grown / 32000.0) -lt $script:MinCommitDelaySec) {
      Say ("  第{0,2}轮 音频 {1,4:N1}s  —（未满 {2}s 门槛，跳过）" -f `
            $round, ($grown / 32000.0), $script:MinCommitDelaySec) DarkGray
      continue
    }

    $out = New-Object byte[] ($hdr + $grown)
    [Array]::Copy($long, 0, $out, 0, $hdr)
    [Array]::Copy($long, $hdr, $out, $hdr, $grown)
    [BitConverter]::GetBytes([int](36 + $grown)).CopyTo($out, 4)
    [BitConverter]::GetBytes([int]$grown).CopyTo($out, 40)
    [System.IO.File]::WriteAllBytes($tmp, $out)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try { $res = Invoke-Recognition -WavPath $tmp -TimeoutSec 60 -Vad } catch { continue }
    $sw.Stop()
    $full = [string]$res.Text
    $s.LastFull = $full

    # 只提交"已确认说完"的段落，末尾正在说的那段不提交（引擎差异由辅助函数抹平）
    $done = @(Select-CompletedSegments -Segments $res.Segments)
    if ($done.Count -eq 0) {
      Say ("  第{0,2}轮 音频 {1,4:N1}s  {2} 段  → 末尾仍在进行，等待" -f `
            $round, ($grown / 32000.0), @($res.Segments).Count) DarkGray
      continue
    }
    $s.SegCount = $done.Count

    if ($done.Count -le $s.CommittedSegs) {
      Say ("  第{0,2}轮 音频 {1,4:N1}s  已确认 {2} 段  → 等待下一句" -f `
            $round, ($grown / 32000.0), $done.Count) DarkGray
      continue
    }

    $newText = ''
    for ($k = $s.CommittedSegs; $k -lt $done.Count; $k++) { $newText += $done[$k].Text }
    $s.CommittedSegs = $done.Count
    if ($newText.Length -lt $script:MinCommitChars) { continue }

    $s.Text += $newText
    $s.Committed = $s.Text.Length
    $commits++
    Say ("  第{0,2}轮 音频 {1,4:N1}s  已确认 {2} 段  → 上屏「{3}」  ({4} ms)" -f `
          $round, ($grown / 32000.0), $done.Count, $newText, $sw.ElapsedMilliseconds) Green
  }

  Say ''
  Say ("最终累计上屏: $($s.Text)") Cyan
  Say ("触发上屏 {0} 次（共 {1} 轮）" -f $commits, $round) DarkGray
  Say ("最终完整识别: $($s.LastFull)") DarkGray
  Say ''
  if ($commits -ge 2) {
    Say "✅ 流式有效：说话过程中就已多次上屏，不是等说完才输出" Green
  } elseif ($commits -eq 1) {
    Say "⚠️ 只上屏 1 次：本次测试音频较短，长句会有更多次上屏" Yellow
  } else {
    Say "❌ 没有触发任何上屏，需要检查 VAD 或前缀判定" Red
  }
  if ($s.LastFull.StartsWith($s.Text)) {
    Say "✅ 一致性校验通过：上屏内容是最终结果的严格前缀（无重复、无回改）" Green
  } else {
    Say "❌ 一致性校验失败" Red
  }
  Remove-Item $tmp, $script:RecFile -Force -ErrorAction SilentlyContinue
  Stop-Worker
  Say '验证完成' Cyan
  exit 0
}

# ── 归一化"已完成的段落" ──
# 两个引擎对"这段说完了吗"的表达方式不同：
#   Qwen3 版 worker 直接在每段上带 closed 标记（VAD 闭段时置 true）
#   SenseVoice 版 worker 没有该字段，靠"末尾那段一律视为还在说"来推断
# 这里统一成一个口径，流式逻辑与测试块都不必关心引擎差异。
function Select-CompletedSegments {
  param($Segments)
  $all = @($Segments | Where-Object { $_.Text -and $_.Text.Length -gt 0 })
  if ($all.Count -eq 0) { return @() }
  $hasFlag = ($all[0].PSObject.Properties.Name -contains 'Closed')
  if ($hasFlag) {
    $done = @($all | Where-Object { $_.Closed })
    # 兜底：若一段都没闭合但确实有内容，就把全部当作完成，
    # 否则会一直不上屏（worker 已补尾部静音，正常情况下不会走到这里）
    if ($done.Count -eq 0) { $done = @($all) }
    return $done
  }
  # 无标记（SenseVoice）：去掉末尾一段，它在增长中的音频里永远是半句
  if ($all.Count -lt 2) { return @() }
  return @($all[0..($all.Count - 2)])
}

# ═══════════════════════ 引擎验证 ═══════════════════════
# 用同一段测试音频跑一遍当前配置的引擎，验证"启动 + VAD + 识别"整条链路。
# 切换引擎后建议先跑这个。
if ($EngineTest) {
  Say '── 引擎验证 ──' Cyan
  Say ("引擎: {0}" -f (Get-EngineLabel)) Green
  Say ("线程: {0}   语言: {1}" -f $script:Cfg.threads, $script:Cfg.lang) DarkGray

  if ($script:Cfg.engine -eq 'qwen3') {
    $md = Get-Qwen3ModelDir
    Say ("模型目录: {0}" -f $md) DarkGray
    Say ("热词: {0}" -f $(if ($script:Cfg.qwen3Hotwords) { $script:Cfg.qwen3Hotwords } else { '（未设置）' })) DarkGray
    $py = Get-PythonExe
    Say ("Python: {0}" -f $py) DarkGray
  }

  $wav = Join-Path $AppDir 'test.wav'
  if (-not (Test-Path $wav)) { Say "缺少测试音频 $wav" Red; exit 1 }

  Say ''
  if ($script:Cfg.engine -eq 'qwen3') {
    Say '启动识别进程（Qwen3 首次需加载约 950MB 模型，实测约 4 秒）…' DarkGray
  } else {
    Say '启动识别进程（SenseVoice 约 1.5 秒）…' DarkGray
  }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try { Start-Worker } catch { Say ("启动失败: {0}" -f $_.Exception.Message) Red; exit 1 }
  Say ("  就绪，用时 {0:N0} ms" -f $sw.ElapsedMilliseconds) Green

  # 1) 整段识别
  Say ''
  Say '① 整段识别:' White
  $sw.Restart()
  try { $t = (Invoke-Recognition -WavPath $wav -TimeoutSec 120).Text } catch { Say ("  失败: {0}" -f $_.Exception.Message) Red; Stop-Worker; exit 1 }
  Say ("  {0}   （{1:N0} ms）" -f $t, $sw.ElapsedMilliseconds) Green

  # 2) VAD 识别
  Say ''
  Say '② VAD 切段识别:' White
  $sw.Restart()
  try { $r = Invoke-Recognition -WavPath $wav -TimeoutSec 120 -Vad } catch { Say ("  失败: {0}" -f $_.Exception.Message) Red; Stop-Worker; exit 1 }
  $ms = $sw.ElapsedMilliseconds
  Say ("  共 {0} 段，用时 {1:N0} ms" -f @($r.Segments).Count, $ms) Green
  $i = 0
  foreach ($sg in $r.Segments) {
    $i++
    Say ("    段{0}  {1:N2}s  closed={2}  「{3}」" -f $i, $sg.Dur, $sg.Closed, $sg.Text) Gray
  }
  if (@($r.Segments).Count -eq 0) { Say '    ⚠️ 没有切出任何段落' Yellow }

  # 3) 完成段筛选（流式逻辑用的就是这个）
  Say ''
  Say '③ 可用于流式提交的段落（末尾正在说的不算）:' White
  $done = @(Select-CompletedSegments -Segments $r.Segments)
  Say ("  {0} 段: {1}" -f $done.Count, (($done | ForEach-Object { $_.Text }) -join '')) Cyan

  Stop-Worker
  Say ''
  Say '引擎验证完成' Cyan
  exit 0
}

# ═══════════════════════ 收尾校验验证 ═══════════════════════
if ($CorrectTest) {
  Say '── 收尾 AI 校验验证 ──' Cyan
  Say ("模型: {0}   超时: {1} ms   总开关: {2}" -f `
        $script:Cfg.correctModel, $script:Cfg.correctTimeoutMs, $script:Cfg.correct) DarkGray
  Say ("词表: {0}" -f $(if ($script:Cfg.correctGlossary) { $script:Cfg.correctGlossary } else { '（空）' })) DarkGray
  Say ''

  # 注意：这里强制走一遍纠错，不受 correct 开关影响
  $savedCorrect = $script:Cfg.correct
  $script:Cfg.correct = $true

  $cases = @(
    @{ t = '开饭时间早上9点至下午5点。';        n = '本来正确，不应改动' },
    @{ t = '派饭时间早上9点至下午5点。';        n = '同音字错误，期望改成「开饭时间」' },
    @{ t = '帮我把这个 deep sick 的配置改一下。'; n = '英文识别错误，期望改成 DeepSeek' },
    @{ t = '我用语音识别来做的。';              n = '本来正确，不应改动' }
  )

  $ok = 0
  foreach ($c in $cases) {
    Say ("输入: {0}" -f $c.t) White
    Say ("       （{0}）" -f $c.n) DarkGray
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = Invoke-Correction -Text $c.t
    $sw.Stop()
    if ($out -eq $c.t) { Say ("输出: {0}   ← 保持不变（{1} ms）" -f $out, $sw.ElapsedMilliseconds) DarkGray }
    else { Say ("输出: {0}   ← 已修正（{1} ms）" -f $out, $sw.ElapsedMilliseconds) Magenta }
    Say ''
    if ($out -ne $c.t) { $ok++ }
  }
  Say ("共 {0} 条被修正，{1} 条保持不变" -f $ok, ($cases.Count - $ok)) Cyan
  $script:Cfg.correct = $savedCorrect
  Say '验证完成' Cyan
  exit 0
}

# ═══════════════════════ 热键测试 ═══════════════════════
if ($HotkeyTest) {
  Say '── 热键测试 ──' Cyan
  if (-not (Register-AllHotkeys)) { Say '注册失败，终止' Red; exit 1 }
  Say ''
  Say "请在 8 秒内按一次 $($script:Cfg.hotkeyToggle) …" Yellow
  $m = New-Object VTNative+MSG
  $hits = 0
  $deadline = (Get-Date).AddSeconds(8)
  while ((Get-Date) -lt $deadline) {
    if ([VTNative]::PeekMessage([ref]$m, [IntPtr]::Zero, 0x0312, 0x0312, 1)) {
      [void][VTNative]::TranslateMessage([ref]$m)
      [void][VTNative]::DispatchMessage([ref]$m)
      $hits++
      Say "收到热键事件 #$hits  id=$([int]$m.wParam)" Green
    }
    Start-Sleep -Milliseconds 40
  }
  Unregister-AllHotkeys
  if ($hits -gt 0) { Say "热键正常（$hits 次）" Green; exit 0 }
  Say '没收到事件' Red; exit 1
}

# ═══════════════════════ 流式提交定时器 ═══════════════════════
# 伪流式策略：把"到目前为止的全部录音"交给识别进程，由 Silero VAD 按真实语音活动
# 切成句子，逐句识别，然后把"还没上屏的新句子"追加到光标处。
#
# 为什么用 VAD 而不是能量阈值：
#   实测能量法区分不了"停顿"和"轻音节的语音"，会把句子内部的轻声段误判成停顿，
#   导致切段错位（切出「.」或把半句当一句）。Silero VAD 是真正的语音活动检测模型，
#   在同一段测试音频上能准确切出 3 段完整句子。
#
# 为什么按"前缀一致性"决定是否上屏：
#   VAD 对增长中的音频可能给出不同的分段，但每段的识别结果本身是稳定完整的。
#   只有当新识别的全文以"已上屏内容"开头时，才认为尾部是可信的新内容 —— 否则放弃本轮。
#   这样就从根本上杜绝了"重复上屏"和"上屏内容被后续推翻"。
$script:StreamTimer = [System.Windows.Forms.Timer]::new()
$script:StreamTimer.Interval = [Math]::Max(700, [int]$script:Cfg.streamTickMs)
$script:StreamBusy = $false
# 阈值已在全局配置区定义（MinCommitDelaySec / MinSegmentSec / MinCommitChars）

$script:StreamTimer.Add_Tick({
    if ($script:StreamBusy) { return }
    if (-not $script:Streaming -or -not $script:recording) { return }
    $script:StreamBusy = $true
    $s = $script:Streaming
    try {
      if (((Get-Date) - $s.Start).TotalSeconds -lt $script:MinCommitDelaySec) { return }

      [void](Flush-RecordedAudio)                       # 落盘并继续录
      if (-not (Test-Path $script:RecFile)) { return }

      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      try { $res = Invoke-Recognition -WavPath $script:RecFile -TimeoutSec 60 -Vad }
      catch { return }                                  # 单轮失败不影响整体
      $sw.Stop()

      $full = [string]$res.Text
      if ([string]::IsNullOrWhiteSpace($full)) { return }
      $s.LastFull = $full

      # 关键规则：末尾那段"还在说"的内容绝不提交。
      # 实测教训：VAD 对增长中的音频会在末尾切出半句话（「派饭时间早上9。」），
      # 等这段音频说完整后它变成「派饭时间早上9点至下午5点。」—— 已上屏内容就被推翻了。
      # 引擎差异（Qwen3 自带 closed 标记 / SenseVoice 靠去掉尾段）由辅助函数抹平。
      $done = @(Select-CompletedSegments -Segments $res.Segments)
      if ($done.Count -eq 0) { return }
      $s.SegCount = $done.Count

      if ($done.Count -le $s.CommittedSegs) {
        Say ("  · 已确认 {0} 段，末尾一段仍在进行中" -f $done.Count) DarkGray
        return
      }

      $newText = ''
      for ($k = $s.CommittedSegs; $k -lt $done.Count; $k++) { $newText += $done[$k].Text }
      $s.CommittedSegs = $done.Count
      if ($newText.Length -lt $script:MinCommitChars) { return }

      $s.Text += $newText
      $s.Committed = $s.Text.Length

      # 开启收尾校验时，不在说话过程中粘贴 —— 否则纠错后的版本无法安全替换已上屏内容。
      # 此时把实时文字显示在悬浮窗里作为预览，真正的粘贴留到停止后一次性完成。
      if ($script:Cfg.correct) {
        Say ("  ▸ 已识别：{0}" -f $newText) DarkGray
      } else {
        Insert-Text -Text $newText -Target $script:target -NoRestore
        Say ("  ▸ 上屏：{0}" -f $newText) Cyan
      }
      Say ("  ● {0:N1}s  已确认 {1} 段  已识别 {2} 字  本轮 {3} ms" -f `
            ((Get-Date) - $s.Start).TotalSeconds, $done.Count, $s.Text.Length, $sw.ElapsedMilliseconds) DarkGray
      Show-Overlay -Text $s.Text
    } catch {
      Say ("  流式处理出错: $($_.Exception.Message)") Yellow
    } finally { $script:StreamBusy = $false }
  })

# ═══════════════════════ 录音 / 识别 动作 ═══════════════════════
$recording = $false
$target = [IntPtr]::Zero
$script:Streaming = $null

function Start-Dictation {
  if ($recording) { return }
  try {
    $script:target = [VTNative]::GetForegroundWindow()
    Start-Recording
    $script:recording = $true
    Register-CancelHotkey          # 录音期间才占用取消键（默认 Esc）

    if ($script:Cfg.streaming) {
      $script:Streaming = [pscustomobject]@{
        Start         = Get-Date
        Text          = ''    # 已上屏的累计文字
        LastFull      = ''    # 最近一次完整识别结果（收尾时比对用）
        SegCount      = 0     # 最近一次 VAD 切出的完整段数
        CommittedSegs = 0     # 已上屏的完整段数
        Committed     = 0
      }
      $script:StreamTimer.Interval = [Math]::Max(700, [int]$script:Cfg.streamTickMs)
      $script:StreamTimer.Start()
      Show-Overlay -Text '● 正在聆听…（说完一句停顿一下，就会自动上屏）'
      Say "● 流式录音中…（停顿即上屏；按 $($script:Cfg.hotkeyToggle) 结束$(if($script:Cfg.hotkeyCancel){"，$($script:Cfg.hotkeyCancel) 取消"}else{''})）" Red
    }
    else {
      Show-Overlay -Text '● 正在聆听…'
      Say "● 录音中…（按 $($script:Cfg.hotkeyToggle) 停止$(if($script:Cfg.hotkeyCancel){"，$($script:Cfg.hotkeyCancel) 取消"}else{''})）" Red
    }
    Set-FloatState -State 'recording'
  } catch {
    $script:recording = $false
    $script:StreamTimer.Stop()
    $script:Streaming = $null
    Unregister-CancelHotkey
    Hide-Overlay
    Set-FloatState -State 'idle'
    Say "无法开始录音: $($_.Exception.Message)" Red
  }
}

function Stop-Dictation {
  param([switch]$Cancel)
  if (-not $script:recording) { return }
  $script:recording = $false
  $script:StreamTimer.Stop()
  Unregister-CancelHotkey           # 录音一结束就把取消键还给系统

  $stream = $script:Streaming
  $script:Streaming = $null

  if ($Cancel) {
    Stop-Recording -Silent
    Hide-Overlay
    Set-FloatState -State 'idle'
    if ($stream -and $stream.Committed -gt 0) {
      Say "已取消本次录音（注意：已上屏的 $($stream.Committed) 字不会撤回）" Yellow
    } else { Say '已取消本次录音' Yellow }
    return
  }

  Show-Overlay -Text '识别中…'
  Set-FloatState -State 'working'
  try { Stop-Recording } catch {
    Say "停止录音失败: $($_.Exception.Message)" Red
    Hide-Overlay; Set-FloatState -State 'idle'; return
  }
  $sec = if ($script:RecStart) { [math]::Round(((Get-Date) - $script:RecStart).TotalSeconds, 2) } else { 0 }
  if ($sec -lt 0.3) { Say "录音太短（$sec s）" Yellow; Hide-Overlay; Set-FloatState -State 'idle'; return }

  try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    if ($stream) {
      # 流式收尾：对完整录音再跑一次识别，补上还没处理的部分。
      # 开校验时说话过程中一个字都没粘，可以直接用最准的整段识别；
      # 关校验时已经边识别边粘贴了，必须沿用同一套 VAD 分段，
      # 否则两边分段方式不同、拼不上，反而会重复或丢内容。
      $correcting = [bool]$script:Cfg.correct
      if ($correcting) {
        Say ("录音 {0}s，正在收尾（整段识别）" -f $sec) DarkGray
        try { $fin = Invoke-Recognition -WavPath $script:RecFile -TimeoutSec 90 }
        catch { $fin = $null }
      } else {
        Say ("录音 {0}s，正在收尾（已识别 {1} 字）" -f $sec, $stream.Text.Length) DarkGray
        try { $fin = Invoke-Recognition -WavPath $script:RecFile -TimeoutSec 90 -Vad }
        catch { $fin = $null }
      }

      if ($fin) {
        # 收尾时用全部内容（含末尾那段），因为录音已经结束、不存在"还在说"的情况
        $allSegs = @($fin.Segments | Where-Object { $_.Text.Length -gt 0 })

        if ($correcting) {
          # 开启校验时：说话过程中一个字都没粘，这里取完整识别结果
          $stream.Text = ($allSegs | ForEach-Object { $_.Text }) -join ''
          if (-not $stream.Text) { $stream.Text = [string]$fin.Text }
          Say ("  最终识别 {0} 字，正在送 AI 校验…" -f $stream.Text.Length) DarkGray
        }
        else {
          $full = [string]$fin.Text
          if ($full.StartsWith($stream.Text)) {
            $tail = $full.Substring($stream.Text.Length)
            if (-not [string]::IsNullOrWhiteSpace($tail)) {
              $stream.Text = $full
              Say ("→ 补上尾部：{0}" -f $tail) Green
              Show-Overlay -Text $stream.Text
              Insert-Text -Text $tail -Target $script:target
            } else {
              Say ("全部内容已上屏，共 {0} 字" -f $stream.Text.Length) Green
            }
          } elseif ([string]::IsNullOrWhiteSpace($stream.Text) -and -not [string]::IsNullOrWhiteSpace($full)) {
            $stream.Text = $full
            Say ("→ 整段上屏：{0}" -f $full) Green
            Show-Overlay -Text $full
            Insert-Text -Text $full -Target $script:target
          } else {
            Say '最终分段与已上屏内容不一致，为避免重复不再追加' Yellow
          }
        }
      }

      if ([string]::IsNullOrWhiteSpace($stream.Text)) {
        Say '本次没有识别到任何内容' Yellow
        Show-Overlay -Text '（没有识别到内容）'
        Set-FloatState -State 'idle'
        Start-Sleep -Milliseconds 900
        Hide-Overlay
        return
      }

      # ── 收尾 AI 校验：整段一起改，避免逐句改导致语义判断不准 ──
      if ($correcting) {
        Show-Overlay -Text $stream.Text
        $before = $stream.Text
        $swC = [System.Diagnostics.Stopwatch]::StartNew()
        $fixed = Invoke-Correction -Text $before
        $swC.Stop()
        if ($fixed -ne $before) {
          $stream.Text = $fixed
          Show-Overlay -Text $fixed
        }
        Say ("  校验耗时 {0} ms" -f $swC.ElapsedMilliseconds) DarkGray
      }

      Say ("→ 上屏：{0}" -f $stream.Text) Green
      Insert-Text -Text $stream.Text -Target $script:target
      Say ("本次共上屏 {0} 字（总 {1} ms）" -f $stream.Text.Length, $sw.ElapsedMilliseconds) DarkGray
      Set-FloatState -State 'ok'
      Start-Sleep -Milliseconds 420
      Hide-Overlay
      Set-FloatState -State 'idle'
      return
    }

    # 非流式路径：直接整段识别，不用 VAD。
    # VAD 切句会在句子中间断开，且会吞掉句首的软起音（实测「我虽然觉得可以了」
    # 被切成「觉得可以了」）。整段识别上下文最完整，准确率明显更好。
    $res = Invoke-Recognition -WavPath $script:RecFile
    $sw.Stop()
    $text = [string]$res.Text

    if ([string]::IsNullOrWhiteSpace($text)) {
      Say ("未识别到内容（{0} ms）" -f $sw.ElapsedMilliseconds) Yellow
      Show-Overlay -Text '（没有识别到内容）'
      Set-FloatState -State 'idle'
      Start-Sleep -Milliseconds 900
      Hide-Overlay
      return
    }

    Say ("→ 识别：{0}   （{1} ms）" -f $text, $sw.ElapsedMilliseconds) Green
    Show-Overlay -Text $text

    if ($script:Cfg.correct) {
      $before = $text
      $swC = [System.Diagnostics.Stopwatch]::StartNew()
      $text = Invoke-Correction -Text $before
      $swC.Stop()
      Say ("  校验耗时 {0} ms" -f $swC.ElapsedMilliseconds) DarkGray
      if ($text -ne $before) { Show-Overlay -Text $text }
    }

    Say ("→ 上屏：{0}" -f $text) Green
    Insert-Text -Text $text -Target $script:target
    Set-FloatState -State 'ok'
    Start-Sleep -Milliseconds 420
    Hide-Overlay
    Set-FloatState -State 'idle'
  } catch {
    Say "识别出错: $($_.Exception.Message)" Red
    Hide-Overlay
    Set-FloatState -State 'idle'
  }
}

function Invoke-ToggleDictation {
  # 纠错等待期间会跑消息泵（为了让悬浮按钮外圈转起来），热键和按钮点击
  # 会从这里重入。必须挡住，否则会在上一条还没处理完时又开一段录音。
  if ($script:Busy) { Say '  正在处理上一条，请稍候…' DarkGray; return }
  if ($script:recording) { Stop-Dictation } else { Start-Dictation }
}

# ═══════════════════════ 生命周期回调 ═══════════════════════

# 设置保存后的回调：重新注册热键 + 重建识别进程
$script:OnSettingsSaved = {
  param($newCfg)
  $oldEngine = $script:Cfg.engine
  $script:Cfg = $newCfg
  if (Register-AllHotkeys) { Say '快捷键已更新' Green } else { Say '快捷键注册失败，请在设置里更换' Red }

  # 引擎/线程/语言/热词任一变化都要重建识别进程：
  # Stop-Worker 是通用的（直接发 exit 并兜底 Kill），旧进程无论哪个引擎都能收掉；
  # 下次 Start-Worker 会按新配置启动正确的引擎。
  Stop-Worker
  if ($oldEngine -ne $script:Cfg.engine) {
    Say ("识别引擎已切换: {0} → {1}" -f `
          $(if ($oldEngine -eq 'qwen3') { 'Qwen3-ASR' } else { 'SenseVoice' }),
          (Get-EngineLabel)) Green
    Say '  下次说话时会自动加载新引擎的模型' DarkGray
  }
  else { Say '  识别进程已释放，下次使用时按新配置启动' DarkGray }

  # 悬浮按钮：按新设置显示/隐藏并调整大小
  if ($script:Cfg.showFloat) {
    if (-not $script:FloatBtn) {
      Start-FloatButton
      if (-not $script:PulseTimer) {
        $script:PulseTimer = [System.Windows.Forms.Timer]::new()
        $script:PulseTimer.Interval = 40    # 25fps；原来 110ms(≈9fps) 太卡，呼吸看着像在闪
        $script:PulseTimer.Add_Tick({ Update-FloatPulse })
      }
      $script:PulseTimer.Start()
    } else { Show-FloatButton }
    Apply-FloatSize
  } else { Hide-FloatButton }

  Say '设置已保存并生效' Green
}

$script:OnExitRequest = {
  Say '正在退出…' DarkGray
  # PostQuitMessage 会让主循环里的 GetMessage 返回 0，从而正常跳出并走 finally 清理
  [VTNative]::PostQuitMessage(0)
}

try {
  Say ('─' * 60) DarkGray
  Say 'voice-typer  全局语音输入 · 本地识别 · 音频不出本机' Green
  Say ('─' * 60) DarkGray

  Start-Tray -Config $script:Cfg
  if (-not (Register-AllHotkeys)) {
    Show-Balloon -Title 'voice-typer' -Text '快捷键注册失败，请在托盘图标上点「设置」更换' -Kind Warning
  }
  Say '托盘图标已就绪（右下角，左键点击打开设置）' DarkGray

  # ── 悬浮按钮：点一下开始/停止听写，可拖动，按状态变色 ──
  $script:OnFloatToggle   = { Invoke-ToggleDictation }
  $script:OnFloatSettings = { Show-SettingsDialog -Config (Get-Config) }
  if ($script:Cfg.showFloat) {
    Start-FloatButton
    Say '悬浮按钮已就绪（可拖动到任意位置，点一下开始听写）' DarkGray
    $script:PulseTimer = [System.Windows.Forms.Timer]::new()
    $script:PulseTimer.Interval = 40    # 25fps；原来 110ms(≈9fps) 太卡，呼吸看着像在闪
    $script:PulseTimer.Add_Tick({ Update-FloatPulse })
    $script:PulseTimer.Start()
  }

  Say '预热识别模型…' DarkGray
  try { Start-Worker; Say "模型就绪（$($script:Cfg.lang) / $($script:Cfg.threads) 线程）" Green }
  catch { Say "预热失败: $($_.Exception.Message)" Yellow; Show-Balloon -Title 'voice-typer' -Text "模型加载失败: $($_.Exception.Message)" -Kind Error }

  if ($script:Cfg.notifyOnStart -or $Notify) {
    Show-Balloon -Title 'voice-typer 已启动' -Text "按 $($script:Cfg.hotkeyToggle) 开始说话；点悬浮按钮也可以" -Kind Info
  }

  if ($ShowSettings) { Show-SettingsDialog -Config $script:Cfg | Out-Null }

  $msg = New-Object VTNative+MSG
  while ($true) {
    if (-not [VTNative]::GetMessage([ref]$msg, [IntPtr]::Zero, 0, 0)) { break }
    if ($msg.message -ne 0x0312) {
      [void][VTNative]::TranslateMessage([ref]$msg)
      [void][VTNative]::DispatchMessage([ref]$msg)
      continue
    }
    [void][VTNative]::TranslateMessage([ref]$msg)
    [void][VTNative]::DispatchMessage([ref]$msg)
    $id = [int]$msg.wParam

    if ($id -eq $ID_CANCEL) {
      if ($recording) { Stop-Dictation -Cancel }
      continue
    }
    if ($id -ne $ID_TOGGLE) { continue }
    Invoke-ToggleDictation
  }
}
finally {
  if ($script:PulseTimer) { $script:PulseTimer.Stop() }
  if ($script:StreamTimer) { $script:StreamTimer.Stop() }
  $script:Streaming = $null
  Unregister-AllHotkeys
  Stop-FloatButton
  Stop-Tray
  if ($recording) { Stop-Recording -Silent }
  Stop-Worker
  Remove-Item $script:RecFile -Force -ErrorAction SilentlyContinue
  Say 'voice-typer 已退出' DarkGray
}
