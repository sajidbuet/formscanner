param(
  [string]$RepoUrl = "https://github.com/sajidbuet/formscanner.git",
  [string]$Branch  = "main",
  [string]$WorkDir = "$env:USERPROFILE\FormScanner",
  [switch]$CreateDesktopShortcut,
  [switch]$ForceClean
)

# ---------- helpers ----------
function Fail($msg) { Write-Host ""; Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }
function Info($msg){ Write-Host ">>> $msg" -ForegroundColor Cyan }
function Warn($msg){ Write-Host "!!  $msg" -ForegroundColor Yellow }
function Ok($msg)  { Write-Host "OK: $msg" -ForegroundColor Green }
function Test-Cmd($name){ $null = Get-Command $name -ErrorAction SilentlyContinue; return $?
}
function Install-WingetPackage($id){
  Info "Installing $id via winget"
  winget install --id $id -e --silent --accept-source-agreements --accept-package-agreements | Out-Null
}

# ---------- prereq ----------
Info "Checking prerequisites"
if (-not (Test-Cmd "winget")) { Fail "winget not found. Install 'App Installer' from Microsoft Store and re-run." }
if (-not (Test-Cmd "git")) { Install-WingetPackage "Git.Git"; if (-not (Test-Cmd "git")) { Fail "Git install failed or not on PATH." } }
if (-not (Test-Cmd "java")) { Install-WingetPackage "EclipseAdoptium.Temurin.17.JDK" }
if (-not (Test-Cmd "mvn"))  { Install-WingetPackage "Apache.Maven" }

# refresh PATH for current process
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine")

Info "Verifying toolchain"
if (-not (Test-Cmd "java"))  { Fail "java not on PATH" }
if (-not (Test-Cmd "javac")) { Fail "javac not on PATH (JDK required)" }
if (-not (Test-Cmd "mvn"))   { Fail "mvn not on PATH" }
Write-Host "java -version:"  -ForegroundColor DarkGray;  java -version
Write-Host "javac -version:" -ForegroundColor DarkGray;  javac -version
Write-Host "mvn -version:"   -ForegroundColor DarkGray;  mvn -version

# ---------- workspace ----------
Info "Preparing workspace: $WorkDir"
if ($ForceClean -and (Test-Path $WorkDir)) {
  Warn "ForceClean enabled: removing $WorkDir"
  Remove-Item -LiteralPath $WorkDir -Recurse -Force
}
if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir | Out-Null }

# ---------- clone / update ----------
$repoName = ([IO.Path]::GetFileNameWithoutExtension(($RepoUrl -replace '\.git$','')))
$repoDir  = Join-Path $WorkDir $repoName

if (-not (Test-Path $repoDir)) {
  Info "Cloning $RepoUrl -> $repoDir"
  git clone $RepoUrl $repoDir | Out-Null
  if (-not (Test-Path $repoDir)) { Fail "Clone failed for $RepoUrl" }
} else {
  Info "Repository exists -> $repoDir"
}

Push-Location $repoDir
git fetch --all --prune | Out-Null
$hasBranch = git branch --all | Select-String -SimpleMatch ("remotes/origin/" + $Branch)
if ($hasBranch) {
  git checkout $Branch | Out-Null
  git pull --rebase origin $Branch | Out-Null
} else {
  Warn "Branch '$Branch' not found on origin. Keeping current branch."
}
Pop-Location

