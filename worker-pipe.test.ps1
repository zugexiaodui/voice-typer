# Windows/offline integration tests for worker-pipe.ps1 (the production stdio bridge).
# No network, credentials, microphone, or real service is touched. Run from the repo root:
#   pwsh -NoProfile -File .\worker-pipe.test.ps1
$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
. (Join-Path $repo 'worker-pipe.ps1')
. (Join-Path $repo 'doubao.ps1')
. (Join-Path $repo 'hunyuan.ps1')

$script:TestOverlayTexts = [System.Collections.Generic.List[string]]::new()
function Show-Overlay { param([string]$Text) $script:TestOverlayTexts.Add([string]$Text) }
function Submit-DoubaoSegments { param($Session) }
function Say { param([string]$Text, [string]$Color = 'Gray') }

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}
function Write-Pass { param([string]$Name) Write-Host ("PASS  {0}" -f $Name) -ForegroundColor Green }

function Get-NodePath {
  $cmd = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  throw 'node.exe not found on PATH'
}

function Start-Mock {
  param(
    [string]$Mode = 'normal',
    [int]$LineBytes = 70000,
    [int]$BurstLines = 10,
    [int]$DelayMs = 3000,
    [int]$QueueBytes = 4 * 1024 * 1024,
    [int]$QueueLines = 1024,
    [int]$MaxWriteBytes = 4 * 1024 * 1024,
    [int]$MaxWriteCount = 256,
    [int]$OverflowWaitMs = 5000,
    [bool]$PreResult = $false
  )
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = Get-NodePath
  $psi.ArgumentList.Add((Join-Path $repo 'worker-pipe-mock.mjs'))
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
  $psi.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
  $psi.Environment['VT_MOCK_MODE'] = $Mode
  $psi.Environment['VT_MOCK_LINE_BYTES'] = "$LineBytes"
  $psi.Environment['VT_MOCK_BURST_LINES'] = "$BurstLines"
  $psi.Environment['VT_MOCK_DELAY_MS'] = "$DelayMs"
  $psi.Environment['VT_MOCK_PRE_RESULT'] = $(if ($PreResult) { '1' } else { '0' })
  $p = [Diagnostics.Process]::Start($psi)
  $errTask = $p.StandardError.ReadToEndAsync()
  $pipe = [VTWorkerPipe]::new($p.StandardOutput, $p.StandardInput.BaseStream,
    $QueueBytes, $QueueLines, $MaxWriteBytes, $MaxWriteCount, $OverflowWaitMs)
  return [pscustomobject]@{ Process = $p; Pipe = $pipe; ErrTask = $errTask }
}

function Read-Ready {
  param($Ctx, [int]$TimeoutMs = 5000)
  $line = $null
  $status = $Ctx.Pipe.ReadLine($TimeoutMs, [ref]$line)
  Assert-True ($status -eq 0) "expected ready line, got status $status ($($Ctx.Pipe.LastError))"
  $event = $line | ConvertFrom-Json
  Assert-True ($event.event -eq 'ready') "expected ready event, got $line"
}

function Stop-Mock {
  param($Ctx)
  if ($Ctx.PSObject.Properties['Stopped'] -and $Ctx.Stopped) { return }
  $Ctx | Add-Member -NotePropertyName Stopped -NotePropertyValue $true -Force
  $processId = $Ctx.Process.Id
  try {
    if (-not $Ctx.Process.HasExited) { $Ctx.Pipe.WriteLine('{"cmd":"exit"}', 500) }
  } catch { }
  try {
    if (-not $Ctx.Process.HasExited) { [void]$Ctx.Process.WaitForExit(1000) }
  } catch { }
  try {
    if (-not $Ctx.Process.HasExited) {
      $Ctx.Process.Kill()
      [void]$Ctx.Process.WaitForExit(2000)
    }
  } catch { }
  try { $Ctx.Pipe.Dispose() } catch { }
  try { $Ctx.Process.Dispose() } catch { }
  $remaining = Get-Process -Id $processId -ErrorAction SilentlyContinue
  Assert-True ($null -eq $remaining) "mock process $processId was left running"
}

