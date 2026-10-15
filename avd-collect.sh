#!/usr/bin/env bash
#
# AVD Assessment - STEP 2: COLLECT  (runs under the scoped read-only identity)
# ===========================================================================
# Pulls AVD host pool configuration (ARM) and per-session usage records
# (Log Analytics), hashes usernames by default, and uploads CSV + JSON to the
# assessment storage container created in Step 1.
#
# Prereq: source the env file from setup, and (SP model) log in as the SP:
#   source avd-assessment.env
#   # SP model only:
#   az login --service-principal -u "$AVD_APP_ID" -p "$AVD_SP_PASS" --tenant "$AVD_TENANT_ID"
#   ./avd-collect.sh
#
# Flags:
#   -d <days>   Log Analytics lookback window (default 30)
#   -r          Keep RAW usernames (default: SHA-256 hashed)
#
# Output files (one folder per run, avd-data-<timestamp>/):
#   hostpools.csv / hostpools.json   host pool configuration
#   sessionhosts.csv                 session hosts + backing VM size / OS / image
#   appgroups.csv                    application groups + assignment counts
#   sessions.csv                     one row per connected session (hashed user)
#   manifest.json                    run metadata
#
# This session is READ-ONLY against the environment. The only write is
# uploading results to the single assessment storage account.
#
set -euo pipefail

LOOKBACK_DAYS=30
HASH_USERS=1

while getopts "d:rh" opt; do
  case $opt in
    d) LOOKBACK_DAYS="$OPTARG" ;;
    r) HASH_USERS=0 ;;
    h) grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
    *) echo "Invalid option"; exit 1 ;;
  esac
done

: "${AVD_SUB_ID:?source avd-assessment.env first}"
: "${AVD_STORAGE:?source avd-assessment.env first}"
: "${AVD_CONTAINER:?source avd-assessment.env first}"

az account set --subscription "$AVD_SUB_ID"

TS=$(date +%Y%m%d-%H%M%S)
OUT="avd-data-$TS"
mkdir -p "$OUT"
# Per-run salt so hashes aren't reversible via precomputed tables, but are
# consistent WITHIN this dataset (same user hashes to same value here).
# The salt is never written to disk.
SALT=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')

# vm_size_lookup <region> <size> -> echoes "vCPU,memoryGB" (blank if unknown).
# az vm list-skus is cached per region so we call it at most once per region.
vm_size_lookup() {
  local region="$1" size="$2"
  local cache="$OUT/_sku_${region}.json"
  if [[ ! -f "$cache" ]]; then
    az vm list-skus -l "$region" --resource-type virtualMachines --only-show-errors -o json 2>/dev/null > "$cache" || echo "[]" > "$cache"
    [[ -s "$cache" ]] || echo "[]" > "$cache"
  fi
  jq -r --arg s "$size" 'map(select(.name==$s and .resourceType=="virtualMachines"))[0].capabilities as $c | (($c[]?|select(.name=="vCPUs")|.value)//"") + "," + (($c[]?|select(.name=="MemoryGB")|.value)//"")' "$cache" 2>/dev/null || echo ","
}

echo "==> Lookback: ${LOOKBACK_DAYS}d | usernames: $([[ $HASH_USERS -eq 1 ]] && echo hashed || echo RAW)"

# --- Ensure read-only extensions ---------------------------------------------
az extension add --name desktopvirtualization --only-show-errors >/dev/null 2>&1 || true
az extension add --name log-analytics --only-show-errors >/dev/null 2>&1 || true

# --- Configuration (ARM) -----------------------------------------------------
echo "subscription,resourceGroup,hostPoolName,type,loadBalancer,maxSessionLimit,startVMOnConnect,validationEnvironment,sessionHosts,appGroups,region,sessionSupport,allocationType" > "$OUT/hostpools.csv"
echo "resourceGroup,hostPoolName,sessionHostName,status,sessions,allowNewSession,vmName,vmSize,vCPU,memoryGB,osType,imageOffer,imageSku,region" > "$OUT/sessionhosts.csv"
echo "resourceGroup,hostPoolName,appGroupName,type,assignedPrincipals" > "$OUT/appgroups.csv"
# Session-level records (one row per connected session). userID is hashed
# inside the KQL query below, so raw usernames never leave Azure.
echo "userID,sessionID,machineID,desktopGroup,startTime,endTime" > "$OUT/sessions.csv"

echo "==> Pulling host pool configuration..."
az desktopvirtualization hostpool list --only-show-errors -o json 2>/dev/null > "$OUT/hostpools.json" || echo "[]" > "$OUT/hostpools.json"
HP_COUNT=$(jq 'length' "$OUT/hostpools.json")
echo "    $HP_COUNT host pool(s)"

