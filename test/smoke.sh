#!/usr/bin/env bash
#
# Static smoke test for ocp-install.sh.
#
# Builds throwaway fixtures (fake pull secret, self-signed CA, inert
# openshift-install/oc/aws stubs on PATH) and exercises the script in --dry-run
# mode plus its preflight error paths. It asserts:
#   - rendered install-config.yaml is valid YAML
#   - the pull secret round-trips byte-identical and still parses as JSON
#   - every platform.aws.userTags value is a string (expirationDate is NOT a
#     YAML date/number) — the quoting guard
#   - CLUSTER_NAME is the single source of truth (metadata.name follows it)
#   - config precedence: defaults < lab.env < environment < CLI flags
#   - preflight reports ALL errors in one run, not just the first
#
# This test NEVER touches AWS or a real cluster: --dry-run exits after rendering,
# and the aws/oc/openshift-install stubs shadow the real tools on PATH.
#
# Usage:   bash test/smoke.sh
#   KEEP=1 bash test/smoke.sh   # keep the scratch dir for inspection
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_DIR/ocp-install.sh"
TEMPLATE="$REPO_DIR/install-config-template.yaml"

for f in "$SCRIPT_UNDER_TEST" "$TEMPLATE"; do
    [ -f "$f" ] || { echo "FATAL: expected file not found: $f" >&2; exit 1; }
done

# --- Scratch dir + cleanup ----------------------------------------------------
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/ocp-smoke.XXXXXX")"
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        echo "KEEP=1 set; leaving scratch dir at: $SCRATCH"
    else
        rm -rf "$SCRATCH"
    fi
}
trap cleanup EXIT

FAILS=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAILS=$((FAILS + 1)); }

echo "== Building shared fixtures in $SCRATCH =="

# --- Fixture: realistic single-line base64-JSON pull secret ------------------
PULL_SECRET_FILE="$SCRATCH/pull-secret.txt"
auth_a="$(printf 'user-a:token-aaaaaaaaaaaaaaaaaaaaaaaa' | base64 | tr -d '\n')"
auth_b="$(printf 'user-b:token-bbbbbbbbbbbbbbbbbbbbbbbb' | base64 | tr -d '\n')"
printf '{"auths":{"registry.redhat.io":{"auth":"%s","email":"lab@example.com"},"quay.io":{"auth":"%s","email":"lab@example.com"}}}\n' \
    "$auth_a" "$auth_b" > "$PULL_SECRET_FILE"

# --- Fixture: throwaway self-signed CA ---------------------------------------
CA_KEY_FILE="$SCRATCH/ca.key"
CA_CERT_FILE="$SCRATCH/ca.crt"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$CA_KEY_FILE" -out "$CA_CERT_FILE" \
    -days 1 -subj "/CN=Smoke Test CA" >/dev/null 2>&1

# --- Fixture: inert stubs on PATH (openshift-install, oc, aws) ----------------
STUB_BIN="$SCRATCH/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/openshift-install" <<'EOF'
#!/usr/bin/env bash
echo "STUB openshift-install: $*"
exit 0
EOF
cat > "$STUB_BIN/oc" <<'EOF'
#!/usr/bin/env bash
echo "STUB oc: $*"
exit 0
EOF
# aws stub: always succeeds and always reports a hosted zone matching whatever
# --dns-name it is asked about, so preflight's AWS branch passes without ever
# touching real AWS.
cat > "$STUB_BIN/aws" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    sts)
        echo '{"UserId":"AIDASTUB","Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/stub"}'
        exit 0
        ;;
    route53)
        dns=""
        while [ $# -gt 0 ]; do
            [ "$1" = "--dns-name" ] && { dns="${2:-}"; }
            shift
        done
        echo "${dns%.}."
        exit 0
        ;;
esac
exit 0
EOF
chmod +x "$STUB_BIN/openshift-install" "$STUB_BIN/oc" "$STUB_BIN/aws"

# --- Helper: extract a dotted path from a YAML file ---------------------------
PYGET="$SCRATCH/pyget.py"
cat > "$PYGET" <<'EOF'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], "rb"))
cur = doc
for k in sys.argv[2].split("."):
    cur = cur[k]
