# 豆包云端会话：UI 线程只轮询已完成的读取任务，网络工作在 Node worker 中。
$script:Doubao = $null
$script:DoubaoRead = $null
$script:DoubaoPumpBusy = $false
$script:DoubaoTimer = $null

function New-DoubaoRequest {
  param($Config, [string]$Session, [string]$Command = 'start')
  return @{
    cmd = $Command; session = $Session; mode = [string]$Config.doubaoMode
    resourceId = [string]$Config.doubaoResourceId
    options = @{
      enable_nonstream = [bool]$Config.doubaoNonstream
      enable_itn = $true; enable_punc = $true; enable_ddc = $false
      show_utterances = $true; result_type = 'full'
      end_window_size = [int]$Config.doubaoEndWindowMs
      hotwords = [string]$Config.doubaoHotwords
      timeoutMs = [int]$Config.doubaoTimeoutMs
    }
  }
}

function Send-DoubaoCommand {
  param($Command)
  if (-not $script:Worker -or $script:Worker.HasExited) { throw '豆包通信进程已退出' }
  $script:Worker.StandardInput.WriteLine(($Command | ConvertTo-Json -Depth 8 -Compress))
  $script:Worker.StandardInput.Flush()
}

function Send-DoubaoAudio {
  param([byte[]]$Data)
  if (-not $Data -or $Data.Length -eq 0) { return }
  for ($offset = 0; $offset -lt $Data.Length; $offset += 6400) {
    $length = [Math]::Min(6400, $Data.Length - $offset)
    Send-DoubaoCommand @{ cmd = 'audio'; session = $script:Doubao.Id; data = [Convert]::ToBase64String($Data, $offset, $length) }
  }
}

function Get-DoubaoConfirmedText {
  param($Segments)
  return ((@($Segments) | Where-Object { $_.definite } | ForEach-Object { [string]$_.text }) -join '')
}

function Receive-DoubaoEvent {
  param($Event)
  $s = $script:Doubao
  if (-not $s -or [string]$Event.session -ne $s.Id -or $s.Cancelled) { return }
  switch ([string]$Event.event) {
    'connected' { $s.Connected = $true; $s.ConnectedMs = $s.Clock.ElapsedMilliseconds }
    'error' { $s.Error = [string]$Event.error; $s.Done = $true }
    { $_ -in 'result','finished' } {
      if ($Event.text) {
        $s.Text = [string]$Event.text
        if ($null -eq $s.FirstResultMs) { $s.FirstResultMs = $s.Clock.ElapsedMilliseconds }
      }
      if ($null -ne $Event.segments) { $s.Segments = @($Event.segments) }
      if ([string]$Event.event -eq 'finished') { $s.Done = $true }
      # 预览允许更新，目标窗口只接收最终确定且尚未提交的内容。
      if ($s.Config.streaming -and -not $s.Config.correct -and -not $s.Finishing) {
        Submit-DoubaoSegments -Session $s
      }
      if ($s.Text) { Show-Overlay -Text $s.Text }
    }
  }
}

function Submit-DoubaoSegments {
  param($Session)
  foreach ($seg in @($Session.Segments)) {
    if (-not $seg.definite -or [string]::IsNullOrWhiteSpace([string]$seg.text)) { continue }
    $key = '{0}:{1}' -f $seg.start, $seg.end
    if ($Session.Committed.ContainsKey($key)) {
      if ($Session.Committed[$key] -ne [string]$seg.text) { throw '服务端修改了已确定分句；已停止追加以避免重复' }
      continue
    }
    Insert-Text -Text ([string]$seg.text) -Target $script:target -NoRestore
    $Session.Committed[$key] = [string]$seg.text
    $Session.CommittedText += [string]$seg.text
  }
}

function Update-DoubaoSession {
  if ($script:DoubaoPumpBusy -or -not $script:Doubao) { return }
  $script:DoubaoPumpBusy = $true
  try {
    $s = $script:Doubao
    if (-not $s.Cancelled -and -not $s.Done -and $s.Capture) {
      Send-DoubaoAudio -Data ($s.Capture.Drain())
    }
    # 限制单次处理数量，避免大量响应饿死界面和热键。
    for ($i = 0; $i -lt 100; $i++) {
      if (-not $script:DoubaoRead) { $script:DoubaoRead = $script:Worker.StandardOutput.ReadLineAsync() }
      if (-not $script:DoubaoRead.IsCompleted) { break }
      $line = $script:DoubaoRead.GetAwaiter().GetResult()
      $script:DoubaoRead = $null
      if ($null -eq $line) {
        if (-not $s.Done -and -not $s.Cancelled) { throw '豆包通信进程意外退出' }
        break
      }
      if (-not $line.Trim()) { continue }
      $event = $line | ConvertFrom-Json
      Receive-DoubaoEvent -Event $event
    }
  } catch {
    $script:Doubao.Error = $_.Exception.Message
    $script:Doubao.Done = $true
  } finally { $script:DoubaoPumpBusy = $false }
}

