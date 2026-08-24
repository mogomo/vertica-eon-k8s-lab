#!/usr/bin/env bash
# ============================================================================
#  bootstrap-vertica-eon.sh
#
#  Turns a clean Rocky Linux 9 (aarch64) VM into a working single-node
#  Vertica Eon Mode cluster on Kubernetes, then optionally drives a set of
#  live demonstrations against it.
#
#    preflight -> k3s -> helm -> MinIO (communal S3) -> VerticaDB operator
#              -> VerticaDB CR -> readiness wait -> vsql smoke test
#
#  Idempotent: safe to re-run. Nothing is regenerated that would invalidate an
#  existing database.
#
#  ---------------------------------------------------------------------------
#  DISCLAIMER  (full text: README.md section 9)
#  ---------------------------------------------------------------------------
#  Provided "AS IS", without warranty of any kind. You run it at your own risk.
#  The author accepts no responsibility and no liability for any loss or damage,
#  including data loss. Parts of this script are deliberately destructive.
#  Run it only on a disposable lab VM, never against anything you care about.
#
#  This is an unofficial lab tool. It is NOT affiliated with, endorsed by or
#  supported by Rocket Software, and NEITHER Rocket Software NOR Vertica Support
#  carries any responsibility for it or for any environment it creates.
#
#  Vertica is a trademark of Rocket Software, Inc. A valid Vertica licence from
#  Rocket Software is required to run Vertica: this script ships no Vertica
#  software and grants no right to use it. Community Edition needs no licence
#  file, but its use is still governed by the vendor's licence terms.
#
#  Usage:  ./bootstrap-vertica-eon.sh [--install|--uninstall] [--dry-run] ...
#
#  Every option and demo that BUILDS or DESTROYS something names its OPPOSITE,
#  so the way back is always documented next to the way forward:
#
#      --install            <->  --uninstall
#      --uninstall          <->  --install
#      --uninstall --purge-k3s  <->  --install  (or --only k3s for K3s alone)
#      --demo wipe          <->  --demo create
#      --demo revive        <->  self-reversing: it ends where it began
#
#
#  ---------------------------------------------------------------------------
#  OPTIONS
#  ---------------------------------------------------------------------------
#    --install              Build the lab: preflight, K3s, Helm, MinIO, the
#                           VerticaDB operator, the VerticaDB and a smoke test.
#                           This is what runs when no action option is given,
#                           and it is idempotent, so it is safe to re-run.
#                           Opposite: --uninstall.
#    --uninstall            Remove the VerticaDB, the operator and MinIO.
#                           K3s is kept unless --purge-k3s is also given.
#                           Opposite: --install.
#    --purge-k3s            Only with --uninstall: also run k3s-uninstall.sh,
#                           removing Kubernetes itself.
#                           Opposite: leave it out and K3s stays; to put
#                           Kubernetes back, --install (or --only k3s).
#    --verbose, -v          Do everything as normal, but also print each command
#                           and SQL statement (green) with a plain-English
#                           explanation beneath it (grey).
#                           Opposite: leave it out for a quiet run.
#    --echo_only            Print every command and SQL statement with its
#                           explanation and DO NOTHING AT ALL. A teaching mode:
#                           it needs no cluster, so it runs anywhere.
#                           Opposite: leave it out to actually do the work.
#    --dry-run              Operational preview: make no changes, but still
#                           check this host and still write the fully rendered
#                           Kubernetes manifests into .rendered/ so you can read
#                           exactly what would be applied. Implies the narration
#                           of --echo_only.
#                           Opposite: re-run the same command without it to
#                           apply for real.
#    --env-file PATH        Config file to source (default: ./.env).
#    --skip-preflight       Turn preflight failures into warnings and continue.
#    --only PHASE           Run a single build phase instead of all of them.
#                           PHASE = preflight | k3s | tools | minio |
#                                   operator | verticadb | smoke
#    --demo NAME[,NAME...]  Run one or more demonstrations against the running
#                           database instead of building. See DEMOS below.
#    --list-demos           Print the demo catalogue with descriptions and exit.
#    --yes                  Assume "yes" for destructive demo confirmations.
#                           Required for unattended runs of wipe/create/revive.
#                           Opposite: leave it out and each destructive demo
#                           asks before it does anything.
#    -h, --help             Show usage and exit.
#
#  ---------------------------------------------------------------------------
#  DEMOS  (./bootstrap-vertica-eon.sh --demo NAME)
#  ---------------------------------------------------------------------------
#    smoke        Connect with vsql; create a table, insert rows, read back.
#    bulk         Load a 1,000,000-row star schema (fact + 2 dimensions) and
#                 run analytic queries over it. Basis for the other demos.
#    dbd          Database Designer end to end: show projections and the query
#                 plan before, run DESIGNER_* to design and deploy, wait for
#                 the asynchronous deploy, then show what changed.
#    depot        Eon depot behaviour: depot size, a cold read served from
#                 communal storage vs. a warm read served from the depot,
#                 and depot pinning.
#    revive       THE Eon demo. Destroy the database and all local storage,
#                 then REVIVE it from communal storage alone and show the data
#                 is still there. Proves compute/storage separation.
#    restore      Time travel. Save a restore point, add more data, then
#                 revive the database back to the restore point.
#    resilience   Delete the Vertica pod and watch the operator rebuild it and
#                 restart the database automatically.
#    scale        Eon elasticity: add a secondary subcluster, show it join the
#                 cluster, then remove it.
#    wipe         Drop the database AND delete depot + communal storage.
#                 Destructive: nothing is recoverable afterwards.
#                 Opposite: --demo create.
#    create       Create a brand-new empty database (use after wipe).
#                 Opposite: --demo wipe.
#    all          Run every non-destructive demo in a sensible order.
#
#  Run "--list-demos" for the same catalogue with timing hints.
# ============================================================================

set -Eeuo pipefail

SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# ============================================================================
#  CONFIG — defaults. Override any of these in .env (see .env.example)
#  or by exporting them in the environment before running.
# ============================================================================

# --- K3s ---------------------------------------------------------------
: "${K3S_CHANNEL:=stable}"
: "${K3S_VERSION:=}"
: "${K3S_INSTALL_ARGS:=--write-kubeconfig-mode 644 --disable traefik --disable metrics-server}"

# --- Preflight minimums ------------------------------------------------
: "${MIN_CPU:=4}"
: "${MIN_RAM_GB:=12}"
: "${MIN_DISK_GB:=60}"
: "${SKIP_PREFLIGHT:=0}"
: "${REQUIRED_ARCH:=aarch64}"

# --- MinIO (communal storage) -----------------------------------------
: "${MINIO_NAMESPACE:=minio}"
: "${MINIO_IMAGE:=quay.io/minio/minio:RELEASE.2025-04-22T22-12-26Z}"
: "${MINIO_MC_IMAGE:=quay.io/minio/mc:RELEASE.2025-04-16T18-13-26Z}"
: "${MINIO_BUCKET:=vertica}"
: "${MINIO_PVC_SIZE:=40Gi}"
: "${MINIO_CPU_REQUEST:=200m}"
: "${MINIO_MEM_REQUEST:=512Mi}"
: "${MINIO_ACCESS_KEY:=verticaminio}"
: "${MINIO_SECRET_KEY:=}"                 # blank => generated on first run
MINIO_SECRET_NAME=minio-creds             # in MINIO_NAMESPACE and VERTICA_NAMESPACE
MINIO_SVC=minio
MINIO_PORT=9000

# --- VerticaDB operator ------------------------------------------------
: "${VDB_OPERATOR_NAMESPACE:=verticadb-operator}"
: "${VDB_HELM_REPO_NAME:=vertica-charts}"
: "${VDB_HELM_REPO_URL:=https://vertica.github.io/charts}"
: "${VDB_HELM_CHART:=vertica-charts/verticadb-operator}"
: "${VDB_HELM_CHART_VERSION:=25.3.0}"
: "${VDB_HELM_EXTRA_SET:=webhook.certSource=internal}"
VDB_HELM_RELEASE=verticadb-operator

# --- Vertica database --------------------------------------------------
: "${VERTICA_NAMESPACE:=vertica}"
: "${VDB_NAME:=verticadb}"
: "${VERTICA_DB_NAME:=vlab}"
: "${VERTICA_IMAGE:=opentext/vertica-k8s:25.3.0-8-multiarch}"
: "${VERTICA_SUBCLUSTER:=main}"
: "${VERTICA_SUBCLUSTER_SIZE:=1}"
: "${VERTICA_SHARD_COUNT:=1}"
: "${VERTICA_PASSWORD:=}"                 # blank => generated on first run
: "${VERTICA_CPU_REQUEST:=2}"
: "${VERTICA_MEM_REQUEST:=8Gi}"
: "${VERTICA_CPU_LIMIT:=}"
: "${VERTICA_MEM_LIMIT:=}"
: "${VERTICA_LOCAL_SIZE:=20Gi}"
VERTICA_SU_SECRET=vertica-superuser
VERTICA_LICENSE_SECRET=vertica-license

# --- Demo tuning -------------------------------------------------------
: "${DEMO_FACT_ROWS:=1000000}"            # rows in the demo fact table
: "${DEMO_SCALE_SUBCLUSTER:=sec}"         # name used by the 'scale' demo
: "${DEMO_SCALE_CPU:=1}"                  # secondary subcluster requests -
: "${DEMO_SCALE_MEM:=4Gi}"                #   deliberately smaller than primary
: "${DEMO_RESTORE_ARCHIVE:=labarchive}"   # archive used by the 'restore' demo

# --- Licensing ---------------------------------------------------------
#  Vertica licensing changed at 26.1:
#
#    * Community Edition (CE) was an evaluation option in RELEASES UP TO 25.x.
#      It is perpetual, limited to 1 TB and 3 nodes, and needs no license file.
#    * FROM v26.1 CE IS NO LONGER OFFERED. New evaluations use a 30-day Trial
#      license, which is a real license file you must supply here.
#    * A database originally created under CE requires a commercial license to
#      move forward; Trial licenses are for new installations only.
#      https://docs.vertica.com/26.1.x/en/getting-started/community-edition-ce/
#
#  Hence: the 25.3.0 default below needs no LICENSE_FILE, and any 26.x image
#  requires one (Trial or commercial). Preflight enforces this.
: "${LICENSE_FILE:=}"

# --- Timeouts (seconds) ------------------------------------------------
: "${WAIT_OPERATOR_TIMEOUT:=300}"
: "${WAIT_MINIO_TIMEOUT:=300}"
: "${WAIT_DB_TIMEOUT:=1800}"
: "${WAIT_DEMO_TIMEOUT:=900}"

# --- Internals ---------------------------------------------------------
KUBECONFIG_PATH=/etc/rancher/k3s/k3s.yaml
RENDER_DIR="${SCRIPT_DIR}/.rendered"

# ============================================================================
#  Logging / error handling
# ============================================================================

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
  C_CYAN=$'\033[36m'; C_DIM=$'\033[2m'
else
  C_RESET=; C_BOLD=; C_RED=; C_GREEN=; C_YELLOW=; C_BLUE=; C_CYAN=; C_DIM=
fi

CURRENT_STEP="startup"
STEP_NO=0

ts()   { date +'%H:%M:%S'; }
log()  { printf '%s[%s]%s %s\n'       "$C_DIM" "$(ts)" "$C_RESET" "$*"; }
info() { printf '%s[%s]%s %s\n'       "$C_DIM" "$(ts)" "$C_RESET" "$*"; }
ok()   { printf '%s[%s]%s %s✔%s %s\n' "$C_DIM" "$(ts)" "$C_RESET" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[%s]%s %s!%s %s\n' "$C_DIM" "$(ts)" "$C_RESET" "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[%s]%s %s✖%s %s\n' "$C_DIM" "$(ts)" "$C_RESET" "$C_RED" "$C_RESET" "$*" >&2; }

step() {
  STEP_NO=$((STEP_NO + 1))
  CURRENT_STEP="$1"
  printf '\n%s==> [%d] %s%s\n' "$C_BOLD$C_BLUE" "$STEP_NO" "$1" "$C_RESET"
}

# Section header used inside demos.
say() { printf '\n%s--- %s%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"; }

# Print the opposite of whatever just finished, so the way back is on screen at
# the moment the user is most likely to want it.
reverse_hint() { printf '%s    reverse: %s%s\n' "$C_DIM" "$*" "$C_RESET"; }

on_error() {
  local rc=$?
  local line=${BASH_LINENO[0]:-?}
  printf '\n'
  err "FAILED during step: ${C_BOLD}${CURRENT_STEP}${C_RESET}"
  err "exit code ${rc} at ${SCRIPT_NAME}:${line}"
  cat >&2 <<HINTS

${C_BOLD}Troubleshooting hints${C_RESET}
  Cluster / nodes
    kubectl get nodes -o wide
    sudo systemctl status k3s ; sudo journalctl -u k3s -n 200 --no-pager

  Everything this script created
    kubectl get pods -A
    kubectl get events -A --sort-by=.lastTimestamp | tail -40

  MinIO (communal storage)
    kubectl -n ${MINIO_NAMESPACE} get pods,pvc,svc
    kubectl -n ${MINIO_NAMESPACE} logs deploy/minio
    kubectl -n ${MINIO_NAMESPACE} logs job/minio-make-bucket

  VerticaDB operator
    kubectl -n ${VDB_OPERATOR_NAMESPACE} get pods
    kubectl -n ${VDB_OPERATOR_NAMESPACE} logs -l app.kubernetes.io/name=verticadb-operator --tail=200

  Vertica database
    kubectl -n ${VERTICA_NAMESPACE} get verticadb ${VDB_NAME} -o yaml
    kubectl -n ${VERTICA_NAMESPACE} describe verticadb ${VDB_NAME}
    kubectl -n ${VERTICA_NAMESPACE} get pods -o wide
    POD=\$(kubectl -n ${VERTICA_NAMESPACE} get pods -l app.kubernetes.io/instance=${VDB_NAME} -o jsonpath='{.items[0].metadata.name}')
    kubectl -n ${VERTICA_NAMESPACE} logs "\$POD" -c server --tail=200
    kubectl -n ${VERTICA_NAMESPACE} logs "\$POD" -c nma --tail=200

  vsql is inside the container, not on the VM ("vsql: command not found"):
    PW=\$(kubectl -n ${VERTICA_NAMESPACE} get secret ${VERTICA_SU_SECRET} -o jsonpath='{.data.password}' | base64 -d)
    kubectl -n ${VERTICA_NAMESPACE} exec -it "\$POD" -c server -- env VSQL_PASSWORD="\$PW" vsql -U dbadmin

  Image pull problems on ARM64 usually mean the tag has no linux/arm64 variant.
  Note that sudo's secure_path excludes /usr/local/bin, so use the full path:
    sudo /usr/local/bin/k3s ctr images pull ${VERTICA_IMAGE}

  Re-run this script — it is idempotent and will resume where it left off.
HINTS
  exit "$rc"
}
trap on_error ERR

# ============================================================================
#  Demo catalogue  (name | one-line description | rough duration)
# ============================================================================

DEMO_NAMES=(smoke bulk dbd depot revive restore resilience scale wipe create)

demo_desc() {
  case "$1" in
    smoke)      echo "Connect with vsql; create a table, insert rows, read back.|~10s" ;;
    bulk)       echo "Load a ${DEMO_FACT_ROWS}-row star schema and run analytic queries.|~30s" ;;
    dbd)        echo "Database Designer: projections + query plan before/after.|~1-2m" ;;
    depot)      echo "Eon depot: cold read from communal vs warm read from depot.|~1m" ;;
    revive)     echo "Destroy the DB and all local storage, then REVIVE from communal.|~3-5m" ;;
    restore)    echo "Save a restore point, add data, then revive back to it.|~5m" ;;
    resilience) echo "Delete the Vertica pod; operator rebuilds and restarts the DB.|~3m" ;;
    scale)      echo "Add a secondary subcluster, show it join, then remove it.|~5m" ;;
    wipe)       echo "Drop the DB and DELETE depot + communal data. Destructive.|~2m" ;;
    create)     echo "Create a brand-new empty database (use after wipe).|~3m" ;;
    *)          echo "unknown|-" ;;
  esac
}

