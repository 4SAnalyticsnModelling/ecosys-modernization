# Keeps the DEEPSEEK pane registered as a Herdr agent ("deepseek").
# The DeepSeek Harness has no built-in Herdr integration, so this polls the pane and reports
# working (harness shows "esc to interrupt") or idle through `herdr pane report-agent`.
#
# Herdr only keeps a report that comes from inside the pane's own process tree, using the pane's
# inherited HERDR_* environment (no --session flag; a report from outside the pane is dropped
# within seconds). Sources starting with "herdr:" are reserved and silently ignored.
# Do not run this directly: scripts/start-deepseek.sh starts it in the background and then dsh.
param([int]$IntervalSeconds = 3)

if ($env:HERDR_ENV -ne "1" -or -not $env:HERDR_PANE_ID) {
    Write-Error "Run inside the DEEPSEEK Herdr pane via scripts/start-deepseek.sh"
    exit 1
}

$pane = $env:HERDR_PANE_ID
$source = "ecosys-deepseek-harness"
# Report as Herdr kind "pi" (dsh is built on the Pi engine): Herdr keeps reports for supported kinds,
# but drops a custom label within ~3 s when it detects no agent process in the pane.
$agent = "pi"
$name = "deepseek"
$last = ""
$log = Join-Path $PSScriptRoot "..\.agent\runtime\herdr-deepseek-status.log"
New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null
Add-Content $log "$(Get-Date -Format s) start pane=$pane socket=$env:HERDR_SOCKET_PATH"

while ($true) {
    $screen = herdr pane read $pane --source visible 2>$null | Out-String
    if ($LASTEXITCODE -ne 0) { Start-Sleep -Seconds 10; continue }
    $state = if ($screen -match "esc to interrupt") { "working" } else { "idle" }
    $listed = (herdr agent list | ConvertFrom-Json).result.agents | Where-Object pane_id -eq $pane
    if ($state -ne $last -or -not $listed) {
        # seq must strictly increase across restarts: use wall-clock milliseconds.
        $seq = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $out = herdr pane report-agent $pane --source $source --agent $agent --state $state `
            --message "Qwen3.5-35B-A3B worker" --seq $seq 2>&1 | Out-String
        Add-Content $log "$(Get-Date -Format s) report state=$state listed=$([bool]$listed) rc=$LASTEXITCODE $($out.Trim())"
        herdr agent rename $pane $name 2>$null | Out-Null
        $last = $state
    }
    Start-Sleep -Seconds $IntervalSeconds
}
