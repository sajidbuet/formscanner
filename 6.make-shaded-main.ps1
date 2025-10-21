# Adds shade plugin and macOS-only Quaqua profile to formscanner-main/pom.xml

$pomPath = Join-Path (Get-Location) 'formscanner-main\pom.xml'
if (-not (Test-Path $pomPath)) { Write-Host ('Missing: ' + $pomPath) -ForegroundColor Red; exit 1 }

[xml]$pom = Get-Content -LiteralPath $pomPath -Raw
$ns = $pom.DocumentElement.NamespaceURI
$mgr = New-Object System.Xml.XmlNamespaceManager($pom.NameTable)
if ($ns) { $mgr.AddNamespace('m', $ns) }

function NX($name,$text=''){
  if ($ns) { $e = $pom.CreateElement($name,$ns) } else { $e = $pom.CreateElement($name) }
  if ($text -ne '') { $e.InnerText = $text }
  $e
}
function S1($xp){
  if ($ns) { $pom.SelectSingleNode($xp.Replace('//','//m:').Replace('/','/m:'),$mgr) } else { $pom.SelectSingleNode($xp) }
}
function S($xp){
  if ($ns) { $pom.SelectNodes($xp.Replace('//','//m:').Replace('/','/m:'),$mgr) } else { $pom.SelectNodes($xp) }
}

# Ensure properties
$props = S1('/project/properties'); if (-not $props){ $props = NX 'properties'; [void]$pom.project.AppendChild($props) }
if (-not (S1('/project/properties/main.class'))){ [void]$props.AppendChild((NX 'main.class' 'com.albertoborsetta.formscanner.main.FormScanner')) }
if (-not (S1('/project/properties/shade.classifier'))){ [void]$props.AppendChild((NX 'shade.classifier' 'shaded')) }
if (-not (S1('/project/properties/maven.shade.version'))){ [void]$props.AppendChild((NX 'maven.shade.version' '3.5.0')) }

# Ensure build/plugins
$build = S1('/project/build'); if (-not $build){ $build = NX 'build'; [void]$pom.project.AppendChild($build) }
$plugins = S1('/project/build/plugins'); if (-not $plugins){ $plugins = NX 'plugins'; [void]$build.AppendChild($plugins) }

# Add shade plugin if missing
$shade = S1("/project/build/plugins/plugin[artifactId='maven-shade-plugin']")
if (-not $shade) {
  $shade = NX 'plugin'
  [void]$shade.AppendChild((NX 'groupId' 'org.apache.maven.plugins'))
  [void]$shade.AppendChild((NX 'artifactId' 'maven-shade-plugin'))
  [void]$shade.AppendChild((NX 'version' (S1('/project/properties/maven.shade.version')).InnerText))

  $execs = NX 'executions'
  $exec  = NX 'execution'
  [void]$exec.AppendChild((NX 'phase' 'package'))
  $goals = NX 'goals'
  [void]$goals.AppendChild((NX 'goal' 'shade'))
  [void]$exec.AppendChild($goals)

  $cfg = NX 'configuration'
  [void]$cfg.AppendChild((NX 'shadedArtifactAttached' 'true'))
  [void]$cfg.AppendChild((NX 'shadedArtifactClassifier' (S1('/project/properties/shade.classifier')).InnerText))

  $trans = NX 'transformers'
  $t1 = NX 'transformer'; $t1.SetAttribute('implementation','org.apache.maven.plugins.shade.resource.ManifestResourceTransformer')
  [void]$t1.AppendChild((NX 'mainClass' (S1('/project/properties/main.class')).InnerText))
  $t2 = NX 'transformer'; $t2.SetAttribute('implementation','org.apache.maven.plugins.shade.resource.ServicesResourceTransformer')
  $t3 = NX 'transformer'; $t3.SetAttribute('implementation','org.apache.maven.plugins.shade.resource.ApacheLicenseResourceTransformer')
  [void]$trans.AppendChild($t1); [void]$trans.AppendChild($t2); [void]$trans.AppendChild($t3)

  $filters = NX 'filters'
  $f = NX 'filter'
  [void]$f.AppendChild((NX 'artifact' '*:*'))
  $exs = NX 'excludes'
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
  Write-Host 'Added maven-shade-plugin to formscanner-main' -ForegroundColor Green
} else {
  Write-Host 'maven-shade-plugin already present in formscanner-main' -ForegroundColor Yellow
}

# Add macOS-only Quaqua profile if missing (so Windows build does not require it)
$profiles = S1('/project/profiles'); if (-not $profiles){ $profiles = NX 'profiles'; [void]$pom.project.AppendChild($profiles) }
$mac = S1("/project/profiles/profile[id='macosx-laf']")
if (-not $mac) {
  $mac = NX 'profile'
  [void]$mac.AppendChild((NX 'id' 'macosx-laf'))
  $act = NX 'activation'
  $os = NX 'os'
  [void]$os.AppendChild((NX 'family' 'mac'))
  [void]$act.AppendChild($os)
  [void]$mac.AppendChild($act)

  $pdeps = NX 'dependencies'
  $dep = NX 'dependency'
  [void]$dep.AppendChild((NX 'groupId' 'randelshofer'))   # or ch.randelshofer if that is what you use on mac
  [void]$dep.AppendChild((NX 'artifactId' 'quaqua'))
  [void]$dep.AppendChild((NX 'version' '8.0'))
  [void]$dep.AppendChild((NX 'scope' 'compile'))
  [void]$pdeps.AppendChild($dep)
  [void]$mac.AppendChild($pdeps)

  [void]$profiles.AppendChild($mac)
  Write-Host 'Added macOS-only profile macosx-laf in formscanner-main' -ForegroundColor Green
}

# Save a backup once and write changes
$bak = $pomPath + '.bak'
if (-not (Test-Path $bak)) { Copy-Item -LiteralPath $pomPath -Destination $bak }
$pom.Save($pomPath)
Write-Host ('Saved: ' + $pomPath) -ForegroundColor Green

mvn -B -e -V -pl formscanner-main -am clean package