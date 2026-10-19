# 腾讯混元云端识别：录音全程在内存中（waveIn），不写任何文件。
# 与豆包不同，混元是"整段识别"：停止录音后一次性把 PCM 交给 worker。
$script:Hunyuan              = $null
$script:HunyuanRead          = $null
$script:HunyuanBusy          = $false
$script:HunyuanRecoveryText  = ''

function New-HunyuanRequest {
  param($Config, [string]$Session)
  return @{
    cmd       = 'recognize'
    session   = $Session
    model     = [string]$Config.hunyuanModel
    timeoutMs = [int]$Config.hunyuanTimeoutMs
  }
}

function Send-HunyuanCommand {
  param($Command)
  if (-not $script:Worker -or $script:Worker.HasExited) { throw '混元通信进程已退出' }
  $script:Worker.StandardInput.WriteLine(($Command | ConvertTo-Json -Depth 6 -Compress))
  $script:Worker.StandardInput.Flush()
}

# 读取 worker 已到达的输出；返回 $true 表示本次识别已到终态。
function Update-HunyuanResult {
  if (-not $script:Hunyuan -or $script:HunyuanBusy) { return $false }
  $script:HunyuanBusy = $true
  $done = $false
  try {
    for ($i = 0; $i -lt 200; $i++) {
      if (-not $script:HunyuanRead) { $script:HunyuanRead = $script:Worker.StandardOutput.ReadLineAsync() }
      if (-not $script:HunyuanRead.IsCompleted) { break }
      $line = $script:HunyuanRead.GetAwaiter().GetResult()
      $script:HunyuanRead = $null
      if ($null -eq $line) { throw '混元通信进程意外退出' }
      if (-not $line.Trim()) { continue }
      try { $e = $line | ConvertFrom-Json } catch { continue }
      if ($e.event -eq 'ready') { continue }
      if ([string]$e.session -ne $script:Hunyuan.Id) { continue }
      switch ([string]$e.event) {
        'finished' {
          $script:Hunyuan.Text       = [string]$e.text
          $script:Hunyuan.Segments   = @($e.segments)
          $script:Hunyuan.DurationMs = $e.durationMs
          $script:Hunyuan.Done       = $true
          $done = $true
        }
        'error' {
          $script:Hunyuan.Error = [string]$e.error
          $script:Hunyuan.Code  = [string]$e.code
          $script:Hunyuan.Done  = $true
          $done = $true
        }
      }
      if ($done) { break }
    }
  } finally { $script:HunyuanBusy = $false }
  return $done
}

function Invoke-HunyuanMessages {
  # 收尾等待期间仍允许按取消键；不能用 DoEvents（会吞掉 WM_HOTKEY）。
  $msg = New-Object VTNative+MSG
  while ([VTNative]::PeekMessage([ref]$msg, [IntPtr]::Zero, 0, 0, 1)) {
    if ($msg.message -eq 0x0312) {
      if ([int]$msg.wParam -eq $ID_CANCEL -and $script:Hunyuan) { $script:Hunyuan.Cancelled = $true }
      continue
    }
    [void][VTNative]::TranslateMessage([ref]$msg)
    [void][VTNative]::DispatchMessage([ref]$msg)
  }
}

