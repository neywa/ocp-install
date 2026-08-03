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
# State-aware oc stub: a strict superset of the old echo-and-exit-0 behavior (so the
# existing tests are unaffected), plus just enough ConfigMap state to let a module's
# verify hook genuinely round-trip a value. `oc create configmap … --from-literal=
# greeting=X …` records X (the value is right there in argv); `oc get configmap … -o
# jsonpath={.data.greeting}` reads it back. Everything else echoes and succeeds.
STUB_STATE="$SCRATCH/oc-state"
mkdir -p "$STUB_STATE"
cat > "$STUB_BIN/oc" <<EOF
#!/usr/bin/env bash
STUB_STATE="$STUB_STATE"
EOF
cat >> "$STUB_BIN/oc" <<'EOF'
ns="default"
prev=""
for a in "$@"; do
    [ "$prev" = "-n" ] && ns="$a"
    prev="$a"
done
case "${1:-}" in
  create)
    if [ "${2:-}" = "configmap" ]; then
        name="${3:-}"
        for a in "$@"; do
            case "$a" in --from-literal=greeting=*) greeting="${a#--from-literal=greeting=}";; esac
        done
        mkdir -p "$STUB_STATE"
        printf '%s' "${greeting:-}" > "$STUB_STATE/cm.$ns.$name.greeting"
    fi
    ;;
  get)
    if [ "${2:-}" = "configmap" ] && printf '%s\n' "$@" | grep -q 'data.greeting'; then
        f="$STUB_STATE/cm.$ns.${3:-}.greeting"
        [ -f "$f" ] && cat "$f"
        exit 0
    fi
    # Simulate a worker pool for the --add capacity check. STUB_NODE_CPU/STUB_NODE_MEM
    # describe a single worker node (defaults to a small m6i.xlarge-ish one).
    if [ "${2:-}" = "nodes" ]; then
        if printf '%s\n' "$@" | grep -q 'allocatable.cpu'; then
            printf '%s' "${STUB_NODE_CPU:-3500m}"; exit 0
        elif printf '%s\n' "$@" | grep -q 'allocatable.memory'; then
            printf '%s' "${STUB_NODE_MEM:-15000000Ki}"; exit 0
        else
            echo "node/worker-0"; exit 0     # -o name -> one worker node
        fi
    fi
    ;;
esac
# Drain piped stdin (`oc apply -f -`) so an upstream `oc create … |` writer never
# takes a SIGPIPE (real `oc apply` reads the manifest; the stub must too).
case " $* " in *" -f - "*) cat >/dev/null 2>&1 || true ;; esac
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
            WORKDIR_ROOT="$rundir/clusters" \
            "${envs[@]}" \
            bash "$SCRIPT_UNDER_TEST" "$@"
    )
}

# =============================================================================
echo
echo "== Test 1: render + core assertions (default cluster name) =="
# Rendered install-config lands under the run dir; find it afterwards.
run_ocp run1 -- -d smoke.example.com --dry-run
RENDERED="$(find "$SCRATCH/run1" -maxdepth 3 -name install-config.yaml -type f | head -n1)"
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

# The rendered config embeds the pull secret and must be locked down.
if [ -n "$RENDERED" ]; then
    mode="$(stat -c '%a' "$RENDERED")"
    if [ "$mode" = "600" ]; then
        pass "rendered install-config.yaml is mode 600"
    else
        fail "rendered install-config.yaml mode is $mode, expected 600"
    fi
    # The install dir holds auth/, keys, and the config; must not be world-traversable.
    dmode="$(stat -c '%a' "$(dirname "$RENDERED")")"
    if [ "$dmode" = "700" ]; then
        pass "install directory is mode 700"
    else
        fail "install directory mode is $dmode, expected 700"
    fi
fi

