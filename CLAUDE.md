# CLAUDE.md

Guidance for working in this repo. Read before changing anything.

## What this repo does

`ocp-install.sh` deploys an OpenShift lab cluster on AWS via IPI, applies custom
API/Ingress certificates signed by a local CA, and bootstraps OpenShift GitOps.
The AWS environment must be prepared beforehand (see the README).

### Script phases, in order

1. **Parse flags** — short + long: `-d/--base-domain` (required), `-c/--cluster-name`,
   `-r/--region`, `--control-plane-replicas`, `--worker-replicas`,
   `--control-plane-type`, `--worker-type`, `--ttl-days`, `-f/--config` (template
   path), `--dry-run`, `--skip-certs`, `--skip-gitops`, `-h/--help`.
2. **Resolve config** — source `lab.env`, then apply defaults, then CLI overrides
   (see precedence below).
3. **Preflight** — one function that collects **all** errors before exiting:
   required tools, pull secret present + JSON-shaped, template present, CA files
   present (unless `--skip-certs`), and — if the `aws` CLI exists — `aws sts
   get-caller-identity` plus a Route53 hosted-zone check for the base domain.
4. **Create per-run install dir** — `${WORKDIR_ROOT}/${CLUSTER_NAME}-YYYYMMDD-HHMMSS`
   (default `WORKDIR_ROOT=$SCRIPT_DIR/clusters`; the whole `clusters/` tree is gitignored).
5. **Render `install-config.yaml`** — `sed` substitutes the safe `__TOKEN__`
   placeholders; the pull secret is injected by a **pure-bash line rewrite** (never
   `sed`, since the JSON contains `/ + = { }`). **`--dry-run` exits here** — nothing
   below runs in dry-run mode.
6. **Create the cluster** — `openshift-install create cluster` (IPI on AWS), using
   the located binary (see below).
7. **Wait for core operators** — `oc wait` on authentication + kube-apiserver.
8. **Custom certificates** (skipped by `--skip-certs`) — generate API + Ingress
   keys/CSRs for the derived hostnames (openssl configs written to real files;
   signed certs carry `basicConstraints/keyUsage/extendedKeyUsage=serverAuth`;
   keys `chmod 600`), sign with the local CA, install a trusted-CA configmap +
   patch the cluster proxy, create the TLS secrets, then — **ordering is critical**
   — `append_ca_to_kubeconfig` updates the local kubeconfig (appending the CA to
   the existing bundle, patching the entry derived from the current context)
   **before** patching `apiserver/cluster`, so the client keeps trusting the API
   once it serves the new cert. Patch `apiserver/cluster` + `ingresscontroller/default`,
   then `wait_co_settled` for kube-apiserver (2400s), ingress, authentication, console.
9. **OpenShift GitOps + Argo CD** (skipped by `--skip-gitops`) — create only the
   `openshift-gitops-operator` namespace (the operator owns `openshift-gitops`),
   apply `gitops-operator-install.yaml`, then `wait_for_object` + `oc wait`/`rollout
   status` through the operator deployment → `openshift-gitops` namespace → the
   `openshift-gitops-application-controller` statefulset. For each
   `ARGOCD_MANAGED_NAMESPACES` namespace (default `retro-invaders`),
   `grant_argocd_namespace` labels it `argocd.argoproj.io/managed-by=openshift-gitops`
   (operator then grants the controller **namespace-scoped** rights) plus a small
   monitoring Role for `prometheusrules`/`probes` — **never cluster-admin** (see
   README "Resolved"). Apply `invaders-application.yaml` **only if present** (warn
   otherwise); print the Argo CD route.

Day-2 cluster mutations are **idempotent and rerunnable**: every `oc create`
(namespace/secret/configmap) uses `oc create … --dry-run=client -o yaml | oc apply
-f -`, not `oc create … || true`. Once provisioning begins, an **ERR trap** prints
the exact `openshift-install destroy cluster --dir=…` command (guarded on
`metadata.json`) so a half-built cluster is never left silently in AWS; it is
cleared before the success banner. The rendered `install-config.yaml` embeds the
pull secret — it is `chmod 600` and copied to `install-config.yaml.bak` before the
installer consumes it.

**`CLUSTER_NAME` is the single source of truth.** It drives `metadata.name` in
install-config **and** the derived hostnames — `api.${CLUSTER_NAME}.${BASE_DOMAIN}`,
`*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}`, the console host — so the certs are always
issued for hostnames the cluster actually serves. Never reintroduce a second
hardcoded name.

### Config precedence & files

