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

Configuration precedence is: built-in defaults < `lab.env` < environment < CLI
flags. `CLUSTER_NAME` is the single source of truth — it sets `metadata.name` and
the API/console/ingress hostnames, so the custom certs always match the cluster.

Useful flags (`--help` lists them all):
```
-d, --base-domain <domain>    required
-c, --cluster-name <name>     default: rbobek
-r, --region <region>         default: eu-central-1
    --ttl-days <n>            expirationDate tag = today + n (default: 7)
    --dry-run                 render install-config.yaml and exit (no cluster/AWS)
    --skip-certs              skip custom certificate configuration
    --skip-gitops             skip OpenShift GitOps + Argo CD
```

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
