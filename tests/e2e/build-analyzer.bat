@echo off
rem Builds analyze.exe next to this file against FFmpeg from the OBS dependency bundle in .deps.
rem Usage: build-analyzer.bat <output-dir>
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
set D=%~dp0..\..\.deps\obs-deps-2026-07-15-x64
if not exist "%~1" mkdir "%~1"
cd /d "%~1"
cl /nologo /utf-8 /std:c++20 /EHsc /O2 /I"%D%\include" "%~dp0analyze.cpp" /Fe:analyze.exe /link /LIBPATH:"%D%\lib" avformat.lib avcodec.lib avutil.lib
copy /y "%D%\bin\*.dll" . >nul