Resolution order (lowest → highest): **built-in defaults < `lab.env` <
environment < CLI flags**. `lab.env` (gitignored; copy from `lab.env.example`) uses
the `: "${VAR:=value}"` form so it never clobbers a value already in the
environment. Overridable vars: `CLUSTER_NAME`, `AWS_REGION`, replicas, instance
types, `OWNER`, `PURPOSE`, `TTL_DAYS`, `OCP_VERSION`, `WORKDIR_ROOT`,
`PULL_SECRET_FILE`, `INSTALL_CONFIG_TEMPLATE`, `CA_KEY_FILE`, `CA_CERT_FILE`,
`ARGOCD_MANAGED_NAMESPACES`, `MODULES`. Paths
default repo-relative — **no personal absolute paths**. `LAB_ENV` (env only) points
at the config file; the smoke test uses it to inject a scratch `lab.env`. `MODULES_DIR`
(env only, defaults to `$SCRIPT_DIR/modules`) points at the module tree — the smoke
test overrides it to inject scratch module fixtures, mirroring the `LAB_ENV` trick.

**openshift-install locator:** `./$OCP_VERSION/openshift-install` →
`./openshift-install` → `$PATH`. This replaces the old "copy the script into a
version subdir" workflow.

## Module system

Optional products (RHACS, RHACM, OADP, OpenShift Logging) are **modules** enabled by
a flag. A module is `modules/<name>/module.sh`, **sourced** by `ocp-install.sh`, so it
shares the `log/warn/die` helpers and the idempotency convention. Modules only ever
run against clusters this script built — **do not add foreign-cluster portability**.
(`modules/hello` is a throwaway test module that exercises the framework; delete it
when the first real module lands.)

**Dispatch is PHASE-MAJOR, never module-major.** The main flow loops over phases and,
within each phase, over the enabled modules — never one module end-to-end. Order:

```
resolve → preflight(all) → provision(all) → [cluster install] → install(all) → wait(all) → verify(all)
```

Every enabled module's **preflight must pass before anything is created**, so an
impossible combination fails in seconds rather than after a ~45-minute build. **Sizing
is resolved during `resolve`, before `install-config.yaml` is rendered**, because a
module may need a bigger worker pool than the default (`resolve_sizing`).

### Module contract

A module sets metadata globals at source time; the loader snapshots them into
per-module arrays and unsets the globals so the next module can't inherit stale values.
Hooks are functions named `<name>_<hook>` — collision-proof because the name embeds the
module. **Namespace every hook and internal variable with the module name.**

| Metadata global | Meaning |
|---|---|
| `MODULE_DESCRIPTION` | human text for `--list-modules` (**required**) |
| `MODULE_REQUIRES` | space-separated module names that must also be enabled |
| `MODULE_MIN_WORKERS` | worker-count floor; empty = no requirement |
| `MODULE_MIN_WORKER_TYPE` | worker instance-type floor; empty = no requirement |
| `MODULE_CREATES_AWS` | `true`/`false`: creates cluster-external AWS resources |

Hooks (all optional **except `install`**; a missing hook is skipped for that phase):

- `preflight` — validate config/tools/creds. **MUST NOT create anything.**
- `provision` — create cluster-external resources (S3/IAM), before the cluster exists.
- `install` — apply manifests to the cluster (**required**).
- `wait` — block until the module's workloads are actually ready.
- `verify` — assert the module works (**meaningful**, not just "pods Running").
- `destroy` — remove what install + provision created, including AWS resources.

**Dependencies** are expanded transitively with cycle detection and a deterministic
order (dependencies before dependents); the resolved set is logged when it differs from
what was asked for. **Sizing** raises `WORKER_REPLICAS`/`WORKER_TYPE` to the max floor
across the enabled set and logs loudly which module forced it — **never scales below
what the user asked for**. Instance types are **not** lexically ordered, so comparison
goes through the explicit `WORKER_TYPE_RANK` table; a type absent from the table is a
hard error, never a guess.

### Flags & modes

- `--with <a,b,c>` — enable modules on a fresh build (repeatable **and** comma-separated).
  `MODULES` (config var) does the same via `lab.env`/environment; `--with` appends.
- `--list-modules` — print modules with descriptions + floors, exit.
- `--add <a,b> --dir <path>` — install modules into an **existing** cluster. Skips
  cluster/cert/gitops entirely; sets `KUBECONFIG` from `<dir>/auth/kubeconfig`. Sizing
  **cannot** be applied to a live cluster, so add-mode preflight compares each floor
  against the **live node capacity** and **hard-fails** naming the module and shortfall
  rather than leaving pods Pending.
- `--remove <a,b> --dir <path>` — run `destroy` hooks (reverse dependency order) against
  an existing cluster. A module lacking a destroy hook is logged (possible orphans).