# The opposite of each build phase, for --only.
phase_reverse() {
  case "$1" in
    preflight) echo "nothing to undo — preflight only reads this host" ;;
    k3s)       echo "./${SCRIPT_NAME} --uninstall --purge-k3s" ;;
    tools)     echo "sudo rm -f /usr/local/bin/helm  (--uninstall leaves Helm in place)" ;;
    minio)     echo "./${SCRIPT_NAME} --uninstall" ;;
    operator)  echo "./${SCRIPT_NAME} --uninstall" ;;
    verticadb) echo "./${SCRIPT_NAME} --demo wipe, or --uninstall for the whole lab" ;;
    smoke)     echo "nothing to undo — the smoke test drops and recreates its own table" ;;
    *)         echo "./${SCRIPT_NAME} --uninstall" ;;
  esac
}

# The opposite of each demo: how to undo it, or why nothing needs undoing.
# Every demo that changes state answers "and how do I get back?" here.
demo_reverse() {
  case "$1" in
    smoke)      echo "nothing to undo — it drops and recreates lab_smoke on every run" ;;
    bulk)       echo "--demo wipe (removes everything), or DROP TABLE fact_sales, dim_store, dim_product" ;;
    dbd)        echo "--demo bulk — it drops the tables CASCADE, taking the DBD projections with them" ;;
    depot)      echo "SELECT CLEAR_DEPOT_PIN_POLICY_TABLE('public.fact_sales'); the depot refills itself" ;;
    revive)     echo "self-reversing — it ends with the same database and the same rows" ;;
    restore)    echo "none: data written after the restore point is gone. Reload with --demo bulk" ;;
    resilience) echo "self-reversing — the operator puts the pod back by itself" ;;
    scale)      echo "self-reversing — the demo removes the subcluster it added" ;;
    wipe)       echo "--demo create (a new EMPTY database; wiped data is not recoverable)" ;;
    create)     echo "--demo wipe" ;;
    all)        echo "nothing to undo — 'all' runs only non-destructive demos" ;;
    *)          echo "-" ;;
  esac
}

list_demos() {
  printf '%sAvailable demos%s  —  run with: ./%s --demo NAME[,NAME...]\n\n' \
    "$C_BOLD" "$C_RESET" "$SCRIPT_NAME"
  local n d
  for n in "${DEMO_NAMES[@]}"; do
    d=$(demo_desc "$n")
    printf '  %s%-11s%s %-62s %s%s%s\n' \
      "$C_BOLD" "$n" "$C_RESET" "${d%%|*}" "$C_DIM" "${d##*|}" "$C_RESET"
    printf '  %s%-11s reverse: %s%s\n' "$C_DIM" "" "$(demo_reverse "$n")" "$C_RESET"
  done
  cat <<LISTEOF

  ${C_BOLD}all${C_RESET}         Run every non-destructive demo, in order:
              smoke -> bulk -> dbd -> depot -> resilience -> revive
              ${C_DIM}reverse: $(demo_reverse all)${C_RESET}

  ${C_BOLD}Destructive demos${C_RESET} (wipe, create, revive, restore, scale) prompt for
  confirmation. Pass ${C_BOLD}--yes${C_RESET} to run them unattended.

  ${C_BOLD}The pairs${C_RESET}   wipe <-> create             the lab's data, down and back up
              --install <-> --uninstall   the whole lab, down and back up

  Add --verbose to narrate a real run, or --echo_only to print every command
  and SQL statement with an explanation while doing nothing at all.

  Examples
    ./$SCRIPT_NAME --demo smoke
    ./$SCRIPT_NAME --demo bulk,dbd
    ./$SCRIPT_NAME --demo revive --yes
    ./$SCRIPT_NAME --demo all
LISTEOF
}

# ============================================================================
#  Flags
# ============================================================================

DRY_RUN=0
VERBOSE=0
ECHO_ONLY=0
DO_INSTALL=0          # explicit --install; the default action when no other is given
DO_UNINSTALL=0
PURGE_K3S=0
ENV_FILE="${SCRIPT_DIR}/.env"
ONLY_PHASE=""
DEMO_LIST=""
ASSUME_YES=0

usage() {
  cat <<USAGE
${C_BOLD}${SCRIPT_NAME}${C_RESET} — Vertica Eon Mode on Kubernetes (single node, ARM64 lab)

${C_BOLD}USAGE${C_RESET}
  ./${SCRIPT_NAME} [OPTIONS]

${C_BOLD}OPTIONS${C_RESET}
  Anything that builds or destroys states its ${C_BOLD}opposite${C_RESET}, so the way back is
  always on the page next to the way forward.

  ${C_BOLD}Actions${C_RESET} (pick at most one; --install is the default)

  --install              Build the lab end to end: preflight, K3s, Helm, MinIO,
                         the VerticaDB operator, the VerticaDB and a smoke
                         test. This is what runs when you pass no action at
                         all: bare ./${SCRIPT_NAME} and ./${SCRIPT_NAME}
                         --install do exactly the same thing. Idempotent:
                         safe to re-run, and it resumes where it left off.
                         ${C_DIM}opposite: --uninstall${C_RESET}
  --uninstall            Remove the VerticaDB, operator and MinIO.
                         K3s is kept unless --purge-k3s is also given.
                         ${C_DIM}opposite: --install${C_RESET}
  --demo NAME[,NAME...]  Run demonstrations against the running database
                         instead of building. See DEMOS below, where each
                         demo states its own opposite.
                         ${C_DIM}opposite: depends on the demo - "--list-demos" prints
                                   the reverse of every one of them${C_RESET}
  --only PHASE           Run a single build phase instead of all of them:
                           preflight  checks arch, CPU, RAM, disk, network
                                      ${C_DIM}reverse: nothing - it only reads${C_RESET}
                           k3s        install K3s and open firewalld
                                      ${C_DIM}reverse: --uninstall --purge-k3s${C_RESET}
                           tools      install Helm
                                      ${C_DIM}reverse: sudo rm /usr/local/bin/helm
                                               (--uninstall leaves Helm alone)${C_RESET}
                           minio      deploy MinIO + create the bucket
                                      ${C_DIM}reverse: --uninstall${C_RESET}
                           operator   install the VerticaDB operator (Helm)
                                      ${C_DIM}reverse: --uninstall${C_RESET}
                           verticadb  apply the VerticaDB CR and wait for it
                                      ${C_DIM}reverse: --demo wipe, or --uninstall${C_RESET}
                           smoke      run the vsql smoke test
                                      ${C_DIM}reverse: nothing to undo${C_RESET}
                         ${C_DIM}opposite of the whole set: --uninstall${C_RESET}

  ${C_BOLD}Modifiers${C_RESET}

  --purge-k3s            Only with --uninstall: also run k3s-uninstall.sh,
                         removing Kubernetes itself.
                         ${C_DIM}opposite: leave it out and K3s survives the uninstall.
                                   To put Kubernetes back: --install, or
                                   --only k3s for K3s on its own${C_RESET}
  --verbose, -v          Do everything as normal, but also print each command
                         and SQL statement, with a plain-English explanation.
                         ${C_DIM}opposite: leave it out for a quiet run${C_RESET}
  --echo_only            Print every command and SQL statement with its
                         explanation, and perform NO action whatsoever.
                         Needs no cluster, so it runs anywhere - use it to
                         read through what the script would do, or to learn
                         what each step means. Works with --demo too.
                         ${C_DIM}opposite: leave it out to actually do the work${C_RESET}
  --dry-run              Operational preview: change nothing, but still check
                         this host and still write the fully rendered
                         Kubernetes manifests to .rendered/ so you can read or
                         diff exactly what would be applied. Also narrates,
                         like --echo_only.
                         ${C_DIM}opposite: re-run the same command without it to apply
                                   it for real${C_RESET}
  --skip-preflight       Turn preflight failures into warnings and continue.
                         ${C_DIM}opposite: leave it out and a failed check stops the run${C_RESET}
  --yes                  Assume "yes" for destructive demo confirmations.
                         ${C_DIM}opposite: leave it out and every destructive demo asks
                                   before it touches anything${C_RESET}
  --env-file PATH        Config file to source (default: ./.env).
  --list-demos           Print the demo catalogue, with the reverse of each
                         demo, and exit.
  -h, --help             This help.

${C_BOLD}DEMOS${C_RESET}
  smoke        Connect with vsql; create a table, insert rows, read back.
               ${C_DIM}opposite: none needed - it drops and recreates lab_smoke
                         every time it runs${C_RESET}
  bulk         Load a ${DEMO_FACT_ROWS}-row star schema (fact + 2 dimensions)
               and run analytic queries. Basis for the other demos.
               ${C_DIM}opposite: --demo wipe, or DROP TABLE fact_sales, dim_store,
                         dim_product${C_RESET}
  dbd          Database Designer end to end: show projections and the query
               plan before, run the DESIGNER_* meta-functions to design and
               deploy, wait for the asynchronous deploy, show what changed.
               ${C_DIM}opposite: --demo bulk - it drops the tables CASCADE, which
                         takes the projections DBD deployed with them${C_RESET}
  depot        Eon depot behaviour: depot size, a cold read served from
               communal storage vs. a warm read from the depot, and pinning.
               ${C_DIM}opposite: SELECT CLEAR_DEPOT_PIN_POLICY_TABLE('public.fact_sales');
                         the cleared depot refills itself on the next reads${C_RESET}
  revive       The Eon headline. Destroy the database and every local volume,
               then REVIVE from communal storage alone; the data is still
               there. Proves compute and storage are genuinely separate.
               ${C_DIM}opposite: none needed - destroy and revive are already the
                         two halves, and it ends where it began${C_RESET}
  restore      Time travel: save a restore point, add more data, then revive
               the database back to the restore point.
               ${C_DIM}opposite: none - rolling forward again is not possible, the
                         data written after the restore point is gone.
                         Reload with --demo bulk${C_RESET}
  resilience   Delete the Vertica pod; the operator rebuilds it and restarts
               the database with no data loss.
               ${C_DIM}opposite: none needed - the operator's rebuild IS the
                         opposite, and it happens by itself${C_RESET}
  scale        Eon elasticity: add a secondary subcluster, show it join the
               cluster, then remove it again.
               ${C_DIM}opposite: none needed - scale-out and scale-in are both in
                         the demo, so the lab is left as it was found${C_RESET}
  wipe         Drop the database AND delete depot + communal storage.
               Destructive - nothing is recoverable afterwards.
               ${C_DIM}opposite: --demo create${C_RESET}
  create       Create a brand-new empty database (typically after wipe).
               ${C_DIM}opposite: --demo wipe${C_RESET}
  all          Every non-destructive demo, in order.
               ${C_DIM}opposite: nothing to undo - 'all' skips the destructive demos${C_RESET}

${C_BOLD}EVERY BUILD STEP AND ITS OPPOSITE${C_RESET}
  build / do this                      undo it with
  ------------------------------------ ------------------------------------
  --install                            --uninstall
  --install (incl. K3s)                --uninstall --purge-k3s
  --only k3s                           --uninstall --purge-k3s
  --only minio                         --uninstall
  --only operator                      --uninstall
  --only verticadb                     --demo wipe, or --uninstall
  --demo bulk    (load a star schema)  --demo wipe
  --demo create  (empty database)      --demo wipe
  --demo wipe    (destroy everything)  --demo create
  --demo revive / resilience / scale   self-reversing: they end where they began
  --demo restore (roll back in time)   irreversible: post-restore-point data is gone

  Two things --uninstall does NOT undo, by design:
    * the Helm binary installed by the 'tools' phase (sudo rm /usr/local/bin/helm)
    * K3s itself, unless you add --purge-k3s

${C_BOLD}CONFIG${C_RESET}
  Copy .env.example to .env and edit. Key variables:
    VERTICA_IMAGE            container image (needs a linux/arm64 variant)
    VDB_HELM_CHART_VERSION   operator chart version (must match the image era)
    VERTICA_DB_NAME          Eon database name
    VERTICA_CPU_REQUEST /    per-pod resource requests
      VERTICA_MEM_REQUEST
    MINIO_BUCKET             communal storage bucket
    MINIO_ACCESS_KEY /       S3 credentials (secret key generated if blank)
      MINIO_SECRET_KEY
    VERTICA_PASSWORD         dbadmin password (generated if blank)
    LICENSE_FILE             required for 26.x images; blank = CE on 25.x
    DEMO_FACT_ROWS           rows loaded by the 'bulk' demo

${C_BOLD}LICENSING${C_RESET}
  Community Edition was an evaluation option up to 25.x (perpetual, 1 TB,
  3 nodes, no license file). From v26.1 CE is no longer offered: new
  evaluations use a 30-day Trial license, which you must supply via
  LICENSE_FILE. A database first created under CE needs a commercial license
  to move forward. The defaults here therefore use 25.3.0 + CE.

${C_BOLD}WHICH OF --verbose / --echo_only / --dry-run DO I WANT?${C_RESET}
                       narrates?   changes anything?   runs where?
  (no flag)              no               yes            on the VM
  --verbose             yes               yes            on the VM
  --dry-run             yes               no             on the VM
  --echo_only           yes               no             anywhere

  --verbose    you are running it for real and want to see and understand
               every command as it happens.
  --echo_only  you want to read and learn, and change nothing. Runs on any
               machine, including your laptop, because it never contacts a
               cluster. Combine with --demo to study a demo without a lab.
  --dry-run    you want to review the exact Kubernetes YAML that would be
               applied before applying it. It still runs the read-only
               preflight checks against this host, and leaves the rendered
               manifests in .rendered/ for you to read or diff. Leaving those
               files behind is the one thing --echo_only does not do.

${C_BOLD}EXAMPLES${C_RESET}
  ./${SCRIPT_NAME} --dry-run
  ./${SCRIPT_NAME}                              # build the lab (same as --install)
  ./${SCRIPT_NAME} --install                    # the same build, said out loud
  ./${SCRIPT_NAME} --only smoke
  ./${SCRIPT_NAME} --list-demos
  ./${SCRIPT_NAME} --demo bulk,dbd
  ./${SCRIPT_NAME} --demo revive --yes
  ./${SCRIPT_NAME} --verbose --demo bulk        # run it, explaining as it goes
  ./${SCRIPT_NAME} --echo_only                  # read the whole build, run nothing
  ./${SCRIPT_NAME} --echo_only --demo revive    # study the revive demo safely
  ./${SCRIPT_NAME} --uninstall                  # the opposite of --install
  ./${SCRIPT_NAME} --uninstall --purge-k3s      # ... and take K3s with it
  ./${SCRIPT_NAME} --demo wipe --yes            # destroy the data
  ./${SCRIPT_NAME} --demo create --yes          # ... and the opposite: build it back

${C_BOLD}DISCLAIMER${C_RESET}
  Provided "AS IS", with no warranty and no liability - you run it at your own
  risk, on a disposable lab VM. Unofficial: not affiliated with, endorsed by or
  supported by Rocket Software, and neither Rocket Software nor Vertica Support
  carries any responsibility for it. Vertica is a trademark of Rocket Software,
  Inc.; a valid Vertica licence from Rocket Software is required to run Vertica.
  Full text in README.md section 9.
USAGE
}

# Kept so the "wrong host" guard can echo back the exact invocation.
SCRIPT_ARGS=("$@")

