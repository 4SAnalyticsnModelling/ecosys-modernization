<#
.SYNOPSIS
    Setup Herdr Layout for 2-Model Adversarial Dance (CLAUDE judge & DEEPSEEK worker)
    Both agents sit side-by-side on the SAME Herdr tab ('ADVERSARIAL') in multi-pane.
#>
$ErrorActionPreference = "Stop"

$Session = if ($env:ECOSYS_HERDR_SESSION) { $env:ECOSYS_HERDR_SESSION } else { "ecosys-adversarial" }
$WorkDir = (Get-Item $PSScriptRoot).Parent.FullName

Write-Host "[*] Setting up Herdr session '$Session' for 2-model adversarial workflow..."

# Check existing panes
$panesRaw = herdr --session $Session pane list 2>$null
$pane1 = $null

if ($panesRaw) {
    try {
        $json = $panesRaw | ConvertFrom-Json
        if ($json.result -and $json.result.panes -and $json.result.panes.Count -gt 0) {
            $pane1 = $json.result.panes[0].pane_id
        }
    } catch {}
}

if (-not $pane1) {
    Write-Host "[*] Creating root tab 'ADVERSARIAL'..."
    $tabRaw = herdr --session $Session tab create --label "ADVERSARIAL" --cwd "$WorkDir"
    try {
        $tabJson = $tabRaw | ConvertFrom-Json
        $pane1 = $tabJson.result.root_pane
    } catch {
        # Fallback query
        $panesRaw2 = herdr --session $Session pane list
        $json2 = $panesRaw2 | ConvertFrom-Json
        $pane1 = $json2.result.panes[0].pane_id
    }
}

Write-Host "[+] Primary pane (CLAUDE): $pane1"
herdr --session $Session pane rename "$pane1" "CLAUDE" 2>$null | Out-Null

Write-Host "[*] Creating split pane to right on same tab for DEEPSEEK..."
$splitRaw = herdr --session $Session pane split --pane "$pane1" --direction right --cwd "$WorkDir" --no-focus 2>$null
$pane2 = $null
if ($splitRaw) {
    try {
        $splitJson = $splitRaw | ConvertFrom-Json
        $pane2 = $splitJson.result.pane.pane_id
    } catch {}
}

if ($pane2) {
    Write-Host "[+] Sibling pane on same tab (DEEPSEEK): $pane2"
    herdr --session $Session pane rename "$pane2" "DEEPSEEK" 2>$null | Out-Null
}

Write-Host "================================================================="
Write-Host "[+] Herdr Same-Tab Multi-Pane Layout Complete!"
Write-Host "    Session:  $Session"
Write-Host "    Tab:      ADVERSARIAL"
Write-Host "    Left:     CLAUDE (Claude Opus 5.5, reviewer/judge - final say) -> Pane $pane1"
Write-Host "    Right:    DEEPSEEK (local Qwen3.5-35B-A3B, does all the work) -> Pane $pane2"
Write-Host "================================================================="
