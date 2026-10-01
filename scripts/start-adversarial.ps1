<#
.SYNOPSIS
    Start or run the worker/judge adversarial runner in PowerShell.
    DEEPSEEK (local Qwen3.5-35B-A3B, llama.cpp) works; CLAUDE (Claude Opus 5.5) reviews and rules.
    CLAUDE's ruling is final; only APPROVED rounds are committed and pushed.
#>
param(
    [switch]$Continuous,
    [int]$Rounds = 1,
    [int]$PollSeconds = 60,
    [switch]$DryRun,
    [switch]$Status
)

$WorkDir = (Get-Item $PSScriptRoot).Parent.FullName
Set-Location $WorkDir

$argsList = @("ecosys-audit/scripts/adversarial_runner.py")
if ($Status) { $argsList += "--status" }
if ($Continuous) { $argsList += "--continuous" }
if ($Rounds -gt 1) { $argsList += @("--rounds", "$Rounds") }
if ($PollSeconds -ne 60) { $argsList += @("--poll-seconds", "$PollSeconds") }
if ($DryRun) { $argsList += "--dry-run" }

Write-Host "[*] Launching adversarial workflow in $WorkDir..."
& uv run @argsList
