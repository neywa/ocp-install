#!/usr/bin/env bash
#
# Deploy an OpenShift lab cluster on AWS (IPI), apply API/Ingress certs signed by
# a local CA, and bootstrap OpenShift GitOps.
#
# CLUSTER_NAME is the single source of truth for the cluster identity: it drives
# metadata.name in install-config, the cert SANs, and the console/API hostnames.
#
# Config resolution order (lowest to highest precedence):
#   built-in defaults  <  lab.env  <  environment  <  CLI flags
#
# See CLAUDE.md for the hard rule: no command here may touch a real cluster or AWS
# account. Use --dry-run and test/smoke.sh for static verification.

set -euo pipefail

# Generated files carry secret material (pull secret, private keys). Create them
# private from the start rather than relying solely on a later chmod, which
# leaves a world-readable window (F2).
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# --- Usage -------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") -d <base_domain> [OPTIONS]

Required:
  -d, --base-domain <domain>        Base domain for the cluster (e.g. mylab.example.com)

Cluster shape:
  -c, --cluster-name <name>         Cluster name / metadata.name (default: rbobek)
  -r, --region <region>             AWS region (default: eu-central-1)
      --control-plane-replicas <n>  Control-plane node count (default: 1)
      --worker-replicas <n>         Worker node count (default: 1)
      --control-plane-type <type>   Control-plane instance type (default: m6i.xlarge)
      --worker-type <type>          Worker instance type (default: m6i.xlarge)
      --ttl-days <n>                Days until the expirationDate userTag (default: 7)

Files:
  -f, --config <file>               install-config template path
                                    (default: \$SCRIPT_DIR/install-config-template.yaml)

Modules (optional products, see --list-modules):
      --with <a,b,c>                Enable modules on a fresh build (repeatable + comma-separated)
      --list-modules                List available modules with descriptions/floors and exit
      --add <a,b>                   Install modules into an EXISTING cluster (needs --dir)
      --remove <a,b>                Destroy modules in an EXISTING cluster (needs --dir)
      --dir <path>                  Install dir to target for --add / --remove

Behaviour:
      --dry-run                     Render install-config.yaml and exit (no cluster/AWS)
      --skip-certs                  Skip custom certificate generation/application
      --skip-gitops                 Skip OpenShift GitOps + Argo CD deployment
  -h, --help                        Show this help and exit

Configuration is read from \$SCRIPT_DIR/lab.env (copy lab.env.example) and the
environment. Precedence: defaults < lab.env < environment < CLI flags.

Example: $(basename "$0") -d mylab.example.com -c rbobek --ttl-days 5
EOF
}

# --- Parse CLI flags into CLI_* holders (highest precedence, applied last) ----
# Holders start unset so ": \${VAR:=...}" defaults and lab.env can fill the gaps;
# a holder that IS set overrides everything at the end.
CLI_BASE_DOMAIN=""
CLI_CLUSTER_NAME=""
CLI_AWS_REGION=""
CLI_CONTROL_PLANE_REPLICAS=""
CLI_WORKER_REPLICAS=""
CLI_CONTROL_PLANE_TYPE=""
CLI_WORKER_TYPE=""
CLI_TTL_DAYS=""
CLI_INSTALL_CONFIG_TEMPLATE=""
DRY_RUN=""
SKIP_CERTS=""
SKIP_GITOPS=""
# Module system holders. WITH_MODULES accumulates --with (repeatable + comma-
# separated); ADD/REMOVE select the against-an-existing-cluster modes; MODE is the
# derived operating mode.
WITH_MODULES=""
ADD_MODULES=""
REMOVE_MODULES=""
TARGET_DIR=""
LIST_MODULES=""
MODE="build"

# Accept "--flag value", "--flag=value", and short "-f value" forms.
die() { echo "Error: $*" >&2; exit 1; }
# Info/warning helpers, shared with sourced modules so hook code stays uniform.
log()  { echo "$*"; }
warn() { echo "Warning: $*" >&2; }

need_val() {
    # $1 = flag name, $2 = value (may be empty if the user gave none)
    [ -n "${2:-}" ] || die "flag $1 requires a value"
}

while [ $# -gt 0 ]; do
    arg="$1"
    val=""
    case "$arg" in
        --*=*) val="${arg#*=}"; arg="${arg%%=*}" ;;
    esac
    case "$arg" in
        -d|--base-domain)
            [ -n "$val" ] || { val="${2:-}"; shift; }; need_val "$arg" "$val"
            CLI_BASE_DOMAIN="$val" ;;
        -c|--cluster-name)
            [ -n "$val" ] || { val="${2:-}"; shift; }; need_val "$arg" "$val"
            CLI_CLUSTER_NAME="$val" ;;
        -r|--region)
            [ -n "$val" ] || { val="${2:-}"; shift; }; need_val "$arg" "$val"
            CLI_AWS_REGION="$val" ;;
        --control-plane-replicas)
            [ -n "$val" ] || { val="${2:-}"; shift; }; need_val "$arg" "$val"
            CLI_CONTROL_PLANE_REPLICAS="$val" ;;
        --worker-replicas)
            [ -n "$val" ] || { val="${2:-}"; shift; }; need_val "$arg" "$val"
            CLI_WORKER_REPLICAS="$val" ;;
        --control-plane-type)
            [ -n "$val" ] || { val="${2:-}"; shift; }; need_val "$arg" "$val"
            CLI_CONTROL_PLANE_TYPE="$val" ;;
        --worker-type)
            [ -n "$val" ] || { val="${2:-}"; shift; }; need_val "$arg" "$val"
            CLI_WORKER_TYPE="$val" ;;
        --ttl-days)
            [ -n "$val" ] || { val="${2:-}"; shift; }; need_val "$arg" "$val"
            CLI_TTL_DAYS="$val" ;;
        -f|--config)
            [ -n "$val" ] || { val="${2:-}"; shift; }; need_val "$arg" "$val"
            CLI_INSTALL_CONFIG_TEMPLATE="$val" ;;
        --with)
            [ -n "$val" ] || { val="${2:-}"; shift; }; need_val "$arg" "$val"
            WITH_MODULES="${WITH_MODULES:+$WITH_MODULES,}$val" ;;
        --add)
            [ -n "$val" ] || { val="${2:-}"; shift; }; need_val "$arg" "$val"
            ADD_MODULES="${ADD_MODULES:+$ADD_MODULES,}$val"; MODE="add" ;;
        --remove)
            [ -n "$val" ] || { val="${2:-}"; shift; }; need_val "$arg" "$val"
            REMOVE_MODULES="${REMOVE_MODULES:+$REMOVE_MODULES,}$val"; MODE="remove" ;;
        --dir)
            [ -n "$val" ] || { val="${2:-}"; shift; }; need_val "$arg" "$val"
            TARGET_DIR="$val" ;;
        --list-modules) LIST_MODULES=1 ;;
        --dry-run)     DRY_RUN=1 ;;
        --skip-certs)  SKIP_CERTS=1 ;;
        --skip-gitops) SKIP_GITOPS=1 ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "Unknown option: $arg" >&2; usage; exit 1 ;;
    esac
    shift
