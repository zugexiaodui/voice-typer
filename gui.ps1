# ═══════════════════════════════════════════════════════════════
#  设置界面（可调整大小）+ 系统托盘
# ═══════════════════════════════════════════════════════════════

$script:Tray = $null
$script:SettingsForm = $null
$script:AppIcon = $null

function New-AppIcon {
  if ($script:AppIcon) { return $script:AppIcon }
  $bmp = [System.Drawing.Bitmap]::new(32, 32)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.FillEllipse([System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(45, 120, 220)), 1, 1, 30, 30)
  $white = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
  $g.FillEllipse($white, 12, 7, 8, 12)
  $g.FillRectangle($white, 12, 13, 8, 6)
  $penW = [System.Drawing.Pen]::new([System.Drawing.Color]::White, 2)
  $g.DrawArc($penW, 8, 13, 16, 12, 0, 180)
  $g.DrawLine($penW, 16, 25, 16, 28)
  $g.Dispose()
  $script:AppIcon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
  return $script:AppIcon
}

function Get-HotkeyTextFromKeyData {
  param([System.Windows.Forms.Keys]$KeyData)
  $key = $KeyData -band [System.Windows.Forms.Keys]::KeyCode
  $mods = $KeyData -band [System.Windows.Forms.Keys]::Modifiers
  $isModOnly = ($key -eq [System.Windows.Forms.Keys]::Control) -or
               ($key -eq [System.Windows.Forms.Keys]::Alt) -or
               ($key -eq [System.Windows.Forms.Keys]::Shift) -or
               ($key -eq [System.Windows.Forms.Keys]::LWin) -or
               ($key -eq [System.Windows.Forms.Keys]::RWin) -or
               ($key -eq [System.Windows.Forms.Keys]::Menu)
  if ($isModOnly -or $key -eq [System.Windows.Forms.Keys]::None) { return $null }
  $parts = @()
  if ($mods -band [System.Windows.Forms.Keys]::Control) { $parts += 'Ctrl' }
  if ($mods -band [System.Windows.Forms.Keys]::Alt) { $parts += 'Alt' }
  if ($mods -band [System.Windows.Forms.Keys]::Shift) { $parts += 'Shift' }
  $parts += (Get-KeyNameFromVk -Vk ([int]$key))
  return ($parts -join '+')
}

# ───────── 校验服务连通性测试 ─────────
# 用界面上当前的参数真跑一次 corrector.mjs，让用户改完来源立刻能验证。
# 不走 $script:Cfg，因为用户可能还没点保存。
$script:CorrSample = '嗯，我虽然觉得这个方案可以，但是有时候会经常断字断的，呃，你帮我看一下。'

function Test-CorrectionService {
  param($Model, $BaseUrl, $Format, $KeyName, $MaxTokens, $TimeoutMs, $ThinkParams, $Mode)

  $inF  = Join-Path $env:TEMP 'voice-typer-testcorr-in.txt'
  $outF = Join-Path $env:TEMP 'voice-typer-testcorr-out.txt'
  try {
    [System.IO.File]::WriteAllText($inF, $script:CorrSample, [System.Text.UTF8Encoding]::new($false))
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
    $psi.EnvironmentVariables['VT_CORRECT_MODEL']      = "$Model"
    $psi.EnvironmentVariables['VT_CORRECT_TIMEOUT_MS'] = "$TimeoutMs"
    if ($BaseUrl) { $psi.EnvironmentVariables['VT_CORRECT_BASE_URL']   = "$BaseUrl" }
    if ($Format)  { $psi.EnvironmentVariables['VT_CORRECT_API_FORMAT'] = "$Format" }
    if ($KeyName) { $psi.EnvironmentVariables['VT_CORRECT_KEY_NAME']   = "$KeyName" }
    if ($MaxTokens -gt 0) { $psi.EnvironmentVariables['VT_CORRECT_MAX_TOKENS'] = "$MaxTokens" }
    if ($ThinkParams) { $psi.EnvironmentVariables['VT_CORRECT_THINK_PARAMS'] = "$ThinkParams" }
    if ($Mode) { $psi.EnvironmentVariables['VT_CORRECT_MODE'] = "$Mode" }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $null = $p.StandardOutput.ReadToEnd()
    $errTxt = $p.StandardError.ReadToEnd()
    if (-not $p.WaitForExit([int]$TimeoutMs + 5000)) {
      try { $p.Kill() } catch { }
      return [pscustomobject]@{ Got = ''; Ms = $sw.ElapsedMilliseconds; Tag = '进程没有按时退出，已强制结束'; Changed = $false; FellBack = $true }
    }
    $sw.Stop()
    $tag = (($errTxt.Trim() -split "`n") | Where-Object { $_.Trim() } | Select-Object -Last 1)
    $got = if (Test-Path $outF) {
      [System.IO.File]::ReadAllText($outF, [System.Text.UTF8Encoding]::new($false)).Trim()
    } else { '' }
    return [pscustomobject]@{
      Got = $got; Ms = $sw.ElapsedMilliseconds; Tag = $tag
      Changed = ($got -and $got -ne $script:CorrSample)
      # 关键：纠错器失败时会"原样返回"——它照样把原文写进输出文件，
      # 所以光看 Got 非空会误判成功。必须靠日志区分
      # 「模型正常回复但认为无需改动」和「压根没调用成功」。
      FellBack = ($tag -match '原样返回')
    }
  } catch {
    return [pscustomobject]@{ Got = ''; Ms = 0; Tag = $_.Exception.Message; Changed = $false; FellBack = $true }
  }
}

