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
4. **Create dated install dir** — `${INSTALL_DIR_PREFIX}-YYYYMMDD`.
5. **Render `install-config.yaml`** — `sed` substitutes the safe `__TOKEN__`
   placeholders; the pull secret is injected by a **pure-bash line rewrite** (never
   `sed`, since the JSON contains `/ + = { }`). **`--dry-run` exits here** — nothing
   below runs in dry-run mode.
6. **Create the cluster** — `openshift-install create cluster` (IPI on AWS), using
   the located binary (see below).
7. **Wait for core operators** — `oc wait` on authentication + kube-apiserver.
8. **Custom certificates** (skipped by `--skip-certs`) — generate API + Ingress
   keys/CSRs for the derived hostnames, sign with the local CA, apply as TLS
   secrets, install a trusted-CA configmap + patch the cluster proxy, patch
   `apiserver/cluster` and `ingresscontroller/default`, then embed the CA in the
   kubeconfig.
9. **OpenShift GitOps + Argo CD** (skipped by `--skip-gitops`) — create namespaces,
   apply `gitops-operator-install.yaml`, `cluster-rbac-argocd.yaml`, and
   `invaders-application.yaml`.

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
types, `OWNER`, `PURPOSE`, `TTL_DAYS`, `OCP_VERSION`, `INSTALL_DIR_PREFIX`,
`PULL_SECRET_FILE`, `INSTALL_CONFIG_TEMPLATE`, `CA_KEY_FILE`, `CA_CERT_FILE`. Paths
default repo-relative — **no personal absolute paths**. `LAB_ENV` (env only) points
at the config file; the smoke test uses it to inject a scratch `lab.env`.

**openshift-install locator:** `./$OCP_VERSION/openshift-install` →
`./openshift-install` → `$PATH`. This replaces the old "copy the script into a
version subdir" workflow.

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

## Conventions

- **bash**; new scripts start with `set -euo pipefail`.
- **No new dependencies** beyond `oc`, `openssl`, `awk`, `sed`, and coreutils.
  `jq` and `aws` are **optional** at runtime — preflight uses them only if present.
  (The test harness additionally uses `python3` + PyYAML for verification only.)
- Config is overridable via `lab.env`/environment/flags with repo-relative
  defaults — don't hardcode absolute or personal paths.
- `CLUSTER_NAME` stays the single source of truth for the cluster's identity.
- `--dry-run` must never reach any cluster or AWS operation.
