@echo off
setlocal
if not defined BACKUP_VCVARS exit /b 2
call "%BACKUP_VCVARS%" >nul
if errorlevel 1 exit /b 1
set "CFLAGS=/nologo /std:c++17 /EHsc /utf-8 /O2 /MT /W4 /DUNICODE /D_UNICODE /D_WIN32_WINNT=0x0601 /Isrc"
cl %CFLAGS% /c src\codec.cpp /Fobuild\codec.obj
if errorlevel 1 exit /b 1
cl %CFLAGS% /c src\crypto.cpp /Fobuild\crypto.obj
if errorlevel 1 exit /b 1
cl %CFLAGS% /c src\archive.cpp /Fobuild\archive.obj
if errorlevel 1 exit /b 1
set "OBJECTS=build\codec.obj build\crypto.obj build\archive.obj"
cl %CFLAGS% src\cli.cpp %OBJECTS% /Fobuild\cli.obj /Febin\backup_cli.exe /link bcrypt.lib
if errorlevel 1 exit /b 1
cl %CFLAGS% src\gui.cpp %OBJECTS% /Fobuild\gui.obj /Febin\BackupAssistant.exe /link /SUBSYSTEM:WINDOWS bcrypt.lib comctl32.lib comdlg32.lib shell32.lib ole32.lib uuid.lib user32.lib gdi32.lib
if errorlevel 1 exit /b 1
cl %CFLAGS% tests\tests.cpp %OBJECTS% /Fobuild\tests.obj /Febin\backup_tests.exe /link bcrypt.lib
if errorlevel 1 exit /b 1
exit /b 0
