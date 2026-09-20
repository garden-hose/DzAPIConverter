@echo off
setlocal
cd /d "%~dp0"

echo ===============================
echo DzApiConverter Compilation Script
echo ===============================

REM --- Clean previous class files ---
echo Cleaning previous class files in 'bin' directory...
if exist bin\*.class del /Q bin\*.class

REM --- Create bin directory if it doesn't exist ---
echo Creating 'bin' directory if it doesn't exist...
if not exist bin mkdir bin

REM --- Check if source file exists ---
echo Checking for source file...
if not exist src\*.java (
    echo ERROR: src\*.java not found.
    pause
    exit /b 1
)

REM --- Check for javac availability ---
where javac >nul 2>&1
if errorlevel 1 (
    echo ERROR: javac not found. Install a JDK and ensure it is on PATH.
    pause
    exit /b 1
)

REM --- Set library path ---
set LIB_PATH=%~dp0lib\flatlaf-3.7.2.jar

REM --- Compile Java source ---
echo Compiling DzApiConverter.java...
javac -encoding UTF-8 -cp "%LIB_PATH%" -d bin src\*.java
if errorlevel 1 (
    echo ===============================
    echo Compilation FAILED.
    pause
    exit /b 1
)

echo Compilation successful. Class files are in the 'bin' directory.

REM --- Create manifest file with main class ---
echo Creating manifest file...
echo Main-Class: DzApiConverter > manifest.mf

REM --- Build the JAR file ---
echo Building DzApiConverter.jar...
jar cfm "%~dp0DzApiConverter.jar" manifest.mf -C bin .

if errorlevel 1 (
    echo ===============================
    echo JAR build FAILED.
    pause
    exit /b 1
)

echo JAR file 'DzApiConverter.jar' created successfully.
del manifest.mf

pause