# ocp-install
A way to automatically deploy an OpenShift lab in AWS with all needed operators and dummy workloads.

In this phase the script deploys the cluster in AWS, applies custom API/Ingress
certificates signed by your own CA, and bootstraps OpenShift GitOps. The AWS
environment needs to be prepared. See my article for more details:
- https://www.linkedin.com/pulse/super-simple-openshift-lab-aws-roman-bobek-gfnqe/

## How to use it

- clone the repository
- copy `lab.env.example` to `lab.env` and edit it (cluster name, region, node
  counts/types, TTL, file paths). `lab.env` is gitignored.
```
$ cp lab.env.example lab.env
```
- download your pull secret to the repo root as `pull-secret.txt` (or point
  `PULL_SECRET_FILE` at it)
- download the `openshift-install` binary. The script locates it as
  `./<OCP_VERSION>/openshift-install`, then `./openshift-install`, then on `$PATH`
  — so you can keep separate y-version dirs (418, 419, …) without moving the
  script. Set `OCP_VERSION` in `lab.env` to pick one.
- run the script with at least the base domain:
```
$ ./ocp-install.sh -d mycluster.mydomain.com
```

## Configuration

Every setting resolves in this order, lowest to highest precedence:

```
built-in defaults  <  lab.env  <  environment  <  CLI flags
```

So a value in `lab.env` overrides the built-in default, an exported environment
variable overrides `lab.env`, and a CLI flag overrides everything. `lab.env` lives
next to the script and is gitignored.

`CLUSTER_NAME` is the single source of truth — it sets `metadata.name` and the
API/console/ingress hostnames (`api.<cluster>.<domain>`, `*.apps.<cluster>.<domain>`),
so the custom certificates always match the hostnames the cluster serves.

### Flags (`--help` prints this too)

```
Required:
  -d, --base-domain <domain>        Base domain (e.g. mylab.example.com)

Cluster shape:
  -c, --cluster-name <name>         Cluster name / metadata.name   (default: rbobek)
  -r, --region <region>             AWS region                     (default: eu-central-1)
      --control-plane-replicas <n>  Control-plane node count       (default: 1)
      --worker-replicas <n>         Worker node count              (default: 1)
      --control-plane-type <type>   Control-plane instance type    (default: m6i.xlarge)
      --worker-type <type>          Worker instance type           (default: m6i.xlarge)
      --ttl-days <n>                Days until expirationDate tag   (default: 7)

Files:
  -f, --config <file>               install-config template path
                                    (default: ./install-config-template.yaml)

Behaviour:
      --dry-run                     Render install-config.yaml and exit (no cluster/AWS)
      --skip-certs                  Skip custom certificate configuration
      --skip-gitops                 Skip OpenShift GitOps + Argo CD
  -h, --help                        Show help and exit
```

Both `--flag value` and `--flag=value` are accepted. `-d`/`--base-domain` is the
only required setting; it has no default.

### Environment / `lab.env` variables (no CLI flag)

Everything in the flag list above can also be set under the same name in `lab.env`
or the environment (the flag just wins). The variables below have **no flag** —
set them in `lab.env` or export them:

| Variable | Default | Meaning |
|---|---|---|
| `OWNER` | `rbobek` | `userTags.owner` (AWS tag). |
| `PURPOSE` | `lab` | `userTags.purpose` (AWS tag). |
| `OCP_VERSION` | *(empty)* | If set, prefer the `./<version>/openshift-install` binary. |
| `WORKDIR_ROOT` | `./clusters` | Fixed parent for all per-run install dirs (the whole tree is gitignored). |
| `PULL_SECRET_FILE` | `./pull-secret.txt` | Path to the OpenShift pull secret. |
| `CA_KEY_FILE` | `./certs/ca.key` | Local CA private key (custom certs). |
| `CA_CERT_FILE` | `./certs/ca.crt` | Local CA certificate. |
| `ARGOCD_MANAGED_NAMESPACES` | `retro-invaders` | Space-separated workload namespaces to scope Argo CD to (managed-by label + monitoring role, no cluster-admin). Must match your Applications' destination namespaces. See [Resolved](#resolved). |
| `LAB_ENV` | `./lab.env` | Path to the config file itself (env-only; used by the smoke test). |

`INSTALL_CONFIG_TEMPLATE` (the `-f`/`--config` target) defaults to
`./install-config-template.yaml`.

## What the script does

