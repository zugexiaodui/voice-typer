# ═══════════════════════════════════════════════════════════════
#  悬浮按钮：真·逐像素透明 + 可拖动 + 可点击 + 按状态变色
#
#  实现要点：用 UpdateLayeredWindow 做分层窗口，配合 32 位带 Alpha 的位图，
#  这样圆外是真正透明的（不是靠键控色抠出来的黑边），边缘也有抗锯齿。
#  缺点是不能用 WinForms 的 Paint 事件，必须自己把整张图推给窗口。
# ═══════════════════════════════════════════════════════════════

$script:FloatBtn = $null
$script:OnFloatToggle = $null
$script:OnFloatSettings = $null
$script:PosFile = Join-Path $env:TEMP 'voice-typer-floatpos.txt'

# ── 分层窗口所需的额外 API ──
if (-not ('VTLayered' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class VTLayered {
  public const int GWL_EXSTYLE = -20;
  public const int WS_EX_NOACTIVATE = 0x08000000;
  public const int WS_EX_TOOLWINDOW = 0x00000080;
  public const int WS_EX_TRANSPARENT = 0x00000020;

  [DllImport("user32.dll", SetLastError = true)]
  public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
  [DllImport("user32.dll", SetLastError = true)]
  public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
  [DllImport("user32.dll", SetLastError = true)]
  public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
      int X, int Y, int cx, int cy, uint uFlags);

  // ── 圆形窗口区域（透明靠它实现，不靠分层窗口）──
  [DllImport("gdi32.dll")]
  public static extern IntPtr CreateEllipticRgn(int l, int t, int r, int b);
  [DllImport("user32.dll")]
  public static extern int SetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool bRedraw);
  [DllImport("gdi32.dll")]
  public static extern bool DeleteObject(IntPtr hObject);
}
'@
}