function New-TestSession {
  param([string]$Id, [switch]$WithCapture)
  $Capture = $null
  if ($WithCapture) {
    # 合成 Capture：让生产 Update-DoubaoSession 真正尝试发送音频，
    # 从而能在 worker 已退出时复现“先发送、后读取”的 F1 竞态。
    $Capture = [pscustomobject]@{ DrainCount = 0 }
    $Capture | Add-Member -MemberType ScriptMethod -Name Drain -Value {
      $this.DrainCount++
      return [byte[]]::new(6400)
    }
  }
  return [pscustomobject]@{
    Id = $Id; Config = @{ streaming = $false; correct = $false }; Capture = $Capture
    Clock = [Diagnostics.Stopwatch]::StartNew(); Text = ''; Segments = @()
    Committed = @{}; CommittedText = ''; Connected = $false; Done = $false; Error = ''
    Cancelled = $false; Finishing = $false; ConnectedMs = $null; FirstResultMs = $null
  }
}

function New-DoubaoScenario {
  param([string]$Mode, [int]$LineBytes = 32, [bool]$PreResult = $false)
  $ctx = Start-Mock -Mode $Mode -LineBytes $LineBytes -PreResult $PreResult
  try {
    Read-Ready -Ctx $ctx
    $script:Worker = $ctx.Process
    $script:WorkerPipe = $ctx.Pipe
    $script:Doubao = New-TestSession -Id ([guid]::NewGuid().ToString()) -WithCapture
    $script:DoubaoPumpBusy = $false
    $script:TestOverlayTexts.Clear()
  } catch {
    Stop-Mock -Ctx $ctx
    throw
  }
  return [pscustomobject]@{ Ctx = $ctx; Id = $script:Doubao.Id }
}

function Close-DoubaoScenario {
  param($Scenario)
  $script:Worker = $null
  $script:WorkerPipe = $null
  $script:Doubao = $null
  $script:DoubaoPumpBusy = $false
  Stop-Mock -Ctx $Scenario.Ctx
}

function Wait-MockExit {
  param($Ctx, [int]$TimeoutMs = 5000)
  Assert-True ($Ctx.Process.WaitForExit($TimeoutMs)) "mock worker did not exit within $TimeoutMs ms"
}

function Pump-Doubao {
  param([scriptblock]$Until, [int]$TimeoutMs = 15000)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while (-not (& $Until) -and $sw.ElapsedMilliseconds -lt $TimeoutMs) {
    Update-DoubaoSession
    Start-Sleep -Milliseconds 5
  }
  Assert-True (& $Until) "Doubao pump did not reach the expected state within $TimeoutMs ms (error: $($script:Doubao.Error))"
}

# ── 1. >64 KB result burst while the UI simultaneously sends audio ───────────
# This is the production read/write path: Send-DoubaoCommand/Send-DoubaoAudio + Update-DoubaoSession.
$burstCtx = Start-Mock -Mode burst -LineBytes 70000 -BurstLines 12
try {
  Read-Ready -Ctx $burstCtx
  $script:Worker = $burstCtx.Process
  $script:WorkerPipe = $burstCtx.Pipe
  $id = [guid]::NewGuid().ToString()
  $script:Doubao = New-TestSession -Id $id
  $script:DoubaoPumpBusy = $false
  $script:TestOverlayTexts.Clear()
  try {
    Send-DoubaoCommand @{ cmd = 'start'; session = $id }
    $sendClock = [Diagnostics.Stopwatch]::StartNew()
    Send-DoubaoAudio -Data ([byte[]]::new(64000))
    $sendClock.Stop()
    Assert-True ($sendClock.ElapsedMilliseconds -lt 5000) "audio writes took $($sendClock.ElapsedMilliseconds) ms"
    # Do not read until all audio has been written: the old single-reader path deadlocked here.
    Pump-Doubao -Until { $script:TestOverlayTexts.Count -ge 12 }
    Assert-True ($script:TestOverlayTexts.Count -eq 12) "expected 12 burst results, got $($script:TestOverlayTexts.Count)"
    foreach ($text in $script:TestOverlayTexts) { Assert-True ($text.Length -gt 65536) "burst line was not >64 KiB" }
    Send-DoubaoCommand @{ cmd = 'finish'; session = $id }
    Pump-Doubao -Until { $script:Doubao.Done }
    Assert-True ($script:Doubao.Text.Length -gt 65536) "final result was not >64 KiB"
    Assert-True (-not $script:Doubao.Error) "unexpected session error: $($script:Doubao.Error)"
  } finally {
    $script:Worker = $null
    $script:WorkerPipe = $null
  }
  Stop-Mock -Ctx $burstCtx
  Write-Pass 'stdout burst >64 KiB + concurrent audio writes'
} catch {
  Stop-Mock -Ctx $burstCtx
  throw
}

