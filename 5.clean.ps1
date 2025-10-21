# Clean duplicate POM entries and rebuild (ASCII safe)
# Usage: powershell -ExecutionPolicy Bypass -File .\5.clean.ascii.ps1

$ErrorActionPreference = 'Stop'

function Info($m) { Write-Host ('>>> ' + $m) -ForegroundColor Cyan }
function Ok($m)   { Write-Host ('OK: ' + $m) -ForegroundColor Green }
function Warn($m) { Write-Host ('!!  ' + $m) -ForegroundColor Yellow }
function Fail($m) { Write-Host ''; Write-Host ('ERROR: ' + $m) -ForegroundColor Red; exit 1 }

function Save-WithBackup {
    param([string]$Path, [xml]$Xml)
    $bak = $Path + '.bak'
    if (-not (Test-Path $bak)) { Copy-Item -LiteralPath $Path -Destination $bak }
    $Xml.Save($Path)
    Ok ('Saved ' + $Path)
}

function Fix-Pom {
    param([string]$PomPath)

    if (-not (Test-Path $PomPath)) {
        Write-Host ('Skip (not found): ' + $PomPath) -ForegroundColor DarkGray
        return
    }

    Info ('Patching: ' + $PomPath)
    [xml]$pom = Get-Content -LiteralPath $PomPath -Raw

    # Helpers using local-name() so namespace never breaks us
    function Nodes($xp) { return $pom.SelectNodes($xp) }
    function Node($xp)  { return $pom.SelectSingleNode($xp) }

    # Root <project>
    $proj = Node('/*[local-name()="project"]')
    if (-not $proj) { Fail ('Invalid POM: no <project> root in ' + $PomPath) }

    # 1) Dedup profile id="macosx-laf"
    $profiles = Nodes('/*[local-name()="project"]/*[local-name()="profiles"]/*[local-name()="profile"][*[local-name()="id"]="macosx-laf"]')
    if ($profiles -and $profiles.Count -gt 1) {
        for ($i = 1; $i -lt $profiles.Count; $i++) {
            $n = $profiles[$i]
            [void]$n.ParentNode.RemoveChild($n)
        }
        Warn 'Removed duplicate profiles macosx-laf (kept first)'
    }

    # 2) Dedup maven-shade-plugin
    $shadeXp = '/*[local-name()="project"]/*[local-name()="build"]/*[local-name()="plugins"]/*[local-name()="plugin"]' +
               '[*[local-name()="groupId"]="org.apache.maven.plugins" and *[local-name()="artifactId"]="maven-shade-plugin"]'
    $shadePlugins = Nodes($shadeXp)
    if ($shadePlugins -and $shadePlugins.Count -gt 1) {
        for ($i = 1; $i -lt $shadePlugins.Count; $i++) {
            $n = $shadePlugins[$i]
            [void]$n.ParentNode.RemoveChild($n)
        }
        Warn 'Removed duplicate maven-shade-plugin (kept first)'
    }

    # 3) Ensure versions for source and javadoc plugins (to silence warnings)
    $src = Node('/*[local-name()="project"]/*[local-name()="build"]/*[local-name()="plugins"]/*[local-name()="plugin"]' +
                '[*[local-name()="groupId"]="org.apache.maven.plugins" and *[local-name()="artifactId"]="maven-source-plugin"]')
    if ($src) {
        $ver = $src.SelectSingleNode('*[local-name()="version"]')
        if (-not $ver -or [string]::IsNullOrWhiteSpace($ver.InnerText)) {
            $ver = $pom.CreateElement('version', $pom.DocumentElement.NamespaceURI)
            $ver.InnerText = '3.3.0'
            [void]$src.AppendChild($ver)
            Ok 'Set version 3.3.0 on maven-source-plugin'
        }
    }

    $jdoc = Node('/*[local-name()="project"]/*[local-name()="build"]/*[local-name()="plugins"]/*[local-name()="plugin"]' +
                 '[*[local-name()="groupId"]="org.apache.maven.plugins" and *[local-name()="artifactId"]="maven-javadoc-plugin"]')
    if ($jdoc) {
        $ver = $jdoc.SelectSingleNode('*[local-name()="version"]')
        if (-not $ver -or [string]::IsNullOrWhiteSpace($ver.InnerText)) {
            $ver = $pom.CreateElement('version', $pom.DocumentElement.NamespaceURI)
            $ver.InnerText = '3.6.3'
            [void]$jdoc.AppendChild($ver)
            Ok 'Set version 3.6.3 on maven-javadoc-plugin'
        }
    }

    Save-WithBackup -Path $PomPath -Xml $pom
}

# Run on parent pom and GUI pom
$rootPom = Join-Path (Get-Location) 'pom.xml'
$guiPom  = Join-Path (Get-Location) 'formscanner-gui\pom.xml'

Fix-Pom $rootPom
Fix-Pom $guiPom

Write-Host ''
Write-Host 'Re-running Maven build...' -ForegroundColor Cyan
mvn -B -e -V clean package