# ── 悬浮按钮用的双缓冲窗体 ──
# 录音时按钮要做呼吸动画（25fps 重绘）。默认的 Form 每次重绘都会先擦一遍背景
# （BackColor 是近白色）再画位图，而窗口被裁成了圆形 —— 那个圆形区域里
# "先白一下再画" 就是肉眼可见的闪烁。只有双缓冲 + 不擦背景才能消掉。
# 注意：只引用 WinForms/Drawing 编译不过（Form 的基类 Component 在
# System.ComponentModel.Primitives 里），所以引用当前已加载的全部程序集。
if (-not ('VTFloatForm' -as [type])) {
  try {
    $vtRefs = [AppDomain]::CurrentDomain.GetAssemblies() |
              Where-Object { -not $_.IsDynamic -and $_.Location } |
              ForEach-Object { $_.Location } | Select-Object -Unique
    Add-Type -ReferencedAssemblies $vtRefs -TypeDefinition @'
using System.Windows.Forms;

public class VTFloatForm : Form {
  public VTFloatForm() {
    // AllPaintingInWmPaint : 只在 WM_PAINT 里画，不单独走 WM_ERASEBKGND
    // UserPaint            : 全部绘制由自己负责
    // OptimizedDoubleBuffer: 先画到离屏缓冲再整张贴出 —— 消除闪烁的关键
    // Opaque               : 声明窗口不透明，让系统不要擦背景
    SetStyle(ControlStyles.AllPaintingInWmPaint
           | ControlStyles.UserPaint
           | ControlStyles.OptimizedDoubleBuffer
           | ControlStyles.Opaque, true);
  }
  // 背景由 Paint 里的位图整张覆盖，这里什么都不画，避免擦背景造成闪烁
  protected override void OnPaintBackground(PaintEventArgs e) { }
}
'@ -ErrorAction Stop
  } catch {
    try {
      Add-Content -Path (Join-Path $env:TEMP 'voice-typer-error.log') `
        -Value "双缓冲窗体编译失败，退回反射方案（可能仍有轻微闪烁）: $($_.Exception.Message)" -Encoding utf8
    } catch { }
  }
  Remove-Variable vtRefs -ErrorAction SilentlyContinue
}

# 造一个带双缓冲的悬浮按钮窗体。编译成功就用上面那个子类；
# ── 悬浮按钮首选方案：分层窗口 + 逐像素 Alpha ──
# 为什么不用 SetWindowRgn 裁圆形：区域是 1 位掩码，没有抗锯齿，边缘必然是锯齿；
# 而且"窗口区域内、位图透明处"会显示成没擦过的黑，就是那圈黑边。
# UpdateLayeredWindow 直接推一张带 Alpha 的整图上去，边缘由位图自己的抗锯齿决定。
#
# 以前试这个失败（窗口不可见），原因是 WinForms 会照常绘制并盖掉推上去的内容。
# 正确写法两条：
#   ① WS_EX_LAYERED 必须在 CreateParams 里加（窗口创建前），事后再 SetWindowLong 常常不生效
#   ② OnPaint / OnPaintBackground 全部留空且不调 base，让 WinForms 一个像素都不画
if (-not ('VTLayeredForm' -as [type])) {
  try {
    $vtRefs2 = [AppDomain]::CurrentDomain.GetAssemblies() |
               Where-Object { -not $_.IsDynamic -and $_.Location } |
               ForEach-Object { $_.Location } | Select-Object -Unique
    Add-Type -ReferencedAssemblies $vtRefs2 -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class VTLayeredForm : Form {
  const int WS_EX_LAYERED    = 0x00080000;
  const int WS_EX_NOACTIVATE = 0x08000000;
  const int WS_EX_TOOLWINDOW = 0x00000080;
  const int ULW_ALPHA        = 0x00000002;
  const byte AC_SRC_OVER     = 0x00;
  const byte AC_SRC_ALPHA    = 0x01;

  [StructLayout(LayoutKind.Sequential)] struct POINT { public int x, y; }
  [StructLayout(LayoutKind.Sequential)] struct SIZE  { public int cx, cy; }
  [StructLayout(LayoutKind.Sequential, Pack = 1)]
  struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }

  [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
  [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
  [DllImport("gdi32.dll")]  static extern IntPtr CreateCompatibleDC(IntPtr dc);
  [DllImport("gdi32.dll")]  static extern bool DeleteDC(IntPtr dc);
  [DllImport("gdi32.dll")]  static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
  [DllImport("gdi32.dll")]  static extern bool DeleteObject(IntPtr obj);
  [DllImport("user32.dll", SetLastError = true)]
  static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst,
      ref SIZE psize, IntPtr hdcSrc, ref POINT pptSrc, int crKey,
      ref BLENDFUNCTION pblend, int dwFlags);

  public VTLayeredForm() {
    // 完全不参与 WinForms 的绘制
    SetStyle(ControlStyles.Opaque | ControlStyles.UserPaint
           | ControlStyles.AllPaintingInWmPaint, true);
    FormBorderStyle = FormBorderStyle.None;
    ShowInTaskbar   = false;
    StartPosition   = FormStartPosition.Manual;
    TopMost         = true;
  }

  protected override CreateParams CreateParams {
    get {
      CreateParams cp = base.CreateParams;
      cp.ExStyle |= WS_EX_LAYERED | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
      return cp;
    }
  }

  // 留空且不调 base：Paint 事件不会触发，WinForms 一个像素都不画
  protected override void OnPaintBackground(PaintEventArgs e) { }
  protected override void OnPaint(PaintEventArgs e) { }

  // 把整张带 Alpha 的位图推成窗口内容（这就是分层窗口的全部内容）
  public void PushBitmap(Bitmap bmp) {
    IntPtr screenDc = GetDC(IntPtr.Zero);
    IntPtr memDc    = CreateCompatibleDC(screenDc);
    IntPtr hBitmap  = IntPtr.Zero;
    IntPtr old      = IntPtr.Zero;
    try {
      hBitmap = bmp.GetHbitmap(Color.FromArgb(0));   // Color.FromArgb(0) 才能保住 Alpha 通道
      old     = SelectObject(memDc, hBitmap);
      SIZE  size   = new SIZE();  size.cx = bmp.Width; size.cy = bmp.Height;
      POINT srcLoc = new POINT(); srcLoc.x = 0; srcLoc.y = 0;
      POINT dstLoc = new POINT(); dstLoc.x = Left; dstLoc.y = Top;
      BLENDFUNCTION blend = new BLENDFUNCTION();
      blend.BlendOp             = AC_SRC_OVER;
      blend.SourceConstantAlpha = 255;
      blend.AlphaFormat         = AC_SRC_ALPHA;
      blend.BlendFlags          = 0;
      bool ok = UpdateLayeredWindow(Handle, screenDc, ref dstLoc, ref size,
                                    memDc, ref srcLoc, 0, ref blend, ULW_ALPHA);
      if (!ok) throw new Exception("UpdateLayeredWindow 失败, GetLastError=" + Marshal.GetLastWin32Error());
    } finally {
      if (old     != IntPtr.Zero) SelectObject(memDc, old);
      if (hBitmap != IntPtr.Zero) DeleteObject(hBitmap);
      DeleteDC(memDc);
      ReleaseDC(IntPtr.Zero, screenDc);
    }
  }
}
'@ -ErrorAction Stop
  } catch {
    try {
      Add-Content -Path (Join-Path $env:TEMP 'voice-typer-error.log') `
        -Value "分层窗口编译失败，退回窗口区域方案（会有锯齿和黑边）: $($_.Exception.Message)" -Encoding utf8
    } catch { }
  }
  Remove-Variable vtRefs2 -ErrorAction SilentlyContinue
}

