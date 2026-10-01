# Keeps the DEEPSEEK pane registered as a Herdr agent ("deepseek").
# The DeepSeek Harness has no built-in Herdr integration, so this polls the pane and reports
# working (harness shows "esc to interrupt") or idle through `herdr pane report-agent`.
param(
    [string]$Pane = "",
    [int]$IntervalSeconds = 3
)

$source = "herdr:deepseek-harness"
$agent = "deepseek"

function Find-DeepseekPane {
    $panes = (herdr pane list | ConvertFrom-Json).result.panes
    ($panes | Where-Object { $_.label -eq "DEEPSEEK" } | Select-Object -First 1).pane_id
}

if (-not $Pane) { $Pane = Find-DeepseekPane }
if (-not $Pane) { Write-Error "No pane labelled DEEPSEEK"; exit 1 }

$seq = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() * 1000)
$last = ""
$named = $false
while ($true) {
    $screen = herdr pane read $Pane --source visible 2>$null | Out-String
    if ($LASTEXITCODE -ne 0) { Start-Sleep -Seconds 10; $Pane = Find-DeepseekPane; continue }
    $state = if ($screen -match "esc to interrupt") { "working" } else { "idle" }
    if ($state -ne $last) {
        $seq++
        herdr pane report-agent $Pane --source $source --agent $agent --state $state `
            --message "Qwen3.8-35B-A3B-Distill worker" --seq $seq | Out-Null
        if (-not $named) { herdr agent rename $Pane $agent 2>$null | Out-Null; $named = $true }
        $last = $state
    }
    Start-Sleep -Seconds $IntervalSeconds
}
