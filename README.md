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
$ openshift-install destroy cluster --dir=ocp-lab-YYYYMMDD
```

where `ocp-lab-YYYYMMDD` is the per-run install directory (the `INSTALL_DIR_PREFIX`
plus the date). Run it from the repo root so the same installer binary is found.

## Verifying changes

The script never needs to touch AWS to be checked. Verify statically:
```
$ bash -n ocp-install.sh     # syntax
$ bash test/smoke.sh         # renders in --dry-run against throwaway fixtures
```

## Next steps
- Automate the dummy workload deployment
    - Dummy workload is available in my https://github.com/neywa/retro-arcade-hub repo
- Automate deployment of customized observability stack