# =============================================================================
echo
echo "== Test 2: CLI flag overrides lab.env (flag wins) =="
mkdir -p "$SCRATCH/run2"
cat > "$SCRATCH/run2/lab.env" <<'EOF'
: "${CLUSTER_NAME:=fromfile}"
EOF
run_ocp run2 -- -d smoke.example.com --cluster-name fromflag --dry-run >/dev/null
R2="$(find "$SCRATCH/run2" -maxdepth 3 -name install-config.yaml -type f | head -n1)"
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
R2B="$(find "$SCRATCH/run2b" -maxdepth 3 -name install-config.yaml -type f | head -n1)"
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
R3="$(find "$SCRATCH/run3" -maxdepth 3 -name install-config.yaml -type f | head -n1)"
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
echo "== Test 5: install-config.yaml.bak keeps the deploy record but redacts the secret =="
# The .bak is written only in the real install path (after --dry-run would exit),
# right before `create cluster`. Run WITHOUT --dry-run but with all stubs on PATH
# and --skip-certs/--skip-gitops, so it never touches AWS. Tolerate a non-zero
# exit: the .bak is produced before any stubbed stage that might fail.
set +e
run_ocp run5 -- -d smoke.example.com --skip-certs --skip-gitops >/dev/null 2>&1
set -e
BAK="$(find "$SCRATCH/run5" -maxdepth 3 -name install-config.yaml.bak -type f | head -n1)"
if [ -z "$BAK" ]; then
    fail "install-config.yaml.bak not found"
else
    pass "install-config.yaml.bak exists"
    if python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$BAK" 2>/dev/null; then
        pass ".bak parses as YAML"
    else
        fail ".bak does not parse as YAML"
    fi
    if grep -qF "$auth_a" "$BAK" || grep -qF "$auth_b" "$BAK" || grep -q 'token-aaaa' "$BAK"; then
        fail ".bak still contains the fixture pull secret"
    else
        pass ".bak does not contain the fixture pull secret"
    fi
    if grep -q "^pullSecret: '<redacted>'$" "$BAK"; then
        pass ".bak has pullSecret redacted"
    else
        fail ".bak is missing the redacted pullSecret line"
    fi
fi

# =============================================================================
echo
echo "== Test 6: bash -x does not leak the pull secret to the trace =="
# Trace the whole run under set -x; both the preflight read and the render
# injection touch the secret. --dry-run keeps it inert. Grep the trace for the
# fixture secret; it must not appear.
mkdir -p "$SCRATCH/run6"
XTRACE_ERR="$SCRATCH/run6/trace.err"
(
    cd "$SCRATCH/run6"
    env \
        PATH="$STUB_BIN:$PATH" \
        PULL_SECRET_FILE="$PULL_SECRET_FILE" \
        CA_KEY_FILE="$CA_KEY_FILE" \
        CA_CERT_FILE="$CA_CERT_FILE" \
        LAB_ENV="$SCRATCH/run6/lab.env" \
        WORKDIR_ROOT="$SCRATCH/run6/clusters" \
        bash -x "$SCRIPT_UNDER_TEST" -d smoke.example.com --dry-run
) >/dev/null 2>"$XTRACE_ERR" || true
if grep -qF "$auth_a" "$XTRACE_ERR" || grep -qF "$auth_b" "$XTRACE_ERR" || grep -q 'token-aaaa' "$XTRACE_ERR"; then
    fail "pull secret leaked into the bash -x trace"
else
    pass "bash -x trace does not contain the pull secret"
fi

# =============================================================================
echo
echo "== Test 7: .gitignore covers every runtime artifact under the new layout =="
# Prove (don't eyeball) that the repo .gitignore ignores each secret-bearing
# artifact path. Paths are hypothetical; git check-ignore evaluates rules, not
# the filesystem. Run against the real repo so the actual .gitignore is tested.
RUN_DIR_EX="clusters/rbobek-20260727-153012"
IGNORED_PATHS=(
    "$RUN_DIR_EX/install-config.yaml"
    "$RUN_DIR_EX/install-config.yaml.bak"
    "$RUN_DIR_EX/auth/kubeconfig"
    "$RUN_DIR_EX/auth/kubeadmin-password"
    "$RUN_DIR_EX/metadata.json"
    "$RUN_DIR_EX/custom-certs/api.key"
    "$RUN_DIR_EX/custom-certs/api.crt"
    "$RUN_DIR_EX/custom-certs/ca.srl"
)
for p in "${IGNORED_PATHS[@]}"; do
    if git -C "$REPO_DIR" check-ignore -q "$p"; then
        pass "ignored: $p"
    else
        fail "NOT ignored: $p"
    fi
done
# The example config must stay trackable (the !lab.env.example negation).
if git -C "$REPO_DIR" check-ignore -q lab.env.example; then
    fail "lab.env.example is ignored (negation broken)"
else
    pass "lab.env.example is trackable (not ignored)"
fi

# =============================================================================
# Module system tests. Modules are discovered from MODULES_DIR (env-overridable),
# so each test points it at a scratch fixture tree. mk_module writes a minimal valid
# module; mk_ordering_module writes one that defines every hook so the phase-major
# dispatcher emits a "[hook] module" marker we can assert order on.
# =============================================================================
MODS="$SCRATCH/mods"