# --- the three narration / execution modes -------------------------------
#
#   NARRATE   print every command and SQL statement, with a plain-English
#             explanation underneath it
#   NO_EXEC   perform no action that changes anything
#
#                       NARRATE   NO_EXEC   probes host?   needs a live lab?
#   (default)              no        no         yes              yes
#   --verbose             yes        no         yes              yes
#   --dry-run             yes       yes         yes              no
#   --echo_only           yes       yes          no              no
#
# --dry-run is an operational preview: it still inspects this host and still
# writes the fully rendered manifests to .rendered/ so you can read exactly
# what would be applied. --echo_only is a teaching mode: it touches nothing at
# all, so it runs anywhere, including a laptop with no cluster.

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)        DRY_RUN=1 ;;
    --verbose|-v)     VERBOSE=1 ;;
    --echo_only|--echo-only) ECHO_ONLY=1 ;;
    --install)        DO_INSTALL=1 ;;
    --uninstall)      DO_UNINSTALL=1 ;;
    --purge-k3s)      PURGE_K3S=1 ;;
    --skip-preflight) SKIP_PREFLIGHT=1 ;;
    --env-file)       ENV_FILE="${2:?--env-file needs a path}"; shift ;;
    --only)           ONLY_PHASE="${2:?--only needs a phase}"; shift ;;
    --demo)           DEMO_LIST="${2:?--demo needs a name}"; shift ;;
    --list-demos)     LIST_DEMOS=1 ;;
    --yes|-y)         ASSUME_YES=1 ;;
    -h|--help)        usage; exit 0 ;;
    *) err "unknown option: $1"; echo; usage; exit 2 ;;
  esac
  shift
done

# --- opposites cannot be asked for at the same time -----------------------
if (( DO_INSTALL && DO_UNINSTALL )); then
  err "--install and --uninstall are opposites — pass one or the other, not both"
  exit 2
fi
if (( DO_INSTALL )) && [[ -n "$DEMO_LIST" ]]; then
  err "--install builds the lab, --demo runs against a lab that is already built"
  err "build first (./${SCRIPT_NAME} --install), then run ./${SCRIPT_NAME} --demo ${DEMO_LIST}"
  exit 2
fi
if (( PURGE_K3S && ! DO_UNINSTALL )); then
  warn "--purge-k3s only means anything with --uninstall — ignoring it"
  warn "to remove Kubernetes as well: ./${SCRIPT_NAME} --uninstall --purge-k3s"
fi

# ============================================================================
#  Load .env (after flag parsing so --env-file works)
# ============================================================================

load_env_file() {
  local f="$1"
  [[ -f "$f" ]] || { info "no config file at ${f} — using built-in defaults"; return 0; }
  info "loading config from ${f}"
  # shellcheck disable=SC1090
  set -a; source "$f"; set +a
}
load_env_file "$ENV_FILE"

NARRATE=0
(( VERBOSE || ECHO_ONLY || DRY_RUN )) && NARRATE=1
NO_EXEC=0
(( ECHO_ONLY || DRY_RUN )) && NO_EXEC=1

# Values derived from config, recomputed after the env file is sourced.
: "${MINIO_NAMESPACE:=minio}"
: "${VERTICA_NAMESPACE:=vertica}"
MINIO_ENDPOINT="http://${MINIO_SVC}.${MINIO_NAMESPACE}.svc.cluster.local:${MINIO_PORT}"
COMMUNAL_PATH="s3://${MINIO_BUCKET}/${VERTICA_DB_NAME}"

if [[ -n "${LIST_DEMOS:-}" ]]; then list_demos; exit 0; fi

# ============================================================================
#  Helpers
# ============================================================================

# ---------------------------------------------------------------------------
#  Narration: show the command, then explain it in plain English.
# ---------------------------------------------------------------------------

# Print a command exactly as it will be issued.
show_cmd() {
  (( NARRATE )) || return 0
  printf '%s    $ %s%s\n' "$C_GREEN" "$*" "$C_RESET"
}

# Print an explanation under the command. Wraps politely at ~76 columns.
explain() {
  (( NARRATE )) || return 0
  printf '%s' "$C_DIM"
  printf '%s\n' "$*" | fold -s -w 76 | sed 's/^/        /'
  printf '%s' "$C_RESET"
}

# Free-standing teaching note, not attached to a command.
note() {
  (( NARRATE )) || return 0
  printf '%s    # %s%s\n' "$C_DIM" "$*" "$C_RESET"
}

# Best-effort plain-English description of a command this script issues.
# Used when a call site does not supply its own explanation.
describe_cmd() {
  local c="$*"
  case "$c" in
    # narrow patterns first: a chmod on an installer must not be described as
    # "runs the installer"
    *chmod*)                  echo "Make the downloaded file executable so it can be run." ;;
    *"ln -sf"*)               echo "Create a symbolic link, so the 'kubectl' command resolves to the k3s binary that provides it." ;;
    *"rm -rf"*)               echo "Delete these files." ;;
    *"kubectl apply"*)        echo "Hand this object description to Kubernetes. Kubernetes creates the objects if they are missing, or updates them to match if they already exist. Running it again with the same file changes nothing." ;;
    *"kubectl create namespace"*) echo "Create a namespace: a named compartment that keeps this lab's objects separate from everything else in the cluster." ;;
    *"kubectl create secret"*)    echo "Store a credential inside Kubernetes so pods can read it without it being written into any file on disk." ;;
    *"kubectl delete"*)       echo "Remove these objects from the cluster. Kubernetes also cleans up whatever it created for them." ;;
    *"kubectl patch"*)        echo "Change one part of an existing object in place, leaving the rest of it alone." ;;
    *"kubectl wait"*)         echo "Pause here until Kubernetes reports that the named condition has become true, or until the timeout expires." ;;
    *"kubectl exec"*)         echo "Run a command inside a container that is already running, rather than on this host." ;;
    *"kubectl get"*|*"kubectl logs"*|*"kubectl describe"*) echo "Read-only: ask the cluster about its current state. Changes nothing." ;;
    *"helm repo add"*)        echo "Register the Vertica chart repository so Helm knows where to download the operator from." ;;
    *"helm repo update"*)     echo "Refresh the local index of what versions that repository currently offers." ;;
    *"helm upgrade --install"*) echo "Install the operator from its chart; if it is already installed, upgrade it in place instead. This is what makes re-running safe." ;;
    *"helm uninstall"*)       echo "Remove everything the chart installed." ;;
    *"dnf install"*)          echo "Install missing Linux packages from the distribution's software repositories." ;;
    *"firewall-cmd"*"--add-source"*) echo "Tell the host firewall to trust the cluster's internal network ranges, so pods can talk to each other." ;;
    *"firewall-cmd"*"--add-port"*)   echo "Open the Kubernetes API port on the host firewall." ;;
    *"firewall-cmd --reload"*)       echo "Apply the firewall changes made above." ;;
    *"systemctl enable --now"*) echo "Start the service now, and also arrange for it to start automatically on every boot." ;;
    *"k3s-install.sh"*|*"get.k3s.io"*) echo "K3s is a small, single-binary Kubernetes distribution. This downloads and runs its official installer." ;;
    *"get-helm-3"*)           echo "Download and run Helm's official installer. Helm is the package manager used to install the Vertica operator." ;;
    *"k3s-uninstall.sh"*)     echo "Run the uninstaller K3s wrote at install time, removing Kubernetes and everything running on it." ;;
    *curl*)                   echo "Download a file over the network." ;;
    *)                        echo "" ;;
  esac
}

# Narrate a command, then run it unless we are only echoing.
# Optional leading explanation:  run --why "..." cmd args...
run() {
  local why=""
  if [[ "${1:-}" == "--why" ]]; then why="$2"; shift 2; fi
  show_cmd "$*"
  [[ -z "$why" ]] && why=$(describe_cmd "$*")
  [[ -n "$why" ]] && explain "$why"
  (( NO_EXEC )) && return 0
  "$@"
}

run_sh() {
  local why=""
  if [[ "${1:-}" == "--why" ]]; then why="$2"; shift 2; fi
  show_cmd "$*"
  [[ -z "$why" ]] && why=$(describe_cmd "$*")
  [[ -n "$why" ]] && explain "$why"
  (( NO_EXEC )) && return 0
  bash -c "$*"
}

have() { command -v "$1" >/dev/null 2>&1; }

kc() {
  show_cmd "kubectl $*"
  local why; why=$(describe_cmd "kubectl $*")
  [[ -n "$why" ]] && explain "$why"
  (( NO_EXEC )) && return 0
  KUBECONFIG="$KUBECONFIG_PATH" kubectl "$@"
}

# Read-only kubectl: quiet on failure, returns non-zero if it cannot answer.
# Under --echo_only there is no cluster to ask (the script may not even be on
# the VM), so it reports "not found" and lets callers narrate the create path.
kcq() {
  (( ECHO_ONLY )) && return 1
  have kubectl || return 1
  KUBECONFIG="$KUBECONFIG_PATH" kubectl "$@" 2>/dev/null
}

apply_manifest() {
  local name="$1"
  local manifest; manifest=$(cat)

  if (( NARRATE )); then
    # Show a form that actually works. Under --echo_only nothing is written to
    # disk, so pointing at a file that does not exist would be a lie; the
    # heredoc form below can be pasted as printed.
    if (( ECHO_ONLY )) && (( ! DRY_RUN )); then
      show_cmd "kubectl apply -f - <<'YAML'"
    else
      show_cmd "kubectl apply -f ${RENDER_DIR}/${name}.yaml"
    fi
    explain "Hand the object description below to Kubernetes. It creates the objects if they are missing, or updates them to match if they already exist — which is why re-running this script is safe."
    printf '%s' "$C_GREEN"
    printf '%s\n' "$manifest" | sed 's/^/        | /'
    (( ECHO_ONLY )) && (( ! DRY_RUN )) && printf '        | YAML\n'
    printf '%s' "$C_RESET"
  fi

  # --echo_only must not touch the filesystem; --dry-run deliberately does,
  # because leaving the rendered manifest behind to read is its whole point.
  if (( ECHO_ONLY )) && (( ! DRY_RUN )); then return 0; fi

  mkdir -p "$RENDER_DIR"
  local out="${RENDER_DIR}/${name}.yaml"
  printf '%s\n' "$manifest" > "$out"
  chmod 600 "$out"          # may embed secrets
  if (( NO_EXEC )); then
    note "rendered to ${out} — inspect it, nothing was applied"
    return 0
  fi
  KUBECONFIG="$KUBECONFIG_PATH" kubectl apply -f "$out"
}