# ── 2. Hunyuan production read/write path shares the same bridge ─────────────
$hunyuanCtx = Start-Mock -Mode normal -LineBytes 256
try {
  Read-Ready -Ctx $hunyuanCtx
  $script:Worker = $hunyuanCtx.Process
  $script:WorkerPipe = $hunyuanCtx.Pipe
  $id = [guid]::NewGuid().ToString()
  $script:Hunyuan = [pscustomobject]@{
    Id = $id; Text = ''; Segments = @(); DurationMs = 0; Done = $false; Error = ''; Code = ''
    Cancelled = $false; Busy = $false
  }
  $script:HunyuanBusy = $false
  Send-HunyuanCommand @{ cmd = 'recognize'; session = $id }
  $done = $false
  $deadline = [Diagnostics.Stopwatch]::StartNew()
  while (-not $done -and $deadline.ElapsedMilliseconds -lt 5000) {
    $done = Update-HunyuanResult
    if (-not $done) { Start-Sleep -Milliseconds 5 }
  }
  Assert-True $done 'Hunyuan production path did not reach finished'
  Assert-True ($script:Hunyuan.Text -eq 'hunyuan-ok') "unexpected Hunyuan text: $($script:Hunyuan.Text)"
  $script:Worker = $null
  $script:WorkerPipe = $null
  Stop-Mock -Ctx $hunyuanCtx
  Write-Pass 'Hunyuan production bridge read/write path'
} catch {
  Stop-Mock -Ctx $hunyuanCtx
  throw
}

