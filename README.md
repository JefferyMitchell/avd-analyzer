# AVD Assessment Collector

Two scripts that gather your **Azure Virtual Desktop (AVD)** configuration and
usage data for a Citrix persona-mapping assessment. You run them in your own
Azure Cloud Shell. **Nothing leaves your tenant until you generate a
time-limited, read-only link and send it to your architect.**

| Step | Who | What happens |
|---|---|---|
| **1. Setup** | A customer administrator, once | Creates a throwaway resource group, a private storage account, and a **scoped read-only collector identity** |
| **2. Collect** | The collector identity | Reads host-pool config and session history, hashes usernames, uploads the results to that storage account |
| **3. Share** | You | Generate a read-only, 7-day link and send it to your architect |
| **4. Cleanup** | You | One command removes everything the scripts created |

Total hands-on time is about 15 minutes.

---

## Security model

Your security team will want to check this, so here is exactly what the
collector identity can do. It holds **three role assignments and nothing else**:

| Role | Scope | Why |
|---|---|---|
| **Reader** | Subscription | Read ARM configuration. Cannot modify anything. |
| **Log Analytics Reader** | Subscription | Run the session-history query. |
| **Storage Blob Data Contributor** | The assessment storage account **only** | Upload results. This is the identity's single write capability. |

- The collector identity is **read-only against your entire environment**. It cannot change host pools, session hosts, VMs, or anything else.
- Its only write target is a **single throwaway storage account** created by the setup step, in your subscription, with public access disabled.
- **Usernames are SHA-256 hashed inside the Log Analytics query** with a random per-run salt. Raw usernames never reach disk and the salt is never saved. The same user hashes to the same value within one run, which is all the analysis needs.
- Everything created is tagged `purpose=avd-assessment temporary=true` and is removed by the cleanup script.

### Exactly what is collected

| File | Contents |
|---|---|
| `hostpools.csv` / `hostpools.json` | Host pool name, type, load balancer, max session limit, start-VM-on-connect, region |
| `sessionhosts.csv` | Session host name, status, current sessions, backing VM size, vCPU, memory, OS, image |
| `appgroups.csv` | Application group name, type (desktop or RemoteApp), count of assigned principals |
| `sessions.csv` | One row per connected session: hashed user ID, session ID, host name, host pool, start time, end time |
| `manifest.json` | Run timestamp, subscription ID, lookback days, hashed flag, counts |

Not collected: usernames (unless you pass `-r`), IP addresses, client details, application names, file or disk contents, network configuration, or anything outside AVD and its session hosts.

---

## Prerequisites

