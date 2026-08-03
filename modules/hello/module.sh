# hello — THROWAWAY test module.
#
# This module exists ONLY to exercise the module framework end to end (discovery,
# metadata, install/wait/verify/destroy dispatch, state, teardown hints). It ships
# no real product and WILL BE DELETED once the first real module (RHACS/RHACM/OADP/
# Logging) lands. Do not build anything on top of it.
#
# It is sourced by ocp-install.sh, so it shares that script's helpers (log/warn/die)
# and its idempotency convention (oc create ... --dry-run=client -o yaml | oc apply -f -).
# Every hook and variable is namespaced with the module name so two sourced modules
# cannot collide.

# --- Metadata (snapshotted by the loader at source time) ---------------------
MODULE_DESCRIPTION="Throwaway framework smoke-test module (namespace + configmap)"
MODULE_REQUIRES=""            # no dependencies
MODULE_MIN_WORKERS=""         # no resource floor
MODULE_MIN_WORKER_TYPE=""     # no resource floor
MODULE_CREATES_AWS="false"    # nothing outside the cluster

# Namespace + the ConfigMap key/value verify reads back. Kept as internal vars so the
# install and verify hooks agree on exactly one source of truth.
_HELLO_NS="hello"
_HELLO_CM="hello-config"
_HELLO_GREETING="hello-from-module-framework"

# --- install: create the namespace and a ConfigMap (idempotent) --------------
# No provision hook: this module creates nothing outside the cluster.
hello_install() {
    oc create namespace "$_HELLO_NS" --dry-run=client -o yaml | oc apply -f -
    oc create configmap "$_HELLO_CM" -n "$_HELLO_NS" \
        --from-literal=greeting="$_HELLO_GREETING" \
        --dry-run=client -o yaml | oc apply -f -
}

# --- wait: block until the ConfigMap actually exists -------------------------
hello_wait() {
    wait_for_object configmap "$_HELLO_CM" "$_HELLO_NS" 120s
}

# --- verify: read the ConfigMap back and check its content -------------------
# A real assertion, not "pods Running": the value must round-trip through the API.
hello_verify() {
    local got
    got="$(oc get configmap "$_HELLO_CM" -n "$_HELLO_NS" \
        -o jsonpath='{.data.greeting}' 2>/dev/null || true)"
    if [ "$got" != "$_HELLO_GREETING" ]; then
        die "hello verify failed: configmap greeting is '${got}', expected '${_HELLO_GREETING}'"
    fi
    log "hello verify: configmap greeting round-tripped correctly ('$got')."
}

# --- destroy: remove everything install created -----------------------------
hello_destroy() {
    oc delete namespace "$_HELLO_NS" --ignore-not-found
}