# ---------- POM patch (shade + macOS-only Quaqua) ----------
function Patch-GuiPom {
  param([string]$PomPath)

  if (-not (Test-Path $PomPath)) { Fail "pom.xml not found at $PomPath" }

  [xml]$pom = Get-Content -LiteralPath $PomPath
  $nsUri = $pom.DocumentElement.NamespaceURI
  $mgr   = New-Object System.Xml.XmlNamespaceManager($pom.NameTable)
  $pfx   = 'm'
  if ($nsUri) { $mgr.AddNamespace($pfx, $nsUri) }

  function NX([string]$name,[string]$text){
    if ($nsUri) { $el = $pom.CreateElement($name,$nsUri) } else { $el = $pom.CreateElement($name) }
    if ($text) { $el.InnerText = $text }
    return $el
  }
  function S1([string]$xp){
    if ($nsUri) { return $pom.SelectSingleNode($xp.Replace('//','//m:').Replace('/','/m:'), $mgr) }
    else        { return $pom.SelectSingleNode($xp) }
  }
  function S([string]$xp){
    if ($nsUri) { return $pom.SelectNodes($xp.Replace('//','//m:').Replace('/','/m:'), $mgr) }
    else        { return $pom.SelectNodes($xp) }
  }

  # Ensure <properties> with values
  $props = S1('/project/properties')
  if (-not $props) {
    $props = NX 'properties' ''
    [void]$pom.project.AppendChild($props)
  }
  if (-not (S1('/project/properties/main.class'))) {
    [void]$props.AppendChild((NX 'main.class' 'com.albertoborsetta.formscanner.main.FormScanner'))
  }
  if (-not (S1('/project/properties/shade.classifier'))) {
    [void]$props.AppendChild((NX 'shade.classifier' 'shaded'))
  }
  if (-not (S1('/project/properties/maven.shade.version'))) {
    [void]$props.AppendChild((NX 'maven.shade.version' '3.5.0'))
  }

  # Ensure <build><plugins>
  $build = S1('/project/build')
  if (-not $build) {
    $build = NX 'build' ''
    [void]$pom.project.AppendChild($build)
  }
  $plugins = S1('/project/build/plugins')
  if (-not $plugins) {
    $plugins = NX 'plugins' ''
    [void]$build.AppendChild($plugins)
  }

  # Add/ensure maven-shade-plugin
  $shade = S1("/project/build/plugins/plugin[artifactId='maven-shade-plugin']")
  if (-not $shade) {
    $shade = NX 'plugin' ''
    [void]$shade.AppendChild((NX 'groupId' 'org.apache.maven.plugins'))
    [void]$shade.AppendChild((NX 'artifactId' 'maven-shade-plugin'))
    [void]$shade.AppendChild((NX 'version' (S1('/project/properties/maven.shade.version')).InnerText))

    $execs = NX 'executions' ''
    $exec  = NX 'execution'  ''
    [void]$exec.AppendChild((NX 'phase' 'package'))
    $goals = NX 'goals' ''
    [void]$goals.AppendChild((NX 'goal' 'shade'))
    [void]$exec.AppendChild($goals)

    $cfg = NX 'configuration' ''
    [void]$cfg.AppendChild((NX 'shadedArtifactAttached' 'true'))
    [void]$cfg.AppendChild((NX 'shadedArtifactClassifier' (S1('/project/properties/shade.classifier')).InnerText))

    $trans = NX 'transformers' ''
    $t1 = NX 'transformer' ''
    $t1.SetAttribute('implementation','org.apache.maven.plugins.shade.resource.ManifestResourceTransformer')
    [void]$t1.AppendChild((NX 'mainClass' (S1('/project/properties/main.class')).InnerText))
    $t2 = NX 'transformer' ''
    $t2.SetAttribute('implementation','org.apache.maven.plugins.shade.resource.ServicesResourceTransformer')
    $t3 = NX 'transformer' ''
    $t3.SetAttribute('implementation','org.apache.maven.plugins.shade.resource.ApacheLicenseResourceTransformer')
    [void]$trans.AppendChild($t1)
    [void]$trans.AppendChild($t2)
    [void]$trans.AppendChild($t3)

    $filters = NX 'filters' ''
    $f   = NX 'filter' ''
    [void]$f.AppendChild((NX 'artifact' '*:*'))
    $exs = NX 'excludes' ''
    [void]$exs.AppendChild((NX 'exclude' 'META-INF/*.SF'))
    [void]$exs.AppendChild((NX 'exclude' 'META-INF/*.DSA'))
    [void]$exs.AppendChild((NX 'exclude' 'META-INF/*.RSA'))
    [void]$f.AppendChild($exs)
    [void]$filters.AppendChild($f)

    [void]$cfg.AppendChild($trans)
    [void]$cfg.AppendChild($filters)
    [void]$exec.AppendChild($cfg)
    [void]$execs.AppendChild($exec)

    [void]$shade.AppendChild($execs)
    [void]$plugins.AppendChild($shade)
    Ok "Added maven-shade-plugin"
  } else {
    Info "maven-shade-plugin already present"
  }

  # Remove Quaqua from standard dependencies (both possible groupIds)
  $qq = S("//project/dependencies/dependency[groupId='randelshofer' and artifactId='quaqua'] | //project/dependencies/dependency[groupId='ch.randelshofer' and artifactId='quaqua']")
  $removed = 0
  foreach($n in @($qq)) {
    [void]$n.ParentNode.RemoveChild($n)
    $removed++
  }
  if ($removed -gt 0) { Ok "Removed $removed Quaqua dependency from regular dependencies" } else { Info "No Quaqua in regular dependencies" }

  # macOS-only profile
  $profiles = S1('/project/profiles')
  if (-not $profiles) {
    $profiles = NX 'profiles' ''
    [void]$pom.project.AppendChild($profiles)
  }
  $macProf = S1("/project/profiles/profile[id='macosx-laf']")
  if (-not $macProf) {
    $macProf = NX 'profile' ''
    [void]$macProf.AppendChild((NX 'id' 'macosx-laf'))

    $activation = NX 'activation' ''
    $os = NX 'os' ''
    [void]$os.AppendChild((NX 'family' 'mac'))
    [void]$activation.AppendChild($os)
    [void]$macProf.AppendChild($activation)

    $pdeps = NX 'dependencies' ''
    $dep   = NX 'dependency' ''
    # keep your current groupId; switch to ch.randelshofer if needed on Mac builds
    [void]$dep.AppendChild((NX 'groupId' 'randelshofer'))
    [void]$dep.AppendChild((NX 'artifactId' 'quaqua'))
    [void]$dep.AppendChild((NX 'version' '8.0'))
    [void]$dep.AppendChild((NX 'scope' 'compile'))
    [void]$pdeps.AppendChild($dep)
    [void]$macProf.AppendChild($pdeps)

    [void]$profiles.AppendChild($macProf)
    Ok "Added macOS-only profile 'macosx-laf' with Quaqua"
  } else {
    Info "macOS-only profile already exists"
  }

  # Backup once and save
  $bak = "$PomPath.bak"
  if (-not (Test-Path $bak)) { Copy-Item -LiteralPath $PomPath -Destination $bak }
  $pom.Save($PomPath)
  Ok "Saved patched pom.xml"
}


