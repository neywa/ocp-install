#!/bin/bash

# --- Configuration Variables ---
# All paths default to their original values but can be overridden via the
# environment (e.g. by test/smoke.sh) so the script is testable without touching
# the real fixtures. Defaults are unchanged from a normal run.
INSTALL_DIR_PREFIX="${INSTALL_DIR_PREFIX:-ocp-lab}"
PULL_SECRET_FILE="${PULL_SECRET_FILE:-/home/roman/OpenShift/ocp-install/pull-secret.txt}" # IMPORTANT: Adjust this path!
INSTALL_CONFIG_TEMPLATE="${INSTALL_CONFIG_TEMPLATE:-../install-config-template.yaml}" # Your template file

# --- Custom Certificate Configuration ---
# IMPORTANT: Adjust these paths to your existing CA files!
CA_KEY_FILE="${CA_KEY_FILE:-/home/roman/OpenShift/certs/ca.key}"
CA_CERT_FILE="${CA_CERT_FILE:-/home/roman/OpenShift/certs/ca.crt}"

# --- Variables to be set by flags ---
BASE_DOMAIN=""
CLUSTER_NAME=rbobek
DRY_RUN="" # When set (via --dry-run), render install-config.yaml and exit.
# Add more variables here as you introduce new flags (e.g., CLUSTER_NAME="", NODE_COUNT="")

# --- Function to display usage ---
usage() {
    echo "Usage: $0 -d <base_domain> [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -d <base_domain>    Required: The base domain for your OpenShift cluster (e.g., mylab.example.com)"
    # Add more options here as you introduce new flags
    echo ""
    echo "Example: $0 -d mylab.yourcompany.com"
    exit 1
}

# --- Parse Command Line Arguments ---
# getopts does not understand long options, so pull --dry-run out of the argument
# list first and leave the remaining args for getopts to parse as usual.
REMAINING_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=1
            ;;
        *)
            REMAINING_ARGS+=("$arg")
            ;;
    esac
done
set -- "${REMAINING_ARGS[@]}"

# 'd:' means -d expects an argument
while getopts "d:" opt; do
    case "${opt}" in
        d)
            BASE_DOMAIN="${OPTARG}"
            ;;
        *)
            # For any other unsupported option
            usage
            ;;
    esac
done
shift $((OPTIND-1)) # Shift positional parameters so $1, $2, etc. refer to non-option arguments

# --- Input Validation ---

# Check if baseDomain was provided via -d flag
if [ -z "$BASE_DOMAIN" ]; then
    echo "Error: Base domain not specified."
    usage
fi

# Check for pull secret file existence
if [ ! -f "$PULL_SECRET_FILE" ]; then
    echo "Error: Pull secret file not found at $PULL_SECRET_FILE"
    exit 1
fi

# Check for install config template existence
if [ ! -f "$INSTALL_CONFIG_TEMPLATE" ]; then
    echo "Error: Install config template file not found at $INSTALL_CONFIG_TEMPLATE"
    exit 1
fi

# Check for CA files existence
if [ ! -f "$CA_KEY_FILE" ] || [ ! -f "$CA_CERT_FILE" ]; then
    echo "Error: CA key or certificate not found. Check the CA_KEY_FILE and CA_CERT_FILE paths."
    exit 1
fi


# --- Dynamic Directory Naming ---
INSTALL_DIR="${INSTALL_DIR_PREFIX}-$(date +%Y%m%d)"

# --- Pre-installation Checks ---
# You might want to add checks here for openshift-install binary, oc binary, etc.

# --- Prepare Installation Directory ---
echo "Creating installation directory: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR" || { echo "Failed to create directory $INSTALL_DIR"; exit 1; }

# --- Read Secrets and Data ---
PULL_SECRET_CONTENT=$(cat "$PULL_SECRET_FILE" | tr -d '\n') # Ensure no newlines in secret

# --- Generate Final install-config.yaml ---
echo "Generating final install-config.yaml in $INSTALL_DIR..."

# Use sed to replace both placeholders.
# We use '#' as a delimiter for sed to avoid issues with slashes in the domain or secret.
sed "s#PULL_SECRET_PLACEHOLDER#${PULL_SECRET_CONTENT}#" "$INSTALL_CONFIG_TEMPLATE" | \
sed "s#BASE_DOMAIN_PLACEHOLDER#${BASE_DOMAIN}#" > "$INSTALL_DIR/install-config.yaml"

