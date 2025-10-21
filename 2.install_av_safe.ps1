param(
  [string]$WorkRoot = (Join-Path $env:USERPROFILE 'FormScanner')
)

# Bitdefender-friendly installer (fixed quoting again)
# - NO COM objects, NO registry edits, NO PATH changes, NO web downloads
# - Assumes: Git, JDK (java), Maven (mvn) already installed and on PATH
# - Clones/updates repo, removes Quaqua for Windows/Linux, builds,
#   creates run-formscanner.bat in distribution folder, and a Desktop CMD launcher

function Fail($msg) { Write-Host ('ERROR: ' + $msg) -ForegroundColor Red; exit 1 }
function Check-Cmd($name) { $null = Get-Command $name -ErrorAction SilentlyContinue; return $? }

Write-Host '>>> Precheck: verifying required tools (git, java, mvn)...' -ForegroundColor Cyan
if (-not (Check-Cmd 'git'))  { Fail 'Git not found. Please install Git and re-run.' }
if (-not (Check-Cmd 'java')) { Fail 'Java (JDK) not found. Please install JDK 17+ and re-run.' }
if (-not (Check-Cmd 'mvn'))  { Fail 'Maven not found. Please install Maven and re-run.' }

# Workspace
$workDir  = $WorkRoot
$formRepo = Join-Path $workDir 'formscanner'
if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir | Out-Null }

if (-not (Test-Path $formRepo)) {
  Write-Host '>>> Cloning FormScanner...' -ForegroundColor Cyan
  git clone https://github.com/sajidmc/formscanner.git $formRepo | Out-Null
  if (-not (Test-Path $formRepo)) { Fail 'Git clone failed.' }
} else {
  Write-Host '>>> Repo exists. Pulling latest...' -ForegroundColor Cyan
  Push-Location $formRepo; git pull --rebase | Out-Null; Pop-Location
}

# Quaqua removal (Windows/Linux)
function Remove-Quaqua-From-Poms([string]$RepoPath) {
  $poms = Get-ChildItem -LiteralPath $RepoPath -Recurse -Filter 'pom.xml' -File
  foreach ($pomFile in $poms) {
    try { [xml]$pom = Get-Content -LiteralPath $pomFile.FullName -Encoding UTF8 } catch { continue }
    $deps = $pom.SelectNodes("//*[local-name()='dependency'][* [local-name()='groupId' and text()='ch.randelshofer'] and *[local-name()='artifactId' and text()='quaqua']]")
    if ($deps) {
      foreach ($d in @($deps)) { $null = $d.ParentNode.RemoveChild($d) }
      $utf8 = New-Object System.Text.UTF8Encoding($false)
      $sw = New-Object System.IO.StreamWriter($pomFile.FullName, $false, $utf8)
      $pom.Save($sw); $sw.Close()
      Write-Host ('Removed Quaqua from: ' + $pomFile.FullName) -ForegroundColor Yellow
    }
  }
}
function Add-Quaqua-MacProfile-To-GUI([string]$RepoPath) {
  $pomPath = Join-Path $RepoPath 'formscanner-gui\pom.xml'
  if (-not (Test-Path $pomPath)) { return }
  [xml]$pom = Get-Content -LiteralPath $pomPath -Encoding UTF8
  $nsUri = $pom.project.xmlns; if (-not $nsUri) { $nsUri = 'http://maven.apache.org/POM/4.0.0'; $pom.project.SetAttribute('xmlns',$nsUri) }
  $ns = New-Object System.Xml.XmlNamespaceManager($pom.NameTable); $ns.AddNamespace('m',$nsUri)
  function New-Node([string]$n){ return $pom.CreateElement($n, $nsUri) }
  $profiles = $pom.project.profiles; if ($profiles -eq $null) { $profiles = New-Node 'profiles'; $null = $pom.project.AppendChild($profiles) }
  $existingProfile = $pom.SelectSingleNode("//m:project/m:profiles/m:profile[m:id='mac-quaqua']", $ns)
  if ($existingProfile -eq $null) {
    $profile = New-Node 'profile'
    $id = New-Node 'id'; $id.InnerText = 'mac-quaqua'; $profile.AppendChild($id) | Out-Null
    $activation = New-Node 'activation'; $os = New-Node 'os'; $family = New-Node 'family'; $family.InnerText = 'mac'; $os.AppendChild($family) | Out-Null; $activation.AppendChild($os) | Out-Null; $profile.AppendChild($activation) | Out-Null
    $deps = New-Node 'dependencies'; $d = New-Node 'dependency'
    $g = New-Node 'groupId'; $g.InnerText = 'ch.randelshofer'; $d.AppendChild($g) | Out-Null
    $a = New-Node 'artifactId'; $a.InnerText = 'quaqua'; $d.AppendChild($a) | Out-Null
    $v = New-Node 'version'; $v.InnerText = '8.0'; $d.AppendChild($v) | Out-Null
    $scope = New-Node 'scope'; $scope.InnerText = 'runtime'; $d.AppendChild($scope) | Out-Null
    $deps.AppendChild($d) | Out-Null; $profile.AppendChild($deps) | Out-Null; $profiles.AppendChild($profile) | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding($false); $sw = New-Object System.IO.StreamWriter($pomPath, $false, $utf8); $pom.Save($sw); $sw.Close()
    Write-Host 'Added mac-quaqua profile to GUI pom.' -ForegroundColor Green
  }
}

