# 1) Path to the bundled Quaqua jar
$quaqua = Join-Path $PWD "formscanner-commons\src\main\resources\lib\quaqua-8.0.jar"

# 2) Install into your local Maven repository
mvn install:install-file `
  -Dfile="$quaqua" `
  -DgroupId=ch.randelshofer `
  -DartifactId=quaqua `
  -Dversion=8.0 `
  -Dpackaging=jar

# 3) Rebuild everything
mvn clean install