$guiPom = Join-Path $repoDir "formscanner-gui\pom.xml"
Info "Patching GUI pom for shaded jar and macOS-only Quaqua"
Patch-GuiPom -PomPath $guiPom

# ---------- build ----------
Info "Building project (this may take a few minutes)"
Push-Location $repoDir
mvn -B -e -V clean package
$code = $LASTEXITCODE
Pop-Location
if ($code -ne 0) { Fail "Maven build failed (exit code $code)" }

# find shaded jar
$targetDir = Join-Path $repoDir "formscanner-gui\target"
$shaded = Get-ChildItem -Path $targetDir -Filter "*-shaded.jar" -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $shaded) { Fail "Shaded JAR not found -- check shade plugin configuration." }
Ok ("Shaded jar: " + $shaded.FullName)

# ---------- optional shortcut ----------
if ($CreateDesktopShortcut) {
  try {
    $ws  = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut("$env:USERPROFILE\Desktop\FormScanner.lnk")
    $lnk.TargetPath = "javaw.exe"
    $lnk.Arguments  = ('-jar "' + $shaded.FullName + '"')
    $lnk.WorkingDirectory = (Split-Path $shaded.FullName)
    $lnk.IconLocation = "shell32.dll, 13"
    $lnk.Save()
    Ok "Desktop shortcut created: $env:USERPROFILE\Desktop\FormScanner.lnk"
  } catch {
    Warn ("Could not create desktop shortcut: " + $_.Exception.Message)
  }
}

Write-Host ""
Ok "BUILD COMPLETE"
$runCmd = ('java -jar "' + $shaded.FullName + '"')
Write-Host "Run now:" -ForegroundColor Cyan
Write-Host $runCmd -ForegroundColor Yellow