gen_password() {
  # 24 chars, alphanumeric only — safe for vsql, URLs and S3 signatures.
  #
  # Deliberately NOT "tr -dc ... </dev/urandom | head -c 24": head exits after
  # 24 bytes, tr keeps writing from an infinite stream and dies on SIGPIPE, and
  # `set -o pipefail` then turns the whole pipeline into exit 141.
  local out=""
  while (( ${#out} < 24 )); do
    out+=$(LC_ALL=C tr -dc 'A-Za-z0-9' < <(head -c 1024 /dev/urandom) || true)
  done
  printf '%s' "${out:0:24}"
}

secret_value() {
  local ns="$1" name="$2" key="$3" v
  # "|| true" INSIDE the substitution: set -E makes the ERR trap fire inside
  # command substitutions too, and a missing secret is an ordinary outcome
  # here, not an error worth printing a troubleshooting block for.
  v=$(kcq -n "$ns" get secret "$name" -o "jsonpath={.data.${key}}" || true)
  [[ -n "$v" ]] || return 0
  printf '%s' "$v" | base64 -d
}

ensure_namespace() {
  local ns="$1"
  if kcq get namespace "$ns" >/dev/null; then
    info "namespace ${ns} already exists"
  else
    kc create namespace "$ns"
  fi
}

wait_for() {
  local desc="$1" timeout="$2"; shift 2
  if (( NO_EXEC )); then
    note "WAIT until: ${desc}"
    explain "Poll the cluster every 5 seconds until this becomes true, giving up after ${timeout} seconds. Waiting changes nothing; it just stops the script racing ahead of Kubernetes."
    return 0
  fi
  info "waiting for ${desc} (timeout ${timeout}s)"
  local deadline=$(( SECONDS + timeout ))
  until "$@" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      err "timed out after ${timeout}s waiting for ${desc}"
      return 1
    fi
    sleep 5
  done
  ok "${desc}"
}

confirm() {
  local prompt="$1"
  # Nothing is performed in echo mode, so there is nothing to confirm. Prompting
  # here would hang an unattended run and, on a non-tty, fail the demo outright.
  if (( NO_EXEC )); then
    note "This step would ask for confirmation: ${prompt}"
    explain "Because this run changes nothing, the question is skipped. In a real run you would answer y, or pass --yes to skip the prompt."
    return 0
  fi
  (( ASSUME_YES )) && { info "${prompt} — proceeding (--yes)"; return 0; }
  if [[ ! -t 0 ]]; then
    err "${prompt}"
    err "This is destructive and stdin is not a terminal. Re-run with --yes to confirm."
    return 1
  fi
  local reply
  printf '%s%s [y/N] %s' "$C_YELLOW" "$prompt" "$C_RESET"
  read -r reply
  [[ "$reply" =~ ^[Yy]$ ]] || { info "aborted by user"; return 1; }
}

# ============================================================================
#  Environment guards
#
#  These exist because the most common way to be confused by this script is to
#  run it in the wrong place. Without them, running on a workstation reports
#  "the database is not up", which points at the database instead of at the
#  real problem: there is no Kubernetes here at all.
#
#  They call exit directly rather than returning non-zero, so the ERR trap's
#  kubectl troubleshooting block (useless when kubectl does not exist) is not
#  printed.
# ============================================================================

require_linux_host() {
  # --echo_only performs no action, so it is safe (and useful) anywhere.
  (( ECHO_ONLY )) && return 0
  [[ "$(uname -s)" == "Linux" ]] && return 0
  local _invocation=""
  (( ${#SCRIPT_ARGS[@]} )) && _invocation=" ${SCRIPT_ARGS[*]}"
  err "This script must run ON the lab VM, which is Linux."
  err "Detected instead: $(uname -s) $(uname -m) — this looks like your workstation."
  cat >&2 <<HOSTEOF

  Everything (K3s, MinIO, the operator, Vertica) lives inside the VM. Nothing is
  installed on the workstation, so there is no cluster here to talk to.

  Copy the script over and run it there:

      scp ${SCRIPT_NAME} .env.example <vm>:~/
      ssh <vm> './${SCRIPT_NAME}${_invocation}'

  where <vm> is your SSH alias for the lab VM (see README section 2.3).
HOSTEOF
  exit 2
}

require_cluster() {
  (( ECHO_ONLY )) && return 0
  if ! have kubectl; then
    err "kubectl is not installed on this host."
    err "Build the lab first:  ./${SCRIPT_NAME}"
    exit 2
  fi
  if [[ ! -r "$KUBECONFIG_PATH" ]]; then
    err "no readable kubeconfig at ${KUBECONFIG_PATH}"
    err "K3s does not appear to be installed. Build the lab first:  ./${SCRIPT_NAME}"
    exit 2
  fi
  if ! kcq get --raw=/readyz >/dev/null; then
    err "the Kubernetes API at ${KUBECONFIG_PATH} is not answering."
    err "Check it with:  sudo systemctl status k3s"
    exit 2
  fi
}

# Demos act on a live database. Say precisely which part is missing.
require_database() {
  (( ECHO_ONLY )) && return 0
  require_cluster
  if ! kcq get namespace "$VERTICA_NAMESPACE" >/dev/null; then
    err "namespace '${VERTICA_NAMESPACE}' does not exist — the lab has not been built."
    err "Build it first:  ./${SCRIPT_NAME}"
    exit 2
  fi
  if ! kcq -n "$VERTICA_NAMESPACE" get verticadb "$VDB_NAME" >/dev/null; then
    err "no VerticaDB '${VDB_NAME}' in namespace '${VERTICA_NAMESPACE}'."
    err "Build the database first:  ./${SCRIPT_NAME}"
    err "or create an empty one:    ./${SCRIPT_NAME} --demo create"
    exit 2
  fi
  local pod; pod=$(vertica_pod)
  if [[ -z "$pod" ]]; then
    err "the VerticaDB '${VDB_NAME}' exists but has no running pod."
    err "Inspect with:  kubectl -n ${VERTICA_NAMESPACE} get pods,verticadb"
    exit 2
  fi
  if ! db_is_up; then
    err "pod ${pod} is running but the database is not accepting connections yet."
    err "Wait for it, or inspect:  kubectl -n ${VERTICA_NAMESPACE} logs ${pod} -c server --tail=100"
    exit 2
  fi
}

# ============================================================================
#  vsql helpers
# ============================================================================

vertica_pod() {
  kcq -n "$VERTICA_NAMESPACE" get pods \
      -l "app.kubernetes.io/instance=${VDB_NAME}" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}' || true
}

vertica_password() { secret_value "$VERTICA_NAMESPACE" "$VERTICA_SU_SECRET" password || true; }

# --- narrating vsql -------------------------------------------------------
# vsql is NOT on the VM: it ships inside the Vertica container. Typing "vsql"
# at the VM shell gives "command not found". Everything narrated below is
# therefore the real kubectl form, so it can be copied and pasted as printed.
VSQL_PREAMBLE_SHOWN=0
vsql_preamble() {
  (( NARRATE )) || return 0
  (( VSQL_PREAMBLE_SHOWN )) && return 0
  VSQL_PREAMBLE_SHOWN=1
  note "vsql is Vertica's command-line SQL client. It is NOT installed on this VM — it lives inside the database container. Running 'vsql ...' at the VM shell gives 'command not found'; it has to be run through kubectl."
  explain "Set these two variables once, then every command below can be pasted as-is:"
  show_cmd "POD=\$(kubectl -n ${VERTICA_NAMESPACE} get pods -l app.kubernetes.io/instance=${VDB_NAME} -o jsonpath='{.items[0].metadata.name}')"
  show_cmd "PW=\$(kubectl -n ${VERTICA_NAMESPACE} get secret ${VERTICA_SU_SECRET} -o jsonpath='{.data.password}' | base64 -d)"
  explain "For an interactive session: kubectl -n ${VERTICA_NAMESPACE} exec -it \"\$POD\" -c server -- env VSQL_PASSWORD=\"\$PW\" vsql -U dbadmin"
}

# The exact command used to reach vsql. The password is passed through the
# environment as $PW, so no real credential is ever printed.
vsql_display_cmd() {
  local mode="$1"; shift          # -i (stdin) or -it (interactive)
  local pod; pod=$(vertica_pod)
  [[ -n "$pod" ]] || pod='"$POD"'
  printf 'kubectl -n %s exec %s %s -c server -- env VSQL_PASSWORD="$PW" vsql -U dbadmin -X %s' \
    "$VERTICA_NAMESPACE" "$mode" "$pod" "$*"
}

# Run SQL supplied on stdin. The password goes through VSQL_PASSWORD so it
# never appears in the container's argv.
vsql_in() {
  # Read the whole heredoc first so it can be echoed before being sent.
  local sql; sql=$(cat)
  if (( NARRATE )); then
    vsql_preamble
    show_cmd "$(vsql_display_cmd -i "$*") <<'SQL'"
    explain "Run the statements below inside the database container. Lines beginning with -- are comments explaining each step."
    printf '%s' "$C_GREEN"
    printf '%s\n' "$sql" | sed 's/^/        | /'
    printf '        | SQL\n'
    printf '%s' "$C_RESET"
  fi
  (( NO_EXEC )) && return 0
  local pod pw
  pod=$(vertica_pod); pw=$(vertica_password)
  [[ -n "$pod" ]] || { err "no running Vertica pod in namespace ${VERTICA_NAMESPACE}"; return 1; }
  KUBECONFIG="$KUBECONFIG_PATH" kubectl -n "$VERTICA_NAMESPACE" exec -i "$pod" -c server \
    -- env VSQL_PASSWORD="$pw" vsql -U dbadmin -X "$@" <<< "$sql"
}

# Run a single statement. NOTE the </dev/null: "kubectl exec -i" consumes the
# caller's stdin, which would otherwise swallow the rest of an enclosing script.
vsql_c() {
  # --quiet marks an internal probe that should not be narrated.
  local quiet=0
  if [[ "${1:-}" == "--quiet" ]]; then quiet=1; shift; fi
  local sql="$1"; shift || true
  if (( NARRATE )) && (( ! quiet )); then
    vsql_preamble
    show_cmd "$(vsql_display_cmd '' "$*") -c \"${sql}\""
  fi
  (( NO_EXEC )) && return 0
  local pod pw
  pod=$(vertica_pod); pw=$(vertica_password)
  [[ -n "$pod" ]] || { err "no running Vertica pod in namespace ${VERTICA_NAMESPACE}"; return 1; }
  KUBECONFIG="$KUBECONFIG_PATH" kubectl -n "$VERTICA_NAMESPACE" exec "$pod" -c server \
    -- env VSQL_PASSWORD="$pw" vsql -U dbadmin -X "$@" -c "$sql" </dev/null
}

# Single scalar value, untrimmed formatting stripped.
vsql_scalar() { vsql_c --quiet "$1" -A -t; }

# EXPLAIN, showing only the human-readable access path. Vertica always appends
# a large GraphViz rendering of the plan; it is unreadable in a terminal, so
# everything from that marker onwards is dropped.
vsql_explain() {
  # Drain the whole result FIRST. Piping kubectl straight into a reader that
  # exits early (awk .../{exit}) gives kubectl a SIGPIPE, and `set -o pipefail`
  # turns that into exit 141 — the same trap as the tr|head idiom above.
  if (( NO_EXEC )); then
    vsql_preamble
    show_cmd "$(vsql_display_cmd '') -c \"EXPLAIN $1\""
    explain "Ask Vertica how it would run this query — which projection it would read and what that would cost — without actually running it."
    return 0
  fi
  local out
  out=$(vsql_c --quiet "EXPLAIN $1") || return $?
  printf '%s\n' "$out" | sed -n '1,/GraphViz Format/p' | sed '/GraphViz Format/d'
}

db_is_up() { (( NO_EXEC )) && return 0; vsql_scalar "SELECT 1;" >/dev/null 2>&1; }

# ============================================================================
#  VerticaDB rendering
# ============================================================================

# render_verticadb <initPolicy> [restore_archive] [restore_index]
render_verticadb() {
  local init_policy="$1" archive="${2:-}" index="${3:-}"

  local license_block=""
  if [[ -n "$LICENSE_FILE" ]]; then
    license_block=$'\n  licenseSecret: '"${VERTICA_LICENSE_SECRET}"
  fi

  local limits_block=""
  if [[ -n "$VERTICA_CPU_LIMIT" || -n "$VERTICA_MEM_LIMIT" ]]; then
    limits_block=$'\n          limits:'
    [[ -n "$VERTICA_CPU_LIMIT" ]] && limits_block+=$'\n            cpu: "'"${VERTICA_CPU_LIMIT}"'"'
    [[ -n "$VERTICA_MEM_LIMIT" ]] && limits_block+=$'\n            memory: "'"${VERTICA_MEM_LIMIT}"'"'
  fi

  local restore_block=""
  if [[ -n "$archive" ]]; then
    restore_block=$'\n  restorePoint:\n    archive: '"${archive}"
    [[ -n "$index" ]] && restore_block+=$'\n    index: '"${index}"
  fi

  cat <<YAML
apiVersion: vertica.com/v1
kind: VerticaDB
metadata:
  name: ${VDB_NAME}
  namespace: ${VERTICA_NAMESPACE}
  annotations:
    # Single-node lab: no K-Safety, and do not block on a stale cluster lease
    # (important for the revive/restore demos).
    vertica.com/k-safety: "0"
    vertica.com/ignore-cluster-lease: "true"
spec:
  image: ${VERTICA_IMAGE}
  imagePullPolicy: IfNotPresent
  initPolicy: ${init_policy}
  dbName: ${VERTICA_DB_NAME}
  shardCount: ${VERTICA_SHARD_COUNT}
  passwordSecret: ${VERTICA_SU_SECRET}${license_block}${restore_block}
  communal:
    path: ${COMMUNAL_PATH}
    endpoint: ${MINIO_ENDPOINT}
    credentialSecret: ${MINIO_SECRET_NAME}
    region: us-east-1
  local:
    requestSize: ${VERTICA_LOCAL_SIZE}
    depotVolume: EmptyDir
    depotPath: /depot
    dataPath: /data
  subclusters:
    - name: ${VERTICA_SUBCLUSTER}
      size: ${VERTICA_SUBCLUSTER_SIZE}
      type: primary
      serviceType: ClusterIP
      resources:
        requests:
          cpu: "${VERTICA_CPU_REQUEST}"
          memory: "${VERTICA_MEM_REQUEST}"${limits_block}
YAML
}

# spec.initPolicy is immutable once the VerticaDB exists ("initPolicy cannot
# change after creation"), so anything that re-applies the CR must preserve
# whatever policy is already in the cluster.
current_init_policy() {
  kcq -n "$VERTICA_NAMESPACE" get verticadb "$VDB_NAME" -o jsonpath='{.spec.initPolicy}' || true
}

wait_db_ready() {
  local timeout="${1:-$WAIT_DB_TIMEOUT}"
  wait_for "VerticaDB '${VDB_NAME}' to report DBInitialized" "$timeout" \
    env KUBECONFIG="$KUBECONFIG_PATH" kubectl -n "$VERTICA_NAMESPACE" \
        wait --for=condition=DBInitialized "verticadb/${VDB_NAME}" --timeout=30s
  wait_for "Vertica pod to become Ready" "$timeout" \
    env KUBECONFIG="$KUBECONFIG_PATH" kubectl -n "$VERTICA_NAMESPACE" \
        wait --for=condition=Ready pod -l "app.kubernetes.io/instance=${VDB_NAME}" --timeout=30s
}

# Delete the VerticaDB CR and every local PersistentVolumeClaim it left behind.
# Communal storage in MinIO is NOT touched.
destroy_db_keep_communal() {
  # In Eon Mode the catalog is checkpointed to communal storage periodically,
  # not on every commit. Tearing down a RUNNING database therefore risks a
  # later revive coming back to an older catalog — tables created minutes ago
  # can simply be missing. sync_catalog() forces the flush, so the revive sees
  # everything that was committed.
  if db_is_up; then
    info "flushing the catalog to communal storage (sync_catalog)"
    if ! vsql_c "SELECT sync_catalog();" >/dev/null 2>&1; then
      warn "sync_catalog failed — a revive may not see the most recent changes"
    fi
  fi

  info "deleting the VerticaDB custom resource"
  kc -n "$VERTICA_NAMESPACE" delete verticadb "$VDB_NAME" --ignore-not-found --timeout=5m || true
  info "deleting local PVCs (depot, catalog and data) so the revive is genuine"
  kc -n "$VERTICA_NAMESPACE" delete pvc --all --ignore-not-found --timeout=5m || true
  wait_for "all Vertica pods to disappear" 300 \
    bash -c "[ -z \"\$(KUBECONFIG=${KUBECONFIG_PATH} kubectl -n ${VERTICA_NAMESPACE} get pods -l app.kubernetes.io/instance=${VDB_NAME} --no-headers 2>/dev/null)\" ]"
}

# Delete the database's objects from the communal bucket.
purge_communal() {
  info "deleting communal data under ${COMMUNAL_PATH}"
  kc -n "$MINIO_NAMESPACE" delete job minio-purge --ignore-not-found >/dev/null 2>&1 || true
  apply_manifest "minio-purge" <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-purge
  namespace: ${MINIO_NAMESPACE}
spec:
  backoffLimit: 4
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: mc
          image: ${MINIO_MC_IMAGE}
          env:
            - name: AK
              valueFrom: {secretKeyRef: {name: ${MINIO_SECRET_NAME}, key: accesskey}}
            - name: SK
              valueFrom: {secretKeyRef: {name: ${MINIO_SECRET_NAME}, key: secretkey}}
          command: ["/bin/sh","-c"]
          args:
            - |
              set -e
              mc alias set lab ${MINIO_ENDPOINT} "\$AK" "\$SK" >/dev/null
              # Count first, then delete quietly: "mc rm --recursive" prints one
              # line per object and a Vertica catalog is thousands of objects.
              BEFORE=\$(mc ls -r lab/${MINIO_BUCKET}/${VERTICA_DB_NAME}/ 2>/dev/null | wc -l)
              mc rm --recursive --force lab/${MINIO_BUCKET}/${VERTICA_DB_NAME}/ >/dev/null 2>&1 || true
              AFTER=\$(mc ls -r lab/${MINIO_BUCKET}/${VERTICA_DB_NAME}/ 2>/dev/null | wc -l)
              echo "communal prefix ${VERTICA_DB_NAME}/ purged: \$BEFORE objects removed, \$AFTER remaining"
              echo "bucket now contains:"
              mc ls lab/${MINIO_BUCKET}/ 2>/dev/null || echo "  (empty)"
YAML
  wait_for "communal purge job to finish" 300 \
    env KUBECONFIG="$KUBECONFIG_PATH" kubectl -n "$MINIO_NAMESPACE" \
        wait --for=condition=complete job/minio-purge --timeout=30s
}

# Print how much data the communal bucket currently holds.
communal_summary() {
  kc -n "$MINIO_NAMESPACE" delete job minio-du --ignore-not-found >/dev/null 2>&1 || true
  apply_manifest "minio-du" <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-du
  namespace: ${MINIO_NAMESPACE}
spec:
  backoffLimit: 3
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: mc
          image: ${MINIO_MC_IMAGE}
          env:
            - name: AK
              valueFrom: {secretKeyRef: {name: ${MINIO_SECRET_NAME}, key: accesskey}}
            - name: SK
              valueFrom: {secretKeyRef: {name: ${MINIO_SECRET_NAME}, key: secretkey}}
          command: ["/bin/sh","-c"]
          args:
            - |
              mc alias set lab ${MINIO_ENDPOINT} "\$AK" "\$SK" >/dev/null
              echo "objects: \$(mc ls -r lab/${MINIO_BUCKET}/${VERTICA_DB_NAME}/ 2>/dev/null | wc -l)"
              mc du lab/${MINIO_BUCKET}/${VERTICA_DB_NAME}/ 2>/dev/null || true
YAML
  wait_for "communal usage query" 180 \
    env KUBECONFIG="$KUBECONFIG_PATH" kubectl -n "$MINIO_NAMESPACE" \
        wait --for=condition=complete job/minio-du --timeout=20s
  kc -n "$MINIO_NAMESPACE" logs job/minio-du 2>/dev/null | sed 's/^/    /' || true
}

# ============================================================================
#  PHASE 1 — Preflight
# ============================================================================

PREFLIGHT_FAILED=0
pf_fail() {
  if [[ "$SKIP_PREFLIGHT" == "1" ]]; then warn "PREFLIGHT (ignored): $*"
  else err "PREFLIGHT: $*"; PREFLIGHT_FAILED=1; fi
}
pf_ok() { ok "$*"; }

phase_preflight() {
  step "Preflight checks"

  if (( ECHO_ONLY )); then
    note "Preflight makes no changes. It refuses to continue if the machine cannot host the lab, so you find out now rather than half way through a long install."
    show_cmd "uname -m"
    explain "Check the CPU architecture. This lab targets ${REQUIRED_ARCH} (64-bit ARM, as used by Apple Silicon)."
    show_cmd "nproc"
    explain "Count the CPU cores. At least ${MIN_CPU} are required."
    show_cmd "awk '/^MemTotal:/{print \$2}' /proc/meminfo"
    explain "Read total memory in kilobytes. At least ${MIN_RAM_GB} GiB is required — Vertica needs real memory, not swap."
    show_cmd "df -BG --output=avail /"
    explain "Check free disk on /. At least ${MIN_DISK_GB} GiB is required for the container images, the depot and the communal bucket."
    show_cmd "sudo -n true"
    explain "Check that sudo works without asking for a password, because installing K3s needs root and the script must not stop to prompt."
    explain "Check the machine can reach the places the installers and container images come from:"
    show_cmd "curl -fsS --max-time 15 -o /dev/null https://get.k3s.io"
    show_cmd "curl -fsS --max-time 15 -o /dev/null https://vertica.github.io"
    show_cmd "curl -fsS --max-time 15 -o /dev/null https://quay.io"
    show_cmd "curl -s -o /dev/null -w '%{http_code}' --max-time 15 https://registry-1.docker.io/v2/"
    explain "Check the container registry answers. A public registry replies 401 (authentication required) rather than 200; both prove it is reachable."
    note "Licence check: an image of 26.x or newer requires a real licence file, because Community Edition was withdrawn at v26.1. The configured image is ${VERTICA_IMAGE}."
    ok "preflight (described only — nothing was checked)"
    return 0
  fi

  local arch; arch=$(uname -m)
  if [[ "$arch" == "$REQUIRED_ARCH" ]]; then
    pf_ok "architecture ${arch}"
  else
    pf_fail "architecture is '${arch}', expected '${REQUIRED_ARCH}'. This lab targets ARM64 (Apple Silicon) VMs. Set REQUIRED_ARCH to override."
  fi

  if [[ -r /etc/os-release ]]; then
    local os_name; os_name=$(. /etc/os-release; echo "${PRETTY_NAME:-unknown}")
    pf_ok "os ${os_name}"
    if ! grep -qiE 'rocky|rhel|centos|almalinux' /etc/os-release; then
      warn "this script is tested on Rocky Linux 9; '${os_name}' may need adjustments"
    fi
  else
    pf_fail "/etc/os-release not readable — cannot identify the OS"
  fi

  local cpus; cpus=$(nproc)
  if (( cpus >= MIN_CPU )); then pf_ok "cpu cores ${cpus} (min ${MIN_CPU})"
  else pf_fail "only ${cpus} CPU core(s); need at least ${MIN_CPU}. Raise the vCPU count in UTM."; fi

  local ram_kb ram_gb
  ram_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
  ram_gb=$(( ram_kb / 1024 / 1024 ))
  if (( ram_gb >= MIN_RAM_GB )); then pf_ok "memory ${ram_gb}GiB (min ${MIN_RAM_GB}GiB)"
  else pf_fail "only ${ram_gb}GiB RAM; need at least ${MIN_RAM_GB}GiB. Raise the memory in UTM."; fi

  local disk_gb
  disk_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  if (( disk_gb >= MIN_DISK_GB )); then pf_ok "free disk ${disk_gb}GiB on / (min ${MIN_DISK_GB}GiB)"
  else pf_fail "only ${disk_gb}GiB free on /; need at least ${MIN_DISK_GB}GiB (images + depot + communal storage)."; fi

  if sudo -n true 2>/dev/null; then pf_ok "passwordless sudo"
  else pf_fail "passwordless sudo is not configured. See the Prerequisites section of README.md."; fi

  local u failed_urls=()
  for u in https://get.k3s.io https://vertica.github.io https://quay.io; do
    curl -fsS --max-time 15 -o /dev/null "$u" || failed_urls+=("$u")
  done
  if (( ${#failed_urls[@]} == 0 )); then pf_ok "internet reachable (k3s, helm charts, quay.io)"
  else pf_fail "cannot reach: ${failed_urls[*]} — check the VM's network/DNS and any proxy."; fi

  local reg_host="${VERTICA_IMAGE%%/*}"
  [[ "$reg_host" == *.* || "$reg_host" == *:* ]] || reg_host="registry-1.docker.io"
  # A public registry answers /v2/ with 200 or, more often, 401 (auth required).
  local reg_code
  reg_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://${reg_host}/v2/" || echo 000)
  case "$reg_code" in
    200|401|403) pf_ok "container registry ${reg_host} reachable (HTTP ${reg_code})" ;;
    000)         pf_fail "cannot reach container registry ${reg_host} — image pulls will fail." ;;
    *)           warn "container registry ${reg_host} answered HTTP ${reg_code}; image pulls may still work" ;;
  esac

  # --- licensing model vs. image version --------------------------------
  # Community Edition was an evaluation option up to 25.x. From v26.1 it is
  # withdrawn: new evaluations use a 30-day Trial license file, and a database
  # created under CE needs a commercial license to move forward. Operator 26.x
  # therefore refuses to reconcile without a real license, so fail early and
  # clearly rather than after a multi-hundred-megabyte image pull.
  local img_major="${VERTICA_IMAGE##*:}"; img_major="${img_major%%.*}"
  if [[ -z "$LICENSE_FILE" ]] && [[ "$img_major" =~ ^[0-9]+$ ]] && (( img_major >= 26 )); then
    pf_fail "VERTICA_IMAGE '${VERTICA_IMAGE}' is a 26.x release. Community Edition is not offered from v26.1, so this image needs a real license (30-day Trial or commercial) in LICENSE_FILE. Either set LICENSE_FILE, or keep the Community Edition default (opentext/vertica-k8s:25.3.0-8-multiarch with VDB_HELM_CHART_VERSION=25.3.0). See README 'Version and licensing constraints'."
  fi

  if [[ -n "$LICENSE_FILE" ]]; then
    if [[ -r "$LICENSE_FILE" ]]; then pf_ok "license file ${LICENSE_FILE}"
    else pf_fail "LICENSE_FILE='${LICENSE_FILE}' is not readable. Leave it blank to use Community Edition on a 25.x image."; fi
  else
    pf_ok "no LICENSE_FILE set — using Vertica Community Edition (25.x only)"
  fi

  have getenforce && info "selinux: $(getenforce)"

  if (( PREFLIGHT_FAILED )); then
    err "preflight failed — fix the items above, or re-run with --skip-preflight to proceed anyway"
    return 1
  fi
  ok "preflight passed"
}

# ============================================================================
#  PHASE 2 — K3s
# ============================================================================

phase_k3s() {
  step "Install K3s (single node)"
  note "GOAL: turn this VM into a one-node Kubernetes cluster. Kubernetes is what starts, restarts and connects the containers; the Vertica operator later relies on it."

  local pkgs=() p
  for p in curl tar; do have "$p" || pkgs+=("$p"); done
  if (( ${#pkgs[@]} )); then
    info "installing missing packages: ${pkgs[*]}"
    run sudo dnf install -y "${pkgs[@]}"
  fi

  if (( ECHO_ONLY )); then
    note "If firewalld is running on the VM, the pod network (10.42.0.0/16) and the service network (10.43.0.0/16) are added to its 'trusted' zone and port 6443 is opened."
    explain "Without this, the host firewall silently drops traffic between pods and the cluster never becomes healthy. This is the single most common reason K3s appears to install fine and then not work on RHEL-family systems."
  elif systemctl is-active --quiet firewalld 2>/dev/null; then
    info "firewalld is active — trusting k3s pod/service networks"
    run sudo firewall-cmd --permanent --add-source=10.42.0.0/16 --zone=trusted
    run sudo firewall-cmd --permanent --add-source=10.43.0.0/16 --zone=trusted
    run sudo firewall-cmd --permanent --add-port=6443/tcp
    run sudo firewall-cmd --reload
  else
    info "firewalld inactive — nothing to open"
  fi

  if systemctl is-active --quiet k3s 2>/dev/null && have k3s; then
    # Read the whole output then take line 1: piping into `head -1` would give
    # k3s a SIGPIPE, which pipefail turns into a fatal error.
    local k3s_ver; k3s_ver=$(k3s --version 2>/dev/null || true)
    ok "k3s already installed and running (${k3s_ver%%$'\n'*})"
  else
    info "installing k3s (channel=${K3S_CHANNEL}${K3S_VERSION:+, version=${K3S_VERSION}})"
    local installer="/tmp/k3s-install.sh"
    run_sh "curl -sfL https://get.k3s.io -o ${installer}"
    run chmod +x "$installer"
    if (( NO_EXEC )); then
      show_cmd "sudo env INSTALL_K3S_CHANNEL=${K3S_CHANNEL}${K3S_VERSION:+ INSTALL_K3S_VERSION=$K3S_VERSION} ${installer} ${K3S_INSTALL_ARGS}"
      explain "Run the K3s installer. K3s is a small, single-binary Kubernetes distribution; this makes the VM into a one-node Kubernetes cluster. Traefik and metrics-server are switched off to leave more memory for Vertica."
    else
      # shellcheck disable=SC2086
      sudo env \
        INSTALL_K3S_CHANNEL="$K3S_CHANNEL" \
        ${K3S_VERSION:+INSTALL_K3S_VERSION="$K3S_VERSION"} \
        "$installer" $K3S_INSTALL_ARGS
    fi
    run sudo systemctl enable --now k3s
  fi

  if ! have kubectl; then
    info "linking kubectl -> k3s"
    run sudo ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl
  fi
  if [[ -f "$KUBECONFIG_PATH" ]] && [[ ! -r "$KUBECONFIG_PATH" ]]; then
    run sudo chmod 644 "$KUBECONFIG_PATH"
  fi

  wait_for "kubernetes API to answer" 180 \
    env KUBECONFIG="$KUBECONFIG_PATH" kubectl get --raw=/readyz
  wait_for "node to become Ready" 180 \
    bash -c "KUBECONFIG=${KUBECONFIG_PATH} kubectl get nodes --no-headers | grep -qw Ready"

  (( NO_EXEC )) || kc get nodes -o wide
  ok "k3s ready"
}

# ============================================================================
#  PHASE 3 — Helm
# ============================================================================

phase_tools() {
  step "Install Helm"
  note "GOAL: install Helm, the package manager for Kubernetes. The Vertica operator is published as a Helm chart, so Helm is how it gets installed and upgraded."
  if have helm; then
    ok "helm already installed ($(helm version --short 2>/dev/null || echo unknown))"
  else
    info "installing helm via the official get-helm-3 script"
    run_sh "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o /tmp/get-helm-3"
    run chmod +x /tmp/get-helm-3
    # sudo's secure_path on RHEL-family systems excludes /usr/local/bin, so the
    # installer would place helm there and then fail its own post-install
    # "command -v helm" check. Give it a PATH that can see its own output.
    run sudo env PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" /tmp/get-helm-3
    hash -r 2>/dev/null || true
  fi
  if (( ! NO_EXEC )); then
    have helm || { err "helm is still not on PATH after installation"; return 1; }
    helm version --short
  fi
}

# ============================================================================
#  PHASE 4 — MinIO (S3-compatible communal storage)
# ============================================================================

resolve_minio_creds() {
  local existing_ak existing_sk
  existing_ak=$(secret_value "$MINIO_NAMESPACE" "$MINIO_SECRET_NAME" accesskey)
  existing_sk=$(secret_value "$MINIO_NAMESPACE" "$MINIO_SECRET_NAME" secretkey)
  if [[ -n "$existing_ak" && -n "$existing_sk" ]]; then
    MINIO_ACCESS_KEY="$existing_ak"
    MINIO_SECRET_KEY="$existing_sk"
    info "reusing existing MinIO credentials from secret ${MINIO_NAMESPACE}/${MINIO_SECRET_NAME}"
    return 0
  fi
  if [[ -z "$MINIO_SECRET_KEY" ]]; then
    if (( NO_EXEC )); then MINIO_SECRET_KEY="<generated-at-run-time>"
    else
      MINIO_SECRET_KEY=$(gen_password)
      info "generated a new MinIO secret key (stored only in the Kubernetes secret)"
    fi
  fi
}

phase_minio() {
  step "Deploy MinIO as communal storage"
  note "GOAL: give Eon Mode somewhere to keep its data. Eon separates compute from storage: the database keeps the authoritative copy of everything in S3-compatible object storage, called COMMUNAL storage. MinIO provides exactly that S3 interface, running inside the cluster so the lab needs no cloud account."

  ensure_namespace "$MINIO_NAMESPACE"
  ensure_namespace "$VERTICA_NAMESPACE"
  resolve_minio_creds

  local ns
  for ns in "$MINIO_NAMESPACE" "$VERTICA_NAMESPACE"; do
    apply_manifest "minio-secret-${ns}" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: ${MINIO_SECRET_NAME}
  namespace: ${ns}
type: Opaque
stringData:
  accesskey: "${MINIO_ACCESS_KEY}"
  secretkey: "${MINIO_SECRET_KEY}"
YAML
  done

  apply_manifest "minio" <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-data
  namespace: ${MINIO_NAMESPACE}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: ${MINIO_PVC_SIZE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: ${MINIO_NAMESPACE}
  labels: {app: minio}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector:
    matchLabels: {app: minio}
  template:
    metadata:
      labels: {app: minio}
    spec:
      containers:
        - name: minio
          image: ${MINIO_IMAGE}
          args: ["server", "/data", "--console-address", ":9001"]
          env:
            - name: MINIO_ROOT_USER
              valueFrom: {secretKeyRef: {name: ${MINIO_SECRET_NAME}, key: accesskey}}
            - name: MINIO_ROOT_PASSWORD
              valueFrom: {secretKeyRef: {name: ${MINIO_SECRET_NAME}, key: secretkey}}
          ports:
            - {containerPort: 9000, name: s3}
            - {containerPort: 9001, name: console}
          volumeMounts:
            - {name: data, mountPath: /data}
          resources:
            requests:
              cpu: "${MINIO_CPU_REQUEST}"
              memory: "${MINIO_MEM_REQUEST}"
          readinessProbe:
            httpGet: {path: /minio/health/ready, port: 9000}
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            httpGet: {path: /minio/health/live, port: 9000}
            initialDelaySeconds: 30
            periodSeconds: 30
      volumes:
        - name: data
          persistentVolumeClaim: {claimName: minio-data}
---
apiVersion: v1
kind: Service
metadata:
  name: ${MINIO_SVC}
  namespace: ${MINIO_NAMESPACE}
spec:
  selector: {app: minio}
  ports:
    - {name: s3, port: ${MINIO_PORT}, targetPort: 9000}
    - {name: console, port: 9001, targetPort: 9001}
YAML

  wait_for "MinIO deployment to become available" "$WAIT_MINIO_TIMEOUT" \
    env KUBECONFIG="$KUBECONFIG_PATH" kubectl -n "$MINIO_NAMESPACE" \
        wait --for=condition=Available deployment/minio --timeout=30s

  info "creating bucket '${MINIO_BUCKET}' (idempotent)"
  kc -n "$MINIO_NAMESPACE" delete job minio-make-bucket --ignore-not-found

  apply_manifest "minio-make-bucket" <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-make-bucket
  namespace: ${MINIO_NAMESPACE}
spec:
  backoffLimit: 6
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: mc
          image: ${MINIO_MC_IMAGE}
          env:
            - name: AK
              valueFrom: {secretKeyRef: {name: ${MINIO_SECRET_NAME}, key: accesskey}}
            - name: SK
              valueFrom: {secretKeyRef: {name: ${MINIO_SECRET_NAME}, key: secretkey}}
          command: ["/bin/sh","-c"]
          args:
            - |
              set -e
              until mc alias set lab ${MINIO_ENDPOINT} "\$AK" "\$SK"; do
                echo "waiting for minio..."; sleep 3
              done
              mc mb --ignore-existing lab/${MINIO_BUCKET}
              mc ls lab/
              echo "bucket ${MINIO_BUCKET} ready"
YAML

  wait_for "bucket ${MINIO_BUCKET} to be created" "$WAIT_MINIO_TIMEOUT" \
    env KUBECONFIG="$KUBECONFIG_PATH" kubectl -n "$MINIO_NAMESPACE" \
        wait --for=condition=complete job/minio-make-bucket --timeout=30s

  ok "MinIO ready at ${MINIO_ENDPOINT} (bucket: ${MINIO_BUCKET})"
}

# ============================================================================
#  PHASE 5 — VerticaDB operator
# ============================================================================

phase_operator() {
  step "Install the VerticaDB operator (Helm)"
  note "GOAL: install the operator. An operator is a program that runs inside Kubernetes and knows how to look after one kind of application. This one watches for VerticaDB objects and does all the work of actually creating, starting and repairing a Vertica database."

  ensure_namespace "$VDB_OPERATOR_NAMESPACE"

  run_sh --why "Register the Vertica chart repository so Helm knows where to fetch the operator from, then refresh its index of available versions." \
    "helm repo add ${VDB_HELM_REPO_NAME} ${VDB_HELM_REPO_URL} --force-update && helm repo update ${VDB_HELM_REPO_NAME}"

  local set_args=() kv
  for kv in $VDB_HELM_EXTRA_SET; do set_args+=(--set "$kv"); done

  local ver_args=()
  [[ -n "$VDB_HELM_CHART_VERSION" ]] && ver_args=(--version "$VDB_HELM_CHART_VERSION")

  if (( NO_EXEC )); then
    show_cmd "helm upgrade --install ${VDB_HELM_RELEASE} ${VDB_HELM_CHART} -n ${VDB_OPERATOR_NAMESPACE} ${ver_args[*]-} ${set_args[*]-}"
    explain "Install the VerticaDB operator from its Helm chart, or upgrade it in place if it is already installed. The operator is the component that watches for VerticaDB objects and builds real databases from them."
  else
    KUBECONFIG="$KUBECONFIG_PATH" helm upgrade --install \
      "$VDB_HELM_RELEASE" "$VDB_HELM_CHART" \
      --namespace "$VDB_OPERATOR_NAMESPACE" \
      "${ver_args[@]}" "${set_args[@]}" \
      --wait --timeout "${WAIT_OPERATOR_TIMEOUT}s"
  fi

  wait_for "VerticaDB CRD to be established" "$WAIT_OPERATOR_TIMEOUT" \
    env KUBECONFIG="$KUBECONFIG_PATH" kubectl wait --for=condition=Established \
        crd/verticadbs.vertica.com --timeout=30s

  wait_for "operator pod to become Ready" "$WAIT_OPERATOR_TIMEOUT" \
    env KUBECONFIG="$KUBECONFIG_PATH" kubectl -n "$VDB_OPERATOR_NAMESPACE" \
        wait --for=condition=Ready pod -l app.kubernetes.io/name=verticadb-operator --timeout=30s

  ok "VerticaDB operator ready in namespace ${VDB_OPERATOR_NAMESPACE}"
}

# ============================================================================
#  PHASE 6 — VerticaDB custom resource
# ============================================================================

resolve_vertica_password() {
  local existing
  existing=$(secret_value "$VERTICA_NAMESPACE" "$VERTICA_SU_SECRET" password)
  if [[ -n "$existing" ]]; then
    VERTICA_PASSWORD="$existing"
    info "reusing the existing dbadmin password from ${VERTICA_NAMESPACE}/${VERTICA_SU_SECRET}"
    return 0
  fi
  if [[ -z "$VERTICA_PASSWORD" ]]; then
    if (( NO_EXEC )); then VERTICA_PASSWORD="<generated-at-run-time>"
    else
      VERTICA_PASSWORD=$(gen_password)
      info "generated a new dbadmin password (stored only in the Kubernetes secret)"
    fi
  fi
}

# Create the license secret from LICENSE_FILE. Only called when LICENSE_FILE is
# set: under Community Edition the operator wants NO licenseSecret at all — it
# actively rejects a CE license placed in a secret.
ensure_license_secret() {
  [[ -n "$LICENSE_FILE" ]] || return 0
  info "creating license secret from ${LICENSE_FILE}"
  if (( NO_EXEC )); then
    show_cmd "kubectl -n ${VERTICA_NAMESPACE} create secret generic ${VERTICA_LICENSE_SECRET} --from-file=${LICENSE_FILE}"
    explain "Load the licence file into Kubernetes as a secret, so the database pod can read it without the file being copied around."
    return 0
  fi
  kc -n "$VERTICA_NAMESPACE" create secret generic "$VERTICA_LICENSE_SECRET" \
    --from-file="$(basename "$LICENSE_FILE")=${LICENSE_FILE}" \
    --dry-run=client -o yaml | kc apply -f -
}

phase_verticadb() {
  step "Deploy the VerticaDB (Eon Mode, ${VERTICA_SUBCLUSTER_SIZE}-node subcluster)"
  note "GOAL: describe the database we want and let the operator build it. We do not run any install command: we hand Kubernetes a VerticaDB object saying which image, how big, and where communal storage is, and the operator makes reality match that description."

  ensure_namespace "$VERTICA_NAMESPACE"
  resolve_minio_creds
  resolve_vertica_password

  apply_manifest "vertica-superuser-secret" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: ${VERTICA_SU_SECRET}
  namespace: ${VERTICA_NAMESPACE}
type: Opaque
stringData:
  password: "${VERTICA_PASSWORD}"
YAML

  if [[ -n "$LICENSE_FILE" ]]; then
    ensure_license_secret
  else
    info "no LICENSE_FILE — deploying Vertica Community Edition (no licenseSecret)"
  fi

  local init_policy="Create"
  local existing_policy; existing_policy=$(current_init_policy || true)
  if [[ -n "$existing_policy" ]]; then
    init_policy="$existing_policy"
    info "VerticaDB already exists with initPolicy=${existing_policy} — keeping it (the field is immutable)"
  fi
  render_verticadb "$init_policy" | apply_manifest "verticadb"

  info "the operator is now creating the database — this takes several minutes on a VM"
  wait_db_ready

  (( NO_EXEC )) || kc -n "$VERTICA_NAMESPACE" get verticadb,pods,svc
  ok "VerticaDB ${VDB_NAME} is up"
}

# ============================================================================
#  PHASE 7 — Smoke test
# ============================================================================

phase_smoke() {
  if (( NO_EXEC )); then
    step "Smoke test (vsql)"
    vsql_preamble
    show_cmd "$(vsql_display_cmd -i) <<'SQL' ... SQL"
    explain "Open a SQL session inside the database container and run a short create/insert/select to prove the database really works."
    return 0
  fi
  # demo_smoke prints its own step header; do not add a second one.
  demo_smoke
}

# ============================================================================
#  DEMOS
# ============================================================================

# ---------------------------------------------------------------------------
#  smoke — prove we can connect and do basic DDL/DML
# ---------------------------------------------------------------------------
demo_smoke() {
  step "DEMO smoke — connect, create, insert, select"
  note "GOAL: prove the database works, and prove it is really in Eon Mode rather than classic Enterprise Mode."
  vsql_in -v ON_ERROR_STOP=1 <<'SQL'
\echo === version ===
-- Which Vertica build is running.
SELECT version();
\echo === nodes and subclusters ===
-- Every node in the cluster and the subcluster it belongs to. "UP" means the
-- node is running and serving queries.
SELECT node_name, node_state, subcluster_name FROM v_catalog.nodes;
\echo === Eon proof: shards exist only in Eon Mode ===
-- A shard is a slice of the data in communal storage. Enterprise Mode has no
-- shards at all, so rows here are proof this database is in Eon Mode.
SELECT shard_type, lower_hash_bound, upper_hash_bound FROM v_catalog.shards;
\echo === Eon proof: the communal location has no node_name ===
-- Local storage belongs to a node, so it has a node_name. Communal storage is
-- shared by the whole cluster, so its row has an empty node_name and an s3://
-- path. That single row is the heart of Eon Mode.
SELECT node_name, location_path, location_usage FROM v_catalog.storage_locations ORDER BY 1,2;
\echo === edition in force ===
-- Which licence this database is running under.
SELECT display_license();
\echo === smoke: create / insert / select ===
-- Start from a known state, then create a small table and put three rows in it.
DROP TABLE IF EXISTS lab_smoke CASCADE;
CREATE TABLE lab_smoke (id INT, name VARCHAR(64), created TIMESTAMP DEFAULT NOW());
INSERT INTO lab_smoke (id, name) VALUES (1, 'hello');
INSERT INTO lab_smoke (id, name) VALUES (2, 'eon');
INSERT INTO lab_smoke (id, name) VALUES (3, 'kubernetes');
COMMIT;
SELECT id, name FROM lab_smoke ORDER BY id;
SELECT COUNT(*) AS row_count FROM lab_smoke;
\echo === smoke test complete ===
SQL
  ok "smoke demo PASSED"
}

# ---------------------------------------------------------------------------
#  bulk — load a star schema and query it
# ---------------------------------------------------------------------------
# Vertica has no generate_series, so rows come from a 10-row digits CTE cross
# joined with itself: six copies give a 1,000,000-row generator.
demo_bulk() {
  step "DEMO bulk — load a ${DEMO_FACT_ROWS}-row star schema"
  note "GOAL: put a realistic amount of data in, so later demos have something meaningful to work on. A star schema is the usual analytics shape: one large table of events (the fact table) plus small lookup tables (dimensions)."
  local fact_rows="$DEMO_FACT_ROWS"
  vsql_in -v ON_ERROR_STOP=1 -v fact_rows="$fact_rows" <<'SQL'
\timing on
DROP TABLE IF EXISTS fact_sales CASCADE;
DROP TABLE IF EXISTS dim_store CASCADE;
DROP TABLE IF EXISTS dim_product CASCADE;

CREATE TABLE dim_store   (store_id INT PRIMARY KEY, store_name VARCHAR(32), region VARCHAR(16));
CREATE TABLE dim_product (product_id INT PRIMARY KEY, product_name VARCHAR(32), category VARCHAR(16));
CREATE TABLE fact_sales  (sale_id INT, sale_date DATE, store_id INT, product_id INT,
                          qty INT, unit_price NUMERIC(10,2));

\echo === loading 100 stores ===
INSERT /*+direct*/ INTO dim_store
WITH d(n) AS (SELECT 0 UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
              UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9)
SELECT d1.n*10+d2.n+1, 'store_'||(d1.n*10+d2.n+1),
       CASE MOD(d2.n,4) WHEN 0 THEN 'north' WHEN 1 THEN 'south' WHEN 2 THEN 'east' ELSE 'west' END
FROM d d1, d d2;

\echo === loading 1000 products ===
INSERT /*+direct*/ INTO dim_product
WITH d(n) AS (SELECT 0 UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
              UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9)
SELECT d1.n*100+d2.n*10+d3.n+1, 'prod_'||(d1.n*100+d2.n*10+d3.n+1),
       CASE MOD(d3.n,5) WHEN 0 THEN 'tools' WHEN 1 THEN 'food' WHEN 2 THEN 'toys' WHEN 3 THEN 'books' ELSE 'misc' END
FROM d d1, d d2, d d3;

\echo === loading the fact table ===
INSERT /*+direct*/ INTO fact_sales
WITH d(n) AS (SELECT 0 UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
              UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9),
g AS (SELECT (d1.n*100000+d2.n*10000+d3.n*1000+d4.n*100+d5.n*10+d6.n) AS n
      FROM d d1, d d2, d d3, d d4, d d5, d d6)
SELECT n, DATE '2024-01-01' + MOD(n,365), MOD(n,100)+1, MOD(n,1000)+1,
       MOD(n,9)+1, (5+MOD(n,90))::NUMERIC(10,2)
FROM g WHERE n < :fact_rows;
COMMIT;

\echo === statistics (the Database Designer needs these) ===
-- Collect statistics about the data just loaded (how many distinct values, how
-- they are spread). The query optimiser uses these to choose a plan, and the
-- Database Designer refuses to propose anything useful without them.
SELECT ANALYZE_STATISTICS('');

\echo === row counts ===
SELECT (SELECT COUNT(*) FROM fact_sales) AS fact_rows,
       (SELECT COUNT(*) FROM dim_store) AS stores,
       (SELECT COUNT(*) FROM dim_product) AS products;

\echo === analytic query: revenue by region and category ===
SELECT s.region, p.category, ROUND(SUM(f.qty*f.unit_price),2) AS revenue
FROM fact_sales f
JOIN dim_store   s ON f.store_id  = s.store_id
JOIN dim_product p ON f.product_id = p.product_id
WHERE f.sale_date BETWEEN '2024-03-01' AND '2024-06-30'
GROUP BY 1,2 ORDER BY revenue DESC LIMIT 10;

\echo === compression: raw vs on-disk ===
-- Vertica stores data by column and compresses it heavily, so a million rows
-- typically occupy only a few megabytes on disk.
SELECT anchor_table_name,
       (SUM(used_bytes)/1024.0/1024.0)::NUMERIC(12,2) AS mb_on_disk,
       SUM(row_count) AS rows_stored
FROM v_monitor.projection_storage
WHERE anchor_table_name IN ('fact_sales','dim_store','dim_product')
GROUP BY 1 ORDER BY 1;
SQL
  ok "bulk demo complete"
}

# Several demos assert on the star schema. Build it if it is not there, so each
# demo is self-contained and can be run in any order.
ensure_bulk_data() {
  if [[ "$(vsql_scalar "SELECT COUNT(*) FROM v_catalog.tables WHERE table_name='fact_sales';")" != "1" ]]; then
    info "fact_sales is not present — running the bulk demo first"
    demo_bulk
  fi
}

# ---------------------------------------------------------------------------
#  dbd — Database Designer
# ---------------------------------------------------------------------------
# DESIGNER_RUN_POPULATE_DESIGN_AND_DEPLOY returns almost immediately: the
# design and deployment run in a BACKGROUND task. Polling for completion is
# therefore mandatory, otherwise you look at the projections too early and
# conclude, wrongly, that DBD did nothing.
demo_dbd() {
  step "DEMO dbd — Database Designer, before and after"
  note "GOAL: show the Database Designer at work. Vertica stores tables as PROJECTIONS: physical copies sorted and compressed for particular queries. The Designer looks at your queries and builds better projections for them."

  ensure_bulk_data

  local design="labdbd"

  local demo_query="SELECT store_id, SUM(qty*unit_price) FROM fact_sales WHERE sale_date BETWEEN '2024-03-01' AND '2024-06-30' GROUP BY store_id ORDER BY 2 DESC"

  say "projections BEFORE the design"
  vsql_in -v ON_ERROR_STOP=1 <<'SQL'
SELECT anchor_table_name, projection_name, is_super_projection
FROM v_catalog.projections
WHERE anchor_table_name IN ('fact_sales','dim_store','dim_product') ORDER BY 1,2;
SQL
  say "query plan BEFORE the design — note which projection it reads"
  vsql_explain "$demo_query"

  say "building and deploying the design"
  # A design left over from an interrupted run would block DESIGNER_CREATE_DESIGN.
  vsql_c "SELECT DESIGNER_DROP_DESIGN('${design}', true);" >/dev/null 2>&1 || true
  vsql_in -v ON_ERROR_STOP=1 <<SQL
SELECT DESIGNER_CREATE_DESIGN('${design}');
SELECT DESIGNER_ADD_DESIGN_TABLES('${design}','public.fact_sales');
SELECT DESIGNER_ADD_DESIGN_TABLES('${design}','public.dim_store');
SELECT DESIGNER_ADD_DESIGN_TABLES('${design}','public.dim_product');
SELECT DESIGNER_ADD_DESIGN_QUERY('${design}',
  'SELECT store_id, SUM(qty*unit_price) FROM public.fact_sales WHERE sale_date BETWEEN ''2024-03-01'' AND ''2024-06-30'' GROUP BY store_id ORDER BY 2 DESC;');
SELECT DESIGNER_ADD_DESIGN_QUERY('${design}',
  'SELECT s.region, p.category, SUM(f.qty*f.unit_price) FROM public.fact_sales f JOIN public.dim_store s ON f.store_id=s.store_id JOIN public.dim_product p ON f.product_id=p.product_id GROUP BY 1,2;');
-- single node: no buddy projections
SELECT DESIGNER_SET_DESIGN_KSAFETY('${design}', 0);
SELECT DESIGNER_SET_OPTIMIZATION_OBJECTIVE('${design}','QUERY');
SELECT DESIGNER_SET_DESIGN_TYPE('${design}','COMPREHENSIVE');
SELECT DESIGNER_RUN_POPULATE_DESIGN_AND_DEPLOY('${design}',
  '/tmp/${design}_design.sql','/tmp/${design}_deploy.sql');
SQL

  # The design row is removed from v_monitor.designs once the background
  # design-and-deploy task finishes and drops its workspace.
  if (( NO_EXEC )); then
    note "WAIT until: the design named '${design}' disappears from v_monitor.designs"
    explain "DESIGNER_RUN_POPULATE_DESIGN_AND_DEPLOY returns almost immediately because the design runs as a BACKGROUND task. Vertica removes the design's row once that task has finished, so polling for the row to vanish is how we know the new projections are really in place. Looking at the projections before this point makes it appear the Designer did nothing."
  else
  info "waiting for the background design/deploy task to finish"
  local deadline=$(( SECONDS + WAIT_DEMO_TIMEOUT )) remaining
  while :; do
    remaining=$(vsql_scalar "SELECT COUNT(*) FROM v_monitor.designs WHERE design_name='${design}';" 2>/dev/null || echo 1)
    [[ "$remaining" == "0" ]] && break
    if (( SECONDS >= deadline )); then
      warn "design did not finish within ${WAIT_DEMO_TIMEOUT}s; showing current state anyway"
      break
    fi
    sleep 5
  done
  ok "design/deploy finished"
  fi

  say "projections AFTER the design — the ones DBD built carry the design name"
  vsql_in -v ON_ERROR_STOP=1 <<SQL
SELECT anchor_table_name, projection_name, is_super_projection, is_up_to_date
FROM v_catalog.projections
WHERE anchor_table_name IN ('fact_sales','dim_store','dim_product') ORDER BY 1,2;
SQL
  say "query plan AFTER the design — it now reads a DBD projection"
  vsql_explain "$demo_query"

  say "running the designed query"
  vsql_in -v ON_ERROR_STOP=1 <<'SQL'
\timing on
SELECT store_id, SUM(qty*unit_price)::NUMERIC(18,2) AS revenue FROM fact_sales
 WHERE sale_date BETWEEN '2024-03-01' AND '2024-06-30'
 GROUP BY store_id ORDER BY revenue DESC LIMIT 5;
SQL

  # DESIGNER_RUN_POPULATE_DESIGN_AND_DEPLOY already dropped the design; this is
  # only a safety net if the wait above timed out.
  vsql_c "SELECT DESIGNER_DROP_DESIGN('${design}', true);" >/dev/null 2>&1 || true
  ok "dbd demo complete"
}

# ---------------------------------------------------------------------------
#  depot — Eon depot behaviour
# ---------------------------------------------------------------------------
demo_depot() {
  step "DEMO depot — cold read from communal vs warm read from depot"
  note "GOAL: show the depot, which is a local disk cache in front of communal storage. A read that misses the depot has to fetch from S3; a read that hits it does not."

  ensure_bulk_data

  say "depot configuration and current usage"
  vsql_in -v ON_ERROR_STOP=1 <<'SQL'
SELECT node_name,
       (max_size_bytes/1024/1024)::NUMERIC(12,1)     AS depot_max_mb,
       (current_usage_bytes/1024/1024)::NUMERIC(12,1) AS depot_used_mb
FROM v_monitor.depot_sizes;
SELECT node_name, COUNT(*) AS cached_files,
       (SUM(file_size_bytes)/1024/1024)::NUMERIC(12,1) AS cached_mb
FROM v_monitor.depot_files GROUP BY 1;
SQL

  say "clearing the depot — every read must now come from communal storage"
  vsql_in -v ON_ERROR_STOP=1 <<'SQL'
-- Empty the local cache, so the next read has no choice but to go to S3.
SELECT CLEAR_DATA_DEPOT();
SELECT node_name, COUNT(*) AS cached_files_after_clear FROM v_monitor.depot_files GROUP BY 1;
SELECT COALESCE(SUM(1),0) AS fetches_so_far FROM v_monitor.depot_fetches;
SQL

  say "COLD read — data is pulled back from S3"
  vsql_in -v ON_ERROR_STOP=1 <<'SQL'
\timing on
SELECT COUNT(*) AS rows_scanned,
       SUM(qty*unit_price)::NUMERIC(18,2) AS revenue
FROM fact_sales;
\timing off
SQL

  say "proof the cold read really went to communal storage"
  vsql_in -v ON_ERROR_STOP=1 <<'SQL'
-- Every row here is a file Vertica had to pull back from communal storage.
-- This is the real evidence of the S3 round trip.
SELECT node_name, COUNT(*) AS files_fetched_from_communal,
       (SUM(file_size_bytes)/1024/1024)::NUMERIC(12,1) AS mb_fetched
FROM v_monitor.depot_fetches GROUP BY 1;
SELECT node_name, COUNT(*) AS files_now_cached,
       (SUM(file_size_bytes)/1024/1024)::NUMERIC(12,1) AS cached_mb
FROM v_monitor.depot_files GROUP BY 1;
SQL

  info "NB: on a lab-sized table the cold/warm wall-clock difference is small —"
  info "the depot_fetches counters above are the real evidence of the S3 round trip."

  say "WARM read — the same query, now served from the local depot"
  vsql_in -v ON_ERROR_STOP=1 <<'SQL'
\timing on
SELECT COUNT(*) AS rows_scanned,
       SUM(qty*unit_price)::NUMERIC(18,2) AS revenue
FROM fact_sales;
\timing off
SELECT source, COUNT(*) AS files FROM v_monitor.depot_files GROUP BY 1 ORDER BY 1;
SQL

  say "pin the fact table so it is the last thing evicted"
  vsql_in -v ON_ERROR_STOP=1 <<SQL
-- signature is (table, subcluster, download)
SELECT SET_DEPOT_PIN_POLICY_TABLE('public.fact_sales', '${VERTICA_SUBCLUSTER}', true);
SELECT object_name, policy_details FROM v_monitor.depot_pin_policies;
SELECT node_name, COUNT(*) AS pinned_files
FROM v_monitor.depot_files WHERE is_pinned GROUP BY 1;
SQL
  ok "depot demo complete"
}

# ---------------------------------------------------------------------------
#  revive — the headline Eon demonstration
# ---------------------------------------------------------------------------
demo_revive() {
  step "DEMO revive — destroy all local storage, then revive from communal"
  note "GOAL: prove compute and storage really are separate. We delete the database and every local disk, keeping only the S3 bucket, then rebuild the database from that bucket alone and show the data is all still there."

  confirm "This deletes the database and ALL local volumes, then revives from communal storage. Continue?" || return 1

  require_database

  # The proof is only meaningful with real data in communal storage.
  ensure_bulk_data

  say "state BEFORE — remember these numbers"
  vsql_in -v ON_ERROR_STOP=1 <<'SQL'
SELECT current_database() AS database;
SELECT table_name FROM v_catalog.tables WHERE table_schema='public' ORDER BY 1;
SELECT COUNT(*) AS fact_rows FROM fact_sales;
SQL
  local before_facts
  if ! before_facts=$(vsql_scalar "SELECT COUNT(*) FROM fact_sales;"); then
    err "could not read fact_sales before the revive"
    return 1
  fi
  info "fact_sales row count before: ${before_facts}"

  say "how much data is in communal storage right now"
  communal_summary

  say "destroying the database and every local volume"
  destroy_db_keep_communal
  ok "database gone; only the S3 bucket still holds anything"

  say "reviving from communal storage (initPolicy: Revive)"
  render_verticadb Revive | apply_manifest "verticadb-revive"
  wait_db_ready

  say "state AFTER the revive"
  vsql_in -v ON_ERROR_STOP=1 <<'SQL'
SELECT current_database() AS database;
SELECT node_name, node_state, subcluster_name FROM v_catalog.nodes;
SELECT table_name FROM v_catalog.tables WHERE table_schema='public' ORDER BY 1;
SELECT COUNT(*) AS fact_rows FROM fact_sales;
SQL

  local after_facts
  if ! after_facts=$(vsql_scalar "SELECT COUNT(*) FROM fact_sales;"); then
    err "fact_sales is unreadable after the revive — the revive did not restore the catalog"
    return 1
  fi
  if [[ "$before_facts" == "$after_facts" ]]; then
    ok "revive demo PASSED — ${after_facts} rows survived with zero local storage"
  else
    err "row count changed across the revive: ${before_facts} -> ${after_facts}"
    return 1
  fi

  # The CR deliberately stays on initPolicy: Revive. It cannot be switched back
  # (the field is immutable) and it does not need to be: Revive is a no-op once
  # the database exists, and phase_verticadb preserves whatever policy it finds.
  info "the VerticaDB now has initPolicy=Revive; that is expected and harmless"
}

# ---------------------------------------------------------------------------
#  restore — time travel to a saved restore point
# ---------------------------------------------------------------------------
demo_restore() {
  step "DEMO restore — save a restore point, add data, then roll back to it"
  note "GOAL: show time travel. A restore point is a saved marker in communal storage; the database can later be rebuilt exactly as it was at that moment, discarding everything after it."

  confirm "This rebuilds the database from a restore point, discarding later changes. Continue?" || return 1
  require_database

  say "creating an archive and saving a restore point"
  # The archive may already exist from an earlier run; CREATE ARCHIVE would then
  # fail, so it is issued outside the ON_ERROR_STOP block.
  vsql_c "CREATE ARCHIVE ${DEMO_RESTORE_ARCHIVE};" >/dev/null 2>&1 || \
    info "archive ${DEMO_RESTORE_ARCHIVE} already exists — reusing it"
  # NOTE: restore points are DDL here, not a meta-function. There is no
  # SAVE_RESTORE_POINT() in this release.
  vsql_in -v ON_ERROR_STOP=1 <<SQL
DROP TABLE IF EXISTS lab_timeline CASCADE;
CREATE TABLE lab_timeline (marker VARCHAR(32), noted TIMESTAMP DEFAULT NOW());
INSERT INTO lab_timeline (marker) VALUES ('before-restore-point');
COMMIT;
SELECT marker FROM lab_timeline ORDER BY 1;
SAVE RESTORE POINT TO ARCHIVE ${DEMO_RESTORE_ARCHIVE};
SQL

  say "restore points now available"
  vsql_in -v ON_ERROR_STOP=1 <<SQL
SELECT archive, state, save_time, vertica_version
FROM v_catalog.all_restore_points
WHERE archive = '${DEMO_RESTORE_ARCHIVE}' ORDER BY save_time;
SQL

  say "adding data AFTER the restore point — this is what we expect to lose"
  vsql_in -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO lab_timeline (marker) VALUES ('after-restore-point');
COMMIT;
SELECT marker FROM lab_timeline ORDER BY 1;
SQL

  say "destroying the database, then reviving AT the restore point"
  destroy_db_keep_communal
  # index 1 = the most recent restore point in the archive.
  render_verticadb Revive "$DEMO_RESTORE_ARCHIVE" 1 | apply_manifest "verticadb-restore"
  wait_db_ready

  say "state after the roll-back — 'after-restore-point' should be gone"
  vsql_in <<'SQL'
SELECT marker, noted FROM lab_timeline ORDER BY 1;
SQL

  local rows
  rows=$(vsql_scalar "SELECT COUNT(*) FROM lab_timeline;" 2>/dev/null || echo -1)
  if [[ "$rows" == "1" ]]; then
    ok "restore demo PASSED — the post-restore-point row was rolled back"
  else
    warn "expected 1 row in lab_timeline after the roll-back, found ${rows}"
  fi
  info "the VerticaDB now has initPolicy=Revive; that is expected and harmless"
}

# ---------------------------------------------------------------------------
#  resilience — kill the pod, let the operator heal it
# ---------------------------------------------------------------------------
demo_resilience() {
  step "DEMO resilience — delete the Vertica pod and watch it come back"
  note "GOAL: show self-healing. We destroy the running database process; the operator notices and rebuilds it, with no data lost and no human involved."

  require_database

  # lab_smoke is created by the smoke demo; make sure it exists before asserting.
  if [[ "$(vsql_scalar "SELECT COUNT(*) FROM v_catalog.tables WHERE table_name='lab_smoke';")" != "1" ]]; then
    info "lab_smoke is not present — running the smoke demo first"
    demo_smoke
  fi

  local pod before_rows
  pod=$(vertica_pod)
  if ! before_rows=$(vsql_scalar "SELECT COUNT(*) FROM lab_smoke;"); then
    err "could not read lab_smoke before the restart"; return 1
  fi
  info "pod ${pod} is serving ${before_rows} rows in lab_smoke"

  # The pod belongs to a StatefulSet, so its replacement gets the SAME name.
  # Waiting for the name to disappear is a race that usually fails: by the time
  # the check runs, the new pod already exists under the old name. Compare the
  # UID instead — it is unique per pod, so it changes exactly when the pod is
  # genuinely replaced.
  local uid
  uid=$(kcq -n "$VERTICA_NAMESPACE" get pod "$pod" -o jsonpath='{.metadata.uid}' || true)
  info "current pod UID: ${uid:-<unknown>}"

  say "deleting the pod"
  kc -n "$VERTICA_NAMESPACE" delete pod "$pod" --wait=false
  wait_for "the pod to be replaced (a different UID, or gone)" 600 \
    bash -c "[ \"\$(KUBECONFIG=${KUBECONFIG_PATH} kubectl -n ${VERTICA_NAMESPACE} get pod ${pod} -o jsonpath='{.metadata.uid}' 2>/dev/null)\" != \"${uid}\" ]"

  say "the operator recreates the pod and restarts the database"
  wait_db_ready 900

  say "state after recovery"
  vsql_in <<'SQL'
SELECT node_name, node_state FROM v_catalog.nodes;
SELECT COUNT(*) AS lab_smoke_rows FROM lab_smoke;
SQL

  local after_rows new_pod new_uid
  if ! after_rows=$(vsql_scalar "SELECT COUNT(*) FROM lab_smoke;"); then
    err "lab_smoke is unreadable after the restart"; return 1
  fi
  new_pod=$(vertica_pod)
  new_uid=$(kcq -n "$VERTICA_NAMESPACE" get pod "$new_pod" -o jsonpath='{.metadata.uid}' || true)
  info "new pod: ${new_pod}  (UID ${new_uid:-<unknown>})"
  if [[ -n "$uid" && "$uid" == "$new_uid" ]]; then
    err "the pod was never actually replaced — UID is unchanged"
    return 1
  fi
  if [[ "$before_rows" == "$after_rows" ]]; then
    ok "resilience demo PASSED — database recovered with ${after_rows} rows intact"
  else
    err "row count changed across the restart: ${before_rows} -> ${after_rows}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
#  scale — Eon elasticity
# ---------------------------------------------------------------------------
demo_scale() {
  step "DEMO scale — add a secondary subcluster, then remove it"
  note "GOAL: show elasticity. Because storage is shared, extra compute can be added and removed at will. A SUBCLUSTER is a group of nodes; secondary subclusters can come and go without affecting the database."

  confirm "This adds a second Vertica pod (${DEMO_SCALE_CPU} CPU / ${DEMO_SCALE_MEM}). It needs spare capacity on the VM. Continue?" || return 1
  require_database

  # The operator labels subcluster pods with vertica.com/subcluster-svc.
  # (There is no vertica.com/subcluster-name label — selecting on that silently
  # matches nothing, which makes every wait succeed or time out incorrectly.)
  local sc_selector="vertica.com/subcluster-svc=${DEMO_SCALE_SUBCLUSTER}"

  # Authoritative check: ask Vertica itself, not Kubernetes.
  sc_nodes_up() {
    vsql_scalar "SELECT COUNT(*) FROM v_catalog.nodes WHERE subcluster_name='${DEMO_SCALE_SUBCLUSTER}' AND node_state='UP';" 2>/dev/null || echo 0
  }

  say "cluster before"
  vsql_in -v ON_ERROR_STOP=1 <<'SQL'
SELECT node_name, node_state, subcluster_name FROM v_catalog.nodes ORDER BY 1;
SQL

  if [[ "$(sc_nodes_up)" != "0" ]]; then
    info "subcluster '${DEMO_SCALE_SUBCLUSTER}' already exists — removing it first"
  else
    say "adding secondary subcluster '${DEMO_SCALE_SUBCLUSTER}'"
    kc -n "$VERTICA_NAMESPACE" patch verticadb "$VDB_NAME" --type=json -p "$(cat <<JSON
[{"op":"add","path":"/spec/subclusters/-","value":{
  "name":"${DEMO_SCALE_SUBCLUSTER}",
  "size":1,
  "type":"secondary",
  "serviceType":"ClusterIP",
  "resources":{"requests":{"cpu":"${DEMO_SCALE_CPU}","memory":"${DEMO_SCALE_MEM}"}}
}}]
JSON
)"

    if wait_for "pod of subcluster '${DEMO_SCALE_SUBCLUSTER}' to be Ready" 900 \
        env KUBECONFIG="$KUBECONFIG_PATH" kubectl -n "$VERTICA_NAMESPACE" \
            wait --for=condition=Ready pod -l "$sc_selector" --timeout=30s \
       && wait_for "subcluster '${DEMO_SCALE_SUBCLUSTER}' to join the Vertica cluster" 600 \
            bash -c "[ \"\$(KUBECONFIG=${KUBECONFIG_PATH} kubectl -n ${VERTICA_NAMESPACE} exec ${VDB_NAME}-${VERTICA_SUBCLUSTER}-0 -c server -- env VSQL_PASSWORD=\"\$(KUBECONFIG=${KUBECONFIG_PATH} kubectl -n ${VERTICA_NAMESPACE} get secret ${VERTICA_SU_SECRET} -o jsonpath='{.data.password}' | base64 -d)\" vsql -U dbadmin -X -A -t -c \"SELECT COUNT(*) FROM v_catalog.nodes WHERE subcluster_name='${DEMO_SCALE_SUBCLUSTER}' AND node_state='UP';\" </dev/null 2>/dev/null)\" = 1 ]"
    then
      say "cluster after scale-out — a second node is now UP"
      vsql_in -v ON_ERROR_STOP=1 <<'SQL'
SELECT node_name, node_state, subcluster_name FROM v_catalog.nodes ORDER BY 1;
SELECT subcluster_name, is_primary, is_default FROM v_catalog.subclusters ORDER BY 1;
SQL
    else
      warn "the secondary subcluster did not come up. On a small VM this is almost"
      warn "always memory: check with"
      warn "  kubectl -n ${VERTICA_NAMESPACE} describe pod -l ${sc_selector}"
      warn "Lower DEMO_SCALE_MEM (currently ${DEMO_SCALE_MEM}) or skip this demo."
      warn "Removing the subcluster again so the lab is left as it was."
    fi
  fi

  say "removing the secondary subcluster"
  local idx
  idx=$(kcq -n "$VERTICA_NAMESPACE" get verticadb "$VDB_NAME" \
        -o "jsonpath={range .spec.subclusters[*]}{.name}{'\n'}{end}" 2>/dev/null \
        | grep -n "^${DEMO_SCALE_SUBCLUSTER}$" | cut -d: -f1 || true)
  if [[ -n "$idx" ]]; then
    kc -n "$VERTICA_NAMESPACE" patch verticadb "$VDB_NAME" --type=json \
      -p "[{\"op\":\"remove\",\"path\":\"/spec/subclusters/$((idx-1))\"}]"
    wait_for "pod of subcluster '${DEMO_SCALE_SUBCLUSTER}' to be removed" 900 \
      bash -c "[ -z \"\$(KUBECONFIG=${KUBECONFIG_PATH} kubectl -n ${VERTICA_NAMESPACE} get pods -l ${sc_selector} --no-headers 2>/dev/null)\" ]"
  else
    info "subcluster '${DEMO_SCALE_SUBCLUSTER}' is not in the CR — nothing to remove"
  fi

  say "cluster after scale-in — back to a single node"
  vsql_in -v ON_ERROR_STOP=1 <<'SQL'
SELECT node_name, node_state, subcluster_name FROM v_catalog.nodes ORDER BY 1;
SQL
  ok "scale demo complete"
}

# ---------------------------------------------------------------------------
#  wipe — drop the database and delete depot + communal storage
# ---------------------------------------------------------------------------
demo_wipe() {
  step "DEMO wipe — drop the database and DELETE depot + communal data"
  note "GOAL: show a complete teardown. Unlike the revive demo, this also empties the S3 bucket, so there is nothing left to revive from."

  confirm "This PERMANENTLY deletes the database, its local volumes AND all communal data under ${COMMUNAL_PATH}. Nothing is recoverable. Continue?" || return 1

  if db_is_up; then
    say "what is about to be destroyed"
    vsql_in <<'SQL'
SELECT current_database() AS database;
SELECT table_schema, table_name FROM v_catalog.tables WHERE table_schema='public' ORDER BY 2;
SQL
    communal_summary
  else
    info "database is not up; proceeding to remove whatever remains"
  fi

  say "deleting the database and local volumes"
  destroy_db_keep_communal

  say "deleting communal storage"
  purge_communal

  say "what is left in the bucket"
  kc -n "$MINIO_NAMESPACE" logs job/minio-purge 2>/dev/null | sed 's/^/    /' || true

  ok "wipe demo complete — the lab is now empty"
}

# ---------------------------------------------------------------------------
#  create — build a brand-new empty database
# ---------------------------------------------------------------------------
demo_create() {
  step "DEMO create — create a brand-new empty database"
  note "GOAL: build a fresh, empty database from nothing."

  if db_is_up; then
    confirm "A database is already running. Recreate it from scratch (all data lost)?" || return 1
    destroy_db_keep_communal
    purge_communal
  fi

  # initPolicy is immutable, so a leftover CR (possibly on Revive from an
  # earlier demo) has to go before a Create can be applied.
  if kcq -n "$VERTICA_NAMESPACE" get verticadb "$VDB_NAME" >/dev/null; then
    info "removing the existing VerticaDB so initPolicy can be set to Create"
    destroy_db_keep_communal
  fi

  say "creating database '${VERTICA_DB_NAME}' (initPolicy: Create)"
  render_verticadb Create | apply_manifest "verticadb"
  wait_db_ready

  say "the new, empty database"
  vsql_in <<'SQL'
SELECT current_database() AS database, version();
SELECT node_name, node_state, subcluster_name FROM v_catalog.nodes;
SELECT COUNT(*) AS user_tables FROM v_catalog.tables WHERE table_schema='public';
SELECT shard_type FROM v_catalog.shards;
SQL
  ok "create demo complete"
}

# ---------------------------------------------------------------------------
#  dispatcher
# ---------------------------------------------------------------------------
run_demo() {
  case "$1" in
    smoke)      demo_smoke ;;
    bulk)       demo_bulk ;;
    dbd)        demo_dbd ;;
    depot)      demo_depot ;;
    revive)     demo_revive ;;
    restore)    demo_restore ;;
    resilience) demo_resilience ;;
    scale)      demo_scale ;;
    wipe)       demo_wipe ;;
    create)     demo_create ;;
    all)
      demo_smoke; demo_bulk; demo_dbd; demo_depot; demo_resilience; demo_revive
      ok "all non-destructive demos completed"
      ;;
    *) err "unknown demo '$1'"; echo; list_demos; return 2 ;;
  esac
}

