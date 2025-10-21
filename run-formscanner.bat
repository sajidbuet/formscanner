@echo off
REM Run FormScanner from the distribution folder using the correct classpath
REM Usage (GUI mode):   run-formscanner.bat
REM Usage (CLI mode):   run-formscanner.bat "C:\path\to\template.fst" "C:\path\to\imagesDir"

setlocal enabledelayedexpansion
set "ROOT=%~dp0"
REM If the script is placed anywhere, try to detect the distribution bin dir
REM Typical layout after build:
REM   formscanner\formscanner-distribution\target\formscanner-1.1.3-SNAPSHOT-bin\
REM     └─ lib\ <all jars>

if exist "%ROOT%lib\" (
  set "LIBDIR=%ROOT%lib"
) else (
  REM If you placed this script one level above lib\, try that
  if exist "%ROOT%..\lib\" (
    set "LIBDIR=%ROOT%..\lib"
  ) else (
    echo [ERROR] Could not find lib\ folder next to this script.
    echo Place this script in: formscanner-distribution\target\formscanner-*-bin\ and run it there.
    exit /b 1
  )
)

REM Launch with all jars on the classpath; the main class lives in formscanner-main
set "CP=%LIBDIR%\*"
set "MAIN=com.albertoborsetta.formscanner.main.FormScanner"

if "%~2"=="" (
  REM GUI mode (no args)
  echo Launching GUI...
  java -cp "%CP%" %MAIN%
) else (
  REM CLI mode: args: <template.fst> <imagesDir>
  echo Launching CLI with template: %1 and imagesDir: %2
  java -cp "%CP%" %MAIN% "%~1" "%~2"
)

endlocal
