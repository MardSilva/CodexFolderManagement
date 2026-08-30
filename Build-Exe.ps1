[CmdletBinding()]
param(
    [string]$OutputPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not $OutputPath) { $OutputPath = Join-Path $PSScriptRoot 'CodexChatManager.exe' }
$sourcePath = Join-Path $PSScriptRoot 'CodexChatManager.ps1'
$assetsPath = Join-Path $PSScriptRoot 'assets'
$iconPath = Join-Path $assetsPath 'CodexChatManager.ico'
$logoPath = Join-Path $assetsPath 'CodexChatManager.png'
$outputPath = [IO.Path]::GetFullPath($OutputPath)
$temporaryOutput = Join-Path ([IO.Path]::GetDirectoryName($outputPath)) ".$(Split-Path -Leaf $outputPath).building-$([Guid]::NewGuid().ToString('N')).exe"

function New-CodexChatManagerIcon {
    param(
        [string]$IconPath,
        [string]$PngPath
    )

    Add-Type -AssemblyName System.Drawing
    $bitmap = New-Object System.Drawing.Bitmap(256, 256, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([Drawing.Color]::Transparent)

    $background = New-Object Drawing.Drawing2D.GraphicsPath
    $background.AddArc(8, 8, 48, 48, 180, 90)
    $background.AddArc(200, 8, 48, 48, 270, 90)
    $background.AddArc(200, 200, 48, 48, 0, 90)
    $background.AddArc(8, 200, 48, 48, 90, 90)
    $background.CloseFigure()

    $backgroundBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 20, 48, 78))
    $folderBrush = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 41, 171, 226))
    $paperBrush = New-Object Drawing.SolidBrush([Drawing.Color]::White)
    $linePen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(255, 20, 48, 78), 13)
    $linePen.StartCap = [Drawing.Drawing2D.LineCap]::Round
    $linePen.EndCap = [Drawing.Drawing2D.LineCap]::Round

    try {
        $graphics.FillPath($backgroundBrush, $background)
        $graphics.FillRectangle($folderBrush, 35, 79, 186, 128)
        $graphics.FillRectangle($folderBrush, 35, 58, 82, 42)
        $graphics.FillPolygon($folderBrush, [Drawing.Point[]]@(
            (New-Object Drawing.Point(35, 79)),
            (New-Object Drawing.Point(221, 79)),
            (New-Object Drawing.Point(207, 207)),
            (New-Object Drawing.Point(49, 207))
        ))

        $graphics.FillEllipse($paperBrush, 78, 91, 116, 91)
        $graphics.FillPolygon($paperBrush, [Drawing.Point[]]@(
            (New-Object Drawing.Point(101, 166)),
            (New-Object Drawing.Point(91, 198)),
            (New-Object Drawing.Point(132, 176))
        ))
        $graphics.DrawLine($linePen, 111, 126, 161, 126)
        $graphics.DrawLine($linePen, 111, 151, 148, 151)

        $bitmap.Save($PngPath, [Drawing.Imaging.ImageFormat]::Png)

        $rectangle = New-Object Drawing.Rectangle(0, 0, 256, 256)
        $bitmapData = $bitmap.LockBits($rectangle, [Drawing.Imaging.ImageLockMode]::ReadOnly, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $stride = [Math]::Abs($bitmapData.Stride)
            $rowBytes = New-Object byte[] (256 * 4)
            $pixelStream = New-Object IO.MemoryStream
            try {
                for ($row = 255; $row -ge 0; $row--) {
                    $rowAddress = [IntPtr]::Add($bitmapData.Scan0, $row * $stride)
                    [Runtime.InteropServices.Marshal]::Copy($rowAddress, $rowBytes, 0, $rowBytes.Length)
                    $pixelStream.Write($rowBytes, 0, $rowBytes.Length)
                }
                $pixelBytes = $pixelStream.ToArray()
            }
            finally {
                $pixelStream.Dispose()
            }
        }
        finally {
            $bitmap.UnlockBits($bitmapData)
        }

        $fileStream = New-Object IO.FileStream($IconPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $writer = New-Object IO.BinaryWriter($fileStream)
        try {
            $maskBytes = New-Object byte[] (256 * 32)
            $imageSize = 40 + $pixelBytes.Length + $maskBytes.Length

            $writer.Write([uint16]0)
            $writer.Write([uint16]1)
            $writer.Write([uint16]1)
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([uint16]1)
            $writer.Write([uint16]32)
            $writer.Write([uint32]$imageSize)
            $writer.Write([uint32]22)

            $writer.Write([uint32]40)
            $writer.Write([int32]256)
            $writer.Write([int32]512)
            $writer.Write([uint16]1)
            $writer.Write([uint16]32)
            $writer.Write([uint32]0)
            $writer.Write([uint32]$pixelBytes.Length)
            $writer.Write([int32]0)
            $writer.Write([int32]0)
            $writer.Write([uint32]0)
            $writer.Write([uint32]0)
            $writer.Write($pixelBytes)
            $writer.Write($maskBytes)
        }
        finally {
            $writer.Dispose()
            $fileStream.Dispose()
        }
    }
    finally {
        $linePen.Dispose()
        $paperBrush.Dispose()
        $folderBrush.Dispose()
        $backgroundBrush.Dispose()
        $background.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $sourcePath)) {
    throw "Main script not found: $sourcePath"
}

$module = Get-Module -ListAvailable ps2exe | Sort-Object Version -Descending | Select-Object -First 1
if (-not $module) {
    throw "The PS2EXE module is not installed. Run: Install-Module ps2exe -Scope CurrentUser"
}

$outputDirectory = [IO.Path]::GetDirectoryName($outputPath)
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $assetsPath)) {
    New-Item -ItemType Directory -Path $assetsPath -Force | Out-Null
}

New-CodexChatManagerIcon -IconPath $iconPath -PngPath $logoPath
Import-Module $module.Path -Force

try {
    Invoke-PS2EXE `
        -InputFile $sourcePath `
        -OutputFile $temporaryOutput `
        -IconFile $iconPath `
        -NoConsole `
        -STA `
        -x64 `
        -DPIAware `
        -SupportOS `
        -Title 'Codex Chat Manager' `
        -Product 'Codex Chat Manager' `
        -Description 'Local Codex conversation manager for Windows' `
        -Company 'Codex Folder Management' `
        -Copyright 'Codex Folder Management' `
        -Version '1.2.0.0'

    if (-not (Test-Path -LiteralPath $temporaryOutput)) {
        throw 'PS2EXE finished without creating the executable.'
    }

    Move-Item -LiteralPath $temporaryOutput -Destination $outputPath -Force
    $executable = Get-Item -LiteralPath $outputPath
    Write-Host "Executable created: $($executable.FullName)"
    Write-Host "Size: $([Math]::Round($executable.Length / 1KB, 1)) KB"
    Write-Host "Version: $($executable.VersionInfo.FileVersion)"
    Write-Host "PNG logo: $logoPath"
}
finally {
    if (Test-Path -LiteralPath $temporaryOutput) {
        Remove-Item -LiteralPath $temporaryOutput -Force -ErrorAction SilentlyContinue
    }
}
