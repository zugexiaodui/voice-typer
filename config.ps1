# ═══════════════════════════════════════════════════════════════
#  配置读写 + 快捷键名 ↔ 虚拟键码 转换
# ═══════════════════════════════════════════════════════════════

$script:ConfigPath = Join-Path $AppDir 'settings.json'

$script:DefaultConfig = [ordered]@{
  hotkeyToggle  = 'Ctrl+Alt+Space'   # 开始/停止录音
  hotkeyCancel  = 'Esc'              # 取消本次录音（留空表示不注册）
  lang          = 'auto'             # auto | zh | en | yue | ja | ko
  threads       = 4
  stream        = $true              # 流式预览（边说边显示）
  tickMs        = 2000               # 流式刷新间隔
  autoPaste     = $true
  idleSec       = 90                 # 识别进程空闲多久后退出释放内存
  showOverlay   = $true              # 是否显示识别结果悬浮提示
  showFloat     = $true              # 是否显示可点击的悬浮按钮
  floatSize     = 46                 # 悬浮按钮直径（像素）
  icon          = 'material'         # 悬浮按钮图标来源，见 icons.ps1
  notifyOnStart = $false             # 启动时气泡提示

  # ── 流式（伪流式：Silero VAD 按真实语音活动切句，说完一句就上屏；只追加不修改）──
  streaming     = $true              # 是否启用流式
  streamTickMs  = 1500               # 每隔多久检查一次是否有句子说完
  vadThreshold  = 0.5                # VAD 语音判定阈值（环境吵可调低到 0.3）
  vadMinSilence = 0.45               # 静音超过多久算一句结束
  vadMaxSpeech  = 25                 # 单句最长时长，超过强制切分。
                                     # 别调小：强制切分是在语音中间硬切，会把一个词
                                     # 劈成两半（实测「断的」被切成「断。」+「的有点儿」）。
                                     # 正常断句靠静音检测，这个只是防无限累积的保险。
                                     # 上限受模型上下文限制：Qwen3 实测可稳到 70 秒。
  # ── 收尾 AI 校验（对识别结果做保守纠错）──
  #  服务来源可换：默认官方 DeepSeek，也能指向兼容的中转站以省钱。
  #  注意有些中转站的 DeepSeek 关不掉思考模式，会先烧几百个思维 token
  #  才吐正文 —— 那种情况必须把 correctMaxTokens 显式给大（如 2048），
  #  否则 token 全被思考吃掉、正文为空，表现为"校验没反应"。
  correct       = $false             # 总开关（默认关，开启后需要联网）
  correctPreset = 'deepseek-official'  # 当前选中的预设 id，见 correct-presets.json
  correctModel  = 'deepseek-flash'
  correctBaseUrl   = ''              # 留空 = 官方 https://api.deepseek.com
  correctApiFormat = 'openai'        # openai | anthropic
  correctKeyName   = 'DEEPSEEK_API_KEY'  # 从 DSH 凭证文件读哪个密钥
  # 关思考的参数发不发。reasoning_effort / thinking 是 DeepSeek 系专用的，
  # 发给 GPT 这类模型会被中转站卡住（实测 aizex 上打 gpt-4o 直接挂到超时）。
  #   deepseek = 发（DeepSeek 官方 / ikuncode 等）
  #   none     = 一个都不发（GPT / Claude 等）
  correctThinkParams = 'deepseek'
  # 提示词模式
  #   proofread = 保守校对：只修同音字和口语填充词，护栏严格（改动率 ≤35%）
  #   tidy      = AI 整理：通顺化、补标点、并句、整理语序，但不许改变原意、不许总结提炼
  correctMode = 'proofread'
  correctMaxTokens = 2048            # 作为"下限"生效：思考模式关不掉的来源需要几百个
                                     # 思维 token 打底。官方 API 给大值不涨价也不变慢，
                                     # 所以默认就抬到 2048。填 0 = 纯按输入长度自动。
  correctTimeoutMs = 6000            # 超时即原样返回，绝不卡住录音流程
  correctGlossary = ''               # 用户词表，逗号或顿号分隔；会拼进提示词
  correctFillers  = ''               # 额外的口语填充词（内置已含 嗯/呃/额/唉/哎/呐/唔）

  # ── 识别引擎选择 ──
  #  sensevoice : 快（RTF≈0.034），本地，5 种语言，不支持热词 —— 日常输入首选
  #  qwen3      : 慢约 7 倍（RTF≈0.25），本地，52 语言+22 方言，支持热词偏置
  #               适合高精度场景 / 多语言 / 长文整理
  engine        = 'sensevoice'
  qwen3ModelDir = ''                 # 留空则自动在 voice-typer\models\ 下查找
  qwen3Hotwords = ''                 # 热词表（逗号/顿号分隔），仅 qwen3 引擎有效
}

# ───────── 收尾校验的服务预设 ─────────
# 预设写在工程目录下的 correct-presets.json，方便用户自己加来源。
# 读不到 / 格式坏了就退回内置的这两条，保证设置界面永远有东西可选。