jq -c '.[]' "$OUT/hostpools.json" | while read -r hp; do
  HP_NAME=$(echo "$hp" | jq -r '.name')
  HP_ID=$(echo "$hp" | jq -r '.id')
  RG=$(echo "$HP_ID" | sed -n 's#.*/[Rr]esource[Gg]roups/\([^/]*\)/.*#\1#p')
  HP_TYPE=$(echo "$hp" | jq -r '.hostPoolType // "Unknown"')
  LB=$(echo "$hp" | jq -r '.loadBalancerType // "Unknown"')
  MAX=$(echo "$hp" | jq -r '.maxSessionLimit // "n/a"')
  SVMOC=$(echo "$hp" | jq -r '.startVMOnConnect // false')
  VALENV=$(echo "$hp" | jq -r '.validationEnvironment // false')
  HP_REGION=$(echo "$hp" | jq -r '.location // ""')
  #   allocationType: Personal -> Static (dedicated); Pooled -> Random (pooled)
  #   sessionSupport: Personal or maxSessions<=1 -> SingleSession; else MultiSession
  if [[ "$HP_TYPE" == "Personal" ]]; then
    ALLOC="Static"; SESSUP="SingleSession"
  else
    ALLOC="Random"
    if [[ "$MAX" =~ ^[0-9]+$ ]] && [[ "$MAX" -gt 1 ]]; then SESSUP="MultiSession"; else SESSUP="SingleSession"; fi
  fi

  # Session hosts: the stable 'desktopvirtualization' CLI extension exposes no
  # session-host command, so query ARM directly.
  az rest --method GET \
    --url "https://management.azure.com${HP_ID}/sessionHosts?api-version=2024-04-03" \
    --only-show-errors -o json 2>/dev/null | jq '.value // []' > "$OUT/_sh.json" 2>/dev/null || echo "[]" > "$OUT/_sh.json"
  [[ -s "$OUT/_sh.json" ]] || echo "[]" > "$OUT/_sh.json"
  SH_COUNT=$(jq 'length' "$OUT/_sh.json")
  jq -c '.[]' "$OUT/_sh.json" | while read -r sh; do
    SH_NAME=$(echo "$sh" | jq -r '.name' | sed 's#.*/##')
    # Enrich with the backing VM's size -> vCPU/RAM, OS, image, region.
    VM_ID=$(echo "$sh" | jq -r '.properties.resourceId // ""')
    VM_NAME=""; VM_SIZE=""; VCPU=""; MEMGB=""; OSTYPE=""; IMG_OFFER=""; IMG_SKU=""; SH_REGION=""
    if [[ -n "$VM_ID" ]]; then
      VM_JSON=$(az vm show --ids "$VM_ID" --only-show-errors -o json 2>/dev/null || echo "{}")
      VM_NAME=$(echo "$VM_JSON" | jq -r '.name // ""')
      VM_SIZE=$(echo "$VM_JSON" | jq -r '.hardwareProfile.vmSize // ""')
      SH_REGION=$(echo "$VM_JSON" | jq -r '.location // ""')
      OSTYPE=$(echo "$VM_JSON" | jq -r '.storageProfile.osDisk.osType // ""')
      IMG_OFFER=$(echo "$VM_JSON" | jq -r '.storageProfile.imageReference.offer // ""')
      IMG_SKU=$(echo "$VM_JSON" | jq -r '.storageProfile.imageReference.sku // ""')
      if [[ -n "$VM_SIZE" && -n "$SH_REGION" ]]; then
        SIZING=$(vm_size_lookup "$SH_REGION" "$VM_SIZE"); VCPU="${SIZING%%,*}"; MEMGB="${SIZING##*,}"
      fi
    fi
    echo "$RG,$HP_NAME,$SH_NAME,$(echo "$sh" | jq -r '.properties.status // "Unknown"'),$(echo "$sh" | jq -r '.properties.sessions // 0'),$(echo "$sh" | jq -r '.properties.allowNewSession // true'),$VM_NAME,$VM_SIZE,$VCPU,$MEMGB,$OSTYPE,$IMG_OFFER,$IMG_SKU,$SH_REGION" >> "$OUT/sessionhosts.csv"
  done

  az desktopvirtualization applicationgroup list --only-show-errors -o json 2>/dev/null \
    --query "[?contains(hostPoolArmPath, '$HP_NAME')]" > "$OUT/_ag.json" || echo "[]" > "$OUT/_ag.json"
  AG_COUNT=$(jq 'length' "$OUT/_ag.json")
  jq -c '.[]' "$OUT/_ag.json" | while read -r ag; do
    AG_NAME=$(echo "$ag" | jq -r '.name')
    AG_TYPE=$(echo "$ag" | jq -r '.applicationGroupType // "Unknown"')
    AG_RG=$(echo "$ag" | jq -r '.id' | sed -n 's#.*/[Rr]esource[Gg]roups/\([^/]*\)/.*#\1#p')
    ASSIGNED=$(az role assignment list --scope "$(echo "$ag" | jq -r '.id')" --only-show-errors --query "length(@)" -o tsv 2>/dev/null || echo "0")
    echo "$AG_RG,$HP_NAME,$AG_NAME,$AG_TYPE,$ASSIGNED" >> "$OUT/appgroups.csv"
  done

  echo "$AVD_SUB_ID,$RG,$HP_NAME,$HP_TYPE,$LB,$MAX,$SVMOC,$VALENV,$SH_COUNT,$AG_COUNT,$HP_REGION,$SESSUP,$ALLOC" >> "$OUT/hostpools.csv"
  echo "    - $HP_NAME ($HP_TYPE, $SH_COUNT hosts, $AG_COUNT app groups)"