function Start-HunyuanDictation {
  $script:Busy = $true
  try {
    Start-Worker
    if (-not ('VTPcmRecorder' -as [type])) { Add-Type -Path (Join-Path $AppDir 'audio-capture.cs') }

    # 配置快照：本次录音期间不受设置变更影响。
    $cfg = [ordered]@{}
    foreach ($key in $script:Cfg.Keys) { $cfg[$key] = $script:Cfg[$key] }

    $script:target = [VTNative]::GetForegroundWindow()
    $script:Hunyuan = [pscustomobject]@{
      Id         = [guid]::NewGuid().ToString()
      Config     = $cfg
      Capture    = [VTPcmRecorder]::new()
      Clock      = [Diagnostics.Stopwatch]::StartNew()
      Text       = ''
      Segments   = @()
      DurationMs = 0
      Done       = $false
      Error      = ''
      Code       = ''
      Cancelled  = $false
      Finishing  = $false
    }
    # 纯内存采集：PCM 只进 Queue<byte[]>，不创建任何文件。
    $script:Hunyuan.Capture.Start()
    $script:recording = $true
    Register-CancelHotkey
    Set-FloatState -State 'recording'
    Show-Overlay -Text '● 混元云端正在聆听…（录音仅在内存中）'
    Say '● 混元识别中：音频仅在内存，识别后发送至腾讯混元' Red
  } catch {
    if ($script:Hunyuan) { try { $script:Hunyuan.Capture.Dispose() } catch { } }
    $script:Hunyuan = $null
    $script:recording = $false
    Unregister-CancelHotkey
    Set-FloatState -State 'idle'
    Show-Balloon -Title '混元识别无法开始' -Text $_.Exception.Message -Kind Error
    Say $_.Exception.Message Red
  } finally { $script:Busy = $false }
}