# 万一编译失败，退回反射设置同样的样式位（拿不到 OnPaintBackground 覆盖，但也能消闪）。
function New-FloatForm {
  # 首选：分层窗口（边缘平滑、无黑边）
  if ('VTLayeredForm' -as [type]) { return [VTLayeredForm]::new() }
  # 兜底：窗口区域裁剪方案
  if ('VTFloatForm' -as [type]) { return [VTFloatForm]::new() }
  $f = [System.Windows.Forms.Form]::new()
  try {
    $styles = [System.Windows.Forms.ControlStyles]::AllPaintingInWmPaint -bor `
              [System.Windows.Forms.ControlStyles]::UserPaint -bor `
              [System.Windows.Forms.ControlStyles]::OptimizedDoubleBuffer -bor `
              [System.Windows.Forms.ControlStyles]::Opaque
    $m = [System.Windows.Forms.Control].GetMethod('SetStyle',
           [System.Reflection.BindingFlags]'Instance,NonPublic')
    if ($m) { $m.Invoke($f, @($styles, $true)) }
  } catch { }
  return $f
}

# ── 把窗口裁成圆形：圆外的像素不属于窗口，所以桌面能透出来 ──
function Set-FloatWindowRegion {
  param([IntPtr]$Handle, [int]$Size)
  try {
    $rgn = [VTLayered]::CreateEllipticRgn(0, 0, $Size + 1, $Size + 1)
    if ($rgn -ne [IntPtr]::Zero) {
      [void][VTLayered]::SetWindowRgn($Handle, $rgn, $true)
      # 系统接管该区域对象，不要自己删
    }
  } catch {
    try { Add-Content -Path (Join-Path $env:TEMP 'voice-typer-error.log') `
            -Value "设置圆形区域失败: $($_.Exception.Message)" -Encoding utf8 } catch { }
  }
}

function Get-FloatPosition {
  param([int]$Size = 46)
  if (Test-Path $script:PosFile) {
    try {
      $p = (Get-Content $script:PosFile -Raw).Trim() -split ','
      $x = [int]$p[0]; $y = [int]$p[1]
      $scr = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
      if ($x -gt ($scr.Left - 200) -and $x -lt ($scr.Right - 10) -and
          $y -gt ($scr.Top - 200) -and $y -lt ($scr.Bottom - 10)) {
        return [System.Drawing.Point]::new($x, $y)
      }
    } catch { }
  }
  $scr = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  return [System.Drawing.Point]::new($scr.Right - $Size - 40, $scr.Bottom - $Size - 120)
}

function Save-FloatPosition {
  if (-not $script:FloatBtn) { return }
  try {
    $b = $script:FloatBtn.Form.Bounds
    Set-Content -Path $script:PosFile -Value "$($b.X),$($b.Y)" -Encoding ascii
  } catch { }
}