print(cur)
EOF
yaml_get() { python3 "$PYGET" "$1" "$2"; }

# --- Helper: run ocp-install.sh in an isolated run dir ------------------------
# Usage: run_ocp <run-subdir> [extra env assignments...] -- <script args...>
# Common fixture env is always injected; extra env pairs precede "--".
run_ocp() {
    local rundir="$SCRATCH/$1"; shift
    mkdir -p "$rundir"
    local envs=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    [ "${1:-}" = "--" ] && shift
    (
        cd "$rundir"
        env \
            PATH="$STUB_BIN:$PATH" \
            PULL_SECRET_FILE="$PULL_SECRET_FILE" \
            CA_KEY_FILE="$CA_KEY_FILE" \
            CA_CERT_FILE="$CA_CERT_FILE" \
            LAB_ENV="$rundir/lab.env" \
            "${envs[@]}" \
            bash "$SCRIPT_UNDER_TEST" "$@"
    )
}

# =============================================================================
echo
echo "== Test 1: render + core assertions (default cluster name) =="
# Rendered install-config lands under the run dir; find it afterwards.
run_ocp run1 -- -d smoke.example.com --dry-run
RENDERED="$(find "$SCRATCH/run1" -maxdepth 2 -name install-config.yaml -type f | head -n1)"
if [ -z "$RENDERED" ]; then
    fail "rendered install-config.yaml not found"
elif RENDERED="$RENDERED" PULL_SECRET_FILE="$PULL_SECRET_FILE" python3 - <<'PY'
import json, os, sys, datetime
import yaml

rendered = os.environ["RENDERED"]
pull_secret_file = os.environ["PULL_SECRET_FILE"]
fails = 0
def ok(m): print(f"  PASS: {m}")
def bad(m):
    global fails; fails += 1; print(f"  FAIL: {m}")

raw = open(rendered, "rb").read()
try:
    doc = yaml.safe_load(raw)
    ok("install-config.yaml is valid YAML") if isinstance(doc, dict) else bad("not a mapping")
    if not isinstance(doc, dict): doc = {}
except yaml.YAMLError as e:
    bad(f"invalid YAML: {e}"); doc = {}

# Pull secret round-trips byte-identical and parses as JSON.
original = open(pull_secret_file).read().replace("\n", "")
rs = doc.get("pullSecret")
if rs is None:
    bad("pullSecret missing")
elif rs != original:
    bad("pullSecret not byte-identical after render")
else:
    try:
        json.loads(rs); ok("pullSecret round-trips byte-identical and parses as JSON")
    except json.JSONDecodeError as e:
        bad(f"pullSecret not JSON: {e}")

# userTags: every value is a string; expirationDate is a str, not a YAML date.
tags = ((doc.get("platform") or {}).get("aws") or {}).get("userTags")
if not isinstance(tags, dict):
    bad(f"userTags missing/not a mapping: {type(tags).__name__}")
else:
    nonstr = {k: type(v).__name__ for k, v in tags.items() if not isinstance(v, str)}
    if nonstr:
        bad(f"non-string userTags: {nonstr}")
    else:
        ok(f"all {len(tags)} userTags values are strings")
    exp = tags.get("expirationDate")
    if isinstance(exp, (datetime.date, datetime.datetime)):
        bad("expirationDate parsed as a YAML date (quoting failed)")
    elif isinstance(exp, str):
        ok(f"expirationDate is a quoted string ({exp!r})")
    else:
        bad(f"expirationDate unexpected type: {type(exp).__name__}")

# CLUSTER_NAME is the single source of truth -> metadata.name.
if doc.get("metadata", {}).get("name") == "rbobek":
    ok("metadata.name == default cluster name 'rbobek'")
