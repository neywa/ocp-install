# CLAUDE.md

Guidance for working in this repo. Read before changing anything.

## What this repo does

`ocp-install.sh` deploys an OpenShift lab cluster on AWS via IPI, applies custom
API/Ingress certificates signed by a local CA, and bootstraps OpenShift GitOps.
The AWS environment must be prepared beforehand (see the README).

### Script phases, in order

1. **Parse flags / validate inputs** — `-d <base_domain>` (required) and
   `--dry-run` (optional). Verifies the pull secret, install-config template, and
   CA key/cert files exist.
2. **Create dated install dir** — `ocp-lab-YYYYMMDD`.
3. **Render `install-config.yaml`** — two `sed` substitutions into the template
   (`PULL_SECRET_PLACEHOLDER`, `BASE_DOMAIN_PLACEHOLDER`). **`--dry-run` exits
   here** — nothing below runs in dry-run mode.
4. **Create the cluster** — `openshift-install create cluster` (IPI on AWS).
5. **Wait for core operators** — `oc wait` on authentication + kube-apiserver.
6. **Custom certificates** — generate API + Ingress keys/CSRs, sign them with the
   local CA, apply as TLS secrets, install a trusted-CA configmap + patch the
   cluster proxy, and patch `apiserver/cluster` and `ingresscontroller/default`.
7. **Update kubeconfig** — embed the custom CA so the client trusts the new certs.
8. **Install OpenShift GitOps** — create namespaces, apply
   `gitops-operator-install.yaml` (OperatorGroup + Subscription), wait for ready.
9. **Argo CD cluster RBAC** — apply `cluster-rbac-argocd.yaml`.
10. **Deploy workload** — apply `invaders-application.yaml` (Argo CD Application).

Config paths (`PULL_SECRET_FILE`, `INSTALL_CONFIG_TEMPLATE`, `CA_KEY_FILE`,
`CA_CERT_FILE`, `INSTALL_DIR_PREFIX`) default to their normal values but are
overridable via the environment so the script is testable.

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
`openshift-install`/`oc` stubs on PATH), runs the script in `--dry-run`, and
asserts: the rendered `install-config.yaml` is valid YAML; the pull secret
round-trips byte-identical and still parses as JSON; every value under
`platform.aws.userTags` is a string (not a YAML-coerced date or number). Run with
`KEEP=1` to keep the scratch dir for inspection.

## Conventions

- **bash**; new scripts start with `set -euo pipefail`.
- **No new dependencies** beyond `oc`, `openssl`, `awk`, `sed`, and coreutils.
  (The test harness additionally uses `python3` + PyYAML and `jq`, which are for
  verification only — not runtime deps of `ocp-install.sh`.)
- Config paths are overridable via the environment, with the existing values as
  defaults — don't hardcode new absolute paths.
- `--dry-run` must never reach any cluster or AWS operation.
