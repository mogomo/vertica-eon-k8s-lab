# Vertica Eon Mode on Kubernetes — ARM64 lab installer

A reusable, idempotent bootstrap script that turns a clean **Rocky Linux 9 Minimal
(aarch64)** VM into a working **single-node Vertica Eon Mode cluster on Kubernetes**.

Built for **Apple Silicon Macs** running the VM under **UTM**. Everything —
K3s, MinIO, the VerticaDB operator, the database itself — lives inside the VM.
Nothing is installed on the Mac.

```
BUILD    preflight ─► K3s ─► Helm ─► MinIO (S3 communal storage)
                   ─► VerticaDB operator ─► VerticaDB CR ─► readiness ─► smoke test

DEMOS    smoke · bulk · dbd · depot · revive · restore · resilience · scale · wipe · create
```
---
<img width="960" height="471" alt="image" src="https://github.com/user-attachments/assets/c357fb60-ebcd-4959-a14e-ac864e0f55e2" />

---

Ten built-in demonstrations drive the running lab through realistic scenarios —
loading a star schema, running the Database Designer, watching a cold read come
back from S3, destroying the database and reviving it from communal storage,
rolling back to a restore point, killing the pod, scaling a subcluster in and out.

> [!IMPORTANT]
> **Unofficial lab tool, provided as is, with no warranty and no liability.**
> Not affiliated with, endorsed by or supported by Rocket Software or Vertica
> Support. It creates *and destroys* databases by design - run it only on a
> disposable lab VM. Vertica® is a trademark of Rocket Software, Inc., and a
> valid Vertica licence from Rocket Software is required to run Vertica.
> Please read [§9 Disclaimer](#9-disclaimer-trademarks-and-licensing) before use.

### Quick start

```bash
scp bootstrap-vertica-eon.sh .env.example vlab:~/   # from the Mac
ssh vlab
./bootstrap-vertica-eon.sh --echo_only    # read every command it would run, change nothing
./bootstrap-vertica-eon.sh --install      # build the lab (~10 min on first run)
./bootstrap-vertica-eon.sh --demo revive  # destroy the database, revive it from S3
./bootstrap-vertica-eon.sh --uninstall    # the opposite of --install
```

Full details in [§4 Usage](#4-usage); `--echo_only` and `--help` are the only
options that work off the VM.

### Contents

| § | Section |
| --- | --- |
| 1 | [Purpose](#1-purpose) |
| 2 | [Prerequisites — manual VM prep](#2-prerequisites--manual-prep-done-beforehand) |
| 3 | [Version and licensing constraints](#3-version-and-licensing-constraints-read-this-before-changing-image-tags) |
| 4 | [Usage — options, modes, configuration](#4-usage) |
| 5 | [Demonstrations](#5-demonstrations) |
| 6 | [Verification](#6-verification) |
| 7 | [Teardown — and the way back](#7-teardown--and-the-way-back) |
| 8 | [Repository contents](#8-repository-contents) |
| 9 | [Disclaimer, trademarks and licensing](#9-disclaimer-trademarks-and-licensing) |

---

## 1. Purpose

Vertica in Eon Mode separates compute from storage: the database keeps its data in
S3-compatible **communal storage** and caches it locally in a **depot**. This repo
automates the smallest useful version of that architecture — one Vertica node, one
shard, one in-cluster MinIO bucket — so you can exercise Eon Mode end to end on a
laptop-class ARM64 VM.

Design goals:

| Goal | How |
| --- | --- |
| **Portable** | Only assumes a clean Rocky 9 aarch64 VM with sudo and internet |
| **Idempotent** | `helm upgrade --install`, `kubectl apply`, existing secrets reused — re-run any time |
| **Reversible** | Every build step names its opposite: `--install` ↔ `--uninstall` (keeps K3s), `--uninstall --purge-k3s` (removes everything), `--demo wipe` ↔ `--demo create` |
| **Inspectable** | `--dry-run` renders every manifest to `.rendered/` without touching the cluster |
| **Configurable** | One `CONFIG` block in the script, overridable via `.env` |
| **No secrets in git** | Passwords are generated at run time and live only in Kubernetes Secrets |

ARM64 is the constraint that shapes most choices here: the Vertica container image
must be a **multi-arch tag** (`…-multiarch`) that publishes a `linux/arm64` variant,
and MinIO / the operator images must likewise be multi-arch.

---

## 2. Prerequisites — manual prep done beforehand

This script starts from an already-provisioned VM. The steps below were done by hand
once; they are documented here so the lab can be rebuilt from scratch.

> Throughout, the VM is referred to **only by its SSH alias `vlab`**. No IP address
> appears in this repo, and none should be added.

### 2.1 UTM virtual machine (on the Apple Silicon Mac)

- **UTM → New VM → Virtualize**, using the **QEMU backend**.
  Do **not** pick *Apple Virtualization* — the Apple hypervisor backend has caused
  installer and networking trouble with Rocky 9 aarch64.
- **OS:** Rocky Linux 9 **Minimal**, **aarch64** ISO.
- **Resources:** ~**4 vCPU**, **16 GB RAM**, **100 GB** disk.
  (The script's preflight enforces 4 CPU / 12 GB RAM / 60 GB free by default.)
- **Network:** Shared Network (the UTM default).
- **After installation completes: shut the VM down and EJECT the ISO** in UTM.
  Otherwise the VM boots the installer again on every start.

### 2.2 Rocky Linux 9 installation (Anaconda)

- **Partitioning — this matters on UTM/EFI:**
  - `/boot` must be a **standard partition, not LVM** (~1 GiB).
  - `/boot/efi` must be an **EFI System Partition of at least 300 MiB**.
  - `/` on LVM and a default swap are fine.
  - Anaconda's *Automatic* partitioning satisfies both constraints.
- **Software selection:** Minimal Install.
- **Root password:** set.
- **User creation:** create the admin user (`admin`) and tick
  *"Make this user administrator"*.

### 2.3 SSH access from the Mac

Key-based login, no passwords:

```bash
# on the Mac — one time
ssh-copy-id -i ~/.ssh/<your-key>.pub <user>@<vm-address>
```

Then add an alias to `~/.ssh/config` on the Mac so nothing downstream needs the
address:

```
Host vlab
    HostName <vm-address>
    User admin
    IdentityFile ~/.ssh/<your-key>
```

> If the VM's DHCP lease changes after a reboot, update **only** `HostName` in
> `~/.ssh/config`. Everything else — this repo included — refers to `vlab`.

### 2.4 Passwordless sudo (inside the VM)

```bash
ssh vlab
echo "admin ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/admin
sudo chmod 440 /etc/sudoers.d/admin
exit
```

### 2.5 Verify the prep

This must complete with **zero prompts** and print `root`:

```bash
ssh vlab "sudo whoami"
```

---

## 3. Version and licensing constraints (read this before changing image tags)

Two independent constraints decide which versions this lab can use on ARM64.
Both were established empirically on the target VM, not from documentation.

### 3.1 The operator image must publish `linux/arm64`

The `verticadb-operator` image is **not** multi-arch for every release. Checked
against the registry directly:

| Operator version | Architectures |
| --- | --- |
| 24.4.0, 25.1.0, 25.2.0, 25.3.0 | amd64, **arm64** |
| **25.4.0** | amd64 only |
| **26.1.0** | amd64 only |
| 26.1.2, 26.2.0, 26.2.1 | amd64, **arm64** |

An amd64-only operator installs happily and then crash-loops with
`exec /manager: exec format error`. 25.4.0 and 26.1.0 are unusable here.

### 3.2 Licensing changed at v26.1 — Community Edition is gone

This is a product change, not a quirk of this lab:

- **Community Edition (CE)** was the free evaluation option **up to 25.x**. It is
  perpetual and capped at **1 TB / 3 nodes**, and needs **no license file** —
  `display_license()` reports `Vertica Community Edition / Perpetual / 1TB CE Nodes 3`.
- **From v26.1, CE is no longer offered.** New evaluations use a **30-day Trial
  license**, which is a real license file you must supply.
- A database originally **created under CE requires a commercial license** to move
  forward. **Trial licenses are for new installations only** — you cannot use one to
  carry an existing CE database into 26.x.

See the vendor's note:
<https://docs.vertica.com/26.1.x/en/getting-started/community-edition-ce/>

The operator enforces this. VerticaDB operator **26.x refuses to reconcile without a
real license**, and all three possible spellings are rejected:

| `spec.licenseSecret` | Result |
| --- | --- |
| absent | admission webhook: `licenseSecret cannot be empty` |
| set, secret empty | reconciler aborts: `no valid Vertica license found from secret …` |
| set, secret holds the CE license from the image | reconciler aborts: `CE license is not allowed and was found in key …` |

Disabling the webhook does not help — the check also lives in the operator's
`LicenseValidationReconciler`, which then aborts with `license secret is empty`.
Confirmed identically on charts **26.2.0-0** and **26.2.1-0**.

Operator **25.3.0** has no such check: with no `licenseSecret` at all it creates the
database normally under Community Edition.

**Practical consequence for this lab:** a no-license, no-signup lab is only possible
on a 25.x image. That is why the defaults below target 25.3.0. If you have a Trial or
commercial license, point `LICENSE_FILE` at it and move to 26.x — everything else in
the script is unchanged.

### 3.3 What this repo therefore defaults to

| | Default (Community Edition) | Licensed edition |
| --- | --- | --- |
| `VERTICA_IMAGE` | `opentext/vertica-k8s:25.3.0-8-multiarch` | `opentext/vertica-k8s:26.2.0-1-multiarch` |
| `VDB_HELM_CHART_VERSION` | `25.3.0` | `26.2.0` |
| `LICENSE_FILE` | *(empty — none needed)* | path to your Trial or commercial license **on the VM** |
| `spec.licenseSecret` | not set | created from `LICENSE_FILE` |
| Edition reported | Community Edition | whatever the licence grants |

25.3.0 is the newest operator that is *both* arm64-capable *and* CE-friendly, so
it is the default. Preflight fails early with an explanatory message if you point
`VERTICA_IMAGE` at a 26.x tag without setting `LICENSE_FILE`.

---

## 4. Usage

### 4.1 Copy the repo to the VM

> **The script runs ON the VM, not on the Mac.** Everything it talks to — K3s,
> MinIO, the operator, Vertica — lives inside the VM, and nothing is installed on
> the Mac. Running it locally will stop immediately with an explanatory error and
> exit code 2.

```bash
# from this directory, on the Mac
scp bootstrap-vertica-eon.sh .env.example vlab:~/
ssh vlab
```

Or drive it over SSH without logging in:

```bash
ssh vlab './bootstrap-vertica-eon.sh --demo revive --yes'
```

The only options that work off the VM are `--help` and `--list-demos`, which print
and exit without touching a cluster.

### 4.2 Configure (optional)

Every value has a lab-sensible default. To change anything:

```bash
cp .env.example .env
vi .env          # .env is git-ignored — it holds passwords
```

### 4.3 Run

```bash
./bootstrap-vertica-eon.sh --dry-run    # show every action, render manifests, change nothing
./bootstrap-vertica-eon.sh              # build the lab
./bootstrap-vertica-eon.sh --install    # exactly the same build, stated explicitly
./bootstrap-vertica-eon.sh --uninstall  # the opposite: take the lab back down
```

First run takes a while: image pulls plus database creation. The Vertica image is
large, so budget time on a laptop VM.

### 4.4 Options — the complete list

Anything that builds or destroys states its **opposite**, so the way back is
always documented next to the way forward. `--install` and `--uninstall` are
mutually exclusive; passing both is an error.

| Option | Argument | What it does | Opposite |
| --- | --- | --- | --- |
| `--install` | — | Build the lab end to end: preflight → K3s → Helm → MinIO → operator → VerticaDB → smoke test. This is the default action, so bare `./bootstrap-vertica-eon.sh` and `--install` do the same thing. Idempotent. | `--uninstall` |
| `--uninstall` | — | Remove the VerticaDB, the operator and MinIO. K3s is kept. | `--install` |
| `--purge-k3s` | — | Only with `--uninstall`: also run `k3s-uninstall.sh`, removing Kubernetes itself. On its own it is ignored, with a warning. | Leave it out and K3s survives; `--install` (or `--only k3s`) puts it back |
| `--demo` | `NAME[,NAME…]` | Run one or more demonstrations against the running database. Comma-separated, executed in the order given. | Per demo — `--list-demos` prints the reverse of each one |
| `--only` | `PHASE` | Run a single build phase (see below) instead of the whole build. | `--uninstall` (per-phase reverses in the table below) |
| `--verbose`, `-v` | — | Run normally, but also print every command and SQL statement (green) with a plain-English explanation (grey). See §4.5. | Leave it out for a quiet run |
| `--echo_only` | — | Print every command and SQL statement with its explanation and do **nothing at all**. Needs no cluster, so it runs anywhere. Works with `--demo`. See §4.5. | Leave it out to actually do the work |
| `--dry-run` | — | Operational preview: change nothing, but still run the read-only preflight checks and still write the fully rendered manifests to `.rendered/`. Also narrates. Cannot be combined with `--demo`. See §4.5. | Re-run the same command without it to apply for real |
| `--skip-preflight` | — | Turn preflight failures into warnings and continue anyway. | Leave it out and a failed check stops the run |
| `--yes`, `-y` | — | Assume "yes" for destructive demo confirmations. Required to run `wipe`, `create`, `revive`, `restore` or `scale` unattended. | Leave it out and every destructive demo asks first |
| `--env-file` | `PATH` | Config file to source. Default `./.env`. | — |
| `--list-demos` | — | Print the demo catalogue with descriptions, rough durations and the reverse of each demo, then exit. | — |
| `-h`, `--help` | — | Show usage and exit. | — |

Each run also prints the opposite of what it just did, as a `reverse:` line
under the final result — after the build, after an uninstall, after `--only`,
and after every demo.

**Phases accepted by `--only`:**

| Phase | What it does | Opposite |
| --- | --- | --- |
| `preflight` | Check arch, CPU, RAM, disk, sudo, internet, registry reachability, licensing model | Nothing to undo — it only reads |
| `k3s` | Install K3s, open the firewall for pod/service CIDRs | `--uninstall --purge-k3s` |
| `tools` | Install Helm | `sudo rm -f /usr/local/bin/helm` — `--uninstall` deliberately leaves Helm in place |
| `minio` | Deploy MinIO and create the communal bucket | `--uninstall` |
| `operator` | Install the VerticaDB operator via Helm | `--uninstall` |
| `verticadb` | Apply the VerticaDB CR and wait for the database | `--demo wipe`, or `--uninstall` for the whole lab |
| `smoke` | Run the vsql smoke test | Nothing to undo — it drops and recreates its own table |

`--only` is the fast path when iterating — e.g. `--only smoke` re-runs just the SQL
test against an already-running database.

### 4.5 Narration and safety modes — `--verbose`, `--echo_only`, `--dry-run`

Three flags control how much the script explains, and whether it changes anything.

| | narrates? | changes anything? | runs where? | leaves manifests in `.rendered/`? |
| --- | --- | --- | --- | --- |
| *(no flag)* | no | **yes** | on the VM | no |
| `--verbose` | **yes** | **yes** | on the VM | no |
| `--dry-run` | **yes** | no | on the VM | **yes** |
| `--echo_only` | **yes** | no | **anywhere** | no |

**Is `--dry-run` required?** No — it is optional, and it overlaps with `--echo_only`.
They differ in exactly one way, and that one way is the reason to keep it:

- `--echo_only` is a **teaching** mode. It contacts nothing, so it runs on your
  laptop with no Kubernetes installed. Use it to read what the script would do, or
  to walk through a demo without a lab.
- `--dry-run` is an **operational preview**. It still runs the read-only preflight
  checks against the machine, and it **writes the fully rendered Kubernetes YAML
  into `.rendered/`** so you can read it, diff it against a previous run, or paste
  it into a review. That is what `--echo_only` does not do.

So: reach for `--echo_only` to *understand*, and `--dry-run` to *review the exact
YAML before it is applied*. If you never review manifests, you never need
`--dry-run`.

**What the narration looks like.** The command is printed in green, prefixed `$`;
the explanation follows in grey; whole manifests and SQL blocks are shown with a
`|` gutter:

```
    $ kubectl apply -f minio.yaml
        Hand the object description below to Kubernetes. It creates the objects if
        they are missing, or updates them to match if they already exist — which is
        why re-running this script is safe.
        | apiVersion: v1
        | kind: PersistentVolumeClaim
        ...
```

Every phase and demo also prints a `GOAL:` line saying, in plain English, what it is
for and why it matters. SQL is annotated with `--` comments explaining each
statement, so `--echo_only --demo smoke` reads as a lesson:

```
        | \echo === Eon proof: shards exist only in Eon Mode ===
        | -- A shard is a slice of the data in communal storage. Enterprise Mode has no
        | -- shards at all, so rows here are proof this database is in Eon Mode.
        | SELECT shard_type, lower_hash_bound, upper_hash_bound FROM v_catalog.shards;
```

**Useful combinations**

```bash
./bootstrap-vertica-eon.sh --echo_only                 # read the whole build, run nothing
./bootstrap-vertica-eon.sh --echo_only --demo revive   # study a demo, no lab needed
./bootstrap-vertica-eon.sh --verbose                   # build for real, explaining as it goes
./bootstrap-vertica-eon.sh --verbose --demo dbd        # watch the Designer work, narrated
./bootstrap-vertica-eon.sh --dry-run                   # review the YAML in .rendered/
```

**What is printed can be pasted.** Every narrated command is the real one, in a form
that runs as shown. SQL is narrated as the full `kubectl exec` invocation, not as a
bare `vsql` (which does not exist on the VM), and the first time SQL appears the
narration prints the two variable assignments needed to make the rest copy-pasteable:

```
    $ POD=$(kubectl -n vertica get pods -l app.kubernetes.io/instance=verticadb -o jsonpath='{.items[0].metadata.name}')
    $ PW=$(kubectl -n vertica get secret vertica-superuser -o jsonpath='{.data.password}' | base64 -d)
    $ kubectl -n vertica exec -i "$POD" -c server -- env VSQL_PASSWORD="$PW" vsql -U dbadmin -X <<'SQL'
```

Under `--echo_only` manifests are shown as `kubectl apply -f - <<'YAML'` rather than
pointing at a file, because in that mode no file is written and naming one would be a
lie.

`--echo_only` never prints a real credential: the password is referenced as `$PW`, and
generated secrets appear as `<generated-at-run-time>`, so the output is safe to paste
into a chat or a ticket.

### 4.6 Configuration variables

Full list with comments in [.env.example](.env.example). The ones you are most
likely to touch:

| Variable | Default | Notes |
| --- | --- | --- |
| `VERTICA_IMAGE` | `opentext/vertica-k8s:25.3.0-8-multiarch` | **Must** have a `linux/arm64` variant — that is what `-multiarch` provides. See section 3 before changing |
| `VERTICA_DB_NAME` | `vlab` | Eon database name |
| `VERTICA_CPU_REQUEST` / `VERTICA_MEM_REQUEST` | `2` / `8Gi` | Per-pod requests; keep the total inside the VM's budget |
| `VERTICA_LOCAL_SIZE` | `20Gi` | One PVC holds catalog + data + depot; the CRD has no separate depot-size field |
| `VERTICA_SHARD_COUNT` | `1` | One shard for a one-node cluster |
| `MINIO_BUCKET` | `vertica` | Communal storage bucket |
| `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` | `verticaminio` / *(generated)* | Blank secret key ⇒ random 24-char value on first run |
| `VERTICA_PASSWORD` | *(generated)* | dbadmin password; blank ⇒ random on first run |
| `LICENSE_FILE` | *(empty)* | **Empty means Community Edition — no license needed.** Required for any 26.x image (section 3.2) |
| `MIN_CPU` / `MIN_RAM_GB` / `MIN_DISK_GB` | `4` / `12` / `60` | Preflight thresholds |
| `WAIT_DB_TIMEOUT` | `1800` | Database creation is the slow phase (~80s once the image is cached) |

**Secrets handling.** If `MINIO_SECRET_KEY` or `VERTICA_PASSWORD` are left blank the
script generates them on the first run and stores them **only** in Kubernetes
Secrets. On every subsequent run it reads the existing Secrets back rather than
regenerating — otherwise a re-run would invalidate the credentials the database was
created against. Nothing is ever written to the repo.

### 4.7 Resource budget

Sized for a ~4 vCPU / 16 GB VM:

| Component | CPU request | Memory request |
| --- | --- | --- |
| Vertica pod | 2 | 8 Gi |
| MinIO | 200m | 512 Mi |
| VerticaDB operator | chart default (~100m) | chart default (~256 Mi) |
| K3s control plane | ~0.5 | ~1 Gi |

Traefik and metrics-server are disabled in the K3s install to save headroom.

---

## 5. Demonstrations

The build gives you a working lab; the demos show it *doing* something. Run
`./bootstrap-vertica-eon.sh --list-demos` for the catalogue, or:

```bash
./bootstrap-vertica-eon.sh --demo smoke          # one demo
./bootstrap-vertica-eon.sh --demo bulk,dbd       # several, in order
./bootstrap-vertica-eon.sh --demo revive --yes   # destructive, unattended
./bootstrap-vertica-eon.sh --demo all            # every non-destructive demo
```

Add `--verbose` to narrate a real run, or `--echo_only` to read every command and
SQL statement with an explanation while changing nothing (§4.5).

| Demo | Destructive? | ~Time | What it demonstrates |
| --- | --- | --- | --- |
| [`smoke`](#51-smoke) | no | 10 s | Connectivity, DDL/DML, and that this really is Eon Mode |
| [`bulk`](#52-bulk) | no | 30 s | Loading a 1,000,000-row star schema; columnar compression |
| [`dbd`](#53-dbd) | no | 1–2 min | Database Designer creating projections, and the plan change |
| [`depot`](#54-depot) | no | 1 min | Depot cache: a cold read from S3 vs a warm read from disk |
| [`resilience`](#55-resilience) | no | ~3 min | Operator self-healing after the pod is deleted |
| [`revive`](#56-revive) | **yes** | 3–5 min | **Compute/storage separation** — the headline Eon demo |
| [`restore`](#57-restore) | **yes** | ~5 min | Time travel to a saved restore point |
| [`scale`](#58-scale) | **yes** | ~5 min | Eon elasticity: add and remove a secondary subcluster |
| [`wipe`](#59-wipe) | **yes** | ~2 min | Drop the database *and* delete depot + communal data |
| [`create`](#510-create) | **yes** | ~3 min | Build a brand-new empty database |

"Destructive" means the demo deletes the database, its local volumes, or its
communal data. Each such demo asks for confirmation first; `--yes` skips the prompt.
Only `wipe` destroys data that cannot be recovered.

---

### 5.1 `smoke`

Connects with `vsql` and proves the basics: `SELECT version()`, the node and
subcluster list, and a `CREATE TABLE` / `INSERT` / `SELECT` round trip.

It also prints the three things that distinguish Eon Mode from Enterprise Mode:

- `v_catalog.shards` — this table is only populated in Eon Mode
- `v_catalog.storage_locations` — the communal `s3://` location has **no** `node_name`
- `display_license()` — which edition is actually in force

### 5.2 `bulk`

Loads a small star schema and queries it:

- `dim_store` (100 rows), `dim_product` (1,000 rows), `fact_sales` (1,000,000 rows)
- runs `ANALYZE_STATISTICS` — **the Database Designer silently does nothing without
  statistics**, so `dbd` depends on this
- runs a three-table join aggregating revenue by region and category
- prints on-disk size, which shows Vertica's columnar compression (1 M rows of six
  columns occupy a few MB)

Row count is controlled by `DEMO_FACT_ROWS`. Vertica has no `generate_series`, so
rows come from a 10-row digits CTE cross-joined with itself six times.

`dbd`, `depot` and `revive` run this automatically if `fact_sales` is missing, and
`resilience` runs `smoke` if `lab_smoke` is missing — so every demo is
self-contained and can be run in any order.

### 5.3 `dbd`

The Database Designer, end to end:

1. show the projections on the three tables, and the `EXPLAIN` plan for a query
2. `DESIGNER_CREATE_DESIGN` → `DESIGNER_ADD_DESIGN_TABLES` →
   `DESIGNER_ADD_DESIGN_QUERY` → set K-safety 0, objective `QUERY`, type
   `COMPREHENSIVE` → `DESIGNER_RUN_POPULATE_DESIGN_AND_DEPLOY`
3. **wait for the design to finish**
4. show the projections and the `EXPLAIN` plan again, then run the query

> **Why the wait matters.** `DESIGNER_RUN_POPULATE_DESIGN_AND_DEPLOY` returns in
> about a millisecond — the design and deployment run as a **background task**. Query
> the projections immediately afterwards and you see no change, and would conclude
> DBD did nothing. The script polls `v_monitor.designs` until the design's row
> disappears, which is how you know the background task has finished.

A successful run replaces the super projections with designed ones, and the plan
changes from reading `fact_sales_super` to reading `fact_sales_DBD_…`:

```
 | | +---> STORAGE ACCESS for fact_sales [Cost: 2K, Rows: 333K] (PATH ID: 3)
 | | |      Projection: default_namespace.public.fact_sales_DBD_2_rep_labdbd
```

Vertica's `EXPLAIN` also emits a large GraphViz rendering of the plan; the script
truncates the output at that point so the readable access path is what you see.

### 5.4 `depot`

In Eon Mode the depot is a local cache in front of communal storage. The demo:

1. prints depot capacity and current usage
2. `CLEAR_DATA_DEPOT()` — empties the cache
3. runs an aggregate over the fact table: the **cold** read, served from S3
4. shows `v_monitor.depot_fetches` — files and MB actually pulled back from communal
5. runs the same query again: the **warm** read, served from the depot
6. pins the fact table with `SET_DEPOT_PIN_POLICY_TABLE` so it is evicted last

> **Read the fetch counters, not the clock.** On a lab-sized table the compressed
> data is well under a megabyte and MinIO is in the same cluster, so cold and warm
> wall-clock times are nearly identical. `depot_fetches` is the honest evidence that
> the cold read really made the S3 round trip.

### 5.5 `resilience`

Deletes the Vertica pod outright, then waits while the operator notices, recreates
the pod and restarts the database. Row counts are compared before and after, so the
demo fails loudly if anything is actually lost.

### 5.6 `revive`

**The demonstration worth running first.** In Eon Mode the database *is* the
communal storage; local disk is only a cache. This demo proves it:

1. record the row counts and how much data is in the S3 bucket
2. delete the VerticaDB **and every PersistentVolumeClaim** — depot, catalog and
   local data are genuinely gone, not merely detached
3. re-apply the CR with `initPolicy: Revive`
4. wait for the database, then re-count

Verified output from this lab — a million rows survived having all local storage
destroyed:

```
[…] ✔ revive demo PASSED — 1000000 rows survived with zero local storage
```

> **The catalog must be flushed first.** Eon checkpoints the *catalog* to communal
> storage periodically, not on every commit. Tear down a running database without
> flushing and the revive can come back to an older catalog — tables created a minute
> earlier are simply missing, even though their data is in the bucket. This is easy to
> miss: the same demo passes if the data happens to have been sitting there long
> enough for a checkpoint. Every teardown path in the script therefore calls
> `SELECT sync_catalog();` first, which reports:
>
> ```
> Finished catalog sync to [s3://vertica/vlab/metadata/vlab] on all nodes.
> ```

> After a revive the CR keeps `initPolicy: Revive`. The field is **immutable**
> (`initPolicy cannot change after creation`), so the script never tries to switch it
> back, and the build phase preserves whatever policy it finds. This is expected and
> harmless — `Revive` is a no-op once the database exists.

### 5.7 `restore`

Time travel using an Eon restore point:

1. `CREATE ARCHIVE`, insert a `before-restore-point` marker, then
   `SAVE RESTORE POINT TO ARCHIVE`
2. insert an `after-restore-point` marker — the change we expect to lose
3. destroy the database and revive it with `spec.restorePoint.archive` +
   `index: 1` (the most recent point)
4. show that only the `before` marker survived

> Restore points are **DDL** in this release — `SAVE RESTORE POINT TO ARCHIVE name`.
> There is no `SAVE_RESTORE_POINT()` meta-function. Restore points are listed in
> `v_catalog.all_restore_points`.

### 5.8 `scale`

Eon separates compute from storage, so compute can be added and removed at will:

1. patch a **secondary** subcluster into `spec.subclusters`
2. wait for the pod, then confirm with Vertica itself that the new node is `UP` in
   `v_catalog.nodes` — a Kubernetes-level check alone is not proof
3. remove the subcluster and confirm the cluster is a single node again

Sizing is deliberately smaller than the primary (`DEMO_SCALE_CPU`,
`DEMO_SCALE_MEM`, default 1 CPU / 4 Gi) so it fits alongside it on a 16 GB VM; that
run reaches roughly 85 % of allocatable memory. If the pod stays `Pending`, lower
`DEMO_SCALE_MEM`. The demo is safe to re-run: an existing secondary subcluster is
detected and removed first.

### 5.9 `wipe`

Drops the database, deletes the local volumes, **and** deletes everything under the
database's prefix in the communal bucket. This is the only demo whose effects cannot
be undone — there is nothing left to revive from. Follow it with `create`.

### 5.10 `create`

Builds a brand-new, empty database. If a database is already running it offers to
destroy it and purge communal storage first, because a fresh `Create` cannot reuse a
communal path that already holds a database — and because `initPolicy` is immutable,
the old CR has to be deleted rather than patched.

---

## 6. Verification

### 6.1 What the script already checks

The `smoke` phase runs, via `vsql` inside the pod:

- `SELECT version();`
- node state and subcluster from `v_catalog.nodes`
- the **communal** storage location from `v_catalog.storage_locations` — this is the
  proof that Eon Mode is actually in use
- `CREATE TABLE` → three `INSERT`s → `COMMIT` → `SELECT` → `COUNT(*)`

It runs with `ON_ERROR_STOP=1`, so any failure fails the script.

For deeper verification, the demos in section 5 are themselves assertions: `revive`,
`restore` and `resilience` each compare row counts before and after and exit
non-zero if anything is lost.

### 6.2 Manual verification

> **`vsql` is not on the VM.** It ships inside the Vertica container, so typing
> `vsql -U dbadmin -c "..."` at the VM shell gives `-bash: vsql: command not found`.
> Everything below runs it through `kubectl exec`, which is the only way to reach it.

```bash
ssh vlab
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# cluster and workloads
kubectl get nodes -o wide
kubectl get pods -A

# the database resource and its conditions
kubectl -n vertica get verticadb verticadb
kubectl -n vertica describe verticadb verticadb

# resolve the pod and the password once, then reuse them
POD=$(kubectl -n vertica get pods -l app.kubernetes.io/instance=verticadb -o jsonpath='{.items[0].metadata.name}')
PW=$(kubectl -n vertica get secret vertica-superuser -o jsonpath='{.data.password}' | base64 -d)

# interactive SQL session
kubectl -n vertica exec -it "$POD" -c server -- env VSQL_PASSWORD="$PW" vsql -U dbadmin

# one-off query
kubectl -n vertica exec "$POD" -c server -- env VSQL_PASSWORD="$PW" \
  vsql -U dbadmin -c "SELECT table_name FROM v_catalog.tables ORDER BY 1;"
```

The password is passed via `VSQL_PASSWORD` rather than `-w`, so it never appears in
the container's process list.

If you use `vsql` often, a shell function on the VM saves the typing:

```bash
# add to ~/.bashrc on the VM
vsql() {
  local ns=vertica
  local pod pw
  pod=$(kubectl -n "$ns" get pods -l app.kubernetes.io/instance=verticadb -o jsonpath='{.items[0].metadata.name}')
  pw=$(kubectl -n "$ns" get secret vertica-superuser -o jsonpath='{.data.password}' | base64 -d)
  kubectl -n "$ns" exec -i "$pod" -c server -- env VSQL_PASSWORD="$pw" vsql -U dbadmin "$@"
}
# then:  vsql -c "SELECT table_name FROM v_catalog.tables ORDER BY 1;"
```

Useful SQL once connected — these are the queries that actually prove Eon Mode:

```sql
-- shards exist only in Eon Mode
SELECT shard_type, lower_hash_bound, upper_hash_bound FROM v_catalog.shards;

-- the communal location appears with a node_name of NULL
SELECT node_name, location_path, location_usage FROM v_catalog.storage_locations;

-- which edition is in force
SELECT display_license();
```

On a healthy lab the storage locations look like this — note the `s3://` row:

```
    node_name    |           location_path           | location_usage
-----------------+-----------------------------------+----------------
 v_vlab_node0001 | /data/vlab/v_vlab_node0001_data   | DATA,TEMP
 v_vlab_node0001 | /depot/vlab/v_vlab_node0001_depot | DEPOT
                 | s3://vertica/vlab                 | DATA
```

> Do not `SELECT` the `AWSAuth` configuration parameter to check the endpoint —
> its value contains the access key **and secret key** in clear text. Use
> `AWSEndpoint` alone if you need to confirm the communal endpoint.

### 6.3 Inspect the communal bucket

```bash
# on the VM — MinIO console in a browser via a port-forward
kubectl -n minio port-forward svc/minio 9001:9001
# credentials:
kubectl -n minio get secret minio-creds -o jsonpath='{.data.accesskey}'  | base64 -d; echo
kubectl -n minio get secret minio-creds -o jsonpath='{.data.secretkey}'  | base64 -d; echo
```

Vertica's data will be under `s3://vertica/<VERTICA_DB_NAME>/`.

### 6.4 When something fails

The script traps errors and prints the failing step plus a block of targeted
`kubectl` hints. The usual suspects:

| Symptom | Likely cause |
| --- | --- |
| Pod stuck in `ImagePullBackOff` | The image tag has no `linux/arm64` variant. Verify with `sudo k3s ctr images pull <image>` |
| Pod `Pending`, events mention insufficient cpu/memory | Requests exceed the VM. Lower `VERTICA_CPU_REQUEST` / `VERTICA_MEM_REQUEST` |
| `DBInitialized` never becomes true | Check the operator log and the pod's `server` container log; usually a communal-storage connectivity or credentials problem |
| MinIO job retries forever | The MinIO deployment is not Ready yet, or the bucket name is invalid |
| Nothing can reach anything | `firewalld` — the script trusts the K3s pod/service CIDRs, but confirm with `sudo firewall-cmd --list-all --zone=trusted` |
| Operator pod `CrashLoopBackOff`, log says `exec /manager: exec format error` | The operator image for that chart version is amd64-only (section 3.1). Use 25.3.0 or 26.1.2+ |
| `LicenseValidationFail` / `license secret is empty` | A 26.x operator with no real license (section 3.2). Use the CE default or set `LICENSE_FILE` |
| `sudo: k3s: command not found` | `sudo`'s `secure_path` excludes `/usr/local/bin`. Use the full path: `sudo /usr/local/bin/k3s …` |
| `initPolicy cannot change after creation` | The field is immutable. Delete the VerticaDB first (`--demo create` does this for you) |
| `dbd` shows no new projections | Either statistics are missing (run `--demo bulk`, which calls `ANALYZE_STATISTICS`) or you looked before the background design task finished |
| `scale` pod stuck `Pending` | Not enough memory. Lower `DEMO_SCALE_MEM` |
| A demo exits 141 | SIGPIPE under `pipefail` — report it; the script avoids pipelines whose reader exits early |
| `This script must run ON the lab VM, which is Linux` | You ran it on the Mac. Copy it to the VM (§4.1); the message echoes back your exact command |
| `-bash: vsql: command not found` | `vsql` is **not** installed on the VM — it ships inside the Vertica container. Run it through `kubectl exec` (§6.2) |
| `namespace 'vertica' does not exist` / `no VerticaDB` | The lab has not been built yet. Run `./bootstrap-vertica-eon.sh` first |
| `the Kubernetes API ... is not answering` | K3s is not running: `sudo systemctl status k3s` |
| After a revive, tables are missing | The catalog was not flushed before teardown. The script calls `sync_catalog()` automatically; if you tear the database down by hand, run it first |

Re-running the script after a fix is safe; it resumes where it left off.

---

## 7. Teardown — and the way back

Every teardown below has a build that undoes it, listed alongside.

```bash
ssh vlab

# remove the database, operator and MinIO — keep the K3s cluster
./bootstrap-vertica-eon.sh --uninstall
# ... the opposite: build it all again (idempotent)
./bootstrap-vertica-eon.sh --install

# remove all of the above and K3s itself
./bootstrap-vertica-eon.sh --uninstall --purge-k3s
# ... the opposite: --install rebuilds K3s too
./bootstrap-vertica-eon.sh --install

# lighter: empty the database but keep the cluster standing
./bootstrap-vertica-eon.sh --demo wipe --yes
# ... the opposite: a brand-new empty database
./bootstrap-vertica-eon.sh --demo create --yes
```

| Teardown | Opposite | What survives the teardown |
| --- | --- | --- |
| `--demo wipe` | `--demo create` | K3s, MinIO, the operator — only the data goes |
| `--uninstall` | `--install` | K3s and the Helm binary |
| `--uninstall --purge-k3s` | `--install` | The Helm binary only |

`wipe` and `--purge-k3s` destroy data that no opposite can bring back: `--demo
create` gives you a new *empty* database, not the old one.

To get back to a pristine VM, restore the UTM snapshot taken before the first run
(see the note about `qemu-img snapshot` in
[How to create VM in MAC UTM.txt](How%20to%20create%20VM%20in%20MAC%20UTM.txt)).

---

## 8. Repository contents

| File | Purpose |
| --- | --- |
| [bootstrap-vertica-eon.sh](bootstrap-vertica-eon.sh) | The installer and demo runner |
| [.env.example](.env.example) | Documented configuration template — copy to `.env` |
| [How to create VM in MAC UTM.txt](How%20to%20create%20VM%20in%20MAC%20UTM.txt) | One-time UTM/Rocky 9 VM preparation notes (§2) |
| [.gitignore](.gitignore) | Excludes `.env`, `*.rpm`, licenses, rendered manifests |
| [README.md](README.md) | This file |

**Nothing secret or host-specific is committed.** `.env` is git-ignored, credentials
are generated at run time into Kubernetes Secrets, and the VM is referenced only by
its SSH alias.

### Handling of secrets at run time

- Generated passwords live in Kubernetes Secrets. On every re-run the script reads
  the existing Secret back instead of regenerating, so re-running never invalidates
  the communal storage the database was created against.
- `apply_manifest` writes each rendered manifest to `.rendered/` so you can inspect
  exactly what was applied. **Two of those files embed the generated passwords in
  clear text**, so the directory is created `chmod 600` per file, is git-ignored,
  and is deleted by `--uninstall`. Remove it by hand if you want them gone sooner:
  `rm -rf .rendered`.
- Never `SELECT` the `AWSAuth` configuration parameter — it returns the access key
  and secret key in clear text (see section 6.2).

---

## 9. Disclaimer, trademarks and licensing

### 9.1 No warranty, no liability

**This script and everything in this repository are provided "AS IS", without
warranty of any kind**, express or implied, including but not limited to the
warranties of merchantability, fitness for a particular purpose and
non-infringement. **You use it entirely at your own risk.**

**The author accepts no responsibility and no liability** for any loss or damage
of any kind arising from its use or misuse — including but not limited to data
loss, corrupted or unrecoverable databases, destroyed virtual machines, lost
work, downtime, cost, or any direct, indirect, incidental, special or
consequential damages.

Parts of this repository are **deliberately destructive**. `--uninstall`,
`--purge-k3s` and the `wipe`, `create`, `revive`, `restore` and `scale` demos
delete databases, persistent volumes and communal storage *by design* — that is
what they are for. Read §5 and §7 first, preview with `--dry-run` or
`--echo_only`, and run this **only on a disposable lab VM**. Never point it at a
production system, or at any system holding data you are not prepared to lose.

### 9.2 Not a vendor project, and not supported by the vendor

This is an **independent, unofficial** lab tool. It is:

- **not affiliated with, endorsed by, sponsored by or connected to Rocket
  Software, Inc.**, its subsidiaries or its affiliates;
- **not a Vertica product**, and not part of any Vertica distribution,
  documentation or supported deployment tooling;
- **not supported by Rocket Software, and not supported by Vertica Support.**

**Neither Rocket Software nor Vertica Support carries any responsibility or
liability whatsoever** for this script, for anything it does, or for any
environment it produces. A lab built by this script is not a supported
configuration. Please do not raise support cases with them about this
repository.

### 9.3 Trademarks

**Vertica® is a trademark of Rocket Software, Inc.** Rocket® and Rocket
Software® are trademarks of Rocket Software, Inc.

All other product names, logos and brands mentioned here — including Kubernetes,
K3s, Helm, MinIO, Rocky Linux, Red Hat, UTM, Apple and Apple silicon — are the
property of their respective owners. All company, product and service names are
used for identification purposes only, and their use does not imply endorsement
or affiliation.

### 9.4 A Vertica licence from Rocket Software is required

**Running Vertica requires a valid Vertica licence from Rocket Software.**

- **This repository ships no Vertica software.** No binaries, no container
  images, no licence keys, no RPMs. The script *pulls* a publicly published
  container image at run time, and applies a licence file only if you supply one
  yourself.
- **Nothing here grants you any right to use Vertica.** Your use of Vertica is
  governed solely by the licence agreement between you and Rocket Software.

