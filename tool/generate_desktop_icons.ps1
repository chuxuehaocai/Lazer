param(
  [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$backgroundColor = [System.Drawing.Color]::White
$inkColor = [System.Drawing.Color]::FromArgb(255, 76, 76, 76)
$cache = @{}

function New-RoundedRectanglePath {
  param(
    [float]$X,
    [float]$Y,
    [float]$Width,
    [float]$Height,
    [float]$Radius
  )

  $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
  $diameter = $Radius * 2
  $path.AddArc($X, $Y, $diameter, $diameter, 180, 90)
  $path.AddArc($X + $Width - $diameter, $Y, $diameter, $diameter, 270, 90)
  $path.AddArc(
    $X + $Width - $diameter,
    $Y + $Height - $diameter,
    $diameter,
    $diameter,
    0,
    90
  )
  $path.AddArc($X, $Y + $Height - $diameter, $diameter, $diameter, 90, 90)
  $path.CloseFigure()
  return $path
}

function New-IconBitmap {
  param([int]$Size)

  $workingSize = $Size * 4
  $unit = $workingSize / 1024.0
  $bitmap = [System.Drawing.Bitmap]::new(
    $workingSize,
    $workingSize,
    [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
  )
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.Clear([System.Drawing.Color]::Transparent)
  $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $graphics.CompositingQuality =
    [System.Drawing.Drawing2D.CompositingQuality]::HighQuality

  $backgroundBrush = [System.Drawing.SolidBrush]::new($backgroundColor)
  $backgroundPath = New-RoundedRectanglePath `
    0 0 $workingSize $workingSize (224 * $unit)
  $graphics.FillPath($backgroundBrush, $backgroundPath)
  $graphics.SetClip($backgroundPath)

  $inkBrush = [System.Drawing.SolidBrush]::new($inkColor)

  $lPen = [System.Drawing.Pen]::new($inkColor, 47 * $unit)
  $lPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $lPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $lPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
  $lPoints = [System.Drawing.PointF[]]@(
    [System.Drawing.PointF]::new(290 * $unit, 379 * $unit),
    [System.Drawing.PointF]::new(290 * $unit, 731 * $unit),
    [System.Drawing.PointF]::new(640 * $unit, 731 * $unit)
  )
  $graphics.DrawLines($lPen, $lPoints)

  $frontPath = New-RoundedRectanglePath `
    (363 * $unit) (253 * $unit) (402 * $unit) (408 * $unit) (55 * $unit)
  $frontRegion = [System.Drawing.Region]::new($frontPath)
  $headPath = [System.Drawing.Drawing2D.GraphicsPath]::new()
  $headPath.AddEllipse(443 * $unit, 483 * $unit, 130 * $unit, 130 * $unit)
  $stemPath = New-RoundedRectanglePath `
    (548 * $unit) (347 * $unit) (52 * $unit) (183 * $unit) (16 * $unit)
  $flagPath = New-RoundedRectanglePath `
    (548 * $unit) (337 * $unit) (111 * $unit) (48 * $unit) (24 * $unit)
  $noteRegion = [System.Drawing.Region]::new($headPath)
  $noteRegion.Union([System.Drawing.Region]::new($stemPath))
  $noteRegion.Union([System.Drawing.Region]::new($flagPath))
  $frontRegion.Exclude($noteRegion)
  $graphics.FillRegion($inkBrush, $frontRegion)

  $graphics.Dispose()
  $backgroundBrush.Dispose()
  $backgroundPath.Dispose()
  $inkBrush.Dispose()
  $lPen.Dispose()
  $frontPath.Dispose()
  $frontRegion.Dispose()
  $headPath.Dispose()
  $stemPath.Dispose()
  $flagPath.Dispose()
  $noteRegion.Dispose()
  return $bitmap
}

function Get-IconPngBytes {
  param([int]$Size)

  if ($cache.ContainsKey($Size)) {
    return $cache[$Size]
  }

  $source = New-IconBitmap $Size
  $target = [System.Drawing.Bitmap]::new(
    $Size,
    $Size,
    [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
  )
  $graphics = [System.Drawing.Graphics]::FromImage($target)
  $graphics.Clear([System.Drawing.Color]::Transparent)
  $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
  $graphics.CompositingQuality =
    [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
  $graphics.InterpolationMode =
    [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $destination = [System.Drawing.Rectangle]::new(0, 0, $Size, $Size)
  $graphics.DrawImage(
    $source,
    $destination,
    [System.Drawing.Rectangle]::new(0, 0, $source.Width, $source.Height),
    [System.Drawing.GraphicsUnit]::Pixel
  )
  $graphics.Dispose()
  $source.Dispose()

  $stream = [System.IO.MemoryStream]::new()
  $target.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
  $target.Dispose()
  [byte[]]$bytes = $stream.ToArray()
  $stream.Dispose()
  $cache[$Size] = $bytes
  return $bytes
}

function Write-IconPng {
  param(
    [int]$Size,
    [string]$RelativePath
  )

  $path = Join-Path $RepositoryRoot $RelativePath
  [System.IO.Directory]::CreateDirectory(
    [System.IO.Path]::GetDirectoryName($path)
  ) | Out-Null
  [System.IO.File]::WriteAllBytes($path, (Get-IconPngBytes $Size))
}

function Write-IconFile {
  $sizes = @(16, 24, 32, 48, 64, 128, 256)
  $images = @()
  foreach ($size in $sizes) {
    $images += ,[byte[]](Get-IconPngBytes $size)
  }

  $path = Join-Path $RepositoryRoot 'windows/runner/resources/app_icon.ico'
  [System.IO.Directory]::CreateDirectory(
    [System.IO.Path]::GetDirectoryName($path)
  ) | Out-Null
  $stream = [System.IO.File]::Open(
    $path,
    [System.IO.FileMode]::Create,
    [System.IO.FileAccess]::Write
  )
  $writer = [System.IO.BinaryWriter]::new($stream)
  $writer.Write([uint16]0)
  $writer.Write([uint16]1)
  $writer.Write([uint16]$sizes.Count)
  $offset = 6 + 16 * $sizes.Count
  for ($index = 0; $index -lt $sizes.Count; $index++) {
    $size = $sizes[$index]
    $bytes = $images[$index]
    $writer.Write([byte]($(if ($size -eq 256) { 0 } else { $size })))
    $writer.Write([byte]($(if ($size -eq 256) { 0 } else { $size })))
    $writer.Write([byte]0)
    $writer.Write([byte]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]32)
    $writer.Write([uint32]$bytes.Length)
    $writer.Write([uint32]$offset)
    $offset += $bytes.Length
  }
  foreach ($bytes in $images) {
    $writer.Write($bytes)
  }
  $writer.Dispose()
  $stream.Dispose()
}

Write-IconPng 1024 'assets/app_icon.png'
foreach ($size in @(16, 32, 64, 128, 256, 512, 1024)) {
  Write-IconPng $size (
    "macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$size.png"
  )
}
Write-IconFile
