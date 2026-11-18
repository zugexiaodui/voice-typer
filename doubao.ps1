# 豆包云端会话：stdout 由 worker-pipe.ps1 的后台泵持续排空，UI 线程只从有界队列取已完成事件；
# 音频发送走有界写队列 + 后台 writer，网络工作在 Node worker 中。
$script:Doubao = $null
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
  # 有界后台写：UI 最多等 5 秒，超时/管道故障都会抛出明确错误，不会永久卡住消息循环。
  Send-WorkerLine -Line ($Command | ConvertTo-Json -Depth 8 -Compress) -TimeoutMs 5000
}

function Send-DoubaoAudio {
  param([byte[]]$Data)
  if (-not $Data -or $Data.Length -eq 0) { return }
  for ($offset = 0; $offset -lt $Data.Length; $offset += 6400) {
    $length = [Math]::Min(6400, $Data.Length - $offset)
    Send-DoubaoCommand @{ cmd = 'audio'; session = $script:Doubao.Id; data = [Convert]::ToBase64String($Data, $offset, $length) }
  }
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

function Receive-DoubaoLines {
  # 从桥队列取行并交给会话。WaitMs>0 时在 BudgetMs 内反复等后台泵入队，
  # 用于进程退出后给 reader 一个有界排空窗口；WaitMs=0 时保持 UI 轮询不阻塞。
  param($Session, [int]$MaxLines = 100, [int]$BudgetMs = 50, [int]$WaitMs = 0)
  $slice = [Diagnostics.Stopwatch]::StartNew()
  $status = 1
  for ($i = 0; $i -lt $MaxLines; $i++) {
    $line = $null
    $status = $script:WorkerPipe.ReadLine($WaitMs, [ref]$line)
    if ($status -eq 1) {
      if ($WaitMs -le 0 -or $slice.ElapsedMilliseconds -ge $BudgetMs) { break }
      continue
    }
    if ($status -ne 0) { return $status }
    if ($line.Trim()) {
      $event = $line | ConvertFrom-Json
      [void](Receive-DoubaoEvent -Event $event)
      if ($Session.Cancelled -or $Session.Done) { return $status }
    }
    if ($slice.ElapsedMilliseconds -ge $BudgetMs) { break }
  }
  return $status
}

function Update-DoubaoSession {
  if ($script:DoubaoPumpBusy -or -not $script:Doubao) { return }
  $script:DoubaoPumpBusy = $true
  try {
    $s = $script:Doubao
    # 先消费已经到达/仍在后台泵里的结果，再发送音频：worker 写完 finished 后立刻退出时，
    # 必须让最终结果优先于 HasExited/EOF，否则会把队列里的成功结果误判成通信失败。
    $readStatus = Receive-DoubaoLines -Session $s -MaxLines 100 -BudgetMs 50
    if ($readStatus -eq 3) { throw ('豆包通信进程读取失败：' + $script:WorkerPipe.LastError) }
    if ($readStatus -eq 2 -and -not $s.Done -and -not $s.Cancelled) { throw '豆包通信进程意外退出' }
    if (-not $s.Cancelled -and -not $s.Done -and $s.Capture) {
      Send-DoubaoAudio -Data ($s.Capture.Drain())
    }
  } catch {
    $s = $script:Doubao
    $reason = $_.Exception.Message
    # 读完队列与发送之间仍有竞态：进程可能已退出并写出 finished，但 reader 尚未入队。
    # 给后台泵一个有界排空机会，只在错误路径付出这段等待（最多约 300ms / 1024 行）。
    if ($s -and -not $s.Done -and -not $s.Cancelled -and $script:WorkerPipe) {
      try { [void](Receive-DoubaoLines -Session $s -MaxLines 1024 -BudgetMs 300 -WaitMs 20) } catch { }
    }
    if ($s -and -not $s.Done) {
      # 没有收到 finished/error：明确失败，保留已到达的最新文本，不把部分结果当成功。
      $s.Error = $reason
      $s.Done = $true
    }
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
    # 管道已坏/EOF 时旧 worker 无法再复用；当场收掉，下一次 Start-Worker 会重建。
    if ($script:WorkerPipe -and ($script:WorkerPipe.IsFaulted -or $script:WorkerPipe.IsEnded)) { Stop-Worker }
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

function Invoke-DoubaoStreamingTest {
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
  try { $pipe = New-WorkerPipe -Process $p }
  catch { try { $p.Kill() } catch { }; $p.Dispose(); throw }
  $errTask = $p.StandardError.ReadToEndAsync()
  $id = [guid]::NewGuid().ToString()
  $request = New-DoubaoRequest -Config $Config -Session $id -Command 'recognize'
  $request.wav = Join-Path $AppDir 'test.wav'
  $clock = [Diagnostics.Stopwatch]::StartNew()
  $first = $null; $connected = $null; $text = ''; $sent = $false
  $oldBusy = $script:Busy; $script:Busy = $true
  try {
    while ($clock.Elapsed.TotalSeconds -lt 45) {
      Invoke-DoubaoMessages
      $line = $null
      $status = $pipe.ReadLine(20, [ref]$line)
      if ($status -eq 1) { continue }
      if ($status -eq 3) { throw ('豆包测试进程读取失败：' + $pipe.LastError) }
      if ($status -eq 2) { throw '豆包测试进程已退出' }
      $e = $line | ConvertFrom-Json
      if ($e.event -eq 'ready' -and -not $sent) {
        $pipe.WriteLine(($request | ConvertTo-Json -Depth 8 -Compress), 5000); $sent = $true
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
    }
    throw '豆包测试超时'
  } finally {
    $script:Busy = $oldBusy
    try { $pipe.WriteLine('{"cmd":"exit"}', 750) } catch { }
    if (-not $p.WaitForExit(1000)) { try { $p.Kill() } catch { } }
    try { $pipe.Dispose() } catch { }
    $p.Dispose()
  }
}

$script:OnDoubaoStreamingTest = { param($Config) Invoke-DoubaoStreamingTest -Config $Config }