function Invoke-DoubaoMessages {
  # 不能用 DoEvents 吞掉 WM_HOTKEY；等待收尾期间仍可取消，切换键只被忽略。
  $msg = New-Object VTNative+MSG
  while ([VTNative]::PeekMessage([ref]$msg, [IntPtr]::Zero, 0, 0, 1)) {
    if ($msg.message -eq 0x0312) {
      if ([int]$msg.wParam -eq $ID_CANCEL -and $script:Doubao) { $script:Doubao.Cancelled = $true }
      continue
    }
    [void][VTNative]::TranslateMessage([ref]$msg)
    [void][VTNative]::DispatchMessage([ref]$msg)
  }
}

function Start-DoubaoDictation {
  $script:Busy = $true
  try {
    Start-Worker
    if (-not ('VTPcmRecorder' -as [type])) { Add-Type -Path (Join-Path $AppDir 'audio-capture.cs') }
    $cfg = [ordered]@{}
    foreach ($key in $script:Cfg.Keys) { $cfg[$key] = $script:Cfg[$key] }
    $script:target = [VTNative]::GetForegroundWindow()
    $script:Doubao = [pscustomobject]@{
      Id = [guid]::NewGuid().ToString(); Config = $cfg
      Capture = [VTPcmRecorder]::new(); Clock = [Diagnostics.Stopwatch]::StartNew()
      Text = ''; Segments = @(); Committed = @{}; CommittedText = ''
      Connected = $false; Done = $false; Error = ''; Cancelled = $false; Finishing = $false
      ConnectedMs = $null; FirstResultMs = $null
    }
    Send-DoubaoCommand (New-DoubaoRequest -Config $cfg -Session $script:Doubao.Id)
    $script:Doubao.Capture.Start()
    $script:recording = $true
    Register-CancelHotkey
    if (-not $script:DoubaoTimer) {
      $script:DoubaoTimer = [Windows.Forms.Timer]::new()
      $script:DoubaoTimer.Interval = 200
      $script:DoubaoTimer.Add_Tick({
        Update-DoubaoSession
        if ($script:Doubao -and $script:recording -and $script:Doubao.Done) {
          Stop-DoubaoDictation
        }
      })
    }
    $script:DoubaoTimer.Start()
    Set-FloatState -State 'recording'
    Show-Overlay -Text '● 豆包云端正在聆听…'
    Say ('● 豆包{0}：音频将发送至豆包云端' -f $(if ($cfg.doubaoMode -eq 'realtime') { '实时识别' } else { '一句话识别' })) Red
  } catch {
    if ($script:Doubao) {
      try { Send-DoubaoCommand @{ cmd = 'cancel'; session = $script:Doubao.Id } } catch { }
      try { $script:Doubao.Capture.Dispose() } catch { }
    }
    $script:Doubao = $null
    $script:recording = $false
    Unregister-CancelHotkey
    Set-FloatState -State 'idle'
    Show-Balloon -Title '豆包识别无法开始' -Text $_.Exception.Message -Kind Error
    Say $_.Exception.Message Red
  } finally { $script:Busy = $false }
}