# ============================================================================
#  Uninstall
# ============================================================================

phase_uninstall() {
  step "Uninstall"

  if ! [[ -r "$KUBECONFIG_PATH" ]] && (( ! PURGE_K3S )); then
    warn "no kubeconfig at ${KUBECONFIG_PATH} — nothing in-cluster to remove"
  else
    info "removing VerticaDB ${VERTICA_NAMESPACE}/${VDB_NAME}"
    kc -n "$VERTICA_NAMESPACE" delete verticadb "$VDB_NAME" --ignore-not-found --timeout=5m || true

    info "removing the VerticaDB operator"
    if (( NO_EXEC )); then
      show_cmd "helm uninstall ${VDB_HELM_RELEASE} -n ${VDB_OPERATOR_NAMESPACE}"
      explain "Remove everything the operator's Helm chart installed."
    else
      have helm && KUBECONFIG="$KUBECONFIG_PATH" helm uninstall "$VDB_HELM_RELEASE" \
        -n "$VDB_OPERATOR_NAMESPACE" 2>/dev/null || true
    fi

    info "removing namespaces ${VERTICA_NAMESPACE}, ${MINIO_NAMESPACE}, ${VDB_OPERATOR_NAMESPACE}"
    kc delete namespace "$VERTICA_NAMESPACE" "$MINIO_NAMESPACE" "$VDB_OPERATOR_NAMESPACE" \
       --ignore-not-found --timeout=5m || true

    info "removing the VerticaDB CRDs"
    kc delete crd verticadbs.vertica.com verticaautoscalers.vertica.com \
       verticaeventtriggers.vertica.com verticarestorepointsqueries.vertica.com \
       verticascrutinizes.vertica.com --ignore-not-found || true
  fi

  if (( PURGE_K3S )); then
    info "purging k3s"
    if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
      run sudo /usr/local/bin/k3s-uninstall.sh
    else
      warn "/usr/local/bin/k3s-uninstall.sh not found — k3s may not be installed"
    fi
  else
    info "k3s left installed (pass --purge-k3s to remove it too)"
  fi

  run rm -rf "$RENDER_DIR"
  ok "uninstall complete"
  reverse_hint "./${SCRIPT_NAME} --install   (rebuilds the whole lab; it is idempotent)"
}

