@echo off
rem Builds dockstate.exe into <output-dir> against Qt 6 from the OBS dependency bundle in .deps.
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
set Q=%~dp0..\..\.deps\obs-deps-qt6-2026-07-15-x64
if not exist "%~1" mkdir "%~1"
cd /d "%~1"
cl /nologo /utf-8 /std:c++17 /EHsc /O2 /Zc:__cplusplus /permissive- /I"%Q%\include" /I"%Q%\include\QtCore" /I"%Q%\include\QtGui" /I"%Q%\include\QtWidgets" "%~dp0dockstate.cpp" /Fe:dockstate.exe /link /LIBPATH:"%Q%\lib" Qt6Core.lib Qt6Gui.lib Qt6Widgets.lib
copy /y "%Q%\bin\Qt6Core.dll" . >nul
copy /y "%Q%\bin\Qt6Gui.dll" . >nul
copy /y "%Q%\bin\Qt6Widgets.dll" . >nul
if not exist platforms mkdir platforms
copy /y "%Q%\plugins\platforms\qminimal.dll" platforms\ >nul
