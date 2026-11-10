@echo off
rem Compile every example with Delphi for Windows 64-bit.
rem Output: bin\win64\NAME.exe; compiled units go to lib\win64
rem
rem Run from a normal command prompt: the script loads rsvars.bat from
rem Delphi 13 (Studio 37.0) if the Delphi environment is not set yet.
rem For other versions, run the rsvars.bat of that version first.
rem
rem The examples read files relative to the project root, so run them from
rem here, for example:  bin\win64\hello.exe

setlocal
cd /d "%~dp0"

if not defined BDS (
  if exist "%ProgramFiles(x86)%\Embarcadero\Studio\37.0\bin\rsvars.bat" (
    call "%ProgramFiles(x86)%\Embarcadero\Studio\37.0\bin\rsvars.bat"
  )
)
if not defined BDS (
  echo Delphi not found. Run rsvars.bat from your Delphi installation first.
  exit /b 1
)

if not exist bin\win64 mkdir bin\win64
if not exist lib\win64 mkdir lib\win64

rem -NS lets the sources say Classes, SysUtils, Math and Windows instead of
rem System.Classes and so on, which is also how Free Pascal names them.
rem The trailing "." in the folder of each program avoids a "\" right before
rem the closing quote, which would escape it.
for /r examples %%f in (*.dpr) do (
  echo == %%f
  dcc64 -Q -B -NS"System;System.Win;Winapi" -U"src;examples\common;%%~dpf." -E"bin\win64" -NU"lib\win64" "%%f" || exit /b 1
)

echo Done: bin\win64