# ============================================================================
#  Summary
# ============================================================================

print_summary() {
  local pod
  pod=$(vertica_pod || true)
  cat <<SUMMARY

${C_BOLD}${C_GREEN}Vertica Eon Mode lab is ready.${C_RESET}

  ${C_BOLD}Database${C_RESET}     ${VERTICA_DB_NAME}  (Eon Mode, ${VERTICA_SUBCLUSTER_SIZE}-node subcluster '${VERTICA_SUBCLUSTER}')
  ${C_BOLD}Image${C_RESET}        ${VERTICA_IMAGE}
  ${C_BOLD}Operator${C_RESET}     chart ${VDB_HELM_CHART_VERSION:-latest}
  ${C_BOLD}Namespace${C_RESET}    ${VERTICA_NAMESPACE}
  ${C_BOLD}Communal${C_RESET}     ${COMMUNAL_PATH}  via ${MINIO_ENDPOINT}
  ${C_BOLD}Pod${C_RESET}          ${pod:-<none>}

${C_BOLD}Connect${C_RESET}  (vsql runs INSIDE the container, not on the VM)
  export KUBECONFIG=${KUBECONFIG_PATH}
  POD=\$(kubectl -n ${VERTICA_NAMESPACE} get pods -l app.kubernetes.io/instance=${VDB_NAME} -o jsonpath='{.items[0].metadata.name}')
  PW=\$(kubectl -n ${VERTICA_NAMESPACE} get secret ${VERTICA_SU_SECRET} -o jsonpath='{.data.password}' | base64 -d)
  kubectl -n ${VERTICA_NAMESPACE} exec -it "\$POD" -c server -- env VSQL_PASSWORD="\$PW" vsql -U dbadmin

  One-off query:
  kubectl -n ${VERTICA_NAMESPACE} exec "\$POD" -c server -- env VSQL_PASSWORD="\$PW" vsql -U dbadmin -c "SELECT table_name FROM v_catalog.tables ORDER BY 1;"

${C_BOLD}Try the demos${C_RESET}
  ./${SCRIPT_NAME} --list-demos          # catalogue with descriptions
  ./${SCRIPT_NAME} --demo bulk,dbd       # load a star schema, run Database Designer
  ./${SCRIPT_NAME} --demo revive --yes   # destroy local storage, revive from S3
  ./${SCRIPT_NAME} --demo all            # everything non-destructive

${C_BOLD}MinIO console${C_RESET} (optional, from the VM)
  kubectl -n ${MINIO_NAMESPACE} port-forward svc/${MINIO_SVC} 9001:9001

${C_BOLD}Teardown${C_RESET}  (each line is the exact opposite of the build you just ran)
  ./${SCRIPT_NAME} --demo wipe              # empty the database, keep the cluster
  ./${SCRIPT_NAME} --uninstall              # remove VerticaDB + operator + MinIO, keep k3s
  ./${SCRIPT_NAME} --uninstall --purge-k3s  # remove everything, Kubernetes included

  ${C_BOLD}Rebuild${C_RESET}
  ./${SCRIPT_NAME} --demo create            # opposite of --demo wipe
  ./${SCRIPT_NAME} --install                # opposite of --uninstall

SUMMARY
}

