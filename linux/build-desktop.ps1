param([ValidateSet('Unified','Cloud','WSL')][string]$Target = 'Unified')
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$root = Split-Path -Parent $PSScriptRoot
$filename = if ($Target -eq 'Unified') { 'BackupAssistant.exe' } else { "BackupAssistant-$Target.exe" }
$output = Join-Path $root $filename
$icon = Join-Path $PSScriptRoot 'BackupAssistant.ico'
$automation = & powershell.exe -NoProfile -Command '[System.Management.Automation.PowerShell].Assembly.Location'
& $compiler "/reference:$automation" "/win32icon:$icon" /nologo /target:winexe /optimize+ /reference:System.Windows.Forms.dll "/out:$output" (Join-Path $PSScriptRoot 'DesktopLauncher.cs')
if ($LASTEXITCODE -ne 0) { throw "Desktop launcher build failed ($LASTEXITCODE)." }
Write-Output $output