Run in order, each phase gated as noted:

1. **Parse & resolve config**, then **preflight** — collects *all* errors at once
   (required tools; pull secret present and JSON-shaped; template and CA files;
   and, if `aws` is installed, `sts get-caller-identity` + a Route53 zone check).
2. **Create the per-run install dir** `WORKDIR_ROOT/<cluster>-YYYYMMDD-HHMMSS` (`0700`).
3. **Render `install-config.yaml`** — pull secret injected safely, `chmod 600`, plus
   a redacted `.bak`. **`--dry-run` exits here** — nothing below touches AWS.
4. **Create the cluster** (`openshift-install create cluster`) and wait for core operators.
5. **Custom certificates** *(skipped by `--skip-certs`)* — CA-signed API + Ingress
   certs, trust wiring, and apiserver/ingress patches.
6. **OpenShift GitOps + Argo CD** *(skipped by `--skip-gitops`)* — install the
   operator, wait for Argo CD, scope Argo CD to each `ARGOCD_MANAGED_NAMESPACES`
   namespace (managed-by label + monitoring Role, not cluster-admin), apply
   `invaders-application.yaml` if present, and print the Argo CD route.

## AWS resource tagging

Every AWS resource the installer creates is tagged via `platform.aws.userTags`:

- `owner`   — from `OWNER` (default: `rbobek`)
- `purpose` — from `PURPOSE` (default: `lab`)
- `expirationDate` — today + `--ttl-days` (default 7), e.g. `2026-08-03`

The tag values are quoted strings in the rendered config on purpose: an unquoted
ISO date would be parsed as a YAML timestamp and break the installer's
`map[string]string` tag unmarshalling.

## Tearing down

The script prints the exact teardown command when it finishes (and, on failure, if
a cluster was created). It is:

```
$ openshift-install destroy cluster --dir=clusters/<cluster-name>-YYYYMMDD-HHMMSS
```

where `clusters/<cluster-name>-YYYYMMDD-HHMMSS` is the per-run install directory.
Every run lives under `WORKDIR_ROOT` (default `./clusters`, the whole tree is
gitignored). Run the command from the repo root so the same installer binary is found.

## Verifying changes

The script never needs to touch AWS to be checked. Verify statically:
```
$ bash -n ocp-install.sh     # syntax
$ bash test/smoke.sh         # renders in --dry-run against throwaway fixtures
```

## Resolved

### Argo CD permissions: scoped per-namespace, not cluster-admin

The repo used to carry `cluster-rbac-argocd.yaml`, a ClusterRole granting the
`openshift-gitops` application controller **cluster-admin** (read every Secret in
every namespace). The open question was whether it was even needed — the hypothesis
being that the OpenShift GitOps operator already grants the default instance enough.

**Tested (RBAC off) — result: not redundant, but cluster-admin was the wrong fix.**
With no grant, the Invaders `Application` failed to sync with `SyncError`s:
```
services / deployments.apps / routes.route.openshift.io /
prometheusrules.monitoring.coreos.com / probes.monitoring.coreos.com is forbidden:
User "system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller" ...
```
Every forbidden resource is **namespaced** and in the **single target namespace**
(`retro-invaders`). The controller wasn't missing cluster-wide power — it was
missing permission in a namespace it was never authorized to manage. The default
`openshift-gitops` instance only manages `openshift-gitops` plus namespaces labeled
`argocd.argoproj.io/managed-by=openshift-gitops`; the auto-created target had no
such label.

**Fix (implemented):** the script now scopes Argo CD per namespace instead of
granting cluster-admin. For each namespace in `ARGOCD_MANAGED_NAMESPACES` (default
`retro-invaders`) it:
1. creates the namespace and labels it `argocd.argoproj.io/managed-by=openshift-gitops`,
   so the operator reconciles a **namespace-scoped** RoleBinding for the controller; and
2. adds a small namespaced Role for the monitoring CRDs (`prometheusrules`, `probes`)
   that the operator's managed-namespace role doesn't cover.

The controller can now manage `retro-invaders` and nothing outside it — no
cross-namespace or Secret-read access. `cluster-rbac-argocd.yaml` has been deleted.
Set `ARGOCD_MANAGED_NAMESPACES` to match your Applications' destination namespaces.

## Next steps
- Automate the dummy workload deployment
    - Dummy workload is available in my https://github.com/neywa/retro-arcade-hub repo
- Automate deployment of customized observability stack