- **Azure Cloud Shell (Bash)**. Open it from the Azure portal (the `>_` icon) or [shell.azure.com](https://shell.azure.com). It already has `az` and `jq` and is signed in as you.
- **Setup** needs someone who can create a resource group and storage account and assign roles at subscription scope (Owner, or User Access Administrator plus Contributor). The default identity model also needs Entra rights to create an app registration. If that is locked down, use `-m role` (see below).
- **Usage data needs diagnostics.** Session history comes from Log Analytics. Your host pools must already have diagnostic settings sending `WVDConnections` to a workspace, with retention covering the lookback window (default 30 days). Without it the scripts still collect full configuration and simply report zero session records.

Get the scripts:

```bash
git clone https://github.com/JefferyMitchell/AVD-Collector.git
cd AVD-Collector
chmod +x avd-setup.sh avd-collect.sh
```

---

## Step 1: Setup

```bash
./avd-setup.sh                       # default: service principal, current subscription
./avd-setup.sh -m role               # custom role on your own user (when SP creation is blocked)
./avd-setup.sh -s <subId> -l eastus  # explicit subscription and region
```

The script prints a plan and asks you to confirm before creating anything.

| `-m` | Model | Use when |
|---|---|---|
| `sp` (default) | A service principal created with no default role, then given the three roles above | You have app-registration rights. Cleanest isolation: collection runs as a separate identity that is deleted at cleanup. |
| `role` | A purpose-built custom role assigned to your current user | Service principal creation is blocked in your tenant. |

Setup writes two files into your Cloud Shell directory:

- `avd-assessment.env` holds the context for Step 2. In the `sp` model it contains the service principal secret. Cleanup deletes it.
- `avd-cleanup.sh` is the one-command teardown with your resource names baked in.

---

## Step 2: Collect

Load the context, then (service principal model only) sign in as the collector:

```bash
source avd-assessment.env

# sp model only. Skip this line if you used -m role:
az login --service-principal -u "$AVD_APP_ID" -p "$AVD_SP_PASS" --tenant "$AVD_TENANT_ID"
```

Then collect:

```bash
./avd-collect.sh            # 30-day lookback, usernames hashed
./avd-collect.sh -d 90      # 90-day lookback
./avd-collect.sh -r         # keep raw usernames (only with your security team's agreement)
```

The results are written to a local folder `avd-data-<timestamp>/` **and** uploaded to the assessment storage account. Expected output:

```
==> Lookback: 30d | usernames: hashed
==> Pulling host pool configuration...
    3 host pool(s)
    - hp-knowledge-workers (Pooled, 12 hosts, 2 app groups)
    - hp-task-workers (Pooled, 8 hosts, 1 app groups)
    - hp-developers (Personal, 15 hosts, 1 app groups)
==> Discovering workspaces with AVD data...
    workspace law-avd-prod has AVD data
    4812 session record(s) exported
==> Uploading results to stavdassess12345/results/avd-data-20260714-101500/ ...
```

A longer lookback gives a more representative picture. Use 90 days if your workspace retention allows it.

---

## Step 3: Share

**Review first.** The output is plain CSV and JSON in the local run folder:

```bash
ls avd-data-*/
cat avd-data-*/manifest.json          # confirm "usernamesHashed": true
head avd-data-*/sessions.csv
```

Then sign back in as yourself (the service principal cannot issue user-delegated links) and generate the link. Step 2 prints this command with your values filled in:

```bash
az login
source avd-assessment.env
az storage container generate-sas \
  --account-name "$AVD_STORAGE" --name "$AVD_CONTAINER" \
  --permissions rl \
  --expiry $(date -u -d '+7 days' '+%Y-%m-%dT%H:%MZ') \
  --auth-mode login --as-user -o tsv
```

Send your architect the full URL:

```
https://<storage-account>.blob.core.windows.net/results?<sas-token>
```

| Property | Value |
|---|---|
| Permissions | Read and list only. The holder cannot write, change, or delete. |
| Scope | The `results` container only. |
| Lifetime | 7 days, then it stops working. |
| Revocation | Run cleanup, or delete the storage account, to invalidate it immediately. |

Use whatever channel your organisation uses for time-limited credentials.

---

## Step 4: Cleanup

Once your architect confirms they have downloaded the results:

```bash
./avd-cleanup.sh
```

This deletes the resource group (storage account and all results), the service principal or custom role, and the local env file. **It also invalidates the shared link.**

Verify nothing is left:

```bash
az group list --query "[?tags.purpose=='avd-assessment'].name" -o tsv
az ad sp list --display-name "sp-avd-assessment" --query "[].displayName" -o tsv
az role definition list --custom-role-only true \
  --query "[?starts_with(roleName,'AVD Assessment Collector')].roleName" -o tsv
```

All three should return nothing. The resource group delete runs in the background, so allow a minute.

If you lost the cleanup script, everything is tagged `purpose=avd-assessment`. Find the resource group with the first command above and delete it with `az group delete -n <name> --yes`, then remove the service principal or custom role by name.

---

## Problems?

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md). The most common causes are a locked-down Log Analytics workspace (network, not permissions) and missing diagnostics.

## Disclaimer

This project is not affiliated with or endorsed by Microsoft or Citrix. Review the scripts and test in a non-production subscription before running against production.
