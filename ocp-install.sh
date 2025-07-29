#!/bin/bash

# --- Configuration Variables ---
INSTALL_DIR_PREFIX="ocp-lab"
PULL_SECRET_FILE="/home/roman/OpenShift/ocp-install/pull-secret.txt" # IMPORTANT: Adjust this path!
INSTALL_CONFIG_TEMPLATE="../install-config-template.yaml" # Your template file

# --- Variables to be set by flags ---
BASE_DOMAIN=""
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

# --- Start OpenShift Cluster Installation ---
echo "Starting OpenShift cluster installation in directory: $INSTALL_DIR"
echo "This process can take 30-60 minutes or more, depending on your platform and cluster size."

# Ensure openshift-install is in your PATH or provide its full path
./openshift-install create cluster --dir="$INSTALL_DIR" --log-level=debug

# Ensure your KUBECONFIG is set correctly here to point to the new cluster's kubeconfig
export KUBECONFIG="$INSTALL_DIR/auth/kubeconfig"

echo "Waiting for all cluster operators to be available..."
# A more robust check might be to wait for specific operators or the "cluster version" to stabilize
# For a lab, waiting for the cluster-version operator to be "Available" is a good start.
oc wait --for=condition=Available clusteroperator/authentication --timeout=600s
oc wait --for=condition=Available clusteroperator/kube-apiserver --timeout=600s

# --- Post-installation Steps (Optional) ---
# Check exit code of openshift-install
if [ $? -eq 0 ]; then
    echo "OpenShift cluster installation successful!"
    echo "Kubeconfig is located at: $INSTALL_DIR/auth/kubeconfig"
    # You might want to copy kubeconfig to ~/.kube/config or set KUBECONFIG env var
    # export KUBECONFIG="$INSTALL_DIR/auth/kubeconfig"
    # oc whoami
else
    echo "OpenShift cluster installation failed. Check logs in $INSTALL_DIR."
    exit 1
fi

echo "Don't forget to tear down the cluster on Friday using:"
echo "openshift-install destroy cluster --dir=$iINSTALL_DIR"

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


# Deploy the  Argo CD Applicationis ---
# If you are using the App-of-Apps pattern with an ApplicationSet (e.g. lab-root-applications from prior discussion)
# you would apply THAT application here, and it would then auto-discover invaders-application.yaml
# (assuming invaders-application.yaml is in your Git repo's app-definitions folder)
# Example: oc apply -f argocd-root-app.yaml

echo "Deploying the Argo CD Applications..."
oc apply -f apps.yaml
echo "Argo CD Applications deployed. Argo CD will now synchronize your apps from Git."

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

# Optional: Display console route or other useful info
# oc get route console -n openshift-console -o jsonpath='{"OpenShift Console: "}{.spec.host}{"\n"}'
# oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{"Argo CD UI: "}{.spec.host}{"\n"}'