Remove-Quaqua-From-Poms -RepoPath $formRepo
Add-Quaqua-MacProfile-To-GUI -RepoPath $formRepo

# Build
Write-Host '>>> Building with Maven (multi-module)...' -ForegroundColor Cyan
Push-Location $formRepo; mvn -U clean install; $lastExit = $LASTEXITCODE; Pop-Location
if ($lastExit -ne 0) { Fail ('Maven build failed (exit ' + $lastExit + '). Scroll up for errors.') }

# Find distribution bin folder
$distBin = Get-ChildItem -LiteralPath (Join-Path $formRepo 'formscanner-distribution\target') -Directory -Recurse -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '-bin$' -and (Test-Path (Join-Path $_.FullName 'lib')) } |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
if (-not $distBin) { Fail 'Build succeeded but could not locate distribution bin folder with lib\' }
Write-Host ('>>> Distribution folder: ' + $distBin.FullName) -ForegroundColor Cyan

# Create run-formscanner.bat (classpath launcher) using a double-quoted here-string
$batPath = Join-Path $distBin.FullName 'run-formscanner.bat'
$batBody = @"
@echo off
REM Run FormScanner from the distribution folder using the correct classpath
REM Usage (GUI mode):   run-formscanner.bat
REM Usage (CLI mode):   run-formscanner.bat "C:\path\to\template.fst" "C:\path\to\imagesDir"

setlocal enabledelayedexpansion
set "ROOT=%~dp0"
if exist "%ROOT%lib\" (
  set "LIBDIR=%ROOT%lib"
) else (
  if exist "%ROOT%..\lib\" (
    set "LIBDIR=%ROOT%..\lib"
  ) else (
    echo [ERROR] Could not find lib\ folder next to this script.
    echo Place this script in: formscanner-distribution\target\formscanner-*-bin\ and run it there.
    exit /b 1
  )
)
set "CP=%LIBDIR%\*"
set "MAIN=com.albertoborsetta.formscanner.main.FormScanner"
if "%~2"=="" (
  echo Launching GUI...
  java -cp "%CP%" %MAIN%
) else (
  echo Launching CLI with template: %1 and imagesDir: %2
  java -cp "%CP%" %MAIN% "%~1" "%~2"
)
endlocal
"@

$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($batPath, $batBody, $utf8)
Write-Host ('Created: ' + $batPath) -ForegroundColor Green

# Create Desktop CMD launcher with a double-quoted here-string (expands $batPath safely)
$desktop = [Environment]::GetFolderPath('Desktop')
if (-not $desktop -or $desktop -eq '') { $desktop = Join-Path $env:USERPROFILE 'Desktop' }
$cmdPath = Join-Path $desktop 'FormScanner.cmd'
$cmdBody = @"
@echo off
call "$batPath"
"@
[IO.File]::WriteAllText($cmdPath, $cmdBody, $utf8)
Write-Host ('Desktop launcher created: ' + $cmdPath) -ForegroundColor Green

Write-Host "`nRun now with:" -ForegroundColor Cyan
Write-Host ('"' + $cmdPath + '"') -ForegroundColor Yellow
