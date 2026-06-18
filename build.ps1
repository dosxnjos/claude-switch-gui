# Build the Claude Switch executable from claude-switch.ps1.
#
# One reproducible command instead of copy-pasting the ps2exe block from the
# README. Run from the project folder:
#
#     ./build.ps1
#
# Requires: ps2exe module (Install-Module ps2exe -Scope CurrentUser).

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

Write-Host "Building Claude Switch.exe (ps2exe)..." -ForegroundColor Cyan
Import-Module ps2exe
Invoke-ps2exe `
    -inputFile   ".\claude-switch.ps1" `
    -outputFile  ".\Claude Switch.exe" `
    -iconFile    ".\claude-switch-full.ico" `
    -noConsole `
    -title       "Claude Switch" `
    -description "Multi-account switcher for Claude Code"

Write-Host "Done -> .\Claude Switch.exe" -ForegroundColor Green
