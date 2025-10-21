<# 
Preprocess OMR scans so every image matches a template image's pixel size.
- Auto-orient
- Optional deskew
- Trim borders
- Fit inside W x H, then center-pad to exact W x H (default)
- Or strict resize (force exact W x H, may distort)

Usage example:
  .\preprocess-omr.ps1 -Template "C:\OMR\template-blank.jpg" `
                       -InDir "C:\OMR\raw" `
                       -OutDir "C:\OMR\fixed" `
                       -Deskew 40 `
                       -Gray $true `
                       -Binarize $false
#>

param(
  [Parameter(Mandatory = $true)][string]$Template,
  [Parameter(Mandatory = $true)][string]$InDir,
  [Parameter(Mandatory = $true)][string]$OutDir,

  [int]$Deskew = 40,          # set 0 to disable deskew
  [bool]$Gray = $true,
  [bool]$Binarize = $false,   # only if you really need hard thresholding
  [int]$ThresholdPercent = 55,
  [bool]$StrictResize = $false
)

function Fail([string]$m) {
  Write-Host "ERROR: $m" -ForegroundColor Red
  exit 1
}

function Check-Cmd([string]$name) {
  $null = Get-Command $name -ErrorAction SilentlyContinue
  return $?
}

# 0) Pre-checks
if (-not (Test-Path -LiteralPath $Template)) { Fail "Template not found: $Template" }
if (-not (Test-Path -LiteralPath $InDir))    { Fail "Input folder not found: $InDir" }
if (-not (Test-Path -LiteralPath $OutDir))   { New-Item -ItemType Directory -Path $OutDir | Out-Null }

# 1) Ensure ImageMagick is available
if (-not (Check-Cmd "magick")) {
  if (-not (Check-Cmd "winget")) { Fail "ImageMagick not found and winget not available. Install ImageMagick manually." }
  Write-Host "Installing ImageMagick via winget..."
  winget install --id ImageMagick.ImageMagick -e --accept-source-agreements --accept-package-agreements | Out-Null
  if (-not (Check-Cmd "magick")) { Fail "ImageMagick installation failed." }
}

# 2) Read template width/height
try {
  $dim = & magick identify -ping -format "%w %h" $Template
} catch {
  Fail "Failed to read template size with ImageMagick identify."
}
if (-not $dim) { Fail "Could not parse template size." }
$parts = $dim.Trim().Split(' ')
if ($parts.Count -lt 2) { Fail "Unexpected size string from identify: '$dim'" }
[int]$W = $parts[0]
[int]$H = $parts[1]
Write-Host "Template size: ${W}x${H}px"

# 3) Build ImageMagick operation list
$ops = @()
$ops += "-auto-orient"
if ($Deskew -gt 0) { $ops += "-deskew"; $ops += ("{0}%" -f $Deskew) }
$ops += "-trim"; $ops += "+repage"
if ($Gray) { $ops += "-colorspace"; $ops += "Gray" }
if ($Binarize) { $ops += "-threshold"; $ops += ("{0}%" -f $ThresholdPercent) }

if ($StrictResize) {
  # Force exact W x H (distorts shapes slightly)
  $ops += "-resize"; $ops += ("{0}x{1}!" -f $W, $H)
} else {
  # Keep aspect ratio: fit inside then center-pad to exact W x H
  $ops += "-resize"; $ops += ("{0}x{1}" -f $W, $H)
  $ops += "-gravity"; $ops += "center"
  $ops += "-extent";  $ops += ("{0}x{1}" -f $W, $H)
}

# 4) Gather inputs
$patterns = @("*.jpg","*.jpeg","*.png","*.tif","*.tiff","*.bmp")
$inputs = @()
foreach ($p in $patterns) {
  $items = Get-ChildItem -LiteralPath $InDir -Filter $p -File -ErrorAction SilentlyContinue
  if ($items) { $inputs += $items }
}
if ($inputs.Count -eq 0) { Fail "No images found in $InDir (jpg, jpeg, png, tif, tiff, bmp)." }

Write-Host "Found $($inputs.Count) image(s). Processing to $OutDir ..."

# 5) Process each image (normalize to .jpg) — IM v7 syntax
foreach ($f in $inputs) {
  $dst = Join-Path $OutDir ($f.BaseName + ".jpg")
  Write-Host "  -> $($f.Name)"

  # magick <input> <ops...> -units PixelsPerInch -density 300 <output>
  $args = @($f.FullName) + $ops + @('-units','PixelsPerInch','-density','300', $dst)
  & magick @args

  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $dst)) {
    Write-Host "    Warning: failed on $($f.Name)" -ForegroundColor Yellow
  }
}

Write-Host "Done. Output in: $OutDir"
Write-Host ("Tip: Use these processed images with the SAME template used to derive {0}x{1}px." -f $W, $H)