else:
    bad(f"metadata.name = {doc.get('metadata', {}).get('name')!r}, expected 'rbobek'")

sys.exit(1 if fails else 0)
PY
then
    :
else
    FAILS=$((FAILS + 1))
fi

# =============================================================================
echo
echo "== Test 2: CLI flag overrides lab.env (flag wins) =="
mkdir -p "$SCRATCH/run2"
cat > "$SCRATCH/run2/lab.env" <<'EOF'
: "${CLUSTER_NAME:=fromfile}"
EOF
run_ocp run2 -- -d smoke.example.com --cluster-name fromflag --dry-run >/dev/null
R2="$(find "$SCRATCH/run2" -maxdepth 2 -name install-config.yaml -type f | head -n1)"
name2="$(yaml_get "$R2" metadata.name)"
if [ "$name2" = "fromflag" ]; then
    pass "flag --cluster-name beat lab.env (metadata.name=$name2)"
else
    fail "expected metadata.name=fromflag, got '$name2'"
fi

# lab.env beats the built-in default when no flag/env is given.
mkdir -p "$SCRATCH/run2b"
cp "$SCRATCH/run2/lab.env" "$SCRATCH/run2b/lab.env"
run_ocp run2b -- -d smoke.example.com --dry-run >/dev/null
R2B="$(find "$SCRATCH/run2b" -maxdepth 2 -name install-config.yaml -type f | head -n1)"
name2b="$(yaml_get "$R2B" metadata.name)"
if [ "$name2b" = "fromfile" ]; then
    pass "lab.env beat the built-in default (metadata.name=$name2b)"
else
    fail "expected metadata.name=fromfile, got '$name2b'"
fi

# =============================================================================
echo
echo "== Test 3: environment overrides lab.env (env wins) =="
mkdir -p "$SCRATCH/run3"
cat > "$SCRATCH/run3/lab.env" <<'EOF'
: "${AWS_REGION:=region-from-file}"
EOF
run_ocp run3 AWS_REGION=region-from-env -- -d smoke.example.com --dry-run >/dev/null
R3="$(find "$SCRATCH/run3" -maxdepth 2 -name install-config.yaml -type f | head -n1)"
region3="$(yaml_get "$R3" platform.aws.region)"
if [ "$region3" = "region-from-env" ]; then
    pass "environment beat lab.env (region=$region3)"
else
    fail "expected region=region-from-env, got '$region3'"
fi

# =============================================================================
echo
echo "== Test 4: preflight reports ALL errors in one run =="
# Point pull secret AND template at non-existent files; expect BOTH errors.
set +e
out4="$(run_ocp run4 \
    PULL_SECRET_FILE="$SCRATCH/nope-secret.txt" \
    INSTALL_CONFIG_TEMPLATE="$SCRATCH/nope-template.yaml" \
    -- -d smoke.example.com --dry-run 2>&1)"
rc4=$?
set -e
if [ "$rc4" -ne 0 ]; then
    pass "preflight exited non-zero ($rc4)"
else
    fail "preflight should have failed but exited 0"
fi
if grep -q "pull secret file not found" <<<"$out4"; then
    pass "reported the missing pull secret"
else
    fail "did not report the missing pull secret"
fi
if grep -q "install-config template not found" <<<"$out4"; then
    pass "reported the missing template"
else
    fail "did not report the missing template"
fi
if grep -q "Preflight failed with 2 error(s)" <<<"$out4"; then
    pass "collected exactly 2 errors in a single run"
else
    echo "----- preflight output -----"; echo "$out4"; echo "----------------------------"
    fail "did not collect both errors in one run"
fi

# =============================================================================
echo
if [ "$FAILS" -ne 0 ]; then
    echo "RESULT: $FAILS check(s) FAILED"
    exit 1
fi
echo "RESULT: all checks PASSED"
echo "== smoke.sh: OK =="