# ── 3. blocked stdin peer: writes fail within the declared timeout, not forever ─
$stallCtx = Start-Mock -Mode stall
try {
  Read-Ready -Ctx $stallCtx
  $script:Worker = $stallCtx.Process
  $script:WorkerPipe = $stallCtx.Pipe
  $id = [guid]::NewGuid().ToString()
  $script:Doubao = New-TestSession -Id $id
  $stallClock = [Diagnostics.Stopwatch]::StartNew()
  $timedOut = $false
  try { Send-DoubaoAudio -Data ([byte[]]::new(64000)) }
  catch [TimeoutException] { $timedOut = $true }
  $stallClock.Stop()
  Assert-True $timedOut 'expected a bounded stdin write timeout'
  Assert-True ($stallClock.ElapsedMilliseconds -ge 4500 -and $stallClock.ElapsedMilliseconds -lt 9000) `
    "write timeout took $($stallClock.ElapsedMilliseconds) ms, expected about 5 s"
  $failFast = [Diagnostics.Stopwatch]::StartNew()
  $failed = $false
  try { $stallCtx.Pipe.WriteLine('{"cmd":"start"}', 500) } catch { $failed = $true }
  Assert-True $failed 'pipe must fail fast after a write timeout'
  Assert-True ($failFast.ElapsedMilliseconds -lt 1500) "post-timeout write waited $($failFast.ElapsedMilliseconds) ms"
  Assert-True $stallCtx.Pipe.IsFaulted 'pipe should be marked faulted after a write timeout'
  $script:Worker = $null
  $script:WorkerPipe = $null
  Stop-Mock -Ctx $stallCtx
  Write-Pass 'blocked stdin writer is bounded and fails fast'
} catch {
  Stop-Mock -Ctx $stallCtx
  throw
}

# ── 4. bounded stdout queue: overflow is reported, memory stays bounded ───────
$floodCtx = Start-Mock -Mode flood -LineBytes 4096 -BurstLines 8 -QueueBytes 16384 -QueueLines 2 -OverflowWaitMs 500
try {
  Read-Ready -Ctx $floodCtx
  $floodCtx.Pipe.WriteLine('{"cmd":"start","session":"flood"}', 1000)
  Start-Sleep -Milliseconds 1400
  Assert-True $floodCtx.Pipe.IsFaulted 'stdout queue overflow was not reported'
  Assert-True ($floodCtx.Pipe.QueuedBytes -le 16384) "stdout queue grew beyond its bound ($($floodCtx.Pipe.QueuedBytes) bytes)"
  $lines = 0
  $finalStatus = 1
  while ($true) {
    $line = $null
    $status = $floodCtx.Pipe.ReadLine(1000, [ref]$line)
    if ($status -eq 0) { $lines++; continue }
    $finalStatus = $status
    break
  }
  Assert-True ($finalStatus -eq 3) "expected fault status after draining queue, got $finalStatus"
  Assert-True ($floodCtx.Pipe.LastError -match 'overflow') "unexpected overflow error: $($floodCtx.Pipe.LastError)"
  Assert-True ($lines -le 2) "queue kept more lines than its bound: $lines"
  Stop-Mock -Ctx $floodCtx
  Write-Pass 'stdout queue is bounded and reports overflow'
} catch {
  Stop-Mock -Ctx $floodCtx
  throw
}

# ── 5. worker exit is an EOF, cleanup leaves no process or stuck thread ────────
$exitCtx = Start-Mock -Mode exit -DelayMs 200
try {
  Read-Ready -Ctx $exitCtx
  $line = $null
  $status = $exitCtx.Pipe.ReadLine(5000, [ref]$line)
  Assert-True ($status -eq 2) "expected EOF after worker exit, got status $status"
  Assert-True $exitCtx.Process.HasExited 'worker should have exited'
  $writeFailed = $false
  try { $exitCtx.Pipe.WriteLine('{"cmd":"start"}', 1000) } catch { $writeFailed = $true }
  Assert-True $writeFailed 'writing to an exited worker must fail, not hang'
  Stop-Mock -Ctx $exitCtx
  Write-Pass 'worker exit becomes EOF and cleans up without hanging'
} catch {
  Stop-Mock -Ctx $exitCtx
  throw
}

# ── 6. repeated start/stop does not leak pipes, processes, or old events ──────
$oldCtx = Start-Mock -Mode delayed -DelayMs 500
try {
  Read-Ready -Ctx $oldCtx
  $oldCtx.Pipe.WriteLine('{"cmd":"start","session":"old"}', 1000)
  Start-Sleep -Milliseconds 100
  Stop-Mock -Ctx $oldCtx

  $newCtx = Start-Mock -Mode normal -LineBytes 1024
  try {
    Read-Ready -Ctx $newCtx
    $newCtx.Pipe.WriteLine('{"cmd":"start","session":"new"}', 1000)
    $line = $null
    $status = $newCtx.Pipe.ReadLine(3000, [ref]$line)
    Assert-True ($status -eq 0) "new session did not produce an event, status $status"
    $event = $line | ConvertFrom-Json
    Assert-True ($event.session -eq 'new') "new session received an old event: $line"
    Assert-True ($event.text -notmatch 'late-') 'late event from stopped worker leaked into the new session'
  } finally {
    Stop-Mock -Ctx $newCtx
  }
  Write-Pass 'restart/stop leaves no old process or leaked event'
} catch {
  try { Stop-Mock -Ctx $oldCtx } catch { }
  throw
}

# ── 7. production Doubao path: finished immediately followed by worker exit ──
# 生产 Update-DoubaoSession 先读队列再发送音频；旧代码先 Send 会先看到 HasExited，
# 把已经排队的 finished 误判为“进程已退出”，随后 Dispose 永久丢失最终结果。
$finalScenario = New-DoubaoScenario -Mode finalexit -LineBytes 32
try {
  Send-DoubaoCommand @{ cmd = 'start'; session = $finalScenario.Id }
  Wait-MockExit -Ctx $finalScenario.Ctx
  Update-DoubaoSession
  $expectedFinal = 'final-exit-' + ('z' * 32)
  Assert-True $script:Doubao.Done 'finished immediately before exit was not consumed'
  Assert-True ($script:Doubao.Error -eq '') "unexpected error after finished: $($script:Doubao.Error)"
  Assert-True ($script:Doubao.Text -eq $expectedFinal) "final text lost: '$($script:Doubao.Text)'"
  Assert-True ($finalScenario.Ctx.Pipe.QueuedLines -eq 0) 'final result stayed queued after update'
  # 不要求 DrainCount 为 0：若 reader 尚未入队，错误恢复路径可能先尝试过一次音频发送，
  # 关键是最终结果不被该失败覆盖。
  Write-Pass 'Doubao finished immediately before exit remains a success'
} finally {
  Close-DoubaoScenario $finalScenario
}

# ── 8. result -> finished -> exit keeps the final text ───────────────────────
$preScenario = New-DoubaoScenario -Mode finalexit -LineBytes 32 -PreResult $true
try {
  Send-DoubaoCommand @{ cmd = 'start'; session = $preScenario.Id }
  Wait-MockExit -Ctx $preScenario.Ctx
  Update-DoubaoSession
  $expectedFinal = 'final-exit-' + ('z' * 32)
  Assert-True $script:Doubao.Done 'final finished was not consumed'
  Assert-True ($script:Doubao.Error -eq '') "unexpected error after final: $($script:Doubao.Error)"
  Assert-True ($script:Doubao.Text -eq $expectedFinal) "final text does not override earlier result: '$($script:Doubao.Text)'"
  Assert-True ($script:TestOverlayTexts.Count -gt 0 -and $script:TestOverlayTexts[$script:TestOverlayTexts.Count - 1] -eq $expectedFinal) `
    'overlay did not end on the final text'
  Write-Pass 'Doubao result -> finished -> exit preserves the final text'
} finally {
  Close-DoubaoScenario $preScenario
}