done

# --- Config resolution: defaults < lab.env < environment < CLI ----------------
# LAB_ENV path is env-overridable so the test harness can inject one without
# writing into the repo.
LAB_ENV="${LAB_ENV:-$SCRIPT_DIR/lab.env}"
# shellcheck disable=SC1090
if [ -f "$LAB_ENV" ]; then
    echo "Sourcing configuration from $LAB_ENV"
    source "$LAB_ENV"
fi

# Built-in defaults fill only what neither the environment nor lab.env set.
: "${CLUSTER_NAME:=rbobek}"
: "${AWS_REGION:=eu-central-1}"
: "${CONTROL_PLANE_REPLICAS:=1}"
: "${WORKER_REPLICAS:=1}"
: "${CONTROL_PLANE_TYPE:=m6i.xlarge}"
: "${WORKER_TYPE:=m6i.xlarge}"
: "${TTL_DAYS:=7}"
: "${OWNER:=rbobek}"
: "${PURPOSE:=lab}"
: "${OCP_VERSION:=}"
: "${WORKDIR_ROOT:=$SCRIPT_DIR/clusters}"   # fixed parent for all per-run install dirs
: "${PULL_SECRET_FILE:=$SCRIPT_DIR/pull-secret.txt}"
: "${INSTALL_CONFIG_TEMPLATE:=$SCRIPT_DIR/install-config-template.yaml}"
: "${CA_KEY_FILE:=$SCRIPT_DIR/certs/ca.key}"
: "${CA_CERT_FILE:=$SCRIPT_DIR/certs/ca.crt}"
# Workload namespaces the openshift-gitops Argo CD instance should manage. Each is
# labeled argocd.argoproj.io/managed-by=openshift-gitops (the GitOps operator then
# grants the application controller NAMESPACE-SCOPED rights there) plus a small
# monitoring Role — never cluster-admin. Must match the destination namespace(s) of
# the Argo CD Applications you deploy (see invaders-application.yaml). Space-separated.
: "${ARGOCD_MANAGED_NAMESPACES:=retro-invaders}"
# Module system: where modules live (env-overridable like LAB_ENV so the smoke test
# can point at scratch fixtures) and the modules enabled by config. --with appends to
# MODULES; resolution follows the usual defaults < lab.env < environment < flags.
: "${MODULES_DIR:=$SCRIPT_DIR/modules}"
: "${MODULES:=}"
# BASE_DOMAIN has no default; it is required.
: "${BASE_DOMAIN:=}"

# CLI flags win over everything.
[ -n "$CLI_BASE_DOMAIN" ]             && BASE_DOMAIN="$CLI_BASE_DOMAIN"
[ -n "$CLI_CLUSTER_NAME" ]            && CLUSTER_NAME="$CLI_CLUSTER_NAME"
[ -n "$CLI_AWS_REGION" ]              && AWS_REGION="$CLI_AWS_REGION"
[ -n "$CLI_CONTROL_PLANE_REPLICAS" ] && CONTROL_PLANE_REPLICAS="$CLI_CONTROL_PLANE_REPLICAS"
[ -n "$CLI_WORKER_REPLICAS" ]        && WORKER_REPLICAS="$CLI_WORKER_REPLICAS"
[ -n "$CLI_CONTROL_PLANE_TYPE" ]     && CONTROL_PLANE_TYPE="$CLI_CONTROL_PLANE_TYPE"
[ -n "$CLI_WORKER_TYPE" ]            && WORKER_TYPE="$CLI_WORKER_TYPE"
[ -n "$CLI_TTL_DAYS" ]               && TTL_DAYS="$CLI_TTL_DAYS"
[ -n "$CLI_INSTALL_CONFIG_TEMPLATE" ] && INSTALL_CONFIG_TEMPLATE="$CLI_INSTALL_CONFIG_TEMPLATE"

# --- Derive everything from the single source of truth ------------------------
API_HOST="api.${CLUSTER_NAME}.${BASE_DOMAIN}"
CONSOLE_HOST="console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
INGRESS_WILDCARD="*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
EXPIRATION_DATE="$(date -u -d "+${TTL_DAYS} days" +%Y-%m-%d 2>/dev/null || true)"

# --- Locate the openshift-install binary --------------------------------------
# Prefer ./<OCP_VERSION>/openshift-install, then ./openshift-install, then PATH.
# This replaces the old workflow of copying the script into a version subdir.
locate_openshift_install() {
    if [ -n "$OCP_VERSION" ] && [ -x "./${OCP_VERSION}/openshift-install" ]; then
        echo "./${OCP_VERSION}/openshift-install"
    elif [ -x "./openshift-install" ]; then
        echo "./openshift-install"
    elif command -v openshift-install >/dev/null 2>&1; then
        command -v openshift-install
    else
        echo ""
    fi
}
OPENSHIFT_INSTALL="$(locate_openshift_install)"

# --- xtrace guards around secret handling ------------------------------------
# `bash -x` would otherwise print the pull secret to stderr the moment it lands
# in a shell variable (F3). secret_xtrace_off records whether tracing was on and
# disables it; secret_xtrace_restore turns it back on ONLY if it was on, so a
# user debugging with -x keeps tracing everywhere else.
_SECRET_XTRACE=0
secret_xtrace_off()     { case $- in *x*) _SECRET_XTRACE=1;; *) _SECRET_XTRACE=0;; esac; set +x; }
secret_xtrace_restore() { [ "$_SECRET_XTRACE" = 1 ] && set -x; return 0; }

# --- Cluster-operator settle helper ------------------------------------------
# Wait a ClusterOperator through a full rollout cycle after a change: it starts
# Progressing (which we may miss, so that wait is tolerant), then must return to
# Progressing=False, Available=True, Degraded=False.
wait_co_settled() {
    local co="$1" timeout="${2:-900s}"
    echo "Waiting for clusteroperator/${co} to settle (timeout ${timeout})..."
    # It may not have observed the change yet; tolerate this initial wait timing out.
    oc wait --for=condition=Progressing=True "clusteroperator/${co}" --timeout=120s 2>/dev/null || true
    oc wait --for=condition=Progressing=False "clusteroperator/${co}" --timeout="$timeout"
    oc wait --for=condition=Available=True   "clusteroperator/${co}" --timeout="$timeout"
    oc wait --for=condition=Degraded=False   "clusteroperator/${co}" --timeout="$timeout"
    echo "clusteroperator/${co} settled."
}

