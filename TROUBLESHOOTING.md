# Troubleshooting

## Step 1: Setup

### "Insufficient privileges to complete the operation" when creating the service principal

Your account lacks Entra app-registration rights. Use the custom-role model instead. It creates no service principal:

```bash
./avd-setup.sh -m role
```

### "AuthorizationFailed" when assigning roles

Creating role assignments requires **Owner** or **User Access Administrator** at subscription scope. Contributor alone can create resources but cannot grant roles. Ask whoever holds that role to run Step 1.

### Storage account name already taken

Storage account names are globally unique across Azure. The name uses a timestamp suffix, so collisions are rare. Re-run `./avd-setup.sh` to get a new suffix.

### The custom role is not recognised immediately

RBAC changes take time to propagate. The `role` model already waits 20 seconds. If the assignment still fails, wait a minute and re-run. Propagation can occasionally take several minutes.

---

## Step 2: Collect

### "source avd-assessment.env first"

Run the collector from the same directory where setup wrote the env file:

```bash
source avd-assessment.env
./avd-collect.sh
```

If Cloud Shell timed out and the file is gone, re-run Step 1, or reconstruct the variables from the resource names in the portal.

### Zero host pools found

Check you are pointed at the right subscription:

```bash
az account show --query name -o tsv
```

The collector's Reader role is scoped to the subscription Step 1 ran against. If your AVD estate lives in a different subscription, re-run Step 1 there with `-s <subId>`. Multi-subscription collection in a single run is not supported. Run the scripts once per subscription.

### No session records, only configuration files

This is expected when no Azure Monitor diagnostic settings forward AVD logs to Log Analytics. The script queries only workspaces that actually contain `WVDConnections` data.

Check whether any workspace has AVD data:

```bash
az monitor log-analytics query \
  -w <workspace-customer-id> \
  --analytics-query "WVDConnections | take 1 | count" -o table
```

If this returns 0, diagnostics are not configured or the data has aged out of retention. Config-only collection is still useful, and the lack of telemetry is itself a finding.

### Usage queries fail with "access denied from <IP>" (workspace locked down)

The query errors even though the workspace exists and has data:

```
InsufficientAccessError / NspValidationFailedError:
Access to workspace '<name>' from '<your IP>' is denied.
```

This is **not** a permissions problem with the collector identity. The Log Analytics workspace has **public query access disabled** and is reachable only over Private Link or from inside an Azure Monitor Private Link Scope or Network Security Perimeter. Cloud Shell egresses from a public IP, so the query is blocked at the network layer before RBAC is evaluated.

This is a deliberate, mature security choice. To collect usage data anyway, pick one:

- **Run collection from inside your network.** Use a jump host or VM on a VNet inside the workspace's Private Link scope, or Cloud Shell with VNet integration. This keeps the read-only model intact.
- **Temporarily allow query.** Add the collector's egress IP to the Network Security Perimeter or firewall rules, or re-enable public query for the assessment window and revert afterward:
  ```bash
  az monitor log-analytics workspace update \
    -g <rg> -n <workspace> --query-access Enabled
  ```
- **Fall back to config-only.** ARM configuration collects fine regardless. Only the session history is blocked.

Note: Terraform's Azure Verified Module for Log Analytics disables public ingestion and query by default, whereas the raw `azurerm_log_analytics_workspace` resource enables both. A workspace built from the module without Private Link wiring rejects queries out of the box.

### Session data looks thin

The default lookback is 30 days. If workspace retention is shorter, you only get what is retained. If retention is longer, widen the window:

```bash
./avd-collect.sh -d 90
```

### Upload fails with an authorization error

The Storage Blob Data Contributor assignment is scoped to the assessment storage account, and data-plane role assignments can take a few minutes to propagate. Wait a couple of minutes and re-run. Collection is safe to repeat. It writes a new timestamped folder each time.

Confirm you are signed in as the collector identity (sp model):

```bash
az account show --query user.name -o tsv    # should be the app ID, not your user
```

---

## Step 3: Share

### The SAS command fails with "auth-mode login" or "as-user" errors

`--as-user` requires a signed-in **user**, not the service principal. Sign back in as yourself first:

```bash
az login
source avd-assessment.env
```

### The architect says the link expired

Links last 7 days. Generate a fresh one with the same command. The data is unchanged as long as you have not run cleanup.

---

## Still stuck?

Open an issue on [GitHub](https://github.com/JefferyMitchell/AVD-Collector/issues) with the command you ran and the error output. Redact subscription IDs and tenant IDs.