# ───────── 悬浮按钮的配色 + 标记 ─────────
# 全部集中在这一张表里：换颜色、换"正在思考"的标记，只动这里，不碰绘制逻辑。
#   body   主体圆填充色 (R,G,B)
#   edge   外圈描边色
#   marker 圆里画什么：icon=话筒 | wave=声波柱 | dots=三点 | sparkle=火花 | question=问号
#   ring   外圈那一道：none=没有 | glow=呼吸光晕 | spin=旋转弧
#   anim   这个状态要不要定时器不停重绘
#   period 一个完整循环几秒
$script:FloatPalette = [ordered]@{
  idle = @{
    body = @(52, 120, 200); edge = @(120, 175, 240)
    marker = 'icon'; ring = 'none'; anim = $false; period = 2.2
  }
  recording = @{
    body = @(232, 64, 64); edge = @(255, 255, 140)
    marker = 'wave'; ring = 'glow'; anim = $true; period = 2.2
  }
  working = @{
    body = @(238, 162, 48); edge = @(255, 236, 190)
    marker = 'icon'; ring = 'none'; anim = $false; period = 2.2
  }
  correcting = @{
    # 原来用的紫 (139,92,246) 色相 262°，离待机蓝的 212° 只有 50°，
    # 小尺寸下会被直接读成"还是那个蓝按钮"。改成玫红，色相 ~318°，彻底分家。
    body = @(214, 60, 168); edge = @(255, 214, 240)
    marker = 'dots'; ring = 'none'; anim = $true; period = 1.4
  }
  ok = @{
    body = @(52, 178, 108); edge = @(200, 255, 225)
    marker = 'icon'; ring = 'none'; anim = $false; period = 2.2
  }
}