# mk_module <root> <name> <requires> <min_workers> <min_type>
mk_module() {
    local root="$1" name="$2" reqs="$3" minw="$4" mint="$5"
    mkdir -p "$root/$name"
    cat > "$root/$name/module.sh" <<EOF
MODULE_DESCRIPTION="test module $name"
MODULE_REQUIRES="$reqs"
MODULE_MIN_WORKERS="$minw"
MODULE_MIN_WORKER_TYPE="$mint"
MODULE_CREATES_AWS="false"
${name}_install() { echo "PHASE:install:$name"; }
EOF
}

# mk_ordering_module <root> <name>: defines all five hooks so every phase is dispatched.
mk_ordering_module() {
    local root="$1" name="$2"
    mkdir -p "$root/$name"
    cat > "$root/$name/module.sh" <<EOF
MODULE_DESCRIPTION="ordering probe $name"
MODULE_REQUIRES=""
MODULE_MIN_WORKERS=""
MODULE_MIN_WORKER_TYPE=""
MODULE_CREATES_AWS="false"
${name}_preflight() { :; }
${name}_provision() { :; }
${name}_install()   { :; }
${name}_wait()      { :; }
${name}_verify()    { :; }
EOF
}

# -----------------------------------------------------------------------------
echo
echo "== Test 8: module discovery + malformed module rejected =="
mk_module "$MODS/ok" good "" "" ""
out8="$(run_ocp run8-list MODULES_DIR="$MODS/ok" -- --list-modules 2>&1)"
if grep -q "good" <<<"$out8" && grep -q "test module good" <<<"$out8"; then
    pass "discovery listed the scratch module with its description"
else
    echo "$out8"; fail "discovery did not list the scratch module"
fi
# Malformed: no MODULE_DESCRIPTION (write a module that only defines an install hook).
mkdir -p "$MODS/bad/bad"
cat > "$MODS/bad/bad/module.sh" <<'EOF'
bad_install() { :; }
EOF
set +e
out8b="$(run_ocp run8-bad MODULES_DIR="$MODS/bad" -- -d smoke.example.com --with bad --dry-run 2>&1)"
rc8b=$?
set -e
if [ "$rc8b" -ne 0 ] && grep -q "malformed" <<<"$out8b" && grep -q "'bad'" <<<"$out8b"; then
    pass "malformed module rejected with a clear, module-naming error"
else
    echo "$out8b"; fail "malformed module was not rejected clearly"
fi

# -----------------------------------------------------------------------------
echo
echo "== Test 9: dependency expansion (transitive) + cycle detection =="
mk_module "$MODS/dep" a "b" "" ""
mk_module "$MODS/dep" b "c" "" ""
mk_module "$MODS/dep" c "" "" ""
out9="$(run_ocp run9 MODULES_DIR="$MODS/dep" -- -d smoke.example.com --with a --dry-run 2>&1)"
if grep -q "resolved with dependencies" <<<"$out9" \
   && grep -Eq "resolved with dependencies \[a b c\]|resolved with dependencies \[.*a.*b.*c.*\]" <<<"$out9"; then
    pass "transitive dependency expansion (a -> b -> c) resolved and logged"
else
    echo "$out9" | grep -i "module\|resolved" || true
    fail "transitive dependency expansion not logged as expected"
fi
# Order: dependencies must come before dependents.
if grep -q "Module install order: c b a" <<<"$out9"; then
    pass "install order lists dependencies before dependents (c b a)"
else
    echo "$out9" | grep -i "install order" || true
    fail "install order did not put dependencies first"
fi
# Cycle x -> y -> x must be detected.
mk_module "$MODS/cyc" x "y" "" ""
mk_module "$MODS/cyc" y "x" "" ""
set +e
out9c="$(run_ocp run9c MODULES_DIR="$MODS/cyc" -- -d smoke.example.com --with x --dry-run 2>&1)"
rc9c=$?
set -e
if [ "$rc9c" -ne 0 ] && grep -qi "cycle" <<<"$out9c"; then
    pass "dependency cycle detected and reported"
else
    echo "$out9c"; fail "dependency cycle not detected"
fi

