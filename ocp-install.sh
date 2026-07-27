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

# Accept "--flag value", "--flag=value", and short "-f value" forms.
die() { echo "Error: $*" >&2; exit 1; }

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
: "${INSTALL_DIR_PREFIX:=ocp-lab}"
: "${PULL_SECRET_FILE:=$SCRIPT_DIR/pull-secret.txt}"
: "${INSTALL_CONFIG_TEMPLATE:=$SCRIPT_DIR/install-config-template.yaml}"
: "${CA_KEY_FILE:=$SCRIPT_DIR/certs/ca.key}"
: "${CA_CERT_FILE:=$SCRIPT_DIR/certs/ca.crt}"
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

# --- ERR trap: never leave a half-built cluster running silently --------------
# On any failure after provisioning has begun, print the exact destroy command.
on_err() {
    local rc=$?
    echo "ERROR: deployment failed (exit $rc)." >&2
    if [ -n "${INSTALL_DIR:-}" ] && [ -f "${INSTALL_DIR}/metadata.json" ]; then
        echo "A cluster exists in AWS (dir=${INSTALL_DIR}). If you want to tear it down:" >&2
        echo "  ${OPENSHIFT_INSTALL} destroy cluster --dir=${INSTALL_DIR}" >&2
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
        ps="$(tr -d '[:space:]' < "$PULL_SECRET_FILE")"
        trimmed="$ps"
        if [[ "$trimmed" != \{* || "$trimmed" != *\} || "$trimmed" != *'"auths"'* ]]; then
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

preflight

# --- Prepare installation directory ------------------------------------------
INSTALL_DIR="${INSTALL_DIR_PREFIX}-$(date +%Y%m%d)"
echo "Creating installation directory: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

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
cp "$RENDERED" "$RENDERED.bak"
chmod 600 "$RENDERED.bak"
echo "Backed up rendered install-config to $RENDERED.bak (installer consumes the original)."

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

    echo "Deploying Argo CD ClusterRole and ClusterRoleBinding..."
    oc apply -f "$SCRIPT_DIR/cluster-rbac-argocd.yaml"
    echo "Argo CD cluster-wide permissions applied."

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

# Success: disarm the ERR trap so the destroy hint is not printed on a clean exit.
trap - ERR

echo "OpenShift Lab Deployment Complete!"
echo "Tear down the cluster with: $OPENSHIFT_INSTALL destroy cluster --dir=$INSTALL_DIR"
