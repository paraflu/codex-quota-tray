param([switch]$Test)
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $compiler)) { throw '.NET Framework 4.8 compiler not found. Build on Windows with .NET Framework 4.8 installed.' }
$output = Join-Path $PSScriptRoot 'bin'
New-Item -ItemType Directory -Force -Path $output | Out-Null
$references = @('/nologo', '/optimize+', '/reference:System.Windows.Forms.dll',
    '/reference:System.Drawing.dll', '/reference:System.Web.Extensions.dll')
& $compiler @references /target:winexe "/out:$output\CodexQuotaTray.exe" "$PSScriptRoot\CodexQuotaTray.cs"
if ($LASTEXITCODE -ne 0) { throw 'Application compilation failed.' }
if ($Test) {
    & $compiler @references /target:exe /main:QuotaTrayCheck "/out:$output\QuotaTrayCheck.exe" `
        "$PSScriptRoot\CodexQuotaTray.cs" "$PSScriptRoot\Test-QuotaTray.cs"
    if ($LASTEXITCODE -ne 0) { throw 'Test compilation failed.' }
    & "$output\QuotaTrayCheck.exe"
    if ($LASTEXITCODE -ne 0) { throw 'C# UI check failed.' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\Test-QuotaTray.ps1"
    if ($LASTEXITCODE -ne 0) { throw 'PowerShell UI check failed.' }
}
Write-Output "Built $output\CodexQuotaTray.exe"
