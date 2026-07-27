#!/bin/bash
#
# Static smoke test for ocp-install.sh.
#
# Builds a scratch directory full of throwaway fixtures (fake pull secret, a
# self-signed CA, inert `openshift-install`/`oc` stubs on PATH), runs the real
# script in --dry-run mode, and asserts on the rendered install-config.yaml.
#
# This test NEVER touches AWS or a real cluster: --dry-run exits after rendering,
# and the stubs are inert. Safe to run anywhere.
#
# Usage:   bash test/smoke.sh
#   KEEP=1 bash test/smoke.sh   # keep the scratch dir for inspection
#
set -euo pipefail

# --- Locate the repo and the script under test -------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_DIR/ocp-install.sh"
TEMPLATE="$REPO_DIR/install-config-template.yaml"

for f in "$SCRIPT_UNDER_TEST" "$TEMPLATE"; do
    if [ ! -f "$f" ]; then
        echo "FATAL: expected file not found: $f" >&2
        exit 1
    fi
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

echo "== Building fixtures in $SCRATCH =="

# --- Fixture: realistic single-line base64-JSON pull secret ------------------
# A real Red Hat pull secret is single-line JSON whose per-registry "auth" values
# are base64. We mirror that shape so the round-trip assertion is meaningful.
PULL_SECRET_FILE="$SCRATCH/pull-secret.txt"
auth_a="$(printf 'user-a:token-aaaaaaaaaaaaaaaaaaaaaaaa' | base64 | tr -d '\n')"
auth_b="$(printf 'user-b:token-bbbbbbbbbbbbbbbbbbbbbbbb' | base64 | tr -d '\n')"
# Compact JSON, single line, with a trailing newline (as a downloaded file has).
printf '{"auths":{"registry.redhat.io":{"auth":"%s","email":"lab@example.com"},"quay.io":{"auth":"%s","email":"lab@example.com"}}}\n' \
    "$auth_a" "$auth_b" > "$PULL_SECRET_FILE"

# --- Fixture: throwaway self-signed CA ---------------------------------------
CA_KEY_FILE="$SCRATCH/ca.key"
CA_CERT_FILE="$SCRATCH/ca.crt"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$CA_KEY_FILE" -out "$CA_CERT_FILE" \
    -days 1 -subj "/CN=Smoke Test CA" >/dev/null 2>&1

# --- Fixture: inert stubs on PATH --------------------------------------------
# These are never reached in --dry-run (the script exits before any cluster/AWS
# command), but we create them per the harness contract so a regression that let
# execution fall through would hit harmless no-ops rather than real tools.
STUB_BIN="$SCRATCH/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/openshift-install" <<'EOF'
#!/bin/bash
echo "STUB openshift-install: $*"
exit 0
EOF
cat > "$STUB_BIN/oc" <<'EOF'
#!/bin/bash
echo "STUB oc: $*"
exit 0
EOF
chmod +x "$STUB_BIN/openshift-install" "$STUB_BIN/oc"

# --- Fixture: template copy ---------------------------------------------------
cp "$TEMPLATE" "$SCRATCH/install-config-template.yaml"

# The script also invokes ./openshift-install relative to its CWD; provide it
# there too so an accidental fall-through stays inert.
RUN_DIR="$SCRATCH/run"
mkdir -p "$RUN_DIR"
cp "$STUB_BIN/openshift-install" "$RUN_DIR/openshift-install"

# --- Run the script under test in --dry-run ----------------------------------
echo "== Running ocp-install.sh --dry-run =="
(
    cd "$RUN_DIR"
    PATH="$STUB_BIN:$PATH" \
    INSTALL_DIR_PREFIX="ocp-lab" \
    PULL_SECRET_FILE="$PULL_SECRET_FILE" \
    INSTALL_CONFIG_TEMPLATE="$SCRATCH/install-config-template.yaml" \
    CA_KEY_FILE="$CA_KEY_FILE" \
    CA_CERT_FILE="$CA_CERT_FILE" \
    bash "$SCRIPT_UNDER_TEST" -d smoke.example.com --dry-run
)

# --- Locate the rendered install-config.yaml ---------------------------------
RENDERED="$(find "$RUN_DIR" -maxdepth 2 -name install-config.yaml -type f | head -n1)"
if [ -z "$RENDERED" ] || [ ! -f "$RENDERED" ]; then
    echo "FAIL: rendered install-config.yaml not found under $RUN_DIR" >&2
    exit 1
fi
echo "== Rendered: $RENDERED =="

# --- Assertions (python3 + PyYAML/json) --------------------------------------
# The heavy lifting is one python3 process so YAML/JSON parsing is exact. It
# prints PASS/FAIL lines and exits non-zero on any failure.
echo "== Assertions =="
RENDERED="$RENDERED" PULL_SECRET_FILE="$PULL_SECRET_FILE" python3 - <<'PY'
import json
import os
import sys

import yaml

rendered = os.environ["RENDERED"]
pull_secret_file = os.environ["PULL_SECRET_FILE"]

failures = 0

def ok(msg):
    print(f"PASS: {msg}")

def bad(msg):
    global failures
    failures += 1
    print(f"FAIL: {msg}")

# (a) The rendered file is valid YAML.
raw = open(rendered, "rb").read()
try:
    doc = yaml.safe_load(raw)
    if not isinstance(doc, dict):
        bad(f"install-config.yaml did not parse to a mapping (got {type(doc).__name__})")
        doc = {}
    else:
        ok("install-config.yaml is valid YAML")
except yaml.YAMLError as e:
    bad(f"install-config.yaml is not valid YAML: {e}")
    doc = {}

# (b) The pull secret round-trips byte-identical and still parses as JSON.
# The script does `$(cat FILE | tr -d '\n')`, i.e. all newlines stripped; command
# substitution also drops trailing newlines. Mirror that exactly.
original = open(pull_secret_file, "r").read().replace("\n", "")
rendered_secret = doc.get("pullSecret")
if rendered_secret is None:
    bad("pullSecret key missing from rendered install-config.yaml")
elif rendered_secret != original:
    bad("pullSecret is not byte-identical to the source after render")
    print(f"      original[:60]={original[:60]!r}")
    print(f"      rendered[:60]={rendered_secret[:60]!r}")
else:
    try:
        json.loads(rendered_secret)
        ok("pullSecret round-trips byte-identical and parses as JSON")
    except json.JSONDecodeError as e:
        bad(f"pullSecret is byte-identical but does not parse as JSON: {e}")

# (c) Every value under platform.aws.userTags is a string (not a date/number).
# PyYAML coerces bare 2026-07-27 to a datetime.date and bare 7 to an int, so a
# non-str here means an unquoted tag value slipped through.
aws = (doc.get("platform") or {}).get("aws") or {}
user_tags = aws.get("userTags")
if user_tags is None:
    print("NOTE: platform.aws.userTags absent — vacuous pass (guard ready for a future commit that adds tags)")
elif not isinstance(user_tags, dict):
    bad(f"platform.aws.userTags is not a mapping (got {type(user_tags).__name__})")
else:
    non_str = {k: type(v).__name__ for k, v in user_tags.items() if not isinstance(v, str)}
    if non_str:
        bad(f"userTags values must be strings; non-string: {non_str}")
    else:
        ok(f"all {len(user_tags)} userTags value(s) are strings")

print()
if failures:
    print(f"RESULT: {failures} assertion(s) FAILED")
    sys.exit(1)
print("RESULT: all assertions PASSED")
PY

echo
echo "== smoke.sh: OK =="
