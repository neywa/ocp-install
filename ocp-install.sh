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

echo "--- Generated install-config.yaml snippet ---"
grep -E "baseDomain:|name:|region:|expirationDate:|pullSecret:" "$RENDERED" || true
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
    (
        echo "--- Starting Custom Certificate Configuration ---"
        CERT_DIR="$INSTALL_DIR/custom-certs"
        mkdir -p "$CERT_DIR"
        cd "$CERT_DIR"

        echo "Generating private keys and CSRs for API and Ingress..."
        openssl genrsa -out api.key 2048
        openssl req -new -key api.key -out api.csr -subj "/CN=${API_HOST}" -reqexts SAN \
            -config <(printf "[req]\ndistinguished_name=req_distinguished_name\n[req_distinguished_name]\n[SAN]\nsubjectAltName=DNS:${API_HOST}")

        openssl genrsa -out ingress.key 2048
        openssl req -new -key ingress.key -out ingress.csr -subj "/CN=${INGRESS_WILDCARD}" -reqexts SAN \
            -config <(printf "[req]\ndistinguished_name=req_distinguished_name\n[req_distinguished_name]\n[SAN]\nsubjectAltName=DNS:${INGRESS_WILDCARD},DNS:${CONSOLE_HOST}")

        echo "Signing certificates with the provided CA..."
        openssl x509 -req -in api.csr -CA "$CA_CERT_FILE" -CAkey "$CA_KEY_FILE" -CAcreateserial \
            -out api.crt -days 365 -sha256 -extfile <(printf "subjectAltName=DNS:${API_HOST}")
        openssl x509 -req -in ingress.csr -CA "$CA_CERT_FILE" -CAkey "$CA_KEY_FILE" -CAcreateserial \
            -out ingress.crt -days 365 -sha256 -extfile <(printf "subjectAltName=DNS:${INGRESS_WILDCARD},DNS:${CONSOLE_HOST}")

        echo "Applying custom certificates to the cluster..."
        cd ../..
        oc create configmap custom-ca --from-file=ca-bundle.crt="$CA_CERT_FILE" -n openshift-config || true
        oc patch proxy/cluster --type=merge --patch='{"spec":{"trustedCA":{"name":"custom-ca"}}}'

        oc create secret tls api-tls --cert="$INSTALL_DIR/custom-certs/api.crt" --key="$INSTALL_DIR/custom-certs/api.key" -n openshift-config || true
        oc create secret tls ingress-tls --cert="$INSTALL_DIR/custom-certs/ingress.crt" --key="$INSTALL_DIR/custom-certs/ingress.key" -n openshift-ingress || true

        echo "Patching API server to use the new certificate..."
        oc patch apiserver/cluster --type=merge --patch='{"spec":{"servingCerts":{"namedCertificates":[{"names":["'"$API_HOST"'"],"servingCertificate":{"name":"api-tls"}}]}}}'

        echo "Patching Ingress Controller to use the new certificate..."
        oc patch ingresscontroller/default -n openshift-ingress-operator --type=merge --patch='{"spec":{"defaultCertificate":{"name":"ingress-tls"}}}'

        echo "--- Custom Certificate Configuration Complete ---"
        echo "IMPORTANT: import and trust the CA certificate ($CA_CERT_FILE) on your client to avoid browser warnings."
    )

    echo "Updating kubeconfig to trust the new custom CA..."
    oc --kubeconfig="$KUBECONFIG" config set-cluster "${CLUSTER_NAME}" --certificate-authority="${CA_CERT_FILE}" --embed-certs=true
    echo "Kubeconfig updated successfully."
else
    echo "Skipping custom certificate configuration (--skip-certs)."
fi

# --- OpenShift GitOps + Argo CD ----------------------------------------------
if [ -z "$SKIP_GITOPS" ]; then
    echo "Deploying OpenShift GitOps Operator..."
    oc create namespace openshift-gitops || true
    oc create namespace openshift-gitops-operator || true
    oc apply -f "$SCRIPT_DIR/gitops-operator-install.yaml"

    echo "Waiting for OpenShift GitOps Operator to be ready..."
    oc wait --for=condition=Available deployment/openshift-gitops-operator-controller-manager \
        -n openshift-gitops-operator --timeout=300s || true
    echo "OpenShift GitOps Operator deployed."

    echo "Deploying Argo CD ClusterRole and ClusterRoleBinding..."
    oc apply -f "$SCRIPT_DIR/cluster-rbac-argocd.yaml"
    echo "Argo CD cluster-wide permissions applied."

    echo "Deploying the Invaders Argo CD Application..."
    oc apply -f "$SCRIPT_DIR/invaders-application.yaml"
    echo "Invaders Argo CD Application deployed."
else
    echo "Skipping OpenShift GitOps deployment (--skip-gitops)."
fi

echo "OpenShift Lab Deployment Complete!"
echo "Tear down the cluster with: $OPENSHIFT_INSTALL destroy cluster --dir=$INSTALL_DIR"
