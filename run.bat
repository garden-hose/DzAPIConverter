@echo off
setlocal
cd /d "%~dp0"

where java >nul 2>&1
if errorlevel 1 (
    echo ERROR: java not found. Install a JRE/JDK and ensure it is on PATH.
    pause
    exit /b 1
)

if not exist lib\ (
    echo ERROR: lib\ folder not found. Keep lib\ next to this script.
    pause
    exit /b 1
)

REM Prefer JAR if present, otherwise class files
if exist DzApiConverter.jar (
    REM Run with classpath including the JAR and the external library
    java -cp "DzApiConverter.jar;lib\flatlaf-3.7.2.jar" DzApiConverter %*
) else if exist DzApiConverter.class (
    java -cp . DzApiConverter %*
) else (
    echo ERROR: DzApiConverter.jar / .class not found.
    echo Run compile.bat first.
    pause
    exit /b 1
)