# ───────── 托盘里的「后处理模型」快速切换 ─────────
# 用函数创建每个菜单项（而不是在 foreach 里直接建）：
# 函数每次调用都有自己独立的 $Preset 变量，事件脚本块捕获到的才是各自那一项。
# 直接在循环里建的话，所有脚本块会共用同一个循环变量，最后全指向最后一个预设。
function Add-CorrectPresetMenu {
  param($ParentMenu, $Preset)
  $item = [System.Windows.Forms.ToolStripMenuItem]::new([string]$Preset.name)
  $item.Tag = [string]$Preset.id
  $item.Add_Click({
      try {
        $p = Get-CorrectPreset -Id $Preset.id
        if (-not $p) {
          Show-Balloon '后处理模型' "预设「$($Preset.name)」已经不在配置文件里了" 'Warning'
          return
        }
        $cfg = Get-Config
        Set-ConfigFromPreset -Config $cfg -Preset $p | Out-Null
        if (Save-Config -Config $cfg) {
          $script:Cfg = $cfg
          Show-Balloon '后处理模型已切换' "$($p.name)`r`n$($p.note)" 'Info'
        } else {
          Show-Balloon '切换失败' '配置写入失败' 'Error'
        }
      } catch {
        Show-Balloon '切换失败' "$($_.Exception.Message)" 'Error'
      }
    })
  [void]$ParentMenu.DropDownItems.Add($item)
  return $item
}