# ───────── 把按钮画到一张带 Alpha 的位图上 ─────────
function New-FloatBitmap {
  param(
    [int]$Size, [string]$State, [double]$Pulse,
    [hashtable]$Override      # 只给预览用：临时盖掉配色/标记，方便并排比方案
  )

  $pal = $script:FloatPalette[$State]
  if (-not $pal) { $pal = $script:FloatPalette['idle'] }
  $pick = {
    param($key)
    if ($Override -and $Override.ContainsKey($key)) { return $Override[$key] }
    return $pal[$key]
  }
  $bodyRGB = & $pick 'body'
  $edgeRGB = & $pick 'edge'
  $marker  = & $pick 'marker'
  $ring    = & $pick 'ring'

  $body = [System.Drawing.Color]::FromArgb(255, $bodyRGB[0], $bodyRGB[1], $bodyRGB[2])
  $edge = [System.Drawing.Color]::FromArgb(255, $edgeRGB[0], $edgeRGB[1], $edgeRGB[2])
  $fg   = [System.Drawing.Color]::FromArgb(255, 255, 255, 255)

  $bmp = [System.Drawing.Bitmap]::new($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.Clear([System.Drawing.Color]::Transparent)

  $cx = $Size / 2.0
  $cy = $Size / 2.0

  # 外圈的呼吸光晕（录音用）
  # 用正弦做透明度曲线（$Pulse 是 0→1 的相位）。原来直接线性映射，
  # 在相位折返处是硬拐点，视觉上像"闪"而不是"呼吸"。
  if ($ring -eq 'glow') {
    $haloA = [int](45 + 80 * (1.0 - [Math]::Cos($Pulse * 2 * [Math]::PI)) / 2.0)
    $r = $Size / 2.0 - 2
    $hb = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb($haloA, $bodyRGB[0], $bodyRGB[1], $bodyRGB[2]))
    $g.FillEllipse($hb, [float]($cx - $r), [float]($cy - $r), [float]($r * 2), [float]($r * 2))
    $hb.Dispose()
  }

  # 投影：范围控制在整张位图内（窗口已被裁成圆形，超出的部分会被剪掉）
  $shPad = $Size * 0.08
  $shD = $Size - 2 * $shPad
  $shOff = [Math]::Max(1.0, $Size * 0.030)
  $shb = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(40, 20, 30, 50))
  $g.FillEllipse($shb, [float]$shPad, [float]($shPad + $shOff), [float]$shD, [float]$shD)
  $shb.Dispose()

  # 主体圆（内缩留出抗锯齿边缘）
  $pad = $Size * 0.115
  $d = $Size - 2 * $pad
  $bb = [System.Drawing.SolidBrush]::new($body)
  $g.FillEllipse($bb, [float]$pad, [float]$pad, [float]$d, [float]$d)
  $bb.Dispose()
  $ep = [System.Drawing.Pen]::new($edge, [float]([Math]::Max(1.0, $Size * 0.026)))
  $g.DrawEllipse($ep, [float]$pad, [float]$pad, [float]$d, [float]$d)
  $ep.Dispose()

  # 贴着外缘转一段弧。画在主体圆之外、窗口圆之内那圈留白里，所以不会压住图标。
  # 弧色取主体色的浅色版，换配色方案时不用另外维护一个色值。
  if ($ring -eq 'spin') {
    $ar = $Size / 2.0 - 2.0
    $aw = [float][Math]::Max(1.8, $Size * 0.050)
    $lR = [int]($bodyRGB[0] + (255 - $bodyRGB[0]) * 0.60)
    $lG = [int]($bodyRGB[1] + (255 - $bodyRGB[1]) * 0.60)
    $lB = [int]($bodyRGB[2] + (255 - $bodyRGB[2]) * 0.60)
    $ap = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(240, $lR, $lG, $lB), $aw)
    $ap.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $ap.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
    # $Pulse 是 0→1 的相位，映射成 0→360° 的起始角，正方向旋转
    $g.DrawArc($ap, [float]($cx - $ar), [float]($cy - $ar), [float]($ar * 2), [float]($ar * 2),
               [float]($Pulse * 360.0), 96.0)
    $ap.Dispose()
  }

  # ── 圆内标记 ──
  # 话筒按 24 单位画布绘制再缩放，所以画笔粗细必须跟"图标缩放比"走，
  # 不能用按按钮直径算的 $u —— 否则大按钮上画笔会粗得糊成一团。
  $iconScale = $d / 30.0
  $fb = [System.Drawing.SolidBrush]::new($fg)
  $fp = [System.Drawing.Pen]::new($fg, [float]([Math]::Max(1.5, 2.0 * $iconScale)))
  $fp.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $fp.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
  $fp.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round

  switch ($marker) {
    'wave' {
      # 录音：声波柱（坐标直接是像素，所以用 $u）
      $u = $d / 24.0
      $bars = 4
      $bw = [float](1.95 * $u)
      $gap = [float](2.3 * $u)
      $x0 = $cx - ($bars * $bw + ($bars - 1) * $gap) / 2.0
      for ($i = 0; $i -lt $bars; $i++) {
        $ph = $Pulse * 2 * [Math]::PI + $i * 0.85
        $hh = (2.8 + 5.8 * [Math]::Abs([Math]::Sin($ph))) * $u
        $x = $x0 + $i * ($bw + $gap)
        $g.DrawLine($fp, [float]$x, [float]($cy - $hh / 2), [float]$x, [float]($cy + $hh / 2))
      }
    }
    'dots' {
      # 三个点从左到右依次亮起、变大 —— "正在处理"最通用的符号。
      # 注意：点是画在不透明的主体圆上的，alpha 混合后最终像素的 A 恒为 255，
      # 亮度差异只落在 RGB 上。所以光靠透明度不够（最暗那档只有 27% 白，
      # 在 46px 的小按钮上几乎看不出来），必须让点的大小一起跟着变。
      $gapx = $d * 0.255
      for ($i = 0; $i -lt 3; $i++) {
        # 相位各错开 0.20，形成从左到右依次亮灭的波浪
        $ph = ($Pulse + $i * 0.20) % 1.0
        $k  = (1.0 - [Math]::Cos($ph * 2 * [Math]::PI)) / 2.0   # 0→1→0
        $a  = [int](105 + 150 * $k)
        $dr = [float]($d * 0.090 * (0.72 + 0.46 * $k))
        $db = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb($a, $fg))
        $x = $cx + ($i - 1) * $gapx
        $g.FillEllipse($db, [float]($x - $dr), [float]($cy - $dr), [float]($dr * 2), [float]($dr * 2))
        $db.Dispose()
      }
    }
    'sparkle' {
      # 四角星（生成式 AI 的那种"火花"），整体随呼吸轻微明暗
      $R = $d * 0.34
      $pts = @()
      for ($i = 0; $i -lt 8; $i++) {
        $ang = $i * [Math]::PI / 4.0 - [Math]::PI / 2.0
        $rr = if ($i % 2 -eq 0) { $R } else { $R * 0.28 }
        $pts += [System.Drawing.PointF]::new([float]($cx + $rr * [Math]::Cos($ang)),
                                             [float]($cy + $rr * [Math]::Sin($ang)))
      }
      $a = [int](165 + 90 * (1.0 - [Math]::Cos($Pulse * 2 * [Math]::PI)) / 2.0)
      $sb = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb($a, $fg))
      $g.FillPolygon($sb, $pts)
      # 右下角再点一颗小星，更像"在生成"
      $g.FillEllipse($sb, [float]($cx + $d * 0.24), [float]($cy + $d * 0.22),
                          [float]($d * 0.13), [float]($d * 0.13))
      $sb.Dispose()
    }
    'question' {
      # 一个问号 —— "正在琢磨你这句话"
      $fsz = [float]($d * 0.80)
      $font = [System.Drawing.Font]::new('Segoe UI', $fsz, [System.Drawing.FontStyle]::Bold,
                                         [System.Drawing.GraphicsUnit]::Pixel)
      $sf = [System.Drawing.StringFormat]::new()
      $sf.Alignment     = [System.Drawing.StringAlignment]::Center
      $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
      $g.DrawString('?', $font, $fb, [System.Drawing.PointF]::new([float]$cx, [float]($cy + $d * 0.02)), $sf)
      $font.Dispose(); $sf.Dispose()
    }
    default {
      # 话筒图标：直接使用专业图标库的 SVG 路径数据（见 icons.ps1），不再手工绘制
      $iconKey = if ($script:Cfg.icon) { $script:Cfg.icon } else { 'material' }
      Draw-IconOnGraphics -G $g -IconKey $iconKey -CenterX $cx -CenterY $cy `
        -Diameter ($d * 0.78) -Color $fg
    }
  }
  $fp.Dispose(); $fb.Dispose()
  $g.Dispose()
  return $bmp
}

# ───────── 重绘（走 WinForms 的 Paint，配合圆形窗口区域做裁剪）─────────
# 说明：早先试过 UpdateLayeredWindow 做逐像素透明，API 返回成功但窗口始终不可见
#       （WinForms 的 Form 类与手动分层窗口冲突）。改用 SetWindowRgn 把窗口本身
#       裁成圆形，圆外像素不属于窗口，桌面自然透出来 —— 这个方案实测可靠。
function Update-FloatVisual {
  if (-not $script:FloatBtn) { return }
  try {
    $f = $script:FloatBtn.Form
    # Form 还没建好（或已经 Dispose）时直接跳过：
    # 否则 $f.GetType() 会抛"不能对 Null 调用方法"，日志里刷一堆没用的报错
    if (-not $f) { return }
    # 用类型名判断，不写 [VTLayeredForm] —— 万一那个类型没编译出来，
    # 直接引用类型名会抛"找不到类型"，这里必须稳。
    if ($f.GetType().Name -eq 'VTLayeredForm') {
      # 分层窗口：画一张带 Alpha 的整图推上去就是全部内容
      $cs = $f.ClientSize
      if ($cs.Width -le 0 -or $cs.Height -le 0) { return }
      $bmp = New-FloatBitmap -Size $cs.Width -State $script:FloatBtn.State.State `
                             -Pulse $script:FloatBtn.State.Pulse
      try { $f.PushBitmap($bmp) } finally { $bmp.Dispose() }
    } else {
      # 兜底方案：走 WinForms 的 Paint（Paint 处理器里会自己画一张整图）
      $f.Invalidate()
      $f.Update()
    }
  } catch {
    try {
      Add-Content -Path (Join-Path $env:TEMP 'voice-typer-error.log') `
        -Value "悬浮按钮绘制失败: $($_.Exception.Message)" -Encoding utf8
    } catch { }
  }
}

# ───────── 创建悬浮按钮 ─────────
function Start-FloatButton {
  if ($script:FloatBtn) { return }
  $size = if ($script:Cfg.floatSize) { [int]$script:Cfg.floatSize } else { 46 }

  $f = New-FloatForm
  $f.AutoScaleMode    = [System.Windows.Forms.AutoScaleMode]::None
  $f.FormBorderStyle  = [System.Windows.Forms.FormBorderStyle]::None
  $f.StartPosition    = [System.Windows.Forms.FormStartPosition]::Manual
  $f.ShowInTaskbar    = $false
  $f.TopMost          = $true
  $f.MinimumSize      = [System.Drawing.Size]::new($size, $size)
  $f.MaximumSize      = [System.Drawing.Size]::new($size, $size)
  $f.ClientSize       = [System.Drawing.Size]::new($size, $size)
  $f.Cursor           = [System.Windows.Forms.Cursors]::Hand
  $f.Text             = 'voice-typer'
  $f.Location         = (Get-FloatPosition -Size $size)
  $f.BackColor        = [System.Drawing.Color]::FromArgb(252, 253, 255)

  [void]$f.Handle
  # 不抢焦点 + 不进 Alt+Tab。
  # 注意只清 WS_EX_TRANSPARENT，不能用 -band 把 WS_EX_LAYERED 抹掉 ——
  # 分层窗口全靠那个位（它在 CreateParams 里就设好了）。
  $ex = [VTLayered]::GetWindowLong($f.Handle, [VTLayered]::GWL_EXSTYLE)
  $ex = ($ex -bor [VTLayered]::WS_EX_NOACTIVATE -bor [VTLayered]::WS_EX_TOOLWINDOW) `
             -band (-bnot [VTLayered]::WS_EX_TRANSPARENT)
  [void][VTLayered]::SetWindowLong($f.Handle, [VTLayered]::GWL_EXSTYLE, $ex)

  # ── 圆外透明怎么做，取决于用的是哪种窗体 ──
  # 分层窗口（首选）：靠位图自己的 Alpha 通道，边缘自带抗锯齿，什么都别裁。
  # 兜底方案：把窗口裁成圆形区域 —— 但这没有抗锯齿，边缘一定是锯齿。
  $script:FloatIsLayered = ($f.GetType().Name -eq 'VTLayeredForm')
  if (-not $script:FloatIsLayered) {
    Set-FloatWindowRegion -Handle $f.Handle -Size $size
  }

  # 先挂到 script 作用域：Paint 会在 Show() 时立即触发
  $script:FloatBtn = [pscustomobject]@{
    Form  = $f
    State = [pscustomobject]@{ State = 'idle'; Pulse = 0.0; T0 = $null }
  }

  # 绘制：整张按钮图直接贴到窗口上
  $f.Add_Paint({
      if (-not $script:FloatBtn) { return }
      $bm = $null
      try {
        $cs = $script:FloatBtn.Form.ClientSize
        if ($cs.Width -le 0 -or $cs.Height -le 0) { return }
        $bm = New-FloatBitmap -Size $cs.Width -State $script:FloatBtn.State.State -Pulse $script:FloatBtn.State.Pulse
        $_.Graphics.DrawImageUnscaled($bm, 0, 0)
      } catch {
        try { Add-Content -Path (Join-Path $env:TEMP 'voice-typer-error.log') `
                -Value "悬浮按钮绘制失败: $($_.Exception.Message)" -Encoding utf8 } catch { }
      } finally {
        if ($bm) { $bm.Dispose() }
      }
    })

  $f.Show()
  Update-FloatVisual

  # ── 拖动 + 点击（状态放 $script: 作用域，否则事件里取不到）──
  $script:FloatDragDown   = $false
  $script:FloatDragMoved  = $false
  $script:FloatDragCursor = [System.Drawing.Point]::new(0, 0)
  $script:FloatDragForm   = [System.Drawing.Point]::new(0, 0)

  $f.Add_MouseDown({
      param($s, $e)
      if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:FloatDragDown   = $true
        $script:FloatDragMoved  = $false
        $script:FloatDragCursor = [System.Windows.Forms.Cursor]::Position
        $script:FloatDragForm   = $script:FloatBtn.Form.Location
      }
    })

  $f.Add_MouseMove({
      param($s, $e)
      try {
        if ($script:FloatDragDown) {
          $now = [System.Windows.Forms.Cursor]::Position
          $dx = $now.X - $script:FloatDragCursor.X
          $dy = $now.Y - $script:FloatDragCursor.Y
          if ([Math]::Abs($dx) -gt 3 -or [Math]::Abs($dy) -gt 3) { $script:FloatDragMoved = $true }
          if ($script:FloatDragMoved) {
            $script:FloatBtn.Form.Location = [System.Drawing.Point]::new(
              $script:FloatDragForm.X + $dx, $script:FloatDragForm.Y + $dy)
          }
        }
      } catch { }
    })

  $f.Add_MouseUp({
      param($s, $e)
      if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $wasDrag = $script:FloatDragMoved
        $script:FloatDragDown  = $false
        $script:FloatDragMoved = $false
        if ($wasDrag) { Save-FloatPosition }
        elseif ($script:OnFloatToggle) {
          try { & $script:OnFloatToggle } catch {
            try { Add-Content -Path (Join-Path $env:TEMP 'voice-typer-error.log') `
                    -Value "听写切换失败: $($_.Exception.Message)" -Encoding utf8 } catch { }
          }
        }
      }
    })

  # 拖动结束后把最终位置推一次，避免残留
  $f.Add_LocationChanged({ })

  # ── 右键菜单 ──
  $menu = [System.Windows.Forms.ContextMenuStrip]::new()
  $menu.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 9.5)
  $miSet = $menu.Items.Add('设置…')
  $miSet.Add_Click({ if ($script:OnFloatSettings) { & $script:OnFloatSettings } })
  $miHide = $menu.Items.Add('隐藏悬浮按钮')
  $miHide.Add_Click({
      $script:Cfg.showFloat = $false
      Save-Config -Config $script:Cfg | Out-Null
      Hide-FloatButton
    })
  [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
  $miExit = $menu.Items.Add('退出')
  $miExit.Add_Click({ if ($script:OnExitRequest) { & $script:OnExitRequest } })
  $f.ContextMenuStrip = $menu

  Set-FloatState -State 'idle'
}

