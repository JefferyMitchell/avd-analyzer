# Troubleshooting

## Step 1: Setup

### "Insufficient privileges to complete the operation" when creating the service principal

Your account lacks Entra app-registration rights. Use the custom-role model instead. It creates no service principal:

```bash
./avd-setup.sh -m role
```

Or skip Step 1 entirely and run collection as a user who already holds Reader and Log Analytics Reader.

### "AuthorizationFailed" when assigning roles

Creating role assignments requires **Owner** or **User Access Administrator** at subscription scope. Contributor alone cannot grant roles. Ask whoever holds that role to run Step 1, or skip Step 1 as above.

### The custom role is not recognised immediately

RBAC changes take time to propagate. The `role` model already waits 20 seconds. If the assignment still fails, wait a minute and re-run. Propagation can occasionally take several minutes.

---

## Step 2: Collect

### Zero host pools found

Check you are pointed at the right subscription:

```bash
az account show --query name -o tsv
```

If your AVD estate lives in a different subscription, pass it explicitly:

```bash
./avd-collect.sh -s <subId>
```

The collector identity from Step 1 only has rights on the subscription Step 1 ran against. For several subscriptions, run Step 1 and Step 2 once per subscription.

### "AuthorizationFailed" while collecting

The signed-in identity lacks Reader or Log Analytics Reader on this subscription. Confirm who you are:

```bash
az account show --query user.name -o tsv    # sp model: should be the app ID
```

If you just ran Step 1, role assignments can take a few minutes to propagate. Wait and re-run. Collection is safe to repeat.

### No session records, only configuration files

This is expected when no Azure Monitor diagnostic settings forward AVD logs to Log Analytics. The script queries only workspaces that actually contain `WVDConnections` data.

Check whether any workspace has AVD data:

```bash
az monitor log-analytics query \
  -w <workspace-customer-id> \
  --analytics-query "WVDConnections | take 1 | count" -o table
```

If this returns 0, diagnostics are not configured or the data has aged out of retention. Config-only collection is still useful, and the lack of telemetry is itself a finding.

### Session records are present but performance records are zero

Session history and performance counters are collected separately. Session history comes from host pool diagnostic settings. Performance counters come from the Azure Monitor Agent on each session host, configured by the data collection rule that AVD Insights creates. If you see sessions but no performance data, Insights was never enabled, or the hosts do not have the agent and data collection rule associated. Open AVD Insights in the portal and use its configuration workbook to check per host pool.

Performance data is optional. The configuration and session history are still complete without it.

### The performance query times out or returns nothing on a large estate

The `Perf` table is the largest in the workspace. On estates with hundreds of hosts and a 90-day window the summarising query can exceed the Log Analytics query timeout, in which case the performance files are empty while everything else is complete. Re-run with a shorter window:

```bash
./avd-collect.sh -d 30
```

### Usage queries fail with "access denied from <IP>" (workspace locked down)

The query errors even though the workspace exists and has data:

```
InsufficientAccessError / NspValidationFailedError:
Access to workspace '<name>' from '<your IP>' is denied.
```

This is **not** a permissions problem. The Log Analytics workspace has **public query access disabled** and is reachable only over Private Link or from inside an Azure Monitor Private Link Scope or Network Security Perimeter. Cloud Shell egresses from a public IP, so the query is blocked at the network layer before RBAC is evaluated.

This is a deliberate, mature security choice. To collect usage data anyway, pick one:

- **Run collection from inside your network.** Use a jump host or VM on a VNet inside the workspace's Private Link scope, or Cloud Shell with VNet integration. The script needs only `az` and `jq`.
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

---

## Step 3: Download

### The `download` command is not found

`download` is built into Azure Cloud Shell. If you ran the script somewhere else, the zip is in the directory you ran it from. Copy it to your computer however you normally would.

### The package is a `.tar.gz`, not a `.zip`

The script falls back to tar when `zip` is not installed. Windows 11 and macOS both open it natively.

---

## Still stuck?

Open an issue on [GitHub](https://github.com/JefferyMitchell/avd-analyzer/issues) with the command you ran and the error output. Redact subscription IDs and tenant IDs.