# ───────── 设置窗口 ─────────
function Show-SettingsDialog {
  param($Config)

  if ($script:SettingsForm -and -not $script:SettingsForm.IsDisposed) {
    $script:SettingsForm.Activate(); return
  }

  $FS = 'Microsoft YaHei UI'
  $form = [System.Windows.Forms.Form]::new()
  $form.Text = 'voice-typer 设置'
  $form.ClientSize = [System.Drawing.Size]::new(780, 830)
  $form.MinimumSize = [System.Drawing.Size]::new(620, 520)
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
  $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable   # ← 可调整大小
  $form.MaximizeBox = $true
  $form.Font = [System.Drawing.Font]::new($FS, 9.5)
  $form.Icon = New-AppIcon

  # 底部按钮条（停靠到底部，缩放时自动跟随）
  $bottom = [System.Windows.Forms.Panel]::new()
  $bottom.Dock = [System.Windows.Forms.DockStyle]::Bottom
  $bottom.Height = 56
  $form.Controls.Add($bottom)

  # 主区域：四列自适应表
  # AutoScroll：设置项较多，窗口被调小时可以滚动，避免底部控件够不着
  $grid = [System.Windows.Forms.TableLayoutPanel]::new()
  $grid.Dock = [System.Windows.Forms.DockStyle]::Fill
  $grid.AutoScroll = $true
  $grid.ColumnCount = 4
  $grid.Padding = [System.Windows.Forms.Padding]::new(16, 14, 16, 8)
  # 第 2 列要放得下服务地址这种长 URL，所以给到 300
  [void]$grid.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 140))
  [void]$grid.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 300))
  [void]$grid.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Absolute, 300))
  [void]$grid.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new([System.Windows.Forms.SizeType]::Percent, 100))
  $form.Controls.Add($grid)
  $grid.BringToFront()

  $script:row = 0
  function AddRow {
    param($label, $control, $hint)
    $l = [System.Windows.Forms.Label]::new()
    $l.Text = $label; $l.Dock = 'Fill'
    $l.TextAlign = 'MiddleRight'
    $l.Margin = [System.Windows.Forms.Padding]::new(0, 6, 10, 6)
    $grid.Controls.Add($l, 0, $script:row)

    $control.Dock = 'Fill'
    $control.Margin = [System.Windows.Forms.Padding]::new(0, 4, 10, 4)
    $grid.Controls.Add($control, 1, $script:row)

    $h = [System.Windows.Forms.Label]::new()
    $h.Text = $hint; $h.Dock = 'Fill'
    $h.TextAlign = 'MiddleLeft'
    $h.ForeColor = [System.Drawing.Color]::Gray
    $h.Margin = [System.Windows.Forms.Padding]::new(0, 6, 0, 6)
    $grid.Controls.Add($h, 2, $script:row)
    [void]$grid.SetColumnSpan($h, 2)
    $script:row++
  }

  # ── 录音快捷键 ──
  $tbToggle = [System.Windows.Forms.TextBox]::new()
  $tbToggle.ReadOnly = $true; $tbToggle.BackColor = [System.Drawing.Color]::White
  $tbToggle.Text = $Config.hotkeyToggle; $tbToggle.Cursor = [System.Windows.Forms.Cursors]::Hand
  $tbToggle.Add_KeyDown({
      $t = Get-HotkeyTextFromKeyData -KeyData $_.KeyData
      if ($t) { $tbToggle.Text = $t }
      $_.SuppressKeyPress = $true; $_.Handled = $true
    })
  AddRow '录音快捷键' $tbToggle '点这里，然后直接按你想用的组合键'

  # ── 取消快捷键 ──
  $cancelPanel = [System.Windows.Forms.Panel]::new()
  $cancelPanel.Height = 28
  $tbCancel = [System.Windows.Forms.TextBox]::new()
  $tbCancel.ReadOnly = $true; $tbCancel.BackColor = [System.Drawing.Color]::White
  $tbCancel.Text = $Config.hotkeyCancel; $tbCancel.Cursor = [System.Windows.Forms.Cursors]::Hand
  $tbCancel.Location = [System.Drawing.Point]::new(0, 0)
  $tbCancel.Width = 140
  $tbCancel.Add_KeyDown({
      $t = Get-HotkeyTextFromKeyData -KeyData $_.KeyData
      if ($t) { $tbCancel.Text = $t }
      $_.SuppressKeyPress = $true; $_.Handled = $true
    })
  $btnClear = [System.Windows.Forms.Button]::new()
  $btnClear.Text = '清空'; $btnClear.Location = [System.Drawing.Point]::new(148, 0)
  $btnClear.Size = [System.Drawing.Size]::new(52, 26)
  $btnClear.Add_Click({ $tbCancel.Text = '' })
  $cancelPanel.Controls.Add($tbCancel); $cancelPanel.Controls.Add($btnClear)
  AddRow '取消快捷键' $cancelPanel '录音时按它放弃本次；AI 校验时按它跳过校验、直接用原文上屏'

  # ── 识别语言 ──
  $cbLang = [System.Windows.Forms.ComboBox]::new()
  $cbLang.DropDownStyle = 'DropDownList'
  [void]$cbLang.Items.AddRange(@('auto|自动识别（中英混说）', 'zh|中文', 'en|英文', 'yue|粤语', 'ja|日语', 'ko|韩语'))
  foreach ($i in 0..($cbLang.Items.Count - 1)) {
    if ($cbLang.Items[$i].ToString().StartsWith("$($Config.lang)|")) { $cbLang.SelectedIndex = $i; break }
  }
  if ($cbLang.SelectedIndex -lt 0) { $cbLang.SelectedIndex = 0 }
  AddRow '识别语言' $cbLang '中英混说建议用「自动」'

  # ── CPU 线程 ──
  $numThreads = [System.Windows.Forms.NumericUpDown]::new()
  $numThreads.Minimum = 1; $numThreads.Maximum = 16
  $numThreads.Value = [Math]::Max(1, [Math]::Min(16, [int]$Config.threads))
  AddRow '识别速度（CPU 线程）' $numThreads '越多越快，但转写时占 CPU。4 核建议 4~6'

  # ── 空闲释放 ──
  $numIdle = [System.Windows.Forms.NumericUpDown]::new()
  $numIdle.Minimum = 10; $numIdle.Maximum = 3600; $numIdle.Increment = 10
  $numIdle.Value = [Math]::Max(10, [Math]::Min(3600, [int]$Config.idleSec))
  AddRow '空闲多久释放内存(秒)' $numIdle '到时间后卸载模型，约释放 400 MB'

  # ── 悬浮按钮大小 ──
  $numFloat = [System.Windows.Forms.NumericUpDown]::new()
  $numFloat.Minimum = 30; $numFloat.Maximum = 96; $numFloat.Increment = 4
  $numFloat.Value = [Math]::Max(30, [Math]::Min(96, [int]$Config.floatSize))
  AddRow '悬浮按钮大小(像素)' $numFloat '用鼠标可以把按钮拖到任意位置'

  # ── 识别引擎 ──
  $cbEngine = [System.Windows.Forms.ComboBox]::new()
  $cbEngine.DropDownStyle = 'DropDownList'
  [void]$cbEngine.Items.AddRange(@(
    'sensevoice|SenseVoice —— 快（推荐日常）',
    'qwen3|Qwen3-ASR-0.6B —— 准（多语言，慢约7倍）'
  ))
  foreach ($i in 0..($cbEngine.Items.Count - 1)) {
    if ($cbEngine.Items[$i].ToString().StartsWith("$($Config.engine)|")) { $cbEngine.SelectedIndex = $i; break }
  }
  if ($cbEngine.SelectedIndex -lt 0) { $cbEngine.SelectedIndex = 0 }
  AddRow '识别引擎' $cbEngine 'Qwen3 支持 52 语言+22 方言，但每句约 1.2 秒'

  $tbHotwords = [System.Windows.Forms.TextBox]::new()
  $tbHotwords.Text = [string]$Config.qwen3Hotwords
  AddRow 'Qwen3 热词' $tbHotwords '仅 Qwen3 有效：提升专有名词准确率，逗号分隔'

  # ── 悬浮按钮图标来源 ──
  $cbIcon = [System.Windows.Forms.ComboBox]::new()
  $cbIcon.DropDownStyle = 'DropDownList'
  [void]$cbIcon.Items.AddRange(@(
    'material|Material Symbols（Google）',
    'tabler|Tabler Icons',
    'phosphor|Phosphor Icons'
  ))
  foreach ($i in 0..($cbIcon.Items.Count - 1)) {
    if ($cbIcon.Items[$i].ToString().StartsWith("$($Config.icon)|")) { $cbIcon.SelectedIndex = $i; break }
  }
  if ($cbIcon.SelectedIndex -lt 0) { $cbIcon.SelectedIndex = 0 }
  AddRow '悬浮按钮图标' $cbIcon '来自开源图标库，可随时换'

  # ── 复选框 ──
  $ckPaste = [System.Windows.Forms.CheckBox]::new()
  $ckPaste.Text = '识别后自动粘贴到光标处'; $ckPaste.Checked = [bool]$Config.autoPaste
  AddRow '' $ckPaste '关闭则只在悬浮提示里显示'

  $ckStream = [System.Windows.Forms.CheckBox]::new()
  $ckStream.Text = '流式模式：边说边上屏（停顿即定稿，只追加不修改）'
  $ckStream.Checked = [bool]$Config.streaming
  AddRow '' $ckStream ("每隔 {0} 秒做一次增量识别" -f ([double]$Config.streamTickMs / 1000))

  $ckCorrect = [System.Windows.Forms.CheckBox]::new()
  $ckCorrect.Text = '收尾 AI 校验：说完后送大模型纠错（需联网）'
  $ckCorrect.Checked = [bool]$Config.correct
  AddRow '' $ckCorrect '开启后说话时不粘贴，等校验完成一次性上屏'

  $cbMode = [System.Windows.Forms.ComboBox]::new()
  $cbMode.DropDownStyle = 'DropDownList'
  [void]$cbMode.Items.AddRange(@(
    'proofread|保守校对：只改错别字和口水话',
    'tidy|AI 整理：通顺化 + 补标点，保留原意'
  ))
  foreach ($i in 0..($cbMode.Items.Count - 1)) {
    if ($cbMode.Items[$i].ToString().StartsWith("$($Config.correctMode)|")) { $cbMode.SelectedIndex = $i; break }
  }
  if ($cbMode.SelectedIndex -lt 0) { $cbMode.SelectedIndex = 0 }
  AddRow '提示词模式' $cbMode '保守校对几乎不动原文；AI 整理会通顺化并补标点，但保留原意'

  # ── 校验服务预设（从 correct-presets.json 读，省得手输地址和模型名）──
  $script:CorrPresets = @(Get-CorrectPresets)
  $cbCorrPreset = [System.Windows.Forms.ComboBox]::new()
  $cbCorrPreset.DropDownStyle = 'DropDownList'
  foreach ($p in $script:CorrPresets) { [void]$cbCorrPreset.Items.Add([string]$p.name) }
  [void]$cbCorrPreset.Items.Add('（自定义）')
  $script:CorrCustomIdx = $cbCorrPreset.Items.Count - 1
  AddRow '校验服务预设' $cbCorrPreset '选一个就行 —— 下面的地址/格式/模型/密钥/超时会自动填好'

  # ── 校验服务来源（可换成中转站，省钱）──
  $tbCorrBase = [System.Windows.Forms.TextBox]::new()
  $tbCorrBase.Text = [string]$Config.correctBaseUrl
  AddRow '校验服务地址' $tbCorrBase '留空 = 官方 api.deepseek.com；换中转站就填它的域名'

  $cbCorrFmt = [System.Windows.Forms.ComboBox]::new()
  $cbCorrFmt.DropDownStyle = 'DropDownList'
  [void]$cbCorrFmt.Items.AddRange(@(
    'openai|OpenAI 兼容  /v1/chat/completions',
    'anthropic|Anthropic 格式  /v1/messages'
  ))
  foreach ($i in 0..($cbCorrFmt.Items.Count - 1)) {
    if ($cbCorrFmt.Items[$i].ToString().StartsWith("$($Config.correctApiFormat)|")) { $cbCorrFmt.SelectedIndex = $i; break }
  }
  if ($cbCorrFmt.SelectedIndex -lt 0) { $cbCorrFmt.SelectedIndex = 0 }
  AddRow '接口格式' $cbCorrFmt '只填域名时，会按这里自动补上对应的路径'

  $tbCorrModel = [System.Windows.Forms.TextBox]::new()
  $tbCorrModel.Text = [string]$Config.correctModel
  AddRow '校验模型' $tbCorrModel '官方是 deepseek-flash；ikuncode 是 deepseek-v4.1-flash'

  $tbCorrKey = [System.Windows.Forms.TextBox]::new()
  $tbCorrKey.Text = [string]$Config.correctKeyName
  AddRow '密钥名称' $tbCorrKey '从 .dsh\.credentials.yaml 里读这个名字对应的密钥'

  $numCorrTok = [System.Windows.Forms.NumericUpDown]::new()
  $numCorrTok.Minimum = 0; $numCorrTok.Maximum = 8192; $numCorrTok.Increment = 256
  $numCorrTok.Value = [Math]::Max(0, [Math]::Min(8192, [int]$Config.correctMaxTokens))
  AddRow '最大输出 token' $numCorrTok '0=自动。思考模式关不掉的来源（如 ikuncode）请给 2048'

  $numCorrTo = [System.Windows.Forms.NumericUpDown]::new()
  $numCorrTo.Minimum = 1000; $numCorrTo.Maximum = 120000; $numCorrTo.Increment = 1000
  $numCorrTo.Value = [Math]::Max(1000, [Math]::Min(120000, [int]$Config.correctTimeoutMs))
  AddRow '校验超时(毫秒)' $numCorrTo '超时就原样输出。思考模式来源建议 20000'

  $cbThink = [System.Windows.Forms.ComboBox]::new()
  $cbThink.DropDownStyle = 'DropDownList'
  [void]$cbThink.Items.AddRange(@(
    'deepseek|DeepSeek 系（发 reasoning_effort / thinking）',
    'none|不发送（GPT、Claude 等）'
  ))
  foreach ($i in 0..($cbThink.Items.Count - 1)) {
    if ($cbThink.Items[$i].ToString().StartsWith("$($Config.correctThinkParams)|")) { $cbThink.SelectedIndex = $i; break }
  }
  if ($cbThink.SelectedIndex -lt 0) { $cbThink.SelectedIndex = 0 }
  AddRow '关思考参数' $cbThink 'DeepSeek 专用参数；发给 GPT 会被中转站卡死，GPT 选「不发送」'

  # ── 预设 ↔ 字段 双向联动 ──
  #  PresetBusy：程序在填值时置真，防止"填值 → 触发 TextChanged → 又判定成自定义"的死循环。
  $script:PresetBusy = $false

  function Apply-CorrPreset($idx) {
    if ($idx -lt 0 -or $idx -ge $script:CorrPresets.Count) { return }
    $p = $script:CorrPresets[$idx]
    $script:PresetBusy = $true
    try {
      $tbCorrBase.Text = [string]$p.baseUrl
      for ($i = 0; $i -lt $cbCorrFmt.Items.Count; $i++) {
        if ($cbCorrFmt.Items[$i].ToString().StartsWith("$($p.apiFormat)|")) { $cbCorrFmt.SelectedIndex = $i; break }
      }
      $tbCorrModel.Text = [string]$p.model
      $tbCorrKey.Text   = [string]$p.keyName
      $numCorrTok.Value = [Math]::Max(0, [Math]::Min(8192, [int]$p.maxTokens))
      $numCorrTo.Value  = [Math]::Max(1000, [Math]::Min(120000, [int]$p.timeoutMs))
      for ($i = 0; $i -lt $cbThink.Items.Count; $i++) {
        if ($cbThink.Items[$i].ToString().StartsWith("$($p.thinkParams)|")) { $cbThink.SelectedIndex = $i; break }
      }
      if ($lblState) {
        $lblState.ForeColor = [System.Drawing.Color]::DimGray
        $lblState.Text = [string]$p.note
      }
    } finally { $script:PresetBusy = $false }
  }

  $cbCorrPreset.Add_SelectedIndexChanged({
      if ($script:PresetBusy) { return }
      Apply-CorrPreset $cbCorrPreset.SelectedIndex
    })

  # 手动改了任一字段 → 下拉框自动切到「（自定义）」
  $markCorrCustom = {
      if ($script:PresetBusy) { return }
      $script:PresetBusy = $true
      $cbCorrPreset.SelectedIndex = $script:CorrCustomIdx
      $script:PresetBusy = $false
      if ($lblState) {
        $lblState.ForeColor = [System.Drawing.Color]::DimGray
        $lblState.Text = '当前是自定义参数（没有使用预设）'
      }
    }
  $tbCorrBase.Add_TextChanged($markCorrCustom)
  $tbCorrModel.Add_TextChanged($markCorrCustom)
  $tbCorrKey.Add_TextChanged($markCorrCustom)
  $cbCorrFmt.Add_SelectedIndexChanged($markCorrCustom)
  $numCorrTok.Add_ValueChanged($markCorrCustom)
  $numCorrTo.Add_ValueChanged($markCorrCustom)
  $cbThink.Add_SelectedIndexChanged($markCorrCustom)

  # 打开窗口时反查：当前配置跟哪个预设一模一样就选中它，否则显示「自定义」
  $initIdx = $script:CorrCustomIdx
  for ($i = 0; $i -lt $script:CorrPresets.Count; $i++) {
    if (Test-ConfigMatchesPreset -Config $Config -Preset $script:CorrPresets[$i]) { $initIdx = $i; break }
  }
  $script:PresetBusy = $true
  $cbCorrPreset.SelectedIndex = $initIdx
  $script:PresetBusy = $false

  $tbGlossary = [System.Windows.Forms.TextBox]::new()
  $tbGlossary.Text = [string]$Config.correctGlossary
  AddRow '常用词表' $tbGlossary '逗号分隔，用于纠正同音字（如 DeepSeek Harness、pnpm）'

  $tbFillers = [System.Windows.Forms.TextBox]::new()
  $tbFillers.Text = [string]$Config.correctFillers
  AddRow '额外填充词' $tbFillers '内置已含 嗯/呃/额/唉/哎/呐/唔，如需删其他口头禅可加在这里'

  $ckOverlay = [System.Windows.Forms.CheckBox]::new()
  $ckOverlay.Text = '显示识别结果悬浮提示'; $ckOverlay.Checked = [bool]$Config.showOverlay
  AddRow '' $ckOverlay '录音和识别时在屏幕底部提示'

  $ckFloat = [System.Windows.Forms.CheckBox]::new()
  $ckFloat.Text = '显示悬浮按钮'; $ckFloat.Checked = [bool]$Config.showFloat
  AddRow '' $ckFloat '点击按钮即可开始/停止听写'

  $ckNotify = [System.Windows.Forms.CheckBox]::new()
  $ckNotify.Text = '启动时弹出气泡提示'; $ckNotify.Checked = [bool]$Config.notifyOnStart
  AddRow '' $ckNotify ''

  # ── 状态栏 + 按钮（放底部面板，右对齐并随窗口缩放跟随）──
  $lblState = [System.Windows.Forms.Label]::new()
  $lblState.Dock = [System.Windows.Forms.DockStyle]::Left
  $lblState.Width = 428
  $lblState.AutoEllipsis = $true
  $lblState.TextAlign = 'MiddleLeft'
  $lblState.ForeColor = [System.Drawing.Color]::DimGray
  $lblState.Padding = [System.Windows.Forms.Padding]::new(20, 0, 0, 0)
  $lblState.Text = '改完点「保存」，立即生效，无需重启。'
  $bottom.Controls.Add($lblState)

  $btnTest = [System.Windows.Forms.Button]::new()
  $btnTest.Text = '测试校验'
  $btnTest.Size = [System.Drawing.Size]::new(96, 32)
  $btnTest.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
  $btnTest.Location = [System.Drawing.Point]::new($bottom.Width - 312, 12)
  $btnTest.Add_Click({
      $lblState.ForeColor = [System.Drawing.Color]::DimGray
      $lblState.Text = '正在测试校验服务，请稍候…'
      $btnTest.Enabled = $false
      [System.Windows.Forms.Application]::DoEvents()
      try {
        $r = Test-CorrectionService `
               -Model      $tbCorrModel.Text.Trim() `
               -BaseUrl    $tbCorrBase.Text.Trim() `
               -Format     $cbCorrFmt.SelectedItem.ToString().Split('|')[0] `
               -KeyName    $tbCorrKey.Text.Trim() `
               -MaxTokens  ([int]$numCorrTok.Value) `
               -TimeoutMs  ([int]$numCorrTo.Value) `
               -ThinkParams $cbThink.SelectedItem.ToString().Split('|')[0] `
               -Mode        $cbMode.SelectedItem.ToString().Split('|')[0]

        if ($r.FellBack -or -not $r.Got) {
          $lblState.ForeColor = [System.Drawing.Color]::Firebrick
          $lblState.Text = "❌ 失败（$($r.Ms) ms）"
          [System.Windows.Forms.MessageBox]::Show(
            "没有拿到纠错结果。`r`n`r`n日志：`r`n$($r.Tag)`r`n`r`n常见原因：`r`n" +
            "  · 服务地址填的是域名但接口格式选错了`r`n" +
            "  · 密钥名称在 .credentials.yaml 里不存在`r`n" +
            "  · 模型名不对`r`n" +
            "  · max tokens 太小，被思考模式吃光（试 2048）`r`n" +
            "  · 超时太短（思考模式来源建议 20000）",
            '校验服务测试失败', 'OK', 'Warning') | Out-Null
        }
        else {
          $lblState.ForeColor = if ($r.Changed) { [System.Drawing.Color]::SeaGreen } else { [System.Drawing.Color]::DarkOrange }
          $lblState.Text = if ($r.Changed) { "✅ 正常（$($r.Ms) ms）" } else { "⚠️ 通了但没改动（$($r.Ms) ms）" }
          [System.Windows.Forms.MessageBox]::Show(
            "耗时：$($r.Ms) ms`r`n`r`n原文：`r`n$script:CorrSample`r`n`r`n纠错后：`r`n$($r.Got)`r`n`r`n日志：$($r.Tag)",
            '校验服务测试', 'OK', 'Information') | Out-Null
        }
      } catch {
        $lblState.ForeColor = [System.Drawing.Color]::Firebrick
        $lblState.Text = "测试出错：$($_.Exception.Message)"
      } finally {
        $btnTest.Enabled = $true
      }
    })
  $bottom.Controls.Add($btnTest)

  $btnCancel = [System.Windows.Forms.Button]::new()
  $btnCancel.Text = '取消'
  $btnCancel.Size = [System.Drawing.Size]::new(90, 32)
  $btnCancel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
  $btnCancel.Location = [System.Drawing.Point]::new($bottom.Width - 200, 12)
  $btnCancel.Add_Click({ $form.Close() })
  $bottom.Controls.Add($btnCancel)

  $btnSave = [System.Windows.Forms.Button]::new()
  $btnSave.Text = '保存'
  $btnSave.Size = [System.Drawing.Size]::new(90, 32)
  $btnSave.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
  $btnSave.Location = [System.Drawing.Point]::new($bottom.Width - 104, 12)
  $btnSave.Add_Click({
      $newCfg = Get-Config
      $newCfg.hotkeyToggle = $tbToggle.Text.Trim()
      $newCfg.hotkeyCancel = $tbCancel.Text.Trim()
      $newCfg.lang    = $cbLang.SelectedItem.ToString().Split('|')[0]
      $newCfg.threads = [int]$numThreads.Value
      $newCfg.idleSec = [int]$numIdle.Value
      $newCfg.floatSize   = [int]$numFloat.Value
      $newCfg.icon        = $cbIcon.SelectedItem.ToString().Split('|')[0]
      $newCfg.autoPaste   = [bool]$ckPaste.Checked
      $newCfg.streaming   = [bool]$ckStream.Checked
      $newCfg.correct     = [bool]$ckCorrect.Checked
      $newCfg.correctMode = $cbMode.SelectedItem.ToString().Split('|')[0]
      $newCfg.correctPreset = if ($cbCorrPreset.SelectedIndex -eq $script:CorrCustomIdx -or $cbCorrPreset.SelectedIndex -lt 0) {
        'custom'
      } else { [string]$script:CorrPresets[$cbCorrPreset.SelectedIndex].id }
      $newCfg.correctModel     = $tbCorrModel.Text.Trim()
      $newCfg.correctBaseUrl   = $tbCorrBase.Text.Trim()
      $newCfg.correctApiFormat = $cbCorrFmt.SelectedItem.ToString().Split('|')[0]
      $newCfg.correctKeyName   = $tbCorrKey.Text.Trim()
      $newCfg.correctMaxTokens = [int]$numCorrTok.Value
      $newCfg.correctTimeoutMs = [int]$numCorrTo.Value
      $newCfg.correctThinkParams = $cbThink.SelectedItem.ToString().Split('|')[0]
      $newCfg.correctGlossary = $tbGlossary.Text.Trim()
      $newCfg.correctFillers  = $tbFillers.Text.Trim()
      $newCfg.engine          = $cbEngine.SelectedItem.ToString().Split('|')[0]
      $newCfg.qwen3Hotwords   = $tbHotwords.Text.Trim()
      $newCfg.showOverlay = [bool]$ckOverlay.Checked
      $newCfg.showFloat   = [bool]$ckFloat.Checked
      $newCfg.notifyOnStart = [bool]$ckNotify.Checked

      if (-not (ConvertTo-HotkeyParts -Text $newCfg.hotkeyToggle)) {
        [System.Windows.Forms.MessageBox]::Show('录音快捷键无效，请重新设置。', 'voice-typer', 'OK', 'Warning') | Out-Null
        return
      }
      if ($newCfg.hotkeyCancel -and -not (ConvertTo-HotkeyParts -Text $newCfg.hotkeyCancel)) {
        [System.Windows.Forms.MessageBox]::Show('取消快捷键无效，请清空或重新设置。', 'voice-typer', 'OK', 'Warning') | Out-Null
        return
      }
      if (Save-Config -Config $newCfg) {
        if ($script:OnSettingsSaved) { & $script:OnSettingsSaved $newCfg }
        $lblState.ForeColor = [System.Drawing.Color]::SeaGreen
        $lblState.Text = '已保存并生效。'
        Start-Sleep -Milliseconds 500
        $form.Close()
      }
    })
  $bottom.Controls.Add($btnSave)

  $form.AcceptButton = $btnSave
  $form.CancelButton = $btnCancel
  $script:SettingsForm = $form
  [void]$form.ShowDialog()
  $script:SettingsForm = $null
}