# ── 9. non-final result followed by exit is a clear failure, text preserved ───
$partialScenario = New-DoubaoScenario -Mode partialexit -LineBytes 32
try {
  Send-DoubaoCommand @{ cmd = 'start'; session = $partialScenario.Id }
  Wait-MockExit -Ctx $partialScenario.Ctx
  Update-DoubaoSession
  Assert-True $script:Doubao.Done 'worker exit without finished must end the session'
  Assert-True ($script:Doubao.Error -ne '') 'exit without finished must report an explicit error'
  Assert-True ($script:Doubao.Error -match '退出') "unexpected error text: $($script:Doubao.Error)"
  Assert-True ($script:Doubao.Text -eq 'partial-only') "latest partial text was not preserved: '$($script:Doubao.Text)'"
  Write-Pass 'Doubao non-final result + exit fails clearly and keeps latest text'
} finally {
  Close-DoubaoScenario $partialScenario
}

# ── 10. empty EOF is an explicit failure, never a silent success ─────────────
$emptyScenario = New-DoubaoScenario -Mode exit -LineBytes 32
try {
  Send-DoubaoCommand @{ cmd = 'start'; session = $emptyScenario.Id }
  Wait-MockExit -Ctx $emptyScenario.Ctx
  Update-DoubaoSession
  Assert-True $script:Doubao.Done 'empty EOF must end the session'
  Assert-True ($script:Doubao.Error -ne '') 'empty EOF must report an explicit error'
  Assert-True ([string]::IsNullOrEmpty($script:Doubao.Text)) "empty EOF produced text: '$($script:Doubao.Text)'"
  Write-Pass 'Doubao empty EOF fails explicitly'
} finally {
  Close-DoubaoScenario $emptyScenario
}

# ── 11. late finished for an old session cannot touch the current session ────
$staleScenario = New-DoubaoScenario -Mode stale -LineBytes 32
try {
  Send-DoubaoCommand @{ cmd = 'start'; session = $staleScenario.Id }
  Pump-Doubao -Until { $script:Doubao.Text -eq 'stale-new-result' }
  Assert-True (-not $script:Doubao.Done) 'late finished from the old session marked the new session done'
  Assert-True ($script:Doubao.Error -eq '') "late old session caused an error: $($script:Doubao.Error)"
  Assert-True ($script:Doubao.Text -eq 'stale-new-result') "unexpected new-session text: '$($script:Doubao.Text)'"
  Assert-True ($script:TestOverlayTexts -notcontains 'stale-old-final') 'old session final leaked into the overlay'
  Send-DoubaoCommand @{ cmd = 'finish'; session = $staleScenario.Id }
  Pump-Doubao -Until { $script:Doubao.Done }
  Assert-True ($script:Doubao.Text.StartsWith('final-')) "current session did not keep its own final: '$($script:Doubao.Text)'"
  Write-Pass 'late old-session finished does not affect the new session'
} finally {
  Close-DoubaoScenario $staleScenario
}

Write-Host ''
Write-Host 'All worker-pipe integration tests passed.' -ForegroundColor Green
