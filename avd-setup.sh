#!/usr/bin/env bash
#
# AVD Assessment - STEP 1: SETUP  (optional; run once by an administrator)
# ========================================================================
# Creates a dedicated READ-ONLY collector identity so the collection step can
# run under an identity your security team can audit line by line.
#
# This step creates NO Azure resources. It only creates an identity and
# grants it two built-in read roles on the subscription:
#       * Reader                 (ARM configuration; cannot modify anything)
#       * Log Analytics Reader   (session-history query)
#
# You can skip this step entirely: avd-collect.sh performs no writes, so it
# can be run as any user who already holds those two roles.
#
# Identity model (pick with -m):
#   sp      Service principal (default). Requires Entra app-registration rights.
#   role    Custom read-only role assigned to the current user. Use when SP
#           creation is blocked.
#
# Usage:
#   ./avd-setup.sh                 # SP model, current subscription
#   ./avd-setup.sh -m role         # custom-role model
#   ./avd-setup.sh -s <subId>      # explicit subscription
#
# Cleanup after the engagement (removes the identity):
#   ./avd-cleanup.sh
#
set -euo pipefail

MODEL="sp"
SUB=""

while getopts "m:s:h" opt; do
  case $opt in
    m) MODEL="$OPTARG" ;;
    s) SUB="$OPTARG" ;;
    h) grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
    *) echo "Invalid option"; exit 1 ;;
  esac
done

# --- Context -----------------------------------------------------------------
az account show >/dev/null 2>&1 || { echo "ERROR: run this in Cloud Shell (already authenticated) or 'az login'."; exit 1; }
[[ -n "$SUB" ]] && az account set --subscription "$SUB"
SUB_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

SUFFIX=$(date +%s | tail -c 6)
SP_NAME="sp-avd-assessment-$SUFFIX"
ROLE_NAME="AVD Assessment Collector $SUFFIX"

echo "==================== SETUP PLAN ===================="
echo "Subscription:     $SUB_ID"
echo "Identity model:   $MODEL"
if [[ "$MODEL" == "sp" ]]; then
  echo "Creates:          service principal $SP_NAME"
  echo "Grants:           Reader + Log Analytics Reader on the subscription"
else
  echo "Creates:          custom role '$ROLE_NAME' (read-only)"
  echo "Grants:           that role to your current user on the subscription"
fi
echo "Azure resources:  none"
echo "===================================================="
read -r -p "Proceed? [y/N] " ok
[[ "$ok" == "y" || "$ok" == "Y" ]] || { echo "Aborted."; exit 0; }

if [[ "$MODEL" == "sp" ]]; then
  echo "==> Creating collector service principal (no default role)..."
  # Current Azure CLI creates the SP with NO role assignment by default; the
  # two read roles below are the only rights it will ever hold.
  SP_JSON=$(az ad sp create-for-rbac --name "$SP_NAME" --only-show-errors -o json)
  APP_ID=$(echo "$SP_JSON" | jq -r '.appId')
  SP_PASS=$(echo "$SP_JSON" | jq -r '.password')
  SP_OID=$(az ad sp show --id "$APP_ID" --query id -o tsv)

  echo "==> Assigning Reader on subscription (read-only over all resources)..."
  az role assignment create --assignee-object-id "$SP_OID" --assignee-principal-type ServicePrincipal \
    --role "Reader" --scope "/subscriptions/$SUB_ID" --only-show-errors -o none

  echo "==> Assigning Log Analytics Reader on subscription..."
  az role assignment create --assignee-object-id "$SP_OID" --assignee-principal-type ServicePrincipal \
    --role "Log Analytics Reader" --scope "/subscriptions/$SUB_ID" --only-show-errors -o none

  cat > avd-assessment.env <<EOF
# Source this, then run avd-collect.sh
export AVD_MODEL="sp"
export AVD_SUB_ID="$SUB_ID"
export AVD_TENANT_ID="$TENANT_ID"
export AVD_APP_ID="$APP_ID"
export AVD_SP_PASS="$SP_PASS"
EOF

  echo ""
  echo "==================== NEXT STEP ===================="
  echo "The read-only collector identity is created."
  echo "To run collection under it:"
  echo ""
  echo "  source avd-assessment.env"
  echo "  az login --service-principal -u \"\$AVD_APP_ID\" -p \"\$AVD_SP_PASS\" --tenant \"\$AVD_TENANT_ID\""
  echo "  ./avd-collect.sh"
  echo ""
  echo "(avd-assessment.env holds the SP secret - cleanup deletes it.)"
  echo "==================================================="

else
  echo "==> Creating custom read-only role..."
  ROLE_DEF=$(cat <<JSON
{
  "Name": "$ROLE_NAME",
  "IsCustom": true,
  "Description": "Read-only AVD assessment collector. No write actions.",
  "Actions": [
    "Microsoft.DesktopVirtualization/*/read",
    "Microsoft.Compute/*/read",
    "Microsoft.OperationalInsights/workspaces/read",
    "Microsoft.OperationalInsights/workspaces/query/read",
    "Microsoft.Authorization/roleAssignments/read"
  ],
  "AssignableScopes": [ "/subscriptions/$SUB_ID" ]
}
JSON
)
  echo "$ROLE_DEF" > _avd_role.json
  az role definition create --role-definition _avd_role.json --only-show-errors -o none
  rm -f _avd_role.json
  sleep 20  # allow role to propagate

  CURRENT_OID=$(az ad signed-in-user show --query id -o tsv)
  echo "==> Assigning custom role to current user at subscription scope..."
  az role assignment create --assignee-object-id "$CURRENT_OID" --assignee-principal-type User \
    --role "$ROLE_NAME" --scope "/subscriptions/$SUB_ID" --only-show-errors -o none

  cat > avd-assessment.env <<EOF
export AVD_MODEL="role"
export AVD_SUB_ID="$SUB_ID"
export AVD_TENANT_ID="$TENANT_ID"
export AVD_ROLE_NAME="$ROLE_NAME"
EOF

  echo ""
  echo "==================== NEXT STEP ===================="
  echo "Custom role created and assigned to you. No service principal was made."
  echo "Run collection directly:"
  echo ""
  echo "  source avd-assessment.env"
  echo "  ./avd-collect.sh"
  echo "==================================================="
fi

# record identifiers for cleanup
cat > avd-cleanup.sh <<EOF
#!/usr/bin/env bash
# Auto-generated. Removes the collector identity this setup created.
set -e
EOF
[[ "$MODEL" == "sp" ]] && cat >> avd-cleanup.sh <<EOF
echo "Removing service principal $SP_NAME..."
az ad sp delete --id "$APP_ID" || true
EOF
[[ "$MODEL" == "role" ]] && cat >> avd-cleanup.sh <<EOF
echo "Removing role assignment and custom role '$ROLE_NAME'..."
az role assignment delete --assignee "$CURRENT_OID" --role "$ROLE_NAME" --scope "/subscriptions/$SUB_ID" || true
az role definition delete --name "$ROLE_NAME" || true
EOF
echo "rm -f avd-assessment.env avd-cleanup.sh" >> avd-cleanup.sh
chmod +x avd-cleanup.sh
echo "==> Cleanup script written: ./avd-cleanup.sh"