# -----------------------------------------------------------------------------
echo
echo "== Test 10: sizing — max floor wins, no scale-down, unknown type fails =="
mk_module "$MODS/size" big "" "3" "m6i.2xlarge"
# (a) Floor raises the default (1 / m6i.xlarge) up to 3 / m6i.2xlarge.
run_ocp run10a MODULES_DIR="$MODS/size" -- -d smoke.example.com --with big --dry-run >/dev/null 2>&1
R10A="$(find "$SCRATCH/run10a" -maxdepth 3 -name install-config.yaml -type f | head -n1)"
if R="$R10A" python3 - <<'PY'
import os, yaml, sys
doc = yaml.safe_load(open(os.environ["R"]))
w = doc["compute"][0]
ok = (w["replicas"] == 3 and w["platform"]["aws"]["type"] == "m6i.2xlarge")
print("  PASS: sizing raised topology to floor (3 / m6i.2xlarge)" if ok
      else f"  FAIL: expected 3/m6i.2xlarge, got {w['replicas']}/{w['platform']['aws']['type']}")
sys.exit(0 if ok else 1)
PY
then :; else FAILS=$((FAILS + 1)); fi
# (b) A larger user-specified topology is NOT scaled down.
run_ocp run10b MODULES_DIR="$MODS/size" -- -d smoke.example.com --with big \
    --worker-replicas 5 --worker-type m6i.4xlarge --dry-run >/dev/null 2>&1
R10B="$(find "$SCRATCH/run10b" -maxdepth 3 -name install-config.yaml -type f | head -n1)"
if R="$R10B" python3 - <<'PY'
import os, yaml, sys
w = yaml.safe_load(open(os.environ["R"]))["compute"][0]
ok = (w["replicas"] == 5 and w["platform"]["aws"]["type"] == "m6i.4xlarge")
print("  PASS: larger user topology preserved (5 / m6i.4xlarge, not scaled down)" if ok
      else f"  FAIL: expected 5/m6i.4xlarge, got {w['replicas']}/{w['platform']['aws']['type']}")
sys.exit(0 if ok else 1)
PY
then :; else FAILS=$((FAILS + 1)); fi
# (c) An unknown instance-type floor fails clearly.
mk_module "$MODS/size" badtype "" "" "z9.enormous"
set +e
out10c="$(run_ocp run10c MODULES_DIR="$MODS/size" -- -d smoke.example.com --with badtype --dry-run 2>&1)"
rc10c=$?
set -e
if [ "$rc10c" -ne 0 ] && grep -q "WORKER_TYPE_RANK" <<<"$out10c" && grep -q "z9.enormous" <<<"$out10c"; then
    pass "unknown instance type failed clearly (not in ranking table)"
else
    echo "$out10c"; fail "unknown instance type did not fail clearly"
fi

# -----------------------------------------------------------------------------
echo
echo "== Test 11: --list-modules prints descriptions and floors =="
mk_module "$MODS/list" sized "" "4" "m6i.4xlarge"
out11="$(run_ocp run11 MODULES_DIR="$MODS/list" -- --list-modules 2>&1)"
if grep -q "sized" <<<"$out11" && grep -q "workers>=4" <<<"$out11" && grep -q "type>=m6i.4xlarge" <<<"$out11"; then
    pass "--list-modules printed the module description and resource floor"
else
    echo "$out11"; fail "--list-modules did not print description + floor"
fi

# -----------------------------------------------------------------------------
echo
echo "== Test 12: --add/--remove require --dir; nonexistent dir fails =="
set +e
o12a="$(run_ocp run12a MODULES_DIR="$REPO_DIR/modules" -- --add hello 2>&1)";     rc12a=$?
o12b="$(run_ocp run12b MODULES_DIR="$REPO_DIR/modules" -- --remove hello 2>&1)";  rc12b=$?
o12c="$(run_ocp run12c MODULES_DIR="$REPO_DIR/modules" -- --add hello --dir "$SCRATCH/does-not-exist" 2>&1)"; rc12c=$?
set -e
if [ "$rc12a" -ne 0 ] && grep -q -- "--dir" <<<"$o12a"; then pass "--add without --dir failed"; else echo "$o12a"; fail "--add without --dir did not fail"; fi
if [ "$rc12b" -ne 0 ] && grep -q -- "--dir" <<<"$o12b"; then pass "--remove without --dir failed"; else echo "$o12b"; fail "--remove without --dir did not fail"; fi
if [ "$rc12c" -ne 0 ] && grep -qi "not found" <<<"$o12c"; then pass "--add with nonexistent --dir failed"; else echo "$o12c"; fail "--add with nonexistent --dir did not fail"; fi

