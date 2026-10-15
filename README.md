# AVD Assessment Collector

A read-only script that gathers your **Azure Virtual Desktop (AVD)**
configuration and session history. You run it in your own Azure Cloud Shell,
review the output, and download one zip file.

| Step | Who | What happens |
|---|---|---|
| **1. Setup** (optional) | An administrator, once | Creates a dedicated **read-only** collector identity. No Azure resources. |
| **2. Collect** | The collector identity, or any user with Reader rights | Reads host-pool config and session history, hashes usernames, writes one zip file |
| **3. Download** | You | Download the zip from Cloud Shell |
| **4. Cleanup** | You | One command removes the collector identity |

Total hands-on time is about 10 minutes.

---

## Security model

- **The script performs no writes against your environment.** It only reads ARM configuration and runs one Log Analytics query. It creates nothing in your subscription.
- If you run Step 1, the collector identity holds exactly **two built-in read roles** on the subscription and nothing else:

  | Role | Why |
  |---|---|
  | **Reader** | Read AVD and VM configuration. Cannot modify anything. |
  | **Log Analytics Reader** | Run the session-history query. |

- **Usernames are SHA-256 hashed inside the Log Analytics query** with a random per-run salt. Raw usernames never reach disk and the salt is never saved. The same user hashes to the same value within one run, which is all the analysis needs.
- **Nothing leaves your tenant automatically.** The output stays in your Cloud Shell until you download it yourself.

### Exactly what is in the zip

| File | Contents |
|---|---|
| `hostpools.csv` / `hostpools.json` | Host pool name, type, load balancer, max session limit, start-VM-on-connect, region |
| `sessionhosts.csv` | Session host name, status, current sessions, backing VM size, vCPU, memory, OS, image |
| `appgroups.csv` | Application group name, type (desktop or RemoteApp), count of assigned principals |
| `sessions.csv` | One row per connected session: hashed user ID, session ID, host name, host pool, start time, end time |
| `hostperf.csv` | One row per host per hour: CPU %, available memory, disk latency, user input delay, network round-trip time. From the AVD Insights counters. No user identifiers. |
| `hostapps.csv` | Application image names seen on each host (for example `excel`, `chrome`), how many hours each was active, and its input delay. From the AVD Insights per-process counter. Process names only: no window titles, document names, or user identifiers. |
| `manifest.json` | Run timestamp, subscription ID, lookback days, hashed flag, counts |

Not collected: usernames (unless you pass `-r`), IP addresses, client details, window titles, document or file names, file or disk contents, network configuration, or anything outside AVD and its session hosts.

---

## Prerequisites

- **Azure Cloud Shell (Bash)**. Open it from the Azure portal (the `>_` icon) or [shell.azure.com](https://shell.azure.com). It already has `az` and `jq` and is signed in as you.
- **Rights.** Collection needs **Reader** and **Log Analytics Reader** on the subscription that holds your AVD estate. If you already have those, you can skip Step 1. Step 1 itself needs Owner or User Access Administrator to assign roles, plus Entra app-registration rights for the default model.
- **Usage data needs AVD Insights.** Session history comes from the `WVDConnections` table in Log Analytics, and host performance from the `Perf` table. If [AVD Insights](https://learn.microsoft.com/azure/virtual-desktop/insights) is enabled for your host pools, both are already in place. If you ship AVD logs to Log Analytics another way, the session history works as long as each host pool's diagnostic setting includes the Connection log category and the workspace retains at least the lookback window (default 30 days). Without these the script still collects full configuration and reports zero session and performance records.

Get the script:

```bash
git clone https://github.com/JefferyMitchell/avd-analyzer.git
cd avd-analyzer
chmod +x avd-setup.sh avd-collect.sh
```

---

## Step 1: Setup (optional)

Skip this if you will run collection as a user who already holds Reader and Log Analytics Reader. Run it if your security team wants collection to happen under a dedicated identity they can audit and delete afterward.

```bash
./avd-setup.sh                 # default: service principal, current subscription
./avd-setup.sh -m role         # custom read-only role on your own user (when SP creation is blocked)
./avd-setup.sh -s <subId>      # explicit subscription
```

The script prints a plan and asks you to confirm before creating anything.

| `-m` | Model | Use when |
|---|---|---|
| `sp` (default) | A service principal created with no default role, then given the two read roles | You have app-registration rights. Cleanest isolation: a separate identity that is deleted at cleanup. |
| `role` | A purpose-built read-only custom role assigned to your current user | Service principal creation is blocked in your tenant. |

Setup writes two files into your Cloud Shell directory:

- `avd-assessment.env` holds the context for Step 2. In the `sp` model it contains the service principal secret. Cleanup deletes it.
- `avd-cleanup.sh` removes the identity.

---

## Step 2: Collect

If you ran Step 1, load the context and (service principal model only) sign in as the collector:

```bash
source avd-assessment.env

# sp model only. Skip this line if you used -m role or skipped Step 1:
az login --service-principal -u "$AVD_APP_ID" -p "$AVD_SP_PASS" --tenant "$AVD_TENANT_ID"
```

Then collect:

```bash
./avd-collect.sh                # 30-day lookback, usernames hashed
./avd-collect.sh -d 90          # 90-day lookback
./avd-collect.sh -s <subId>     # a specific subscription
./avd-collect.sh -r             # keep raw usernames (only with your security team's agreement)
```

Expected output:

```
==> Lookback: 30d | usernames: hashed
==> Pulling host pool configuration...
    3 host pool(s)
    - hp-knowledge-workers (Pooled, 12 hosts, 2 app groups)
    - hp-task-workers (Pooled, 8 hosts, 1 app groups)
    - hp-developers (Personal, 15 hosts, 1 app groups)
==> Discovering workspaces with AVD data...
    workspace law-avd-prod: session history
    workspace law-avd-prod: performance counters
    4812 session record(s) exported
    25200 host-hour performance record(s), 1430 application record(s)

==================== DONE ====================
Host pools:      3
Session records: 4812
Perf records:    25200 host-hours, 1430 application rows
Review:          ./avd-data-20260714-101500/        (plain CSV + JSON)
Package:         ./avd-data-20260714-101500.zip
```

A longer lookback gives a more representative picture. Use 90 days if your workspace retention allows it. If your AVD estate spans several subscriptions, run the script once per subscription.

---

## Step 3: Download

**Review first.** The output is plain CSV and JSON in the run folder:

```bash
cat avd-data-*/manifest.json          # confirm "usernamesHashed": true
head avd-data-*/sessions.csv
```

Then download the zip to your computer. Cloud Shell has a built-in command for this:

```bash
download avd-data-<timestamp>.zip
```

Your browser saves the file.

---

## Step 4: Cleanup

If you ran Step 1, remove the collector identity once you have downloaded the zip:

```bash
./avd-cleanup.sh
```

This deletes the service principal or custom role and the local env file. Verify nothing is left:

```bash
az ad sp list --display-name "sp-avd-assessment" --query "[].displayName" -o tsv
az role definition list --custom-role-only true \
  --query "[?starts_with(roleName,'AVD Assessment Collector')].roleName" -o tsv
```

Both should return nothing. You can also delete the local `avd-data-*` folder and zip from Cloud Shell when you no longer need them.

---

## Problems?

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md). The most common causes are a locked-down Log Analytics workspace (network, not permissions) and missing diagnostics.

## Disclaimer

This project is not affiliated with or endorsed by Microsoft. Review the scripts and test in a non-production subscription before running against production.