# --- Append a CA to the kubeconfig's existing trust bundle --------------------
# Patches the EXISTING cluster entry (derived from the current context, not
# assumed from CLUSTER_NAME) and APPENDS the CA to the existing
# certificate-authority-data rather than replacing it. Fails loudly on empty
# lookups so a bad kubeconfig aborts the run under set -e.
append_ca_to_kubeconfig() {
    local kubeconfig="$1" ca_file="$2"
    local ctx cluster existing tmp

    # || true so the explicit emptiness checks below own the error path (a failing
    # oc would otherwise trip set -e before the friendly message).
    ctx="$(oc --kubeconfig="$kubeconfig" config current-context 2>/dev/null || true)"
    [ -n "$ctx" ] || { echo "Error: could not determine current-context from $kubeconfig" >&2; return 1; }

    cluster="$(oc --kubeconfig="$kubeconfig" config view \
        -o jsonpath="{.contexts[?(@.name==\"$ctx\")].context.cluster}" 2>/dev/null || true)"
    [ -n "$cluster" ] || { echo "Error: could not resolve cluster for context '$ctx'" >&2; return 1; }

    echo "Appending CA to kubeconfig cluster entry '$cluster' (context '$ctx')..."
    tmp="$(mktemp)"
    # Decode the existing embedded CA bundle (installer kubeconfigs embed -data).
    existing="$(oc --kubeconfig="$kubeconfig" config view --raw \
        -o jsonpath="{.clusters[?(@.name==\"$cluster\")].cluster.certificate-authority-data}" 2>/dev/null || true)"
    if [ -n "$existing" ]; then
        printf '%s' "$existing" | base64 -d > "$tmp"
    fi
    cat "$ca_file" >> "$tmp"
    oc --kubeconfig="$kubeconfig" config set-cluster "$cluster" \
        --certificate-authority="$tmp" --embed-certs=true
    rm -f "$tmp"
}

# --- Wait until a named object exists -----------------------------------------
# `oc wait` cannot wait for creation, so poll `oc get` until the object appears.
# An empty namespace argument means cluster-scoped (no -n flag).
wait_for_object() {
    local kind="$1" name="$2" ns="$3" timeout="${4:-300s}"
    # Expected form is "<n>s"; strip the trailing 's' and fall back to 300 if the
    # caller ever passes a non-numeric value, so the arithmetic below can't throw.
    local secs="${timeout%s}" waited=0
    [[ "$secs" =~ ^[0-9]+$ ]] || secs=300
    local nsflag=()
    [ -n "$ns" ] && nsflag=(-n "$ns")
    echo "Waiting for ${kind}/${name}${ns:+ in $ns} to appear (timeout ${timeout})..."
    while ! oc get "$kind" "$name" "${nsflag[@]}" >/dev/null 2>&1; do
        if [ "$waited" -ge "$secs" ]; then
            echo "Error: timed out waiting for ${kind}/${name}${ns:+ in $ns} to appear" >&2
            return 1
        fi
        sleep 5
        waited=$((waited + 5))
    done
    echo "${kind}/${name} exists."
}

# --- Scope Argo CD to a workload namespace (no cluster-admin) -----------------
# The default openshift-gitops Argo CD instance can only manage namespaces it is
# authorized for; an arbitrary target namespace gets "forbidden" on every apply.
# Label it argocd.argoproj.io/managed-by=openshift-gitops so the GitOps operator
# grants the application controller NAMESPACE-SCOPED rights there, then add a small
# Role for the monitoring CRDs (PrometheusRule/Probe) the operator's managed-
# namespace role does not cover. Everything stays namespaced — the controller gains
# no cross-namespace or Secret-read access. Idempotent (create|apply). See README
# "Open questions".
grant_argocd_namespace() {
    local ns="$1"
    local sa="openshift-gitops:openshift-gitops-argocd-application-controller"
    echo "Scoping Argo CD to namespace '$ns' (managed-by label + monitoring role)..."
    oc create namespace "$ns" --dry-run=client -o yaml | oc apply -f -
    oc label namespace "$ns" argocd.argoproj.io/managed-by=openshift-gitops --overwrite
    oc create role argocd-monitoring-manager -n "$ns" \
        --verb=get,list,watch,create,update,patch,delete \
        --resource=prometheusrules.monitoring.coreos.com,probes.monitoring.coreos.com \
        --dry-run=client -o yaml | oc apply -f -
    oc create rolebinding argocd-monitoring-manager -n "$ns" \
        --role=argocd-monitoring-manager \
        --serviceaccount="$sa" \
        --dry-run=client -o yaml | oc apply -f -
}

# =============================================================================
# Module system
# =============================================================================
# Optional products (RHACS, RHACM, OADP, Logging, …) are modules under
# modules/<name>/module.sh, sourced by this script. Dispatch is PHASE-MAJOR: the
# main flow loops over phases and, within each, over the enabled modules. Metadata
# globals a module sets at source time are snapshotted here into per-module arrays;
# hooks are functions named <name>_<hook> so two modules never collide. See CLAUDE.md.

declare -A MOD_DESCRIPTION MOD_REQUIRES MOD_MIN_WORKERS MOD_MIN_WORKER_TYPE MOD_CREATES_AWS MOD_LOADED MOD_FAILED
RESOLVED_ORDER=()      # dependency-resolved, deterministic install order
MODULE_FAILURES=()     # "<module> (<phase>)" entries for the end-of-run summary

# Instance-type ranking. Instance types are NOT lexically ordered ("2xlarge" sorts
# before "xlarge"), so a module's worker-type floor is compared through this explicit
# table. Extend it as modules need bigger workers; a type absent here is a hard error
# rather than a guess. Sizes are ranked by ordinal within a family; cross-family
# comparison is by that ordinal, which is good enough for a floor check.
declare -A WORKER_TYPE_RANK=(
    [m6i.large]=1  [m6i.xlarge]=2  [m6i.2xlarge]=3  [m6i.4xlarge]=4
    [m6i.8xlarge]=5 [m6i.12xlarge]=6 [m6i.16xlarge]=7 [m6i.24xlarge]=8
    [m5.large]=1   [m5.xlarge]=2   [m5.2xlarge]=3   [m5.4xlarge]=4
    [m5.8xlarge]=5  [m5.12xlarge]=6  [m5.16xlarge]=7  [m5.24xlarge]=8
)

# List discoverable module names (basename of each modules/<name>/module.sh).
discover_modules() {
    [ -d "$MODULES_DIR" ] || return 0
    local f
    for f in "$MODULES_DIR"/*/module.sh; do
        [ -f "$f" ] || continue
        basename "$(dirname "$f")"
    done
}

# Source a module once and snapshot its metadata. Fails clearly on a malformed
# module (missing description or install hook). Metadata globals are cleared before
# and after the source so an omitted field can never inherit a previous module's value.
load_module() {
    local name="$1"
    [ -n "${MOD_LOADED[$name]:-}" ] && return 0
    local file="$MODULES_DIR/$name/module.sh"
    [ -f "$file" ] || die "module '$name' not found (expected $file)"
    unset MODULE_DESCRIPTION MODULE_REQUIRES MODULE_MIN_WORKERS MODULE_MIN_WORKER_TYPE MODULE_CREATES_AWS
    # shellcheck disable=SC1090
    source "$file"
    [ -n "${MODULE_DESCRIPTION:-}" ] || die "module '$name' is malformed: MODULE_DESCRIPTION is not set"
    declare -F "${name}_install" >/dev/null || die "module '$name' is malformed: no ${name}_install hook defined"
    MOD_DESCRIPTION[$name]="$MODULE_DESCRIPTION"
    MOD_REQUIRES[$name]="${MODULE_REQUIRES:-}"
    MOD_MIN_WORKERS[$name]="${MODULE_MIN_WORKERS:-}"
    MOD_MIN_WORKER_TYPE[$name]="${MODULE_MIN_WORKER_TYPE:-}"
    MOD_CREATES_AWS[$name]="${MODULE_CREATES_AWS:-false}"
    MOD_LOADED[$name]=1
    unset MODULE_DESCRIPTION MODULE_REQUIRES MODULE_MIN_WORKERS MODULE_MIN_WORKER_TYPE MODULE_CREATES_AWS
}

# DFS with gray/black marking: expand REQUIRES transitively, detect cycles, and emit
# a deterministic order (dependencies before dependents, sorted tie-break).
declare -A _DEP_STATE
_dep_visit() {
    local name="$1" path="$2"
    case "${_DEP_STATE[$name]:-}" in
        2) return 0 ;;
        1) die "module dependency cycle detected: ${path} -> ${name}" ;;
    esac
    load_module "$name"
    _DEP_STATE[$name]=1
    local req
    for req in $(printf '%s\n' ${MOD_REQUIRES[$name]:-} | sort); do
        [ -n "$req" ] || continue
        _dep_visit "$req" "${path:+$path -> }${name}"
    done
    _DEP_STATE[$name]=2
    RESOLVED_ORDER+=("$name")
}

resolve_dependencies() {
    RESOLVED_ORDER=()
    _DEP_STATE=()
    local requested=("$@") m
    for m in $(printf '%s\n' "$@" | sort -u); do
        _dep_visit "$m" ""
    done
    # Announce when dependency expansion pulled in more than was asked for.
    local req_sorted res_sorted
    req_sorted="$(printf '%s\n' "${requested[@]}" | sort -u | tr '\n' ' ')"
    res_sorted="$(printf '%s\n' "${RESOLVED_ORDER[@]}" | sort -u | tr '\n' ' ')"
    if [ "$req_sorted" != "$res_sorted" ]; then
        log "Modules: requested [${req_sorted% }] -> resolved with dependencies [${res_sorted% }]"
    fi
    log "Module install order: ${RESOLVED_ORDER[*]}"
}

# Raise the worker pool to the largest floor any enabled module needs. BUILD MODE
# ONLY — on --add the cluster already exists and cannot be resized (see run_add_mode).
# Never scales below what the user asked for; fails clearly on a type not in the table.
resolve_sizing() {
    local modules=("$@") m
    [ -n "${WORKER_TYPE_RANK[$WORKER_TYPE]:-}" ] || \
        die "worker instance type '$WORKER_TYPE' is not in WORKER_TYPE_RANK; add it to the ranking table"
    local max_workers="$WORKER_REPLICAS" src_workers=""
    local floor_type="" src_type=""
    for m in "${modules[@]}"; do
        local mw="${MOD_MIN_WORKERS[$m]:-}" mt="${MOD_MIN_WORKER_TYPE[$m]:-}"
        if [ -n "$mw" ] && [ "$mw" -gt "$max_workers" ]; then
            max_workers="$mw"; src_workers="$m"
        fi
        if [ -n "$mt" ]; then
            [ -n "${WORKER_TYPE_RANK[$mt]:-}" ] || \
                die "module '$m' requires worker type '$mt', which is not in WORKER_TYPE_RANK"
            if [ -z "$floor_type" ] || [ "${WORKER_TYPE_RANK[$mt]}" -gt "${WORKER_TYPE_RANK[$floor_type]}" ]; then
                floor_type="$mt"; src_type="$m"
            fi
        fi
    done
    if [ "$max_workers" -gt "$WORKER_REPLICAS" ]; then
        log "SIZING: module '$src_workers' requires >= $max_workers workers; raising WORKER_REPLICAS $WORKER_REPLICAS -> $max_workers"
        WORKER_REPLICAS="$max_workers"
    fi
    if [ -n "$floor_type" ] && [ "${WORKER_TYPE_RANK[$floor_type]}" -gt "${WORKER_TYPE_RANK[$WORKER_TYPE]}" ]; then
        log "SIZING: module '$src_type' requires worker type >= $floor_type; raising WORKER_TYPE $WORKER_TYPE -> $floor_type"
        WORKER_TYPE="$floor_type"
    fi
}

# --add only: sizing cannot be applied to a live cluster, so its capacity must
# already meet the floor. Prints an error and returns 1 on a shortfall.
check_live_capacity() {
    local m="$1"
    local need_w="${MOD_MIN_WORKERS[$m]:-}" need_t="${MOD_MIN_WORKER_TYPE[$m]:-}"
    [ -n "$need_w$need_t" ] || return 0
    local worker_count
    worker_count="$(oc get nodes -l node-role.kubernetes.io/worker -o name 2>/dev/null | wc -l | tr -d ' ')"
    if [ -n "$need_w" ] && [ "${worker_count:-0}" -lt "$need_w" ]; then
        echo "module '$m' needs >= $need_w worker node(s) but the cluster has ${worker_count:-0}"
        return 1
    fi
    if [ -n "$need_t" ]; then
        local need_r="${WORKER_TYPE_RANK[$need_t]:-}"
        [ -n "$need_r" ] || { echo "module '$m' requires worker type '$need_t' not in WORKER_TYPE_RANK"; return 1; }
        local types best=0 t
        types="$(oc get nodes -l node-role.kubernetes.io/worker \
            -o jsonpath='{.items[*].metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || true)"
        for t in $types; do
            local r="${WORKER_TYPE_RANK[$t]:-0}"
            [ "$r" -gt "$best" ] && best="$r"
        done
        if [ "$best" -lt "$need_r" ]; then
            echo "module '$m' needs worker type >= $need_t but the cluster's largest worker is below that"
            return 1
        fi
    fi
    return 0
}

# Build-mode module preflight (mode=build) collects ALL errors and aborts before any
# resource is created — the "fail in seconds" guarantee. Add-mode (mode=add) also
# checks live capacity against each module's floor. Hooks MUST NOT create anything.
run_module_preflight() {
    local mode="$1"; shift
    local modules=("$@") m errors=()
    for m in "${modules[@]}"; do
        log "[preflight] module '$m'..."
        if [ "$mode" = "add" ]; then
            local cap_err
            cap_err="$(check_live_capacity "$m")" || errors+=("$cap_err")
        fi
        if declare -F "${m}_preflight" >/dev/null; then
            local out
            if ! out="$("${m}_preflight" 2>&1)"; then
                errors+=("module '$m' preflight failed:${out:+ $out}")
            fi
        fi
    done
    if [ "${#errors[@]}" -gt 0 ]; then
        echo "Module preflight failed with ${#errors[@]} error(s):" >&2
        local e; for e in "${errors[@]}"; do echo "  - $e" >&2; done
        exit 1
    fi
    log "Module preflight passed (${#modules[@]} module(s))."
}

# A module is blocked if it failed earlier or any module it REQUIRES failed — never
# install a dependent onto a broken dependency.
_module_blocked() {
    local m="$1" req
    [ -n "${MOD_FAILED[$m]:-}" ] && return 0
    for req in ${MOD_REQUIRES[$m]:-}; do
        [ -n "${MOD_FAILED[$req]:-}" ] && return 0
    done
    return 1
}

# Phase-major dispatcher for provision/install/wait/verify (continue-on-failure).
# A missing hook is skipped. A failing hook is recorded and its module's later phases
# are skipped; the run continues and the failure is reported in the end-of-run summary.
# Calling the hook inside `if` suspends set -e / the ERR trap (as wait_co_settled does).
run_module_phase() {
    local hook="$1"; shift
    local modules=("$@") m
    for m in "${modules[@]}"; do
        if _module_blocked "$m"; then
            warn "module '$m' skipped for '$hook' (it or a dependency failed earlier)"
            continue
        fi
        declare -F "${m}_${hook}" >/dev/null || continue
        log "[$hook] module '$m'..."
        if "${m}_${hook}"; then
            :
        else
            MOD_FAILED[$m]=1
            MODULE_FAILURES+=("$m ($hook)")
            warn "module '$m' failed during '$hook'"
        fi
    done
}

# Per-cluster state: which modules are installed, one name per line, in the install
# dir so --remove and teardown know what to clean up.
_state_file() { echo "${INSTALL_DIR}/modules.state"; }
state_add_module() {
    local f; f="$(_state_file)"
    touch "$f"; chmod 600 "$f"
    grep -qxF "$1" "$f" 2>/dev/null || echo "$1" >> "$f"
}
state_remove_module() {
    local f; f="$(_state_file)"
    [ -f "$f" ] || return 0
    grep -vxF "$1" "$f" > "$f.tmp" 2>/dev/null || true
    mv "$f.tmp" "$f"
}
state_list_modules() {
    local f; f="$(_state_file)"
    [ -f "$f" ] && cat "$f" || true
}

# Print the correct teardown sequence. If modules are installed they must be removed
# FIRST (their destroy hooks clean up cluster-external AWS resources that
# `openshift-install destroy` will not touch), THEN the cluster is destroyed.
print_teardown_hint() {
    local installed; installed="$(state_list_modules | tr '\n' ' ')"; installed="${installed% }"
    if [ -n "$installed" ]; then
        echo "  # This cluster has modules installed: $installed"
        echo "  # Remove them first (runs destroy hooks, incl. AWS cleanup):"
        echo "  $0 --remove ${installed// /,} --dir $INSTALL_DIR"
        local m
        for m in $installed; do
            load_module "$m" 2>/dev/null || true
            declare -F "${m}_destroy" >/dev/null 2>&1 || \
                echo "  #   note: module '$m' has no destroy hook (may orphan resources)"
        done
        echo "  # Then destroy the cluster:"
    fi
    echo "  $OPENSHIFT_INSTALL destroy cluster --dir=$INSTALL_DIR"
}

# Report module failures at the very end (continue-on-failure). Returns 1 if any.
report_module_failures() {
    [ "${#MODULE_FAILURES[@]}" -eq 0 ] && return 0
    echo "" >&2
    echo "MODULE FAILURES (${#MODULE_FAILURES[@]}):" >&2
    local f; for f in "${MODULE_FAILURES[@]}"; do echo "  - $f" >&2; done
    return 1
}

# Print available modules with descriptions and resource floors (--list-modules).
list_modules() {
    local name floor any=0
    for name in $(discover_modules | sort); do
        any=1
        load_module "$name"
        floor=""
        [ -n "${MOD_MIN_WORKERS[$name]}" ]     && floor+="workers>=${MOD_MIN_WORKERS[$name]} "
        [ -n "${MOD_MIN_WORKER_TYPE[$name]}" ] && floor+="type>=${MOD_MIN_WORKER_TYPE[$name]} "
        [ -n "${MOD_REQUIRES[$name]}" ]        && floor+="requires:${MOD_REQUIRES[$name]// /,} "
        [ "${MOD_CREATES_AWS[$name]}" = "true" ] && floor+="(creates AWS resources) "
        printf '  %-16s %s\n' "$name" "${MOD_DESCRIPTION[$name]}"
        [ -n "$floor" ] && printf '  %-16s   floor: %s\n' "" "${floor% }"
    done
    [ "$any" = 1 ] || echo "  (no modules found in $MODULES_DIR)"
}

# --add / --remove target an EXISTING cluster: require --dir and its kubeconfig.
require_target_dir() {
    [ -n "$TARGET_DIR" ] || die "--add/--remove require --dir <install-dir>"
    [ -d "$TARGET_DIR" ] || die "--dir not found: $TARGET_DIR"
    local kc="$TARGET_DIR/auth/kubeconfig"
    [ -f "$kc" ] || die "kubeconfig not found in --dir: $kc"
    INSTALL_DIR="$TARGET_DIR"
    export KUBECONFIG="$kc"
    log "Targeting existing cluster in $INSTALL_DIR (KUBECONFIG set)."
}

# --add: preflight (with live-capacity check) then install/wait/verify. No cluster
# build, no certs, no gitops. Sizing cannot be applied — preflight hard-fails on a
# too-small cluster rather than leaving pods Pending.
run_add_mode() {
    require_target_dir
    run_module_preflight add "${RESOLVED_ORDER[@]}"
    run_module_phase install "${RESOLVED_ORDER[@]}"
    run_module_phase wait    "${RESOLVED_ORDER[@]}"
    run_module_phase verify  "${RESOLVED_ORDER[@]}"
    local m
    for m in "${RESOLVED_ORDER[@]}"; do
        [ -n "${MOD_FAILED[$m]:-}" ] || state_add_module "$m"
    done
    report_module_failures || die "one or more modules failed (see summary above)"
    log "Add complete."
}

# --remove: run destroy hooks in REVERSE dependency order (dependents before
# dependencies). A module with no destroy hook is logged so orphaned resources are visible.
run_remove_mode() {
    require_target_dir
    local i m
    for (( i=${#RESOLVED_ORDER[@]}-1; i>=0; i-- )); do
        m="${RESOLVED_ORDER[$i]}"
        if declare -F "${m}_destroy" >/dev/null; then
            run_module_phase destroy "$m"
        else
            warn "module '$m' has no destroy hook; nothing removed for it (possible orphaned resources)"
        fi
        [ -n "${MOD_FAILED[$m]:-}" ] || state_remove_module "$m"
    done
    report_module_failures || die "one or more modules failed to destroy (see summary above)"
    log "Remove complete."
}

# --- ERR trap: never leave a half-built cluster running silently --------------
# On any failure after provisioning has begun, print the exact destroy command.
on_err() {
    local rc=$?
    echo "ERROR: deployment failed (exit $rc)." >&2
    if [ -n "${INSTALL_DIR:-}" ] && [ -f "${INSTALL_DIR}/metadata.json" ]; then
        echo "A cluster exists in AWS (dir=${INSTALL_DIR}). If you want to tear it down:" >&2
        print_teardown_hint >&2
    fi
    exit "$rc"
}

# --- Preflight: collect ALL errors, then exit once ----------------------------
preflight() {
    local errors=()

    # BASE_DOMAIN is required.
    [ -n "$BASE_DOMAIN" ] || errors+=("base domain not specified (-d/--base-domain)")

    # TTL_DAYS must be a positive integer (so the derived date is well-formed).
    if ! [[ "$TTL_DAYS" =~ ^[0-9]+$ ]]; then
        errors+=("--ttl-days must be a non-negative integer (got '$TTL_DAYS')")
    elif [ -z "$EXPIRATION_DATE" ]; then
        errors+=("could not derive expirationDate from --ttl-days=$TTL_DAYS")
    fi

    # Required tools.
    local tool
    for tool in oc openssl sed awk date; do
        command -v "$tool" >/dev/null 2>&1 || errors+=("required tool not found on PATH: $tool")
    done
    [ -n "$OPENSHIFT_INSTALL" ] || errors+=("openshift-install not found (looked in ./${OCP_VERSION:-<OCP_VERSION>}/, ./, and PATH)")

    # Install-config template.
    [ -f "$INSTALL_CONFIG_TEMPLATE" ] || errors+=("install-config template not found: $INSTALL_CONFIG_TEMPLATE")

    # Pull secret: present and JSON-shaped.
    if [ ! -f "$PULL_SECRET_FILE" ]; then
        errors+=("pull secret file not found: $PULL_SECRET_FILE")
    else
        local ps trimmed
        secret_xtrace_off
        ps="$(tr -d '[:space:]' < "$PULL_SECRET_FILE")"
        trimmed="$ps"
        local shaped=1
        [[ "$trimmed" == \{* && "$trimmed" == *\} && "$trimmed" == *'"auths"'* ]] || shaped=0
        secret_xtrace_restore
        if [ "$shaped" -eq 0 ]; then
            errors+=("pull secret does not look like JSON with an \"auths\" object: $PULL_SECRET_FILE")
        elif command -v jq >/dev/null 2>&1; then
            jq -e . "$PULL_SECRET_FILE" >/dev/null 2>&1 || errors+=("pull secret is not valid JSON (jq): $PULL_SECRET_FILE")
        fi
    fi

    # CA files, unless certs are skipped.
    if [ -z "$SKIP_CERTS" ]; then
        [ -f "$CA_KEY_FILE" ]  || errors+=("CA key not found: $CA_KEY_FILE (or pass --skip-certs)")
        [ -f "$CA_CERT_FILE" ] || errors+=("CA cert not found: $CA_CERT_FILE (or pass --skip-certs)")
    fi

    # AWS checks only when the aws CLI is available (read-only).
    if command -v aws >/dev/null 2>&1; then
        if ! aws sts get-caller-identity >/dev/null 2>&1; then
            errors+=("aws sts get-caller-identity failed (no valid AWS credentials?)")
        fi
        if [ -n "$BASE_DOMAIN" ]; then
            local zones
            zones="$(aws route53 list-hosted-zones-by-name --dns-name "$BASE_DOMAIN" \
                        --query "HostedZones[].Name" --output text 2>/dev/null || true)"
            case " $zones " in
                *" ${BASE_DOMAIN}. "*|*" ${BASE_DOMAIN} "*) : ;;
                *) errors+=("no Route53 hosted zone matching base domain '$BASE_DOMAIN'") ;;
            esac
        fi
    else
        echo "Note: aws CLI not found; skipping AWS credential and Route53 preflight checks."
    fi

    if [ "${#errors[@]}" -gt 0 ]; then
        echo "Preflight failed with ${#errors[@]} error(s):" >&2
        local e
        for e in "${errors[@]}"; do
            echo "  - $e" >&2
        done
        exit 1
    fi
    echo "Preflight checks passed."
}

# --- Module resolution & mode dispatch ---------------------------------------
# Merge the configured MODULES set with repeated/comma-separated --with additions.
ENABLED_MODULES=()
_add_enabled() {  # split $1 on commas and whitespace into ENABLED_MODULES
    local item; local IFS=', '
    for item in $1; do [ -n "$item" ] && ENABLED_MODULES+=("$item"); done
}
[ -n "${MODULES// }" ] && _add_enabled "$MODULES"
[ -n "$WITH_MODULES" ] && _add_enabled "$WITH_MODULES"

# --list-modules prints and exits before any preflight or cluster work.
if [ -n "$LIST_MODULES" ]; then
    echo "Available modules (from $MODULES_DIR):"
    list_modules
    exit 0
fi

# In --add / --remove the target set comes from that flag, not --with / MODULES.
case "$MODE" in
    add)    ENABLED_MODULES=(); _add_enabled "$ADD_MODULES" ;;
    remove) ENABLED_MODULES=(); _add_enabled "$REMOVE_MODULES" ;;
esac

# Resolve dependencies (transitive, cycle-checked) into RESOLVED_ORDER.
if [ "${#ENABLED_MODULES[@]}" -gt 0 ]; then
    resolve_dependencies "${ENABLED_MODULES[@]}"
fi

# --add / --remove operate on an existing cluster: no build, no build preflight.
case "$MODE" in
    add)    run_add_mode;    exit 0 ;;
    remove) run_remove_mode; exit 0 ;;
esac

# Build mode: sizing must be resolved BEFORE install-config.yaml is rendered, so a
# module's worker-pool floor flows into the render below.
if [ "${#RESOLVED_ORDER[@]}" -gt 0 ]; then
    resolve_sizing "${RESOLVED_ORDER[@]}"
fi

preflight

# Module preflight for the build: every enabled module is validated before ANY
# resource is created, so an impossible combination fails in seconds.
if [ "${#RESOLVED_ORDER[@]}" -gt 0 ]; then
    run_module_preflight build "${RESOLVED_ORDER[@]}"
fi

# --- Prepare installation directory ------------------------------------------
# Every per-run dir lives under the fixed WORKDIR_ROOT parent so .gitignore can
# target the parent, not a leaf naming convention. Timestamped to the second so
# same-day reruns never collide.
INSTALL_DIR="${WORKDIR_ROOT}/${CLUSTER_NAME}-$(date +%Y%m%d-%H%M%S)"
echo "Creating installation directory: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
# Holds auth/kubeconfig, kubeadmin-password, the pull-secret-bearing config, and
# private keys — keep it owner-only, not the default world-traversable 0755 (F2).
chmod 700 "$INSTALL_DIR"

# --- Render install-config.yaml ----------------------------------------------
echo "Generating install-config.yaml in $INSTALL_DIR..."

RENDERED="$INSTALL_DIR/install-config.yaml"

# Step 1: substitute the safe __TOKEN__ placeholders (all values are
# alnum/dot/hyphen, safe for sed). The pull secret is handled separately below.
sed \
    -e "s#__BASE_DOMAIN__#${BASE_DOMAIN}#g" \
    -e "s#__CLUSTER_NAME__#${CLUSTER_NAME}#g" \
    -e "s#__AWS_REGION__#${AWS_REGION}#g" \
    -e "s#__CONTROL_PLANE_REPLICAS__#${CONTROL_PLANE_REPLICAS}#g" \
    -e "s#__WORKER_REPLICAS__#${WORKER_REPLICAS}#g" \
    -e "s#__CONTROL_PLANE_TYPE__#${CONTROL_PLANE_TYPE}#g" \
    -e "s#__WORKER_TYPE__#${WORKER_TYPE}#g" \
    -e "s#__OWNER__#${OWNER}#g" \
    -e "s#__PURPOSE__#${PURPOSE}#g" \
    -e "s#__EXPIRATION_DATE__#${EXPIRATION_DATE}#g" \
    "$INSTALL_CONFIG_TEMPLATE" > "$RENDERED.tmp"

# Step 2: inject the pull secret WITHOUT sed. It is JSON containing / + = and
# braces, which would be mangled by sed. Rewrite the whole pullSecret line in
# pure bash; JSON has no single quotes, so single-quoted YAML is safe.
secret_xtrace_off
PULL_SECRET_CONTENT="$(tr -d '\n' < "$PULL_SECRET_FILE")"
{
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" == pullSecret:* ]]; then
            printf "pullSecret: '%s'\n" "$PULL_SECRET_CONTENT"
        else
            printf '%s\n' "$line"
        fi
    done < "$RENDERED.tmp"
} > "$RENDERED"
rm -f "$RENDERED.tmp"
secret_xtrace_restore

# The rendered config embeds the pull secret; lock it down in every mode.
chmod 600 "$RENDERED"

echo "--- Generated install-config.yaml snippet ---"
# Never echo the pullSecret line: it embeds the pull secret. Show it redacted.
grep -E "baseDomain:|name:|region:|expirationDate:" "$RENDERED" || true
grep -q "^pullSecret:" "$RENDERED" && echo "pullSecret: <redacted>"
echo "------------------------------------------"

# --- Dry-run exit -------------------------------------------------------------
# Nothing below this point runs in dry-run mode, so no command can touch a real
# cluster or AWS account.
if [ -n "$DRY_RUN" ]; then
    echo "Dry-run: rendered install-config.yaml at $RENDERED"
    echo "Dry-run: cluster name '$CLUSTER_NAME' -> API host '$API_HOST'"
    echo "Dry-run: skipping cluster installation and all cluster/AWS operations."
    exit 0
fi

# From here on, any failure may leave a cluster running in AWS. Surface the
# destroy command via the ERR trap (dry-run already exited, so it never affects
# the smoke test).
trap on_err ERR

# openshift-install consumes install-config.yaml during the run; keep a backup.
# Deliberately redacted: this .bak is the only on-disk record of what was
# actually deployed (topology, region, tags), but the pull secret is stripped so
# a durable second copy of the credential never persists (F4).
sed "s#^pullSecret:.*#pullSecret: '<redacted>'#" "$RENDERED" > "$RENDERED.bak"
chmod 600 "$RENDERED.bak"
echo "Backed up rendered install-config to $RENDERED.bak (installer consumes the original)."

# --- Module provision (cluster-external resources, before the cluster) --------
# Runs before `create cluster` so a module can stand up S3/IAM the installer needs.
# No module uses this yet; the plumbing is built and dispatched.
if [ "${#RESOLVED_ORDER[@]}" -gt 0 ]; then
    run_module_phase provision "${RESOLVED_ORDER[@]}"
fi

# --- Start OpenShift cluster installation ------------------------------------
echo "Starting OpenShift cluster installation in directory: $INSTALL_DIR"
echo "This process can take 30-60 minutes or more."

"$OPENSHIFT_INSTALL" create cluster --dir="$INSTALL_DIR" --log-level=info

echo "OpenShift cluster installation successful!"
echo "Kubeconfig is located at: $INSTALL_DIR/auth/kubeconfig"
export KUBECONFIG="$INSTALL_DIR/auth/kubeconfig"

echo "Waiting for cluster operators to become available..."
oc wait --for=condition=Available clusteroperator/authentication --timeout=600s
oc wait --for=condition=Available clusteroperator/kube-apiserver --timeout=600s

# --- Custom certificate generation and application ---------------------------
if [ -z "$SKIP_CERTS" ]; then
    echo "--- Starting Custom Certificate Configuration ---"
    # Absolute cert dir so every openssl/oc arg is unambiguous (no cd/subshell).
    CERT_DIR="$(cd "$INSTALL_DIR" && pwd)/custom-certs"
    mkdir -p "$CERT_DIR"

    # openssl config files written to disk (no process substitution).
    cat > "$CERT_DIR/api-req.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
[req_distinguished_name]
[SAN]
subjectAltName = DNS:${API_HOST}
EOF
    cat > "$CERT_DIR/ingress-req.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
[req_distinguished_name]
[SAN]
subjectAltName = DNS:${INGRESS_WILDCARD},DNS:${CONSOLE_HOST}
EOF
    cat > "$CERT_DIR/api-ext.cnf" <<EOF
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:${API_HOST}
EOF
    cat > "$CERT_DIR/ingress-ext.cnf" <<EOF
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:${INGRESS_WILDCARD},DNS:${CONSOLE_HOST}
EOF

    echo "Generating private keys and CSRs for API and Ingress..."
    openssl genrsa -out "$CERT_DIR/api.key" 2048
    openssl genrsa -out "$CERT_DIR/ingress.key" 2048
    chmod 600 "$CERT_DIR/api.key" "$CERT_DIR/ingress.key"

    openssl req -new -key "$CERT_DIR/api.key" -out "$CERT_DIR/api.csr" \
        -subj "/CN=${API_HOST}" -reqexts SAN -config "$CERT_DIR/api-req.cnf"
    openssl req -new -key "$CERT_DIR/ingress.key" -out "$CERT_DIR/ingress.csr" \
        -subj "/CN=${INGRESS_WILDCARD}" -reqexts SAN -config "$CERT_DIR/ingress-req.cnf"

    echo "Signing certificates with the provided CA..."
    # -CAserial points at the cert dir so ca.srl does not land beside the user's CA.
    openssl x509 -req -in "$CERT_DIR/api.csr" -CA "$CA_CERT_FILE" -CAkey "$CA_KEY_FILE" \
        -CAcreateserial -CAserial "$CERT_DIR/ca.srl" -out "$CERT_DIR/api.crt" \
        -days 365 -sha256 -extfile "$CERT_DIR/api-ext.cnf"
    openssl x509 -req -in "$CERT_DIR/ingress.csr" -CA "$CA_CERT_FILE" -CAkey "$CA_KEY_FILE" \
        -CAcreateserial -CAserial "$CERT_DIR/ca.srl" -out "$CERT_DIR/ingress.crt" \
        -days 365 -sha256 -extfile "$CERT_DIR/ingress-ext.cnf"

    echo "Installing the CA trust bundle and TLS secrets..."
    # Idempotent: generate the manifest client-side, then apply it.
    oc create configmap custom-ca --from-file=ca-bundle.crt="$CA_CERT_FILE" -n openshift-config \
        --dry-run=client -o yaml | oc apply -f -
    oc patch proxy/cluster --type=merge --patch='{"spec":{"trustedCA":{"name":"custom-ca"}}}'

    oc create secret tls api-tls --cert="$CERT_DIR/api.crt" --key="$CERT_DIR/api.key" -n openshift-config \
        --dry-run=client -o yaml | oc apply -f -
    oc create secret tls ingress-tls --cert="$CERT_DIR/ingress.crt" --key="$CERT_DIR/ingress.key" -n openshift-ingress \
        --dry-run=client -o yaml | oc apply -f -

    # CRITICAL ORDERING: trust the CA locally BEFORE the apiserver starts serving
    # the new cert, or every subsequent oc call loses its connection.
    echo "Updating local kubeconfig to trust the custom CA (before patching the API server)..."
    append_ca_to_kubeconfig "$KUBECONFIG" "$CA_CERT_FILE"
    echo "Kubeconfig updated successfully."

    echo "Patching API server to use the new certificate..."
    oc patch apiserver/cluster --type=merge --patch='{"spec":{"servingCerts":{"namedCertificates":[{"names":["'"$API_HOST"'"],"servingCertificate":{"name":"api-tls"}}]}}}'

    echo "Patching Ingress Controller to use the new certificate..."
    oc patch ingresscontroller/default -n openshift-ingress-operator --type=merge --patch='{"spec":{"defaultCertificate":{"name":"ingress-tls"}}}'

    echo "Waiting for operators to roll out the new certificates..."
    # Warn-and-continue: a slow-but-healthy operator should not abort the run or
    # trigger the destroy hint. Calling in a || context also suspends set -e/the ERR
    # trap inside wait_co_settled, so its internal oc waits are non-fatal here.
    wait_co_settled kube-apiserver 2400s || echo "WARN: kube-apiserver slow to settle; continuing." >&2
    wait_co_settled ingress        900s  || echo "WARN: ingress slow to settle; continuing." >&2
    wait_co_settled authentication 900s  || echo "WARN: authentication slow to settle; continuing." >&2
    wait_co_settled console        900s  || echo "WARN: console slow to settle; continuing." >&2

    echo "--- Custom Certificate Configuration Complete ---"
    echo "IMPORTANT: import and trust the CA certificate ($CA_CERT_FILE) on your client to avoid browser warnings."
else
    echo "Skipping custom certificate configuration (--skip-certs)."
fi

# --- OpenShift GitOps + Argo CD ----------------------------------------------
if [ -z "$SKIP_GITOPS" ]; then
    echo "Deploying OpenShift GitOps Operator..."
    # The operator owns the openshift-gitops namespace; creating it ourselves can
    # race the operator. Only create the operator's own namespace.
    oc create namespace openshift-gitops-operator --dry-run=client -o yaml | oc apply -f -
    oc apply -f "$SCRIPT_DIR/gitops-operator-install.yaml"

    echo "Waiting for the GitOps operator to be ready..."
    wait_for_object deployment openshift-gitops-operator-controller-manager openshift-gitops-operator 300s
    oc wait --for=condition=Available deployment/openshift-gitops-operator-controller-manager \
        -n openshift-gitops-operator --timeout=300s

    # The operator creates the openshift-gitops namespace and the Argo CD instance.
    wait_for_object namespace openshift-gitops "" 300s
    wait_for_object statefulset openshift-gitops-application-controller openshift-gitops 300s
    oc rollout status statefulset/openshift-gitops-application-controller -n openshift-gitops --timeout=300s
    echo "OpenShift GitOps is ready."

    # Grant the application controller scoped, namespace-local permissions in each
    # workload namespace. The default openshift-gitops instance cannot manage
    # arbitrary namespaces on its own, and cluster-admin would be wildly over-broad
    # (read every Secret in every namespace); managed-by scoping is the supported,
    # least-privilege alternative.
    if [ -n "${ARGOCD_MANAGED_NAMESPACES// }" ]; then
        for ns in $ARGOCD_MANAGED_NAMESPACES; do
            grant_argocd_namespace "$ns"
        done
    else
        echo "No ARGOCD_MANAGED_NAMESPACES set; skipping Argo CD namespace scoping."
    fi

    # invaders-application.yaml is optional and may not exist in this repo yet.
    if [ -f "$SCRIPT_DIR/invaders-application.yaml" ]; then
        echo "Deploying the Invaders Argo CD Application..."
        oc apply -f "$SCRIPT_DIR/invaders-application.yaml"
        echo "Invaders Argo CD Application deployed."
    else
        echo "Warning: $SCRIPT_DIR/invaders-application.yaml not found; skipping workload deployment."
    fi

    # Surface the Argo CD UI route.
    ARGOCD_HOST="$(oc get route openshift-gitops-server -n openshift-gitops \
        -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    if [ -n "$ARGOCD_HOST" ]; then
        echo "Argo CD is available at: https://${ARGOCD_HOST}"
    else
        echo "Note: Argo CD route (openshift-gitops-server in openshift-gitops) not found yet."
    fi
else
    echo "Skipping OpenShift GitOps deployment (--skip-gitops)."
fi

# --- Module install / wait / verify ------------------------------------------
# The cluster is up; apply each enabled module, wait for it, then verify it works.
# Continue-on-failure: a failing module is recorded and reported in the summary
# below rather than aborting the run (the expensive cluster already exists).
if [ "${#RESOLVED_ORDER[@]}" -gt 0 ]; then
    echo "--- Installing modules: ${RESOLVED_ORDER[*]} ---"
    run_module_phase install "${RESOLVED_ORDER[@]}"
    run_module_phase wait    "${RESOLVED_ORDER[@]}"
    run_module_phase verify  "${RESOLVED_ORDER[@]}"
    for m in "${RESOLVED_ORDER[@]}"; do
        [ -n "${MOD_FAILED[$m]:-}" ] || state_add_module "$m"
    done
fi

# Success: disarm the ERR trap so the destroy hint is not printed on a clean exit.
trap - ERR

echo "OpenShift Lab Deployment Complete!"
echo "Tear down with:"
print_teardown_hint

# Report any module failures at the very end (continue-on-failure semantics), and
# exit non-zero so callers/CI see that the run was not fully clean.
if ! report_module_failures; then
    echo "Cluster is up, but one or more modules failed (see above)." >&2
    exit 1
fi