function Stop-DoubaoDictation {
  param([switch]$Cancel)
  $s = $script:Doubao
  if (-not $s -or $s.Finishing) { return }
  $s.Finishing = $true
  $script:Busy = $true
  $script:recording = $false
  if ($script:DoubaoTimer) { $script:DoubaoTimer.Stop() }
  try {
    $s.Capture.Stop()
    if ($Cancel) { $s.Cancelled = $true }
    if (-not $s.Cancelled -and -not $s.Done) {
      Send-DoubaoAudio -Data ($s.Capture.Drain())
      Send-DoubaoCommand @{ cmd = 'finish'; session = $s.Id }
      Set-FloatState -State 'working'
      Register-CancelHotkey
      Show-Overlay -Text '豆包正在确认最终结果…'
      $wait = [Diagnostics.Stopwatch]::StartNew()
      while (-not $s.Done -and -not $s.Cancelled -and $wait.ElapsedMilliseconds -lt ([int]$s.Config.doubaoTimeoutMs + 2000)) {
        Update-DoubaoSession
        Invoke-DoubaoMessages
        Start-Sleep -Milliseconds 15
      }
      if (-not $s.Done -and -not $s.Cancelled) { throw '豆包最终结果等待超时' }
      Say ('豆包停录后等待 {0} ms；首段文字 {1} ms' -f $wait.ElapsedMilliseconds, $s.FirstResultMs) DarkGray
    }
    if ($s.Cancelled) {
      Send-DoubaoCommand @{ cmd = 'cancel'; session = $s.Id }
      Say '已取消豆包识别，已粘贴的内容保留' Yellow
      Hide-Overlay
      return
    }
    if ($s.Error) { throw $s.Error }
    if ([string]::IsNullOrWhiteSpace($s.Text)) {
      Show-Overlay -Text '（没有识别到内容）'
      Set-FloatState -State 'idle'
      Start-Sleep -Milliseconds 900
      Hide-Overlay
      return
    }
    # 流式逐句提交后，只补最终已确认的剩余部分；不会重新粘贴全文。
    if ($s.Config.streaming -and -not $s.Config.correct) {
      Submit-DoubaoSegments -Session $s
      if ($s.Text.StartsWith($s.CommittedText)) {
        $tail = $s.Text.Substring($s.CommittedText.Length)
        if ($tail) { Insert-Text -Text $tail -Target $script:target }
      } elseif ($s.Text -ne $s.CommittedText) {
        throw '最终文本与已粘贴内容不一致，已保留结果并停止追加'
      }
    } else {
      $text = $s.Text
      Unregister-CancelHotkey
      # Invoke-Correction 自行管理 Busy；结束后立即恢复整段收尾保护。
      $script:Busy = $false
      try { if ($s.Config.correct) { $text = Invoke-Correction -Text $text } }
      finally { $script:Busy = $true }
      if ($text) { Show-Overlay -Text $text; Insert-Text -Text $text -Target $script:target }
    }
    Set-FloatState -State 'ok'
    Say ('豆包完成：{0} 字' -f $s.Text.Length) Green
    Start-Sleep -Milliseconds 420
    Hide-Overlay
  } catch {
    $reason = $_.Exception.Message
    Say ('豆包识别失败：{0}' -f $reason) Red
    Show-Balloon -Title '豆包识别失败' -Text $reason -Kind Error
    if ($s.Text) {
      # 保留内存中的最新结果供用户手动恢复，不自动粘贴未确定的中间结果。
      $script:DoubaoRecoveryText = $s.Text
      Show-Overlay -Text ("识别未正常完成：{0}`r`n{1}" -f $reason, $s.Text)
    } else { Show-Overlay -Text ('豆包识别失败：' + $reason) }
    Start-Sleep -Milliseconds 1200
    Hide-Overlay
  } finally {
    try { Send-DoubaoCommand @{ cmd = 'cancel'; session = $s.Id } } catch { }
    try { $s.Capture.Dispose() } catch { Say $_.Exception.Message Yellow }
    Unregister-CancelHotkey
    $script:Doubao = $null
    $script:Busy = $false
    Set-FloatState -State 'idle'
    if ($script:PendingCloudConfig) {
      $pending = $script:PendingCloudConfig; $script:PendingCloudConfig = $null
      & $script:OnSettingsSaved $pending
    }
  }
}

function Invoke-DoubaoFileTest {
  param($Config)
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = Get-NodeExe
  $psi.ArgumentList.Add((Join-Path $AppDir 'worker_doubao.mjs'))
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
  $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
  $psi.Environment['VT_DOUBAO_KEY_NAME'] = [string]$Config.doubaoKeyName
  $p = [Diagnostics.Process]::Start($psi)
  $errTask = $p.StandardError.ReadToEndAsync()
  $id = [guid]::NewGuid().ToString()
  $request = New-DoubaoRequest -Config $Config -Session $id -Command 'recognize'
  $request.wav = Join-Path $AppDir 'test.wav'
  $clock = [Diagnostics.Stopwatch]::StartNew()
  $first = $null; $connected = $null; $text = ''; $sent = $false
  $oldBusy = $script:Busy; $script:Busy = $true
  try {
    $read = $p.StandardOutput.ReadLineAsync()
    while ($clock.Elapsed.TotalSeconds -lt 45) {
      Invoke-DoubaoMessages
      if (-not $read.IsCompleted) { Start-Sleep -Milliseconds 15; continue }
      $line = $read.GetAwaiter().GetResult()
      if ($null -eq $line) { throw '豆包测试进程已退出' }
      $e = $line | ConvertFrom-Json
      if ($e.event -eq 'ready' -and -not $sent) {
        $p.StandardInput.WriteLine(($request | ConvertTo-Json -Depth 8 -Compress)); $p.StandardInput.Flush(); $sent = $true
      }
      if ($e.session -eq $id) {
        if ($e.event -eq 'error') { throw [string]$e.error }
        if ($e.event -eq 'connected') { $connected = $clock.ElapsedMilliseconds }
        if ($e.text) { $text = [string]$e.text; if ($null -eq $first) { $first = $clock.ElapsedMilliseconds } }
        if ($e.event -eq 'finished') {
          return ('✔ 测试成功：密钥、模型与网络均正常。连接 {0} ms，首次文字 {1} ms，总计 {2} ms（含按实际时长发送音频）。' -f $connected, $first, $clock.ElapsedMilliseconds) +
                 "`r`n（下面这句是软件内置样例音频 test.wav 的识别内容，用于证明识别可用，不是报错）`r`n识别结果：$text"
        }
      }
      $read = $p.StandardOutput.ReadLineAsync()
    }
    throw '豆包测试超时'
  } finally {
    $script:Busy = $oldBusy
    try { $p.StandardInput.WriteLine('{"cmd":"exit"}'); $p.StandardInput.Flush() } catch { }
    if (-not $p.WaitForExit(1000)) { $p.Kill() }
    $p.Dispose()
  }
}

$script:OnDoubaoTest = { param($Config) Invoke-DoubaoFileTest -Config $Config }
