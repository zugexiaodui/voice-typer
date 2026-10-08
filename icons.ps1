# 用 WPF 把 SVG 路径数据渲染成位图，再交给 GDI+ 使用。
# WPF 的 Geometry.Parse 与 SVG path 的 d 属性语法完全兼容，
# 所以可以原样使用专业图标库的路径数据，不需要任何手工绘制。

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Drawing

function Convert-SvgPathToBitmap {
  param(
    [Parameter(Mandatory)][string]$PathData,
    [int]$PixelSize = 128,
    [string]$Color = '#FFFFFF',
    [double]$FitRatio = 0.84,          # 图标占画布的比例
    [double]$ViewBoxW = 24.0,          # 原始画布宽
    [double]$ViewBoxH = 24.0           # 原始画布高
  )

  $geo = [System.Windows.Media.Geometry]::Parse($PathData)
  $b = $geo.Bounds
  if ($b.Width -le 0 -or $b.Height -le 0) { throw '路径包围盒为空' }

  # 把几何体平移到原点
  $shift = [System.Windows.Media.TranslateTransform]::new(-$b.X, -$b.Y)
  $flat = $geo.GetFlattenedPathGeometry()
  $flat.Transform = $shift
  $fl = $flat.Bounds

  # 等比缩放：把几何体塞进 $PixelSize * FitRatio 的方框内
  $target = $PixelSize * $FitRatio
  $scale = [Math]::Min($target / $fl.Width, $target / $fl.Height)
  # 居中：缩放后几何体应位于画布正中
  $offX = ($PixelSize - $fl.Width * $scale) / 2.0
  $offY = ($PixelSize - $fl.Height * $scale) / 2.0

  $visual = [System.Windows.Media.DrawingVisual]::new()
  $dc = $visual.RenderOpen()
  $brush = [System.Windows.Media.SolidColorBrush]::new(
             [System.Windows.Media.ColorConverter]::ConvertFromString($Color))
  $dc.PushTransform([System.Windows.Media.TranslateTransform]::new($offX, $offY))
  $dc.PushTransform([System.Windows.Media.ScaleTransform]::new($scale, $scale))
  $dc.DrawGeometry($brush, $null, $flat)
  $dc.Pop(); $dc.Pop()
  $dc.Close()

  $rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(
           $PixelSize, $PixelSize, 96, 96,
           [System.Windows.Media.PixelFormats]::Pbgra32)
  $rtb.Render($visual)

  # 转成 GDI+ 位图（走 PNG 内存流，保持 Alpha）
  $enc = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
  $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
  $ms = [System.IO.MemoryStream]::new()
  $enc.Save($ms)
  $ms.Position = 0
  $bmp = [System.Drawing.Bitmap]::FromStream($ms)
  $ms.Dispose()
  return $bmp
}

# ── 图标库路径数据（全部来自官方仓库，filled 风格）──
$script:IconPaths = @{
  # Material Symbols — Apache-2.0
  'material' = @{
    d = 'M12 14c1.66 0 2.99-1.34 2.99-3L15 5c0-1.66-1.34-3-3-3S9 3.34 9 5v6c0 1.66 1.34 3 3 3zm5.3-3c0 3-2.54 5.1-5.3 5.1S6.7 14 6.7 11H5c0 3.41 2.72 6.23 6 6.72V21h2v-3.28c3.28-.48 6-3.3 6-6.72h-1.7z'
    vb = 24; license = 'Apache-2.0'; by = 'Google Material Symbols'
  }
  # Tabler Icons (filled) — MIT
  'tabler' = @{
    d = 'M19 9a1 1 0 0 1 1 1a8 8 0 0 1 -6.999 7.938l-.001 2.062h3a1 1 0 0 1 0 2h-8a1 1 0 0 1 0 -2h3v-2.062a8 8 0 0 1 -7 -7.938a1 1 0 1 1 2 0a6 6 0 0 0 12 0a1 1 0 0 1 1 -1m-7 -8a4 4 0 0 1 4 4v5a4 4 0 1 1 -8 0v-5a4 4 0 0 1 4 -4'
    vb = 24; license = 'MIT'; by = 'Tabler Icons'
  }
  # Phosphor Icons (fill) — MIT
  'phosphor' = @{
    d = 'M80,128V64a48,48,0,0,1,96,0v64a48,48,0,0,1-96,0Zm128,0a8,8,0,0,0-16,0,64,64,0,0,1-128,0,8,8,0,0,0-16,0,80.11,80.11,0,0,0,72,79.6V240a8,8,0,0,0,16,0V207.6A80.11,80.11,0,0,0,208,128Z'
    vb = 256; license = 'MIT'; by = 'Phosphor Icons'
  }
}

function Get-IconByKey {
  param([string]$Key)
  if (-not $script:IconPaths.ContainsKey($Key)) { throw "未知图标: $Key" }
  return $script:IconPaths[$Key]
}

# 把指定图标渲染成白色，叠加到按钮上（用于预览和实际绘制）
function Draw-IconOnGraphics {
  param(
    [System.Drawing.Graphics]$G,
    [string]$IconKey,
    [double]$CenterX,
    [double]$CenterY,
    [double]$Diameter,
    [System.Drawing.Color]$Color,
    [double]$VerticalNudge = 0.012     # 向下微调比例：细长支架会造成视觉偏上，补偿一点点
  )
  $info = Get-IconByKey -Key $IconKey
  $px = [int][Math]::Max(16, [Math]::Round($Diameter))
  $col = '#{0:X2}{1:X2}{2:X2}' -f $Color.R, $Color.G, $Color.B
  $bmp = Convert-SvgPathToBitmap -PathData $info.d -PixelSize $px -Color $col -FitRatio 0.98
  $dy = $px * $VerticalNudge
  $G.DrawImage($bmp, [float]($CenterX - $px / 2.0), [float]($CenterY - $px / 2.0 + $dy), $px, $px)
  $bmp.Dispose()
}