# -----------------------------------------------------------------------------
echo
echo "== Test 13: phase ordering — all preflights before any install, etc. =="
mk_ordering_module "$MODS/order" om1
mk_ordering_module "$MODS/order" om2
# Full stubbed path (no --dry-run) so install/wait/verify actually dispatch; skip
# certs + gitops so it never approaches AWS. Stubs make every oc/openshift-install
# call succeed.
set +e
out13="$(run_ocp run13 MODULES_DIR="$MODS/order" -- \
    -d smoke.example.com --with om1,om2 --skip-certs --skip-gitops 2>&1)"
set -e
echo "$out13" > "$SCRATCH/order.log"
if PHASE_LOG="$SCRATCH/order.log" python3 - <<'PY'
import os, re, sys
order = ["preflight", "provision", "install", "wait", "verify"]
rank = {p: i for i, p in enumerate(order)}
seq = []
for line in open(os.environ["PHASE_LOG"]):
    m = re.match(r"\[(preflight|provision|install|wait|verify)\] module '(\w+)'", line)
    if m:
        seq.append((m.group(1), m.group(2)))
fails = 0
def bad(msg):
    global fails; fails += 1; print(f"  FAIL: {msg}")
# Every module must be seen in every phase.
mods = {mod for _, mod in seq}
if mods != {"om1", "om2"}:
    bad(f"expected modules om1,om2 in the phase log, saw {sorted(mods)}")
# The phase index must be non-decreasing across the whole run (phase-major dispatch).
last = -1
for phase, mod in seq:
    if rank[phase] < last:
        bad(f"phase '{phase}' ({mod}) ran after a later phase started (out of order)")
    last = max(last, rank[phase])
# Hard guarantee: the last preflight precedes the first install.
pre = [i for i, (p, _) in enumerate(seq) if p == "preflight"]
ins = [i for i, (p, _) in enumerate(seq) if p == "install"]
if pre and ins and max(pre) < min(ins):
    print("  PASS: all module preflights ran before any module install")
else:
    bad("preflight/install ordering guarantee violated")
if not fails:
    print("  PASS: phases dispatched in documented order across both modules")
sys.exit(1 if fails else 0)
PY
then :; else FAILS=$((FAILS + 1)); fi

# -----------------------------------------------------------------------------
echo
echo "== Test 13b: hello module install -> verify round-trips through the cluster =="
# Full stubbed path with the real repo `hello` module. The state-aware oc stub records
# the ConfigMap greeting on create and returns it on get, so hello_verify (which reads
# the value back and compares) is a genuine round-trip, not a no-op.
set +e
out13b="$(run_ocp run13b MODULES_DIR="$REPO_DIR/modules" -- \
    -d smoke.example.com --with hello --skip-certs --skip-gitops 2>&1)"
rc13b=$?
set -e
if [ "$rc13b" -eq 0 ] && grep -q "greeting round-tripped correctly" <<<"$out13b"; then
    pass "hello install/verify round-tripped the ConfigMap value (clean exit)"
else
    echo "$out13b" | grep -i "hello\|verify\|module\|fail" || true
    fail "hello install/verify round-trip did not succeed"
fi
# The install dir records the module so teardown/--remove know to clean it up.
STATE13B="$(find "$SCRATCH/run13b" -maxdepth 3 -name modules.state -type f | head -n1)"
if [ -n "$STATE13B" ] && grep -qE "^hello installed$" "$STATE13B"; then
    pass "modules.state records the installed module (status installed)"
else
    fail "modules.state did not record the installed module as installed"
fi

# -----------------------------------------------------------------------------
echo
echo "== Test 14: --dry-run with modules enabled still renders valid install-config =="
run_ocp run14 MODULES_DIR="$REPO_DIR/modules" -- -d smoke.example.com --with hello --dry-run >/dev/null 2>&1
R14="$(find "$SCRATCH/run14" -maxdepth 3 -name install-config.yaml -type f | head -n1)"
if [ -n "$R14" ] && R="$R14" python3 - <<'PY'
import os, yaml, json, sys
doc = yaml.safe_load(open(os.environ["R"]))
ok = isinstance(doc, dict) and doc.get("metadata", {}).get("name") == "rbobek"
try:
    json.loads(doc.get("pullSecret", ""))
except Exception:
    ok = False