# Verify content (optional, for debugging)
echo "--- Generated install-config.yaml snippet ---"
cat "$INSTALL_DIR/install-config.yaml" | grep -E "baseDomain|pullSecret|name:"
echo "------------------------------------------"

# --- Dry-run exit ---
# In dry-run mode we stop right after rendering install-config.yaml. Nothing below
# this point runs, so no command can touch a real cluster or AWS account.
if [ -n "$DRY_RUN" ]; then
    echo "Dry-run: rendered install-config.yaml at $INSTALL_DIR/install-config.yaml"
    echo "Dry-run: skipping cluster installation and all cluster/AWS operations."
    exit 0
fi

# --- Start OpenShift Cluster Installation ---
echo "Starting OpenShift cluster installation in directory: $INSTALL_DIR"
echo "This process can take 30-60 minutes or more, depending on your platform and cluster size."

# Ensure openshift-install is in your PATH or provide its full path
./openshift-install create cluster --dir="$INSTALL_DIR" --log-level=info

# --- Post-installation Steps ---
if [ $? -ne 0 ]; then
    echo "OpenShift cluster installation failed. Check logs in $INSTALL_DIR."
    exit 1
fi

echo "OpenShift cluster installation successful!"
echo "Kubeconfig is located at: $INSTALL_DIR/auth/kubeconfig"
export KUBECONFIG="$INSTALL_DIR/auth/kubeconfig"

echo "Waiting for cluster operators to become available..."
# A more robust check might be to wait for specific operators or the "cluster version" to stabilize
# For a lab, waiting for the cluster-version operator to be "Available" is a good start.
oc wait --for=condition=Available clusteroperator/authentication --timeout=600s
oc wait --for=condition=Available clusteroperator/kube-apiserver --timeout=600s

# --- Custom Certificate Generation and Application ---
# IMPROVEMENT: Run certificate generation in a subshell to avoid changing the main script's directory
(
    echo "--- Starting Custom Certificate Configuration ---"
    CERT_DIR="$INSTALL_DIR/custom-certs"
    mkdir -p "$CERT_DIR"
    cd "$CERT_DIR" || exit 1

    API_HOST="api.rbobek.${BASE_DOMAIN}"
    CONSOLE_HOST="console-openshift-console.apps.rbobek.${BASE_DOMAIN}"
    INGRESS_WILDCARD="*.apps.rbobek.${BASE_DOMAIN}"

    echo "Generating private keys and CSRs for API and Ingress..."

    # Generate API Server Key and CSR
    openssl genrsa -out api.key 2048
    openssl req -new -key api.key -out api.csr -subj "/CN=${API_HOST}" -reqexts SAN -config <(printf "[req]\ndistinguished_name=req_distinguished_name\n[req_distinguished_name]\n[SAN]\nsubjectAltName=DNS:${API_HOST}")

    # Generate Ingress Key and CSR
    openssl genrsa -out ingress.key 2048
    openssl req -new -key ingress.key -out ingress.csr -subj "/CN=${INGRESS_WILDCARD}" -reqexts SAN -config <(printf "[req]\ndistinguished_name=req_distinguished_name\n[req_distinguished_name]\n[SAN]\nsubjectAltName=DNS:${INGRESS_WILDCARD},DNS:${CONSOLE_HOST}")

    echo "Signing certificates with the provided CA..."

    # Sign the API server certificate
    openssl x509 -req -in api.csr -CA "$CA_CERT_FILE" -CAkey "$CA_KEY_FILE" -CAcreateserial -out api.crt -days 365 -sha256 -extfile <(printf "subjectAltName=DNS:${API_HOST}")

    # Sign the Ingress certificate
    openssl x509 -req -in ingress.csr -CA "$CA_CERT_FILE" -CAkey "$CA_KEY_FILE" -CAcreateserial -out ingress.crt -days 365 -sha256 -extfile <(printf "subjectAltName=DNS:${INGRESS_WILDCARD},DNS:${CONSOLE_HOST}")

    echo "Applying custom certificates to the cluster..."

    # Create the custom CA config map and apply it to the proxy
    cd ../..
    oc create configmap custom-ca --from-file=ca-bundle.crt=$CA_CERT_FILE -n openshift-config
    oc patch proxy/cluster --type=merge --patch='{"spec":{"trustedCA":{"name":"custom-ca"}}}'

    # Create secrets in the appropriate namespaces
    oc create secret tls api-tls --cert=$INSTALL_DIR/custom-certs/api.crt --key=$INSTALL_DIR/custom-certs/api.key -n openshift-config
    oc create secret tls ingress-tls --cert=$INSTALL_DIR/custom-certs/ingress.crt --key=$INSTALL_DIR/custom-certs/ingress.key -n openshift-ingress

    # Patch the cluster resources to use the new secrets
    echo "Patching API server to use the new certificate..."
    oc patch apiserver/cluster --type=merge --patch='{"spec":{"servingCerts":{"namedCertificates":[{"names":["'"$API_HOST"'"],"servingCertificate":{"name":"api-tls"}}]}}}'

    echo "Patching Ingress Controller to use the new certificate..."
    oc patch ingresscontroller/default -n openshift-ingress-operator --type=merge --patch='{"spec":{"defaultCertificate":{"name":"ingress-tls"}}}'

    echo "Monitoring rollout of new certificates..."
    echo "Watching API server pods (this may take several minutes)..."
    oc get pods -n openshift-kube-apiserver -w

    echo "Watching Ingress controller pods..."
    oc get pods -n openshift-ingress -w

    echo "--- Custom Certificate Configuration Complete ---"
    echo "IMPORTANT: To avoid browser warnings, you must import and trust the CA certificate ($CA_CERT_FILE) on your client machine."

    # A 30-second countdown function to show the user a timer.
    countdown() {
      local seconds=30
      echo "Let's wait till the needed bits of the cluster are up and running..."
      for ((i = seconds; i >= 0; i--)); do
        # Use printf with \r to overwrite the same line
        printf "\r Time remaining: %2d seconds" "$i"
        sleep 1
      done
      # Print a newline at the end to move to the next line in the terminal
      printf "\n Countdown complete!\n"
    }

    countdown 
)