- `--dir` is required by `--add`/`--remove`; a missing dir or kubeconfig fails clearly.

Installed modules are recorded in `<install-dir>/modules.state` so `--remove` and
teardown know what to clean up.

### Failure semantics (chosen)

- **preflight (build): all-or-nothing, before any creation.** Collect every enabled
  module's preflight errors and abort if any — nothing is created. This is the
  "fail in seconds" guarantee.
- **provision/install/wait/verify: continue-on-failure, reported at the end.** These
  run *after* a ~45-minute cluster build already succeeded; aborting because one module
  failed would waste the working cluster and the other modules. A failed module is
  recorded, its own later phases and any modules that `REQUIRE` it are **skipped** (never
  install a dependent onto a broken dependency), and a **failure summary is printed at
  the very end** with a non-zero exit — never buried mid-log.

### Teardown

`openshift-install destroy cluster` does **not** remove a module's S3/IAM. The ERR-trap
and success-banner destroy hints are module-aware: if `modules.state` is non-empty they
tell you to `--remove` the installed modules **first** (runs destroy hooks), **then**
destroy the cluster, and name any installed module that has no destroy hook.

### How to write a module

1. Create `modules/<name>/module.sh`. Set `MODULE_DESCRIPTION` (required) and any floors
   /`MODULE_REQUIRES`/`MODULE_CREATES_AWS` it needs.
2. Implement `<name>_install` (required) and whichever of `preflight`/`provision`/`wait`
   /`verify`/`destroy` apply. **Prefix every function and variable with `<name>_`.**
3. Use the shared `log/warn/die` helpers and the idempotent
   `oc create … --dry-run=client -o yaml | oc apply -f -` pattern; `wait_for_object`
   is available for "wait until it exists".
4. Give `verify` a real assertion (read something back), and `destroy` must undo both
   `install` and `provision` (including AWS resources).
5. Add smoke coverage in `test/smoke.sh` using scratch module fixtures via `MODULES_DIR`
   and the stub `oc` — never touch a real cluster.

## HARD RULE — never touch a real cluster or AWS

**Never run `openshift-install create cluster`, `oc apply`, or any command that
touches a real cluster or AWS account.** A run costs money and takes ~45 minutes.

All verification here is **static only**. When you need to exercise the script,
use `--dry-run` (stops after rendering `install-config.yaml`) and the smoke test —
both are inert and never reach AWS.

## Verification

```bash
bash -n ocp-install.sh          # syntax check (always)
shellcheck ocp-install.sh       # lint, if installed (currently absent on this box)
bash test/smoke.sh              # static smoke test against throwaway fixtures
```

`test/smoke.sh` builds a scratch dir (fake pull secret, self-signed CA, inert
`openshift-install`/`oc`/`aws` stubs on PATH — the `aws` stub keeps preflight off
real AWS), runs the script in `--dry-run`, and asserts: the rendered
`install-config.yaml` is valid YAML; the pull secret round-trips byte-identical and
still parses as JSON; every `platform.aws.userTags` value is a string (the
`expirationDate` guard — an unquoted ISO date would parse as a YAML timestamp);
`CLUSTER_NAME` drives `metadata.name`; config precedence (flag > env > lab.env >
default); and preflight reports **all** errors in one run. Run with `KEEP=1` to keep
the scratch dir for inspection.

For the **module system** it additionally points `MODULES_DIR` at scratch module
fixtures and uses a state-aware `oc` stub (records a ConfigMap's value on `create`,
returns it on `get` — so a module `verify` genuinely round-trips) to assert: discovery
+ a malformed module rejected clearly; transitive dependency expansion + cycle
detection; sizing (max floor wins, a larger user topology is not scaled down, an
unknown instance type fails); `--list-modules`; `--add`/`--remove` require `--dir`;
**phase ordering** (all preflights before any install, across modules); and `--dry-run`
with modules still renders a valid install-config. When adding an `oc`-piped call to the
stub path, remember the stub drains `-f -` stdin so `oc create … | oc apply -f -` can't
SIGPIPE.

## Conventions

- **bash**; new scripts start with `set -euo pipefail`.
- **No new dependencies** beyond `oc`, `openssl`, `awk`, `sed`, and coreutils.
  `jq` and `aws` are **optional** at runtime — preflight uses them only if present.
  (The test harness additionally uses `python3` + PyYAML for verification only.)
- Config is overridable via `lab.env`/environment/flags with repo-relative
  defaults — don't hardcode absolute or personal paths.
- `CLUSTER_NAME` stays the single source of truth for the cluster's identity.
- `--dry-run` must never reach any cluster or AWS operation.
