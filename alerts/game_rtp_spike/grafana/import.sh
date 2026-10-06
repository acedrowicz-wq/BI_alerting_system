#!/usr/bin/env bash
# Imports the "Game RTP spike" alert rule into Grafana via the provisioning API.
# Run from a machine that can reach Grafana (office network / VPN):
#   ./import.sh <prodch_datasource_uid> <folder_uid> "<slack contact point name>"
# The service account token is prompted for and never stored or echoed.
set -euo pipefail
DS_UID="$1"; FOLDER_UID="$2"; CONTACT_POINT="$3"
GRAFANA_URL="${GRAFANA_URL:-https://grafana.enjoygaming.live}"
GROUP="bi_game_rtp_spike"
DIR="$(cd "$(dirname "$0")" && pwd)"

read -rsp "Grafana service account token: " TOKEN; echo
URI="$GRAFANA_URL/api/v1/provisioning/folder/$FOLDER_UID/rule-groups/$GROUP"

# Safety: PUT replaces the whole group, so refuse if it already holds other rules.
EXISTING=$(curl -sS -H "Authorization: Bearer $TOKEN" "$URI" || true)
if echo "$EXISTING" | python3 -c 'import json,sys
d=json.load(sys.stdin); o=[r["title"] for r in d.get("rules",[]) if r.get("uid")!="bi-game-rtp-spike"]
sys.exit(1 if o else 0)' 2>/dev/null; then :; else
  echo "Group $GROUP already has other rules (or Grafana is unreachable). Aborting."; exit 1; fi

sed -e "s/__PRODCH_DS_UID__/$DS_UID/g" -e "s/__FOLDER_UID__/$FOLDER_UID/g" \
    -e "s/__SLACK_CONTACT_POINT__/$CONTACT_POINT/g" "$DIR/rule-group.json" |
curl -sS --fail-with-body -X PUT "$URI" \
     -H "Authorization: Bearer $TOKEN" -H "X-Disable-Provenance: true" \
     -H "Content-Type: application/json" --data-binary @- >/dev/null
echo "OK: rule imported into folder $FOLDER_UID, group $GROUP (every 5m, pending 15m)."
echo "Check: $GRAFANA_URL/alerting/grafana/bi-game-rtp-spike/view"