echo "Updating kubeconfig to trust the new custom CA..."

oc --kubeconfig="$KUBECONFIG" config set-cluster "${CLUSTER_NAME}" --certificate-authority="${CA_CERT_FILE}" --embed-certs=true

echo "Kubeconfig updated successfully."

# --- Automate OpenShift GitOps Operator Deployment ---
echo "Deploying OpenShift GitOps Operator..."

# Apply the OperatorGroup and Subscription
oc create namespace openshift-gitops
oc create namespace openshift-gitops-operator
oc apply -f gitops-operator-install.yaml

# Optional: Wait for the GitOps Operator to be ready
echo "Waiting for OpenShift GitOps Operator to be ready..."
# The operator will create a deployment in the openshift-gitops namespace
sleep 60
oc wait --for=condition=Available deployment/openshift-gitops-operator-controller-manager -n openshift-gitops-operator --timeout=300s

echo "OpenShift GitOps Operator deployed and ready!"

# --- Continue with your Argo CD Application-of-Applications deployment ---
# Example: oc apply -f my-argocd-app-of-apps.yaml

# Deploy Argo CD ClusterRole and ClusterRoleBinding ---
echo "Deploying Argo CD ClusterRole and ClusterRoleBinding for controller permissions..."
oc apply -f cluster-rbac-argocd.yaml
echo "Argo CD Cluster-wide permissions applied."


# Deploy the Invaders Argo CD Application ---
# If you are using the App-of-Apps pattern with an ApplicationSet (e.g. lab-root-applications from prior discussion)
# you would apply THAT application here, and it would then auto-discover invaders-application.yaml
# (assuming invaders-application.yaml is in your Git repo's app-definitions folder)
# Example: oc apply -f argocd-root-app.yaml

echo "Deploying the Invaders Argo CD Application..."
oc apply -f invaders-application.yaml
echo "Invaders Argo CD Application deployed. Argo CD will now synchronize your Invaders game from Git."

# Optional: Add a brief pause to allow Argo CD to start syncing
sleep 10

# Optional: You can try to wait for the Argo CD application to sync and become healthy.
# This requires the 'argocd' CLI to be installed, or more complex 'oc' parsing.
# For a lab, observing via the Argo CD UI or 'oc get app -n openshift-gitops' might be enough.
# echo "Waiting for Invaders application to sync..."
# argocd app wait invaders-game --health --sync --timeout 600 # Requires argocd CLI
# echo "Invaders application should now be synced and healthy."

echo "OpenShift Lab Deployment Complete!"
echo "You can now access your OpenShift cluster and observe Argo CD syncing applications."

echo "Don't forget to tear down the cluster on Friday using:"
echo "openshift-install destroy cluster --dir=$INSTALL_DIR"