function Stop-HunyuanDictation {
  param([switch]$Cancel)
  $s = $script:Hunyuan
  if (-not $s) { return }
  # 防御：即使对象缺字段（历史遗留/异常构造），也绝不重复进入或抛出到调用方。
  try {
    if ($s.PSObject.Properties['Finishing'] -and $s.Finishing) { return }
    $s | Add-Member -NotePropertyName Finishing -NotePropertyValue $true -Force
  } catch { return }

  $script:Busy  = $true
  $script:recording = $false
  Unregister-CancelHotkey

  try {
    # 停止采集，取出全部 PCM（仍在内存中）。
    $s.Capture.Stop()
    $pcm = $s.Capture.Drain()

    if ($Cancel) {
      $s.Cancelled = $true
      Say '已取消混元识别' Yellow
      Hide-Overlay
      return
    }
    if (-not $pcm -or $pcm.Length -lt 6400) {
      Show-Overlay -Text '（录音太短）'
      Set-FloatState -State 'idle'
      Start-Sleep -Milliseconds 900
      Hide-Overlay
      return
    }

    Set-FloatState -State 'working'
    Show-Overlay -Text '混元正在识别…'
    $req = New-HunyuanRequest -Config $s.Config -Session $s.Id
    # 关键：裸 base64（无 data: 前缀），worker 内部作为 JSON 的 data 字段发出。
    $req.pcm = [Convert]::ToBase64String($pcm)

    $sendClock = [Diagnostics.Stopwatch]::StartNew()
    Send-HunyuanCommand $req

    Register-CancelHotkey
    while (-not $s.Done -and -not $s.Cancelled -and $sendClock.ElapsedMilliseconds -lt ([int]$s.Config.hunyuanTimeoutMs + 5000)) {
      [void](Update-HunyuanResult)
      Invoke-HunyuanMessages
      if ($s.Done -or $s.Cancelled) { break }
      Start-Sleep -Milliseconds 20
    }

    if ($s.Cancelled) {
      Say '已取消混元识别（结果已丢弃）' Yellow
      Hide-Overlay
      return
    }
    if (-not $s.Done) { throw '混元识别等待超时' }
    if ($s.Error) { throw ('混元识别失败：' + $s.Error + $(if ($s.Code) { "（$($s.Code)）" } else { '' })) }
    if ([string]::IsNullOrWhiteSpace($s.Text)) {
      Show-Overlay -Text '（没有识别到内容）'
      Set-FloatState -State 'idle'
      Start-Sleep -Milliseconds 900
      Hide-Overlay
      return
    }

    $text = $s.Text
    Say ('混元识别完成：{0} 字 / 音频 {1:N1}s / 用时 {2:N0}ms' -f `
          $text.Length, ($pcm.Length / 32000.0), $sendClock.ElapsedMilliseconds) DarkGray

    # 复用现有收尾 AI 校验（与混元自身识别完全独立）。
    Unregister-CancelHotkey
    $script:Busy = $false
    try { if ($s.Config.correct) { $text = Invoke-Correction -Text $text } }
    finally { $script:Busy = $true }
    Unregister-CancelHotkey

    if ($text) {
      Show-Overlay -Text $text
      Insert-Text -Text $text -Target $script:target
      Say ('→ 上屏：{0}' -f $text) Green
    }
    Set-FloatState -State 'ok'
    Start-Sleep -Milliseconds 420
    Hide-Overlay
  } catch {
    $reason = $_.Exception.Message
    Say $reason Red
    Show-Balloon -Title '混元识别失败' -Text $reason -Kind Error
    if ($s.Text) { $script:HunyuanRecoveryText = $s.Text }
    Show-Overlay -Text $reason
    Start-Sleep -Milliseconds 1200
    Hide-Overlay
  } finally {
    try { $s.Capture.Dispose() } catch { Say $_.Exception.Message Yellow }
    Unregister-CancelHotkey
    $script:Hunyuan = $null
    $script:Busy    = $false
    Set-FloatState -State 'idle'
    if ($script:PendingCloudConfig) {
      $pending = $script:PendingCloudConfig; $script:PendingCloudConfig = $null
      & $script:OnSettingsSaved $pending
    }
  }
}

# 用 test.wav 走一次真实请求，验证密钥、模型与网络（该测试会读本地文件，仅测试用）。
function Invoke-HunyuanFileTest {
  param($Config)
  $wav = Join-Path $AppDir 'test.wav'
  if (-not (Test-Path $wav)) { throw "缺少测试音频 $wav" }

  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = Get-NodeExe
  $psi.ArgumentList.Add((Join-Path $AppDir 'worker_hunyuan.mjs'))
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardInputEncoding  = [Text.UTF8Encoding]::new($false)
  $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
  $psi.Environment['VT_HUNYUAN_KEY_NAME'] = [string]$Config.hunyuanKeyName

  $p = [Diagnostics.Process]::Start($psi)
  $null = $p.StandardError.ReadToEndAsync()
  $id = [guid]::NewGuid().ToString()
  $req = New-HunyuanRequest -Config $Config -Session $id
  $req.wav = $wav
  $clock = [Diagnostics.Stopwatch]::StartNew()
  $oldBusy = $script:Busy; $script:Busy = $true
  $sent = $false
  try {
    $read = $p.StandardOutput.ReadLineAsync()
    while ($clock.Elapsed.TotalSeconds -lt 150) {
      Invoke-HunyuanMessages
      if (-not $read.IsCompleted) { Start-Sleep -Milliseconds 15; continue }
      $line = $read.GetAwaiter().GetResult()
      if ($null -eq $line) { throw '混元测试进程已退出' }
      try { $e = $line | ConvertFrom-Json } catch { $read = $p.StandardOutput.ReadLineAsync(); continue }
      if ($e.event -eq 'ready' -and -not $sent) {
        $p.StandardInput.WriteLine(($req | ConvertTo-Json -Depth 6 -Compress)); $p.StandardInput.Flush(); $sent = $true
      }
      if ([string]$e.session -eq $id) {
        if ($e.event -eq 'error') { throw ('{0}（{1}）' -f $e.error, $e.code) }
        if ($e.event -eq 'finished') {
          return ('✔ 测试成功：密钥、模型与网络均正常。耗时 {0} ms，音频 {1}s，计费 {2} token。' -f `
                  $clock.ElapsedMilliseconds, [math]::Round(([double]$e.durationMs / 1000), 2), $e.tokens) +
                 "`r`n（下面这句是软件内置样例音频 test.wav 的识别内容，用于证明识别可用，不是报错）`r`n识别结果：$($e.text)"
        }
      }
      $read = $p.StandardOutput.ReadLineAsync()
    }
    throw '混元测试超时'
  } finally {
    $script:Busy = $oldBusy
    try { $p.StandardInput.WriteLine('{"cmd":"exit"}'); $p.StandardInput.Flush() } catch { }
    if (-not $p.WaitForExit(1500)) { try { $p.Kill() } catch { } }
    $p.Dispose()
  }
}

$script:OnHunyuanTest = { param($Config) Invoke-HunyuanFileTest -Config $Config }
