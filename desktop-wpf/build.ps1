$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$staging = Join-Path ([IO.Path]::GetTempPath()) ('BackupAssistant-publish-' + [guid]::NewGuid())
try {
    dotnet publish (Join-Path $PSScriptRoot 'BackupAssistant.csproj') -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true -o $staging
    if ($LASTEXITCODE) { throw "WPF build failed ($LASTEXITCODE)" }
    Copy-Item -LiteralPath (Join-Path $staging 'BackupAssistant.exe') -Destination (Join-Path $root 'BackupAssistant.exe') -Force
} finally {
    if (Test-Path -LiteralPath $staging) {
        $resolved = (Resolve-Path -LiteralPath $staging).Path
        if ($resolved -eq $staging) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    }
}