$script:BuiltinPresets = @(
  [pscustomobject]@{
    id = 'deepseek-official'; name = 'DeepSeek 官方'
    baseUrl = ''; apiFormat = 'openai'; model = 'deepseek-flash'
    keyName = 'DEEPSEEK_API_KEY'; maxTokens = 2048; timeoutMs = 6000
    thinkParams = 'deepseek'
    note = '官方直连，最快（实测约 1.1 秒）'
  }
  [pscustomobject]@{
    id = 'deepseek-ikuncode'; name = 'DeepSeek - ikuncode'
    baseUrl = 'https://api.ikuncode.ai'; apiFormat = 'anthropic'; model = 'deepseek-v4.1-flash'
    keyName = 'IKUNCODE_API_KEY'; maxTokens = 2048; timeoutMs = 20000
    thinkParams = 'deepseek'
    note = '中转站，便宜但慢 4~5 倍（实测约 4~6 秒），思考模式关不掉'
  }
)

function Get-CorrectPresets {
  $path = Join-Path $AppDir 'correct-presets.json'
  if (-not (Test-Path $path)) { return $script:BuiltinPresets }
  try {
    $raw = Get-Content $path -Raw -Encoding UTF8
    $obj = $raw | ConvertFrom-Json
    $list = @()
    foreach ($p in @($obj.presets)) {
      if (-not $p) { continue }
      if ([string]::IsNullOrWhiteSpace([string]$p.name)) { continue }
      # 缺字段时用默认值补齐，避免用户手写 JSON 漏项就整条失效
      $list += [pscustomobject]@{
        id        = if ($p.id)        { [string]$p.id }        else { [string]$p.name }
        name      = [string]$p.name
        baseUrl   = if ($null -ne $p.baseUrl) { [string]$p.baseUrl } else { '' }
        apiFormat = if ($p.apiFormat) { [string]$p.apiFormat } else { 'openai' }
        model     = if ($p.model)     { [string]$p.model }     else { 'deepseek-flash' }
        keyName   = if ($p.keyName)   { [string]$p.keyName }   else { 'DEEPSEEK_API_KEY' }
        maxTokens = if ($p.maxTokens) { [int]$p.maxTokens }    else { 2048 }
        timeoutMs = if ($p.timeoutMs) { [int]$p.timeoutMs }    else { 6000 }
        # 漏填就按模型名猜：deepseek 系要发关思考参数，其他模型发了会被卡住
        thinkParams = if ($p.thinkParams) { [string]$p.thinkParams }
                      elseif ("$($p.model)" -match '^deepseek') { 'deepseek' }
                      else { 'none' }
        note      = if ($p.note)      { [string]$p.note }      else { '' }
      }
    }
    if ($list.Count -eq 0) { return $script:BuiltinPresets }
    return $list
  } catch {
    Write-Host "[警告] correct-presets.json 读不了（$($_.Exception.Message)），用内置预设" -ForegroundColor Yellow
    return $script:BuiltinPresets
  }
}

function Get-CorrectPreset {
  param([string]$Id)
  $all = Get-CorrectPresets
  foreach ($p in $all) { if ($p.id -eq $Id) { return $p } }
  return $null
}

# 把预设写进配置对象（返回是否成功）
function Set-ConfigFromPreset {
  param($Config, $Preset)
  if (-not $Preset) { return $false }
  $Config.correctPreset    = $Preset.id
  $Config.correctBaseUrl   = $Preset.baseUrl
  $Config.correctApiFormat = $Preset.apiFormat
  $Config.correctModel     = $Preset.model
  $Config.correctKeyName   = $Preset.keyName
  $Config.correctMaxTokens = $Preset.maxTokens
  $Config.correctTimeoutMs = $Preset.timeoutMs
  $Config.correctThinkParams = $Preset.thinkParams
  return $true
}

# 判断当前配置是否和某个预设完全一致（用来在界面上反查选中项）
function Test-ConfigMatchesPreset {
  param($Config, $Preset)
  if (-not $Preset) { return $false }
  return ([string]$Config.correctBaseUrl   -eq [string]$Preset.baseUrl) -and
         ([string]$Config.correctApiFormat -eq [string]$Preset.apiFormat) -and
         ([string]$Config.correctModel     -eq [string]$Preset.model) -and
         ([string]$Config.correctKeyName   -eq [string]$Preset.keyName) -and
         ([int]$Config.correctMaxTokens    -eq [int]$Preset.maxTokens) -and
         ([int]$Config.correctTimeoutMs    -eq [int]$Preset.timeoutMs) -and
         ([string]$Config.correctThinkParams -eq [string]$Preset.thinkParams)
}

# ───────── 虚拟键码表 ─────────
$script:KeyNameToVk = @{}
$script:VkToKeyName = @{}

