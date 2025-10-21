param(
  [string]$MavenVersion = '3.9.11',
  [string]$InstallRoot  = '',
  [string]$WorkRoot     = (Join-Path $env:USERPROFILE 'FormScanner'),
  [switch]$PreferMain
)

# All-in-one Windows setup for FormScanner (admin-safe) — FIXED target finder
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Fail($msg) { Write-Host ('ERROR: ' + $msg) -ForegroundColor Red; exit 1 }
function Check-Cmd($name) { $null = Get-Command $name -ErrorAction SilentlyContinue; return $? }
function Is-Admin { try { (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $false } }

# Decide Maven install root
if (-not $InstallRoot -or $InstallRoot.Trim() -eq '') { if (Is-Admin) { $InstallRoot = 'C:\\Program Files\\Maven' } else { $InstallRoot = Join-Path $env:LOCALAPPDATA 'Maven' } }
Write-Host ('>>> Maven will be installed under: ' + $InstallRoot) -ForegroundColor Cyan

# Ensure Git + JDK + Maven (same as previous fixed scripts)
if (-not (Check-Cmd 'winget')) { Write-Host 'winget not found. If installs fail, install App Installer from Microsoft Store.' -ForegroundColor Yellow }
if (-not (Check-Cmd 'git')) { if (Check-Cmd 'winget') { winget install --id Git.Git -e --accept-source-agreements --accept-package-agreements | Out-Null }; if (-not (Check-Cmd 'git')) { Fail 'Git install failed or not on PATH.' } }
if (-not (Check-Cmd 'java')) { if (Check-Cmd 'winget') { winget install --id EclipseAdoptium.Temurin.17.JDK -e --accept-source-agreements --accept-package-agreements | Out-Null }; if (-not (Check-Cmd 'java')) { Fail 'Java JDK not found after attempted install.' } }
function Ensure-Maven([string]$MvnVersion, [string]$Root) {
  if (Check-Cmd 'mvn') { return }
  Write-Host '>>> Installing Maven (winget or manual)...' -ForegroundColor Cyan
  $installed = $false
  if (Check-Cmd 'winget') {
    try {
      $pkg = winget search maven --source winget | Select-String -Pattern 'Maven' -SimpleMatch
      if ($pkg) {
        winget install --id Apache.Maven -e --accept-source-agreements --accept-package-agreements -h 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $installed = $true }
        if (-not $installed) {
          winget install --id TheApacheFoundation.Maven -e --accept-source-agreements --accept-package-agreements -h 2>$null | Out-Null
          if ($LASTEXITCODE -eq 0) { $installed = $true }
        }
      }
    } catch { }
  }
  if (-not $installed) {
    $destDir = Join-Path $Root ('apache-maven-' + $MvnVersion)
    $zipUrl  = 'https://dlcdn.apache.org/maven/maven-3/' + $MvnVersion + '/binaries/apache-maven-' + $MvnVersion + '-bin.zip'
    $zipPath = Join-Path $env:TEMP ('apache-maven-' + $MvnVersion + '-bin.zip')
    try { if (-not (Test-Path $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null } } catch { $fallback = Join-Path $env:LOCALAPPDATA 'Maven'; Write-Host ('No write access to ' + $Root + '. Falling back to ' + $fallback + '.') -ForegroundColor Yellow; $Root = $fallback; if (-not (Test-Path $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }; $destDir = Join-Path $Root ('apache-maven-' + $MvnVersion) }
    Write-Host ('>>> Downloading Maven ' + $MvnVersion + ' ...') -ForegroundColor Cyan
    try { Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing } catch { Fail ('Failed to download Maven from ' + $zipUrl) }
    Write-Host '>>> Extracting...' -ForegroundColor Cyan
    try { if (Test-Path $destDir) { Remove-Item -Recurse -Force $destDir }; Expand-Archive -LiteralPath $zipPath -DestinationPath $Root -Force } catch { Fail 'Failed to extract Maven ZIP.' }
    $bin = Join-Path $destDir 'bin'
    if (Is-Admin) { [Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + $bin, 'Machine') } else { [Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','User') + ';' + $bin, 'User') }
    $env:Path += ';' + $bin
    Write-Host ('Maven installed to: ' + $destDir) -ForegroundColor Green
  }
  if (-not (Check-Cmd 'mvn')) { Fail 'mvn still not on PATH after install.' }
}
Ensure-Maven -MvnVersion $MavenVersion -Root $InstallRoot

# Workspace
$workDir  = $WorkRoot; $formRepo = Join-Path $workDir 'formscanner'
Write-Host ('`n>>> Using working directory: ' + $workDir) -ForegroundColor Cyan
if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir | Out-Null }
if (-not (Test-Path $formRepo)) { Write-Host '>>> Cloning FormScanner...' -ForegroundColor Cyan; git clone https://github.com/ylemkimon/formscanner.git $formRepo | Out-Null } else { Write-Host '>>> Repo already exists. Pulling latest...' -ForegroundColor Cyan; Push-Location $formRepo; git pull --rebase | Out-Null; Pop-Location }

# Quaqua cleanup (same logic as previous) - minimal here to keep focus on target finder
function Remove-Quaqua-From-Poms([string]$RepoPath) {
  $poms = Get-ChildItem -LiteralPath $RepoPath -Recurse -Filter 'pom.xml' -File
  foreach ($pomFile in $poms) {
    try { [xml]$pom = Get-Content -LiteralPath $pomFile.FullName -Encoding UTF8 } catch { continue }
    $deps = $pom.SelectNodes("//*[local-name()='dependency'][* [local-name()='groupId' and text()='ch.randelshofer'] and *[local-name()='artifactId' and text()='quaqua']]")
    if ($deps) { foreach ($d in @($deps)) { $null = $d.ParentNode.RemoveChild($d) }; $utf8 = New-Object System.Text.UTF8Encoding($false); $sw = New-Object System.IO.StreamWriter($pomFile.FullName, $false, $utf8); $pom.Save($sw); $sw.Close(); Write-Host ('Removed Quaqua from: ' + $pomFile.FullName) -ForegroundColor Yellow }
  }
}
Remove-Quaqua-From-Poms -RepoPath $formRepo

# Build all modules
Write-Host '>>> Building with Maven (multi-module)...' -ForegroundColor Cyan
Push-Location $formRepo; mvn -U clean install; $lastExit = $LASTEXITCODE; Pop-Location
if ($lastExit -ne 0) { Fail ('Maven build failed (exit ' + $lastExit + '). Scroll up for errors.') }

# ---- FIXED: locate the runnable JAR anywhere under the repo ---------------
# Prefer main module jar, else latest non-sources/javadoc jar
$allJars = Get-ChildItem -LiteralPath $formRepo -Recurse -Filter '*.jar' -File |
  Where-Object { $_.Name -match 'formscanner' -and $_.Name -notmatch '(?i)(sources|javadoc|tests|original)\.jar$' }

if (-not $allJars -or $allJars.Count -eq 0) {
  Fail "Build finished but no JARs were produced under submodule targets."
}

# Try to pick main module first
$mainJar = $allJars | Where-Object { $_.FullName -match 'formscanner-main\\target' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$chosen = $null
if ($PreferMain -and $mainJar) { $chosen = $mainJar }
if (-not $chosen) {
  $chosen = $allJars | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

Write-Host ('>>> Selected JAR: ' + $chosen.FullName) -ForegroundColor Green
Write-Host ('    Module path : ' + (Split-Path $chosen.FullName -Parent)) -ForegroundColor DarkGray

Write-Host "`nRun FormScanner with:" -ForegroundColor Cyan
$cmd = 'java -jar "{0}"' -f $chosen.FullName
Write-Host $cmd -ForegroundColor Yellow

# Optional auto-run
# Start-Process -FilePath 'java' -ArgumentList ('-jar', $chosen.FullName)