function Show-FloatButton {
  if (-not $script:FloatBtn) { Start-FloatButton; return }
  $script:FloatBtn.Form.Show()
  Update-FloatVisual
}

function Hide-FloatButton {
  if ($script:FloatBtn -and $script:FloatBtn.Form.Visible) { $script:FloatBtn.Form.Hide() }
}

# 某个状态要不要定时器不停重绘，由配色表的 anim 决定
function Test-FloatAnimates {
  param([string]$State)
  $pal = $script:FloatPalette[$State]
  return [bool]($pal -and $pal.anim)
}

function Set-FloatState {
  param([ValidateSet('idle', 'recording', 'working', 'correcting', 'ok')][string]$State)
  if (-not $script:FloatBtn) { return }
  $st = $script:FloatBtn.State
  $prev = $st.State
  $st.State = $State
  if (Test-FloatAnimates $State) {
    # 换了状态就把相位归零，动画从头开始
    if ($prev -ne $State) { $st.T0 = [datetime]::Now }
  } else {
    $st.Pulse = 0.0
    $st.T0    = $null
  }
  Update-FloatVisual
}

function Update-FloatPulse {
  if (-not $script:FloatBtn) { return }
  $st = $script:FloatBtn.State
  if (-not (Test-FloatAnimates $st.State)) { return }
  if (-not $st.T0) { $st.T0 = [datetime]::Now }
  # 相位按真实时间算，而不是每次 += 固定值：定时器本身有抖动，
  # 累加会让动画忽快忽慢。周期由配色表给。
  $period = [double]$script:FloatPalette[$st.State].period
  $st.Pulse = ((([datetime]::Now - $st.T0).TotalSeconds / $period) % 1.0)
  Update-FloatVisual
}

function Apply-FloatSize {
  if (-not $script:FloatBtn) { return }
  $s = [int]$script:Cfg.floatSize
  try {
    $f = $script:FloatBtn.Form
    $f.MinimumSize = [System.Drawing.Size]::new(0, 0)
    $f.MaximumSize = [System.Drawing.Size]::new(0, 0)
    $f.ClientSize  = [System.Drawing.Size]::new($s, $s)
    $f.MinimumSize = [System.Drawing.Size]::new($s, $s)
    $f.MaximumSize = [System.Drawing.Size]::new($s, $s)
    if (-not $script:FloatIsLayered) {
      Set-FloatWindowRegion -Handle $f.Handle -Size $s   # 尺寸变了要重建圆形区域
    }
    Update-FloatVisual
  } catch { }
}

function Stop-FloatButton {
  if ($script:FloatBtn) {
    try { $script:FloatBtn.Form.Close(); $script:FloatBtn.Form.Dispose() } catch { }
    $script:FloatBtn = $null
  }
  $script:FloatIsLayered = $false
}