done
rm -f "$OUT/_sh.json" "$OUT/_ag.json" "$OUT"/_sku_*.json

# --- Usage (Log Analytics / KQL) --------------------------------------------
# One row per connected session, reconstructed from WVDConnections by
# CorrelationId (Started -> Connected -> Completed). The username is SHA-256
# hashed in-query with the per-run salt, so raw usernames never leave Azure.
if [[ "$HASH_USERS" -eq 1 ]]; then
  USERID_EXPR="substring(hash_sha256(strcat('${SALT}', UserName)), 0, 16)"
else
  USERID_EXPR="UserName"
fi
KQL_SESSIONS="WVDConnections | where TimeGenerated > ago(${LOOKBACK_DAYS}d) | where State in ('Connected','Completed') | summarize StartTime=min(TimeGenerated), EndTime=max(TimeGenerated), hadConnected=countif(State=='Connected') by CorrelationId, UserName, SessionHostName, _ResourceId | where hadConnected > 0 and EndTime > StartTime | extend DesktopGroup=tostring(split(_ResourceId,'/')[-1]), UserID=${USERID_EXPR} | project UserID, SessionID=CorrelationId, MachineID=SessionHostName, DesktopGroup, StartTime, EndTime | order by StartTime asc"

echo "==> Discovering workspaces with AVD data..."
az monitor log-analytics workspace list --only-show-errors -o json 2>/dev/null | jq -c '.[]' | while read -r ws; do
  WS_NAME=$(echo "$ws" | jq -r '.name')
  WS_CID=$(echo "$ws" | jq -r '.customerId')
  # -o tsv appends a TableName column ("<count>\tPrimaryResult"); take field 1.
  HAS=$(az monitor log-analytics query -w "$WS_CID" --analytics-query "WVDConnections | count" --only-show-errors -o tsv 2>/dev/null | tail -1 | cut -f1 || echo "0")
  [[ "$HAS" =~ ^[0-9]+$ ]] && [[ "$HAS" -gt 0 ]] || continue
  echo "    workspace $WS_NAME has AVD data"

  az monitor log-analytics query -w "$WS_CID" --analytics-query "$KQL_SESSIONS" --only-show-errors -o json 2>/dev/null \
    | jq -r '.[] | [.UserID, .SessionID, .MachineID, .DesktopGroup, .StartTime, .EndTime] | @csv' >> "$OUT/sessions.csv" 2>/dev/null || true
done
SESS_COUNT=$(($(wc -l < "$OUT/sessions.csv") - 1))
if [[ "$SESS_COUNT" -gt 0 ]]; then
  echo "    $SESS_COUNT session record(s) exported"
else
  echo "    no AVD session data found in any workspace (config-only collection)"
fi

# --- Manifest ----------------------------------------------------------------
cat > "$OUT/manifest.json" <<EOF
{
  "generated": "$TS",
  "subscription": "$AVD_SUB_ID",
  "lookbackDays": $LOOKBACK_DAYS,
  "usernamesHashed": $([[ $HASH_USERS -eq 1 ]] && echo true || echo false),
  "hostPoolCount": $HP_COUNT,
  "sessionRecords": $SESS_COUNT
}
EOF

# --- Upload to assessment storage -------------------------------------------
echo "==> Uploading results to $AVD_STORAGE/$AVD_CONTAINER/$OUT/ ..."
az storage blob upload-batch \
  --account-name "$AVD_STORAGE" --auth-mode login \
  --destination "$AVD_CONTAINER" --destination-path "$OUT" \
  --source "$OUT" --only-show-errors -o none

echo ""
echo "==================== DONE ===================="
echo "Host pools:      $HP_COUNT"
echo "Session records: $SESS_COUNT"
echo "Local copy:      ./$OUT/   (review this before sharing)"
echo "Uploaded to:     $AVD_STORAGE / $AVD_CONTAINER / $OUT/"
echo ""
echo "To share, sign back in as yourself (az login) and generate a read-only SAS:"
echo "  az storage container generate-sas --account-name $AVD_STORAGE \\"
echo "    --name $AVD_CONTAINER --permissions rl \\"
echo "    --expiry \$(date -u -d '+7 days' '+%Y-%m-%dT%H:%MZ') \\"
echo "    --auth-mode login --as-user -o tsv"
echo "=============================================="
