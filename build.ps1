param([switch]$Test)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
New-Item -ItemType Directory -Force bin,build | Out-Null
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = $null
if (Test-Path $vswhere) { $vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath }
if ($vs) {
    $env:BACKUP_VCVARS = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
    & cmd.exe /d /c build-msvc.cmd
    if ($LASTEXITCODE -ne 0) { throw 'Visual Studio 构建失败' }
} else {
$compiler = Get-Command g++.exe -ErrorAction SilentlyContinue
if (-not $compiler) { throw '需要 Visual Studio C++ 工具或较新 MinGW-w64（GCC 10+）。' }
$common = @('-std=c++17','-O2','-Wall','-Wextra','-Wno-misleading-indentation','-Wno-unknown-pragmas','-DUNICODE','-D_UNICODE','-D_WIN32_WINNT=0x0601','-Isrc','-static','-static-libgcc','-static-libstdc++')
$objects = @()
foreach ($module in @('codec','crypto','archive')) {
    $object = "build/$module.o"
    & $compiler.Source @common -c "src/$module.cpp" -o $object
    if ($LASTEXITCODE -ne 0) { throw "编译 $module 失败" }
    $objects += $object
}
& $compiler.Source @common src/cli.cpp @objects -o bin/backup_cli.exe -municode -lstdc++fs -lbcrypt
if ($LASTEXITCODE -ne 0) { throw '命令行程序构建失败' }
& $compiler.Source @common src/gui.cpp @objects -o bin/BackupAssistant.exe -municode -mwindows -lstdc++fs -lbcrypt -lcomctl32 -lcomdlg32 -lshell32 -lole32 -luuid
if ($LASTEXITCODE -ne 0) { throw '桌面程序构建失败' }
& $compiler.Source @common tests/tests.cpp @objects -o bin/backup_tests.exe -municode -lstdc++fs -lbcrypt
if ($LASTEXITCODE -ne 0) { throw '测试程序构建失败' }
}
Write-Host '构建完成：bin/BackupAssistant.exe'
if ($Test) {
    & ./bin/backup_tests.exe 2>&1 | Tee-Object -FilePath build/test-results.txt
    if ($LASTEXITCODE -ne 0) { throw '自动测试未通过' }
}
