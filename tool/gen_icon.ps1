# Crop the main content of the source image and generate app icon assets:
#   assets/icon.png            1024x1024 white square master
#   assets/icon_foreground.png 1024x1024 transparent adaptive foreground (66% safe zone)
# Usage: powershell -File tool\gen_icon.ps1 -Source D:\others\test1\icon.png
param(
  [string]$Source = "D:\others\test1\icon.png"
)

Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $MyInvocation.MyCommand.Path   # <project>\tool
$project = Split-Path -Parent $root
$assets = Join-Path $project "assets"
New-Item -ItemType Directory -Force -Path $assets | Out-Null
$outMaster = Join-Path $assets "icon.png"
$outForeground = Join-Path $assets "icon_foreground.png"

$src = [System.Drawing.Bitmap]::FromFile($Source)
$w = $src.Width; $h = $src.Height

function Test-Content([System.Drawing.Color]$c) {
  if ($c.A -lt 16) { return $false }
  if ($c.R -ge 242 -and $c.G -ge 242 -and $c.B -ge 242) { return $false }
  return $true
}

# bounding box of non-white / non-transparent pixels
$minX = $w; $minY = $h; $maxX = -1; $maxY = -1
for ($y = 0; $y -lt $h; $y += 2) {
  for ($x = 0; $x -lt $w; $x += 2) {
    if (Test-Content ($src.GetPixel($x, $y))) {
      if ($x -lt $minX) { $minX = $x }
      if ($x -gt $maxX) { $maxX = $x }
      if ($y -lt $minY) { $minY = $y }
      if ($y -gt $maxY) { $maxY = $y }
    }
  }
}
if ($maxX -lt 0) { $minX = 0; $minY = 0; $maxX = $w - 1; $maxY = $h - 1 }

$pad = [int]((($maxX - $minX) + ($maxY - $minY)) / 2 * 0.02)
$cx = [Math]::Max(0, $minX - $pad)
$cy = [Math]::Max(0, $minY - $pad)
$cw = [Math]::Min($w - $cx, $maxX - $minX + 1 + 2 * $pad)
$ch = [Math]::Min($h - $cy, $maxY - $minY + 1 + 2 * $pad)
$crop = $src.Clone([System.Drawing.Rectangle]::new($cx, $cy, $cw, $ch), $src.PixelFormat)

function New-SquareCanvas([System.Drawing.Bitmap]$image, [int]$size, [bool]$transparent) {
  $bmp = New-Object System.Drawing.Bitmap -ArgumentList $size, $size
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  if ($transparent) { $g.Clear([System.Drawing.Color]::Transparent) }
  else { $g.Clear([System.Drawing.Color]::White) }
  $scale = [float]$size / [Math]::Max($image.Width, $image.Height)
  $dw = [int]($image.Width * $scale)
  $dh = [int]($image.Height * $scale)
  $g.DrawImage($image, [int](($size - $dw) / 2), [int](($size - $dh) / 2), $dw, $dh)
  $g.Dispose()
  return $bmp
}

# master: 1024 white square
$square = New-SquareCanvas $crop 1024 $false
$square.Save($outMaster, [System.Drawing.Imaging.ImageFormat]::Png)

# adaptive foreground: opaque white canvas, logo width = 60% of canvas
# (adaptive mask circle is ~66.7% of the 108dp canvas, wide logo must stay inside)
$fg = New-Object System.Drawing.Bitmap -ArgumentList 1024, 1024
$g2 = [System.Drawing.Graphics]::FromImage($fg)
$g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g2.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
$g2.Clear([System.Drawing.Color]::White)
$inner = [int](1024 * 0.60)
$dw2 = $inner
$dh2 = [int]($inner * [double]$crop.Height / [double]$crop.Width)
$g2.DrawImage($crop, [int]((1024 - $dw2) / 2), [int]((1024 - $dh2) / 2), $dw2, $dh2)
$g2.Dispose()
$fg.Save($outForeground, [System.Drawing.Imaging.ImageFormat]::Png)

$src.Dispose(); $crop.Dispose(); $square.Dispose(); $fg.Dispose()
Write-Output ("content box: ({0},{1})-({2},{3}), crop {4}x{5}" -f $minX, $minY, $maxX, $maxY, $cw, $ch)
Write-Output "master: $outMaster"
Write-Output "foreground: $outForeground"