# ============================================================================
#  Main
# ============================================================================

main() {
  printf '%s%s — Vertica Eon Mode on Kubernetes (ARM64 lab)%s\n' "$C_BOLD" "$SCRIPT_NAME" "$C_RESET"
  # --help and --list-demos already returned; everything else needs the VM.
  require_linux_host
  (( DRY_RUN )) && warn "DRY RUN — no changes will be made; manifests render to ${RENDER_DIR}/"

  if (( DO_UNINSTALL )); then
    phase_uninstall
    exit 0
  fi

  if [[ -n "$DEMO_LIST" ]]; then
    if (( DRY_RUN )); then
      err "--dry-run and --demo are mutually exclusive: demos act on a live database"
      exit 2
    fi
    # Fail with an accurate reason before any demo starts.
    local d
    IFS=',' read -r -a _demos <<< "$DEMO_LIST"
    for d in "${_demos[@]}"; do
      d="${d// /}"
      case "$d" in
        ""|create) : ;;                 # 'create' builds the DB, so it may be absent
        *) require_database; break ;;
      esac
    done
    for d in "${_demos[@]}"; do
      d="${d// /}"
      [[ -n "$d" ]] || continue
      CURRENT_STEP="demo ${d}"
      run_demo "$d"
      reverse_hint "$(demo_reverse "$d")"
    done
    CURRENT_STEP="done"
    exit 0
  fi

  if [[ -n "$ONLY_PHASE" ]]; then
    case "$ONLY_PHASE" in
      preflight) phase_preflight ;;
      k3s)       phase_k3s ;;
      tools)     phase_tools ;;
      minio)     require_cluster; phase_minio ;;
      operator)  require_cluster; phase_operator ;;
      verticadb) require_cluster; phase_verticadb ;;
      smoke)     require_database; phase_smoke ;;
      *) err "unknown phase '${ONLY_PHASE}'"; usage; exit 2 ;;
    esac
    ok "phase '${ONLY_PHASE}' finished"
    reverse_hint "$(phase_reverse "$ONLY_PHASE")"
    exit 0
  fi

  phase_preflight
  phase_k3s
  phase_tools
  phase_minio
  phase_operator
  phase_verticadb
  phase_smoke

  (( NO_EXEC )) || print_summary
  CURRENT_STEP="done"
  ok "all phases complete"
  reverse_hint "./${SCRIPT_NAME} --uninstall   (add --purge-k3s to remove Kubernetes too)"
}

main "$@"
