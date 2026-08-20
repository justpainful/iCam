@echo off
rem Builds iCam.VirtualCamera.dll with the MSVC toolchain. No solution needed.
rem
rem     build.cmd            release, x64
rem     build.cmd Debug      debug, x64

setlocal EnableExtensions
set "CONFIG=%~1"
if "%CONFIG%"=="" set "CONFIG=Release"

rem The vswhere path is put in a variable first: the "(x86)" in Program Files
rem would otherwise close the for-loop's own parentheses.
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
    echo Could not find vswhere.exe. Install Visual Studio with the C++ tools.
    exit /b 1
)

set "VSPATH="
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%i"

if not defined VSPATH (
    echo Visual Studio with the C++ desktop workload was not found.
    exit /b 1
)

call "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b 1

set "HERE=%~dp0"
set "OUTDIR=%HERE%build\%CONFIG%"
if not exist "%OUTDIR%" mkdir "%OUTDIR%"

set "CFLAGS=/nologo /std:c++20 /EHsc /W4 /permissive- /DUNICODE /D_UNICODE"
if /i "%CONFIG%"=="Debug" (
    set "CFLAGS=%CFLAGS% /Zi /Od /MDd /D_DEBUG"
) else (
    set "CFLAGS=%CFLAGS% /O2 /MD /DNDEBUG"
)

cl %CFLAGS% /I"%HERE%." ^
   "%HERE%dllmain.cpp" "%HERE%MediaSource.cpp" "%HERE%SourceActivate.cpp" "%HERE%MediaStream.cpp" "%HERE%FrameSource.cpp" "%HERE%HoldingPattern.cpp" "%HERE%Diagnostics.cpp" ^
   /Fo"%OUTDIR%\\" /Fd"%OUTDIR%\iCam.VirtualCamera.pdb" ^
   /link /DLL /DEF:"%HERE%iCam.VirtualCamera.def" ^
   /OUT:"%OUTDIR%\iCam.VirtualCamera.dll" ^
   /IMPLIB:"%OUTDIR%\iCam.VirtualCamera.lib" ^
   mf.lib mfplat.lib mfuuid.lib mfsensorgroup.lib ole32.lib oleaut32.lib advapi32.lib gdi32.lib user32.lib

if errorlevel 1 exit /b 1
echo.
echo Built %OUTDIR%\iCam.VirtualCamera.dll