print("  PASS: install-config renders and stays valid with a module enabled" if ok
      else "  FAIL: install-config invalid with a module enabled")
sys.exit(0 if ok else 1)
PY
then :; else FAILS=$((FAILS + 1)); fi

# -----------------------------------------------------------------------------
# Helper: a fake existing-cluster --dir (auth/kubeconfig + optional state lines).
mk_cluster_dir() {
    local dir="$1"; shift
    mkdir -p "$dir/auth"; : > "$dir/auth/kubeconfig"
    : > "$dir/modules.state"
    local line; for line in "$@"; do echo "$line" >> "$dir/modules.state"; done
}

echo
echo "== Test 15: --add capacity check sums allocatable CPU/mem, not node count =="
mkdir -p "$MODS/cap/heavy"
cat > "$MODS/cap/heavy/module.sh" <<'EOF'
MODULE_DESCRIPTION="heavy module with an allocatable floor"
# Build knobs consistent with the --add gate (1 × m6i.4xlarge = 15.5 CPU / 58Gi >= 8/32).
MODULE_MIN_WORKERS="1"
MODULE_MIN_WORKER_TYPE="m6i.4xlarge"
MODULE_MIN_CPU="8"
MODULE_MIN_MEMORY="32"
MODULE_CREATES_AWS="false"
heavy_install() { echo "PHASE:install:heavy"; }
EOF
CL15="$SCRATCH/cluster15"; mk_cluster_dir "$CL15"
# One undersized worker (3.5 CPU / ~14Gi): node count is 1, which the OLD check waved
# through; the capacity gate must reject it.
set +e
out15="$(run_ocp run15 MODULES_DIR="$MODS/cap" STUB_NODE_CPU=3500m STUB_NODE_MEM=15000000Ki \
    -- --add heavy --dir "$CL15" 2>&1)"
rc15=$?
set -e
if [ "$rc15" -ne 0 ] && grep -q "needs >= 8 CPU" <<<"$out15"; then
    pass "capacity check rejected a single undersized node (allocatable < floor)"
else
    echo "$out15"; fail "capacity check did not reject the undersized node"
fi
# A big-enough worker passes the gate.
CL15B="$SCRATCH/cluster15b"; mk_cluster_dir "$CL15B"
set +e
out15b="$(run_ocp run15b MODULES_DIR="$MODS/cap" STUB_NODE_CPU=16000m STUB_NODE_MEM=70000000Ki \
    -- --add heavy --dir "$CL15B" 2>&1)"
rc15b=$?
set -e
if [ "$rc15b" -eq 0 ] && ! grep -q "needs >=" <<<"$out15b"; then
    pass "capacity check passed when allocatable meets the floor"
else
    echo "$out15b"; fail "capacity check wrongly rejected an adequate cluster"
fi

# -----------------------------------------------------------------------------
echo
echo "== Test 16: a half-failed install is still recorded (so destroy will run) =="
mkdir -p "$MODS/pf/halffail"
cat > "$MODS/pf/halffail/module.sh" <<'EOF'
MODULE_DESCRIPTION="module whose install creates something then fails"
MODULE_CREATES_AWS="false"
# Simulate: the Subscription applies, but readiness never comes -> install fails.
halffail_install() { oc apply -f - >/dev/null 2>&1 <<<'kind: Subscription'; return 1; }
halffail_destroy() { :; }
EOF
set +e
out16="$(run_ocp run16 MODULES_DIR="$MODS/pf" -- \
    -d smoke.example.com --with halffail --skip-certs --skip-gitops 2>&1)"
rc16=$?
set -e
STATE16="$(find "$SCRATCH/run16" -maxdepth 3 -name modules.state -type f | head -n1)"
if [ "$rc16" -ne 0 ] && [ -n "$STATE16" ] && grep -qE "^halffail failed$" "$STATE16"; then
    pass "half-failed module recorded as 'failed' in state (destroy will cover it)"
else
    echo "--- state ---"; [ -n "$STATE16" ] && cat "$STATE16"; echo "rc=$rc16"
    fail "half-failed module was not recorded for cleanup"
fi

