# Imports the "Game RTP spike" alert rule into Grafana via the provisioning API.
# Run from a machine that can reach Grafana (office network / VPN):
#   powershell -ExecutionPolicy Bypass -File .\import.ps1 -DatasourceUid <uid> -FolderUid <uid> -ContactPoint "<name>"
# The service account token is prompted for and never stored or echoed.
param(
    [Parameter(Mandatory = $true)] [string] $DatasourceUid,   # ProdCH ClickHouse datasource UID
    [Parameter(Mandatory = $true)] [string] $FolderUid,       # alert folder UID
    [Parameter(Mandatory = $true)] [string] $ContactPoint,    # Slack contact point name (exact)
    [string] $GrafanaUrl = "https://grafana.enjoygaming.live"
)
$ErrorActionPreference = "Stop"
$group = "bi_game_rtp_spike"

$secure = Read-Host -AsSecureString "Grafana service account token"
$token  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
$headers = @{ Authorization = "Bearer $token"; "X-Disable-Provenance" = "true" }

$body = Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot "rule-group.json")
$body = $body.Replace("__PRODCH_DS_UID__", $DatasourceUid).
              Replace("__FOLDER_UID__", $FolderUid).
              Replace("__SLACK_CONTACT_POINT__", $ContactPoint)

# Safety: PUT replaces the whole group, so refuse if it already holds other rules.
$uri = "$GrafanaUrl/api/v1/provisioning/folder/$FolderUid/rule-groups/$group"
$existing = $null
try { $existing = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers }
catch { if ($_.Exception.Response.StatusCode.value__ -ne 404) { throw } }   # 404 = new group, fine
if ($existing) {
    $others = @($existing.rules | Where-Object { $_.uid -ne "bi-game-rtp-spike" })
    if ($others.Count -gt 0) { throw "Group '$group' already has other rules: $($others.title -join ', '). Aborting." }
}

Invoke-RestMethod -Method Put -Uri $uri -Headers $headers -ContentType "application/json; charset=utf-8" `
    -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
Write-Host "OK: rule 'Game RTP spike' imported into folder $FolderUid, group $group (every 5m, pending 15m)."
Write-Host "Check: $GrafanaUrl/alerting/grafana/bi-game-rtp-spike/view"