function Initialize-KeyMaps {
  if ($script:KeyNameToVk.Count -gt 0) { return }
  foreach ($c in [char[]]'ABCDEFGHIJKLMNOPQRSTUVWXYZ') {
    $script:KeyNameToVk["$c"] = [int][char]$c
  }
  for ($i = 0; $i -le 9; $i++) { $script:KeyNameToVk["$i"] = 0x30 + $i }
  for ($i = 1; $i -le 24; $i++) { $script:KeyNameToVk["F$i"] = 0x6F + $i }
  $named = @{
    'Space' = 0x20; 'Enter' = 0x0D; 'Return' = 0x0D; 'Tab' = 0x09; 'Esc' = 0x1B; 'Escape' = 0x1B
    'Backspace' = 0x08; 'Delete' = 0x2E; 'Del' = 0x2E; 'Insert' = 0x2D; 'Ins' = 0x2D
    'Home' = 0x24; 'End' = 0x23; 'PageUp' = 0x21; 'PageDown' = 0x22
    'Up' = 0x26; 'Down' = 0x28; 'Left' = 0x25; 'Right' = 0x27
    'OemMinus' = 0xBD; 'OemPlus' = 0xBB; 'OemComma' = 0xBC; 'OemPeriod' = 0xBE
    'OemQuestion' = 0xBF; 'OemTilde' = 0xC0; 'OemOpenBrackets' = 0xDB
    'OemCloseBrackets' = 0xDD; 'OemPipe' = 0xDC; 'OemQuotes' = 0xDE; 'OemSemicolon' = 0xBA
  }
  foreach ($k in $named.Keys) { $script:KeyNameToVk[$k] = $named[$k] }

  # 反查表（用于把已保存的 VK 显示回名字）
  foreach ($k in $script:KeyNameToVk.Keys) {
    $vk = $script:KeyNameToVk[$k]
    if (-not $script:VkToKeyName.ContainsKey($vk)) { $script:VkToKeyName[$vk] = $k }
  }
  # 修正几个显示优先级，让名字更好看
  $script:VkToKeyName[0x1B] = 'Esc'
  $script:VkToKeyName[0x0D] = 'Enter'
  $script:VkToKeyName[0x20] = 'Space'
}

function ConvertTo-HotkeyParts {
  <#  把 'Ctrl+Alt+Space' 解析成 @{ Mods = 3; Vk = 0x20; Text = 'Ctrl+Alt+Space' }
      解析失败返回 $null  #>
  param([string]$Text)
  Initialize-KeyMaps
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

  $mods = 0
  $vkName = $null
  foreach ($raw in $Text.Split('+')) {
    $p = $raw.Trim()
    if (-not $p) { continue }
    switch -Regex ($p) {
      '^(Ctrl|Control)$' { $mods = $mods -bor 0x0002; continue }
      '^Alt$' { $mods = $mods -bor 0x0001; continue }
      '^Shift$' { $mods = $mods -bor 0x0004; continue }
      '^(Win|Windows|Meta)$' { $mods = $mods -bor 0x0008; continue }
      default {
        if ($script:KeyNameToVk.ContainsKey($p)) { $vkName = $p }
        else {
          $up = $p.ToUpper()
          if ($script:KeyNameToVk.ContainsKey($up)) { $vkName = $up }
        }
      }
    }
  }
  if (-not $vkName) { return $null }
  $vk = $script:KeyNameToVk[$vkName]

  # 组装规范化的显示文本
  $parts = @()
  if ($mods -band 0x0002) { $parts += 'Ctrl' }
  if ($mods -band 0x0001) { $parts += 'Alt' }
  if ($mods -band 0x0004) { $parts += 'Shift' }
  if ($mods -band 0x0008) { $parts += 'Win' }
  $parts += $vkName

  return [pscustomobject]@{ Mods = $mods; Vk = $vk; Text = ($parts -join '+') }
}

function Get-KeyNameFromVk {
  param([int]$Vk)
  Initialize-KeyMaps
  if ($script:VkToKeyName.ContainsKey($Vk)) { return $script:VkToKeyName[$Vk] }
  return "0x$('{0:X2}' -f $Vk)"
}

# ───────── 配置读写 ─────────
function Get-Config {
  $cfg = [ordered]@{}
  foreach ($k in $script:DefaultConfig.Keys) { $cfg[$k] = $script:DefaultConfig[$k] }
  if (Test-Path $script:ConfigPath) {
    try {
      $saved = Get-Content $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($p in $saved.PSObject.Properties) {
        if ($cfg.Contains($p.Name)) { $cfg[$p.Name] = $p.Value }
      }
    } catch {
      Write-Host "[警告] 配置文件损坏，使用默认值: $($_.Exception.Message)" -ForegroundColor Yellow
    }
  }
  # 旧值归一化：instruct 是第一版激进模式的取值，现在统一按 tidy 处理。
  # 必须在读取时就归一 —— 否则界面下拉框里没有 instruct 这一项，
  # 打开设置会显示成「保守校对」，而实际跑的是「AI 整理」，界面和真实行为对不上。
  if ("$($cfg['correctMode'])" -eq 'instruct') { $cfg['correctMode'] = 'tidy' }
  return $cfg
}

function Save-Config {
  param($Config)
  try {
    ($Config | ConvertTo-Json -Depth 4) | Set-Content -Path $script:ConfigPath -Encoding UTF8
    return $true
  } catch {
    Write-Host "[错误] 保存配置失败: $($_.Exception.Message)" -ForegroundColor Red
    return $false
  }
}