# -----------------------------------------------------------------------------
echo
echo "== Test 17: --teardown runs destroy hooks, THEN destroys the cluster =="
mkdir -p "$MODS/td/tdmod"
cat > "$MODS/td/tdmod/module.sh" <<'EOF'
MODULE_DESCRIPTION="teardown probe module"
MODULE_CREATES_AWS="false"
tdmod_install() { :; }
tdmod_destroy() { echo "DESTROY:tdmod"; }
EOF
CL17="$SCRATCH/cluster17"; mk_cluster_dir "$CL17" "tdmod installed"
set +e
out17="$(run_ocp run17 MODULES_DIR="$MODS/td" -- --teardown --dir "$CL17" 2>&1)"
rc17=$?
set -e
echo "$out17" > "$SCRATCH/td17.log"
d_line="$(grep -n 'DESTROY:tdmod' "$SCRATCH/td17.log" | head -n1 | cut -d: -f1)"
c_line="$(grep -n 'STUB openshift-install: destroy cluster' "$SCRATCH/td17.log" | head -n1 | cut -d: -f1)"
if [ "$rc17" -eq 0 ] && [ -n "$d_line" ] && [ -n "$c_line" ] && [ "$d_line" -lt "$c_line" ]; then
    pass "destroy hook ran before the cluster destroy"
else
    echo "$out17"; fail "teardown ordering wrong (destroy hook must precede cluster destroy)"
fi
if [ -f "$CL17/modules.state" ] && ! grep -q "tdmod" "$CL17/modules.state"; then
    pass "teardown cleared the module from state"
else
    fail "teardown did not clear the module from state"
fi

# -----------------------------------------------------------------------------
echo
echo "== Test 18: a failing destroy hook blocks the cluster destroy =="
mkdir -p "$MODS/td/tdfail"
cat > "$MODS/td/tdfail/module.sh" <<'EOF'
MODULE_DESCRIPTION="teardown probe whose destroy fails"
MODULE_CREATES_AWS="true"
tdfail_install() { :; }
tdfail_destroy() { echo "DESTROY:tdfail attempted"; return 1; }
EOF
CL18="$SCRATCH/cluster18"; mk_cluster_dir "$CL18" "tdfail installed"
set +e
out18="$(run_ocp run18 MODULES_DIR="$MODS/td" -- --teardown --dir "$CL18" 2>&1)"
rc18=$?
set -e
if [ "$rc18" -ne 0 ] && ! grep -q "STUB openshift-install: destroy cluster" <<<"$out18" \
   && grep -qi "NOT destroying the cluster" <<<"$out18"; then
    pass "failed destroy hook aborted before cluster destroy (no orphaned bucket)"
else
    echo "$out18"; fail "failed destroy hook did not block the cluster destroy"
fi
if [ -f "$CL18/modules.state" ] && grep -q "tdfail" "$CL18/modules.state"; then
    pass "failed module left in state for a retry"
else
    fail "failed module was wrongly cleared from state"
fi

# -----------------------------------------------------------------------------
echo
echo "== Test 19: --teardown without --dir fails clearly =="
set +e
out19="$(run_ocp run19 MODULES_DIR="$MODS/td" -- --teardown 2>&1)"; rc19=$?
set -e
if [ "$rc19" -ne 0 ] && grep -q -- "--dir" <<<"$out19"; then
    pass "--teardown without --dir failed clearly"
else
    echo "$out19"; fail "--teardown without --dir did not fail clearly"
fi

# -----------------------------------------------------------------------------
echo
echo "== Test 20: a provision hook (not the flag) forces the teardown hard-block =="
# The module creates cluster-external state in provision but FORGETS CREATES_AWS and has
# no destroy hook. The old flag-only check waved this through; deriving state from the
# provision hook must hard-block teardown so its bucket is never orphaned.
mkdir -p "$MODS/ext/tdforgot"
cat > "$MODS/ext/tdforgot/module.sh" <<'EOF'
MODULE_DESCRIPTION="creates external state in provision but forgot CREATES_AWS"
MODULE_CREATES_AWS="false"
tdforgot_provision() { :; }   # defined -> implies cluster-external state
tdforgot_install()   { :; }
# no destroy hook on purpose
EOF
CL20="$SCRATCH/cluster20"; mk_cluster_dir "$CL20" "tdforgot installed"
set +e
out20="$(run_ocp run20 MODULES_DIR="$MODS/ext" -- --teardown --dir "$CL20" 2>&1)"
rc20=$?
set -e
if [ "$rc20" -ne 0 ] && ! grep -q "STUB openshift-install: destroy cluster" <<<"$out20" \
   && grep -qi "NOT destroying the cluster" <<<"$out20"; then
    pass "provision-hook module with no destroy hook blocked the cluster destroy"
else
    echo "$out20"; fail "provision-hook module did not block the cluster destroy"