# ───────── 托盘 ─────────
function Start-Tray {
  param($Config)
  $script:Tray = [System.Windows.Forms.NotifyIcon]::new()
  $script:Tray.Icon = New-AppIcon
  $script:Tray.Text = 'voice-typer  全局语音输入'
  $script:Tray.Visible = $true

  $menu = [System.Windows.Forms.ContextMenuStrip]::new()
  $menu.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 9.5)

  $miSet = $menu.Items.Add('设置…')
  $miSet.Add_Click({ Show-SettingsDialog -Config (Get-Config) })

  $miFloat = $menu.Items.Add('显示/隐藏悬浮按钮')
  $miFloat.Add_Click({
      $script:Cfg.showFloat = -not $script:Cfg.showFloat
      if ($script:Cfg.showFloat) { Show-FloatButton } else { Hide-FloatButton }
      Save-Config -Config $script:Cfg | Out-Null
    })

  # 后处理模型：一步切换，不用开设置窗口
  $miCorr = [System.Windows.Forms.ToolStripMenuItem]::new('后处理模型')
  $script:CorrMenuItems = @()
  foreach ($p in @(Get-CorrectPresets)) {
    $script:CorrMenuItems += Add-CorrectPresetMenu -ParentMenu $miCorr -Preset $p
  }
  if ($script:CorrMenuItems.Count -eq 0) {
    $miNone = [System.Windows.Forms.ToolStripMenuItem]::new('（没读到预设文件）')
    $miNone.Enabled = $false
    [void]$miCorr.DropDownItems.Add($miNone)
  }
  [void]$menu.Items.Add($miCorr)
  # 每次展开菜单时刷新勾选状态
  $menu.Add_Opening({
      $cur = [string]$script:Cfg.correctPreset
      foreach ($it in $script:CorrMenuItems) { $it.Checked = ([string]$it.Tag -eq $cur) }
    })

  $miTip = $menu.Items.Add('快捷键说明')
  $miTip.Add_Click({
      $c = Get-Config
      [System.Windows.Forms.MessageBox]::Show(
        "录音：$($c.hotkeyToggle)`r`n取消：$(if($c.hotkeyCancel){$c.hotkeyCancel}else{'（未设置）'})`r`n`r`n也可以直接点屏幕上的悬浮按钮开始/停止。",
        'voice-typer', 'OK', 'Information') | Out-Null
    })

  [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
  $miExit = $menu.Items.Add('退出')
  $miExit.Add_Click({ if ($script:OnExitRequest) { & $script:OnExitRequest } })

  $script:Tray.ContextMenuStrip = $menu
  $script:Tray.Add_MouseClick({
      if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-SettingsDialog -Config (Get-Config) }
    })
  $script:Tray.Add_DoubleClick({ Show-SettingsDialog -Config (Get-Config) })
}

function Show-Balloon {
  param([string]$Title, [string]$Text, [string]$Kind = 'Info')
  if (-not $script:Tray) { return }
  $icon = switch ($Kind) {
    'Warning' { [System.Windows.Forms.ToolTipIcon]::Warning }
    'Error' { [System.Windows.Forms.ToolTipIcon]::Error }
    default { [System.Windows.Forms.ToolTipIcon]::Info }
  }
  try { $script:Tray.ShowBalloonTip(4000, $Title, $Text, $icon) } catch { }
}

function Stop-Tray {
  if ($script:Tray) {
    try { $script:Tray.Visible = $false; $script:Tray.Dispose() } catch { }
    $script:Tray = $null
  }
}