fi
if [ -f "$CL20/modules.state" ] && grep -q "tdforgot" "$CL20/modules.state"; then
    pass "blocked module left in state"
else
    fail "blocked module was wrongly cleared from state"
fi

# -----------------------------------------------------------------------------
echo
echo "== Test 21: load-time warning when provision hook and CREATES_AWS disagree =="
# (tdforgot above has a provision hook but CREATES_AWS=false.)
out21="$(run_ocp run21 MODULES_DIR="$MODS/ext" -- --list-modules 2>&1)"
if grep -q "tdforgot" <<<"$out21" && grep -qi "provision hook but MODULE_CREATES_AWS is not true" <<<"$out21"; then
    pass "load warned about the provision/CREATES_AWS mismatch, naming the module"
else
    echo "$out21"; fail "no load-time warning for the provision/CREATES_AWS mismatch"
fi

# -----------------------------------------------------------------------------
echo
echo "== Test 22: inconsistent sizing knobs are rejected at load =="
# Build (1 × m6i.xlarge = 3.5 CPU) cannot satisfy the module's own --add gate (8 CPU).
mkdir -p "$MODS/sz/badsize"
cat > "$MODS/sz/badsize/module.sh" <<'EOF'
MODULE_DESCRIPTION="knobs disagree: build too small for its own --add gate"
MODULE_MIN_WORKERS="1"
MODULE_MIN_WORKER_TYPE="m6i.xlarge"
MODULE_MIN_CPU="8"
MODULE_CREATES_AWS="false"
badsize_install() { :; }
EOF
set +e
out22="$(run_ocp run22 MODULES_DIR="$MODS/sz" -- -d smoke.example.com --with badsize --dry-run 2>&1)"
rc22=$?
set -e
if [ "$rc22" -ne 0 ] && grep -q "sizing is inconsistent" <<<"$out22" \
   && grep -q "badsize" <<<"$out22" && grep -q "MODULE_MIN_CPU=8" <<<"$out22"; then
    pass "inconsistent knobs rejected at load, naming module + both figures"
else
    echo "$out22"; fail "inconsistent knobs were not rejected at load"
fi
# A --add gate with no build knobs at all is also rejected.
mkdir -p "$MODS/sz/nobuild"
cat > "$MODS/sz/nobuild/module.sh" <<'EOF'
MODULE_DESCRIPTION="declares a gate but no build knobs to back it"
MODULE_MIN_CPU="8"
MODULE_CREATES_AWS="false"
nobuild_install() { :; }
EOF
set +e
out22b="$(run_ocp run22b MODULES_DIR="$MODS/sz" -- -d smoke.example.com --with nobuild --dry-run 2>&1)"
rc22b=$?
set -e
if [ "$rc22b" -ne 0 ] && grep -q "not MODULE_MIN_WORKERS" <<<"$out22b"; then
    pass "a --add gate without build knobs is rejected at load"
else
    echo "$out22b"; fail "a gate without build knobs was not rejected"
fi

# -----------------------------------------------------------------------------
echo
echo "== Test 23: consistent sizing knobs load and render =="
# Build (3 × m6i.2xlarge = 22.5 CPU / 86Gi) covers the gate (16 CPU / 48Gi).
mkdir -p "$MODS/sz/goodsize"
cat > "$MODS/sz/goodsize/module.sh" <<'EOF'
MODULE_DESCRIPTION="knobs agree"
MODULE_MIN_WORKERS="3"
MODULE_MIN_WORKER_TYPE="m6i.2xlarge"
MODULE_MIN_CPU="16"
MODULE_MIN_MEMORY="48"
MODULE_CREATES_AWS="false"
goodsize_install() { :; }
EOF
run_ocp run23 MODULES_DIR="$MODS/sz" -- -d smoke.example.com --with goodsize --dry-run >/dev/null 2>&1
R23="$(find "$SCRATCH/run23" -maxdepth 3 -name install-config.yaml -type f | head -n1)"
if [ -n "$R23" ] && python3 -c 'import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if isinstance(d,dict) else 1)' "$R23"; then
    pass "consistent module loaded and the build rendered a valid install-config"
else
    fail "consistent module failed to load/render"
fi

# =============================================================================
echo
if [ "$FAILS" -ne 0 ]; then
    echo "RESULT: $FAILS check(s) FAILED"
    exit 1
fi
echo "RESULT: all checks PASSED"
echo "== smoke.sh: OK =="
