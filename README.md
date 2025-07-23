# ocp-install
A way to automatically deploy an OpenShift lab in AWS with all needed operators and dummy workloads.

In this phase the script just deploys the cluster in AWS. The AWS environment needs to be prepared. See my article for more details:
- https://www.linkedin.com/pulse/super-simple-openshift-lab-aws-roman-bobek-gfnqe/

How to use it
- clone the repository
- create a sub-directory under ocp-install (i'm using separate dirs for openshift y versions, i.e. 418, 419, etc.)
- move the ocp-install.sh to the created sub-directory
- download your pull secret to the ocp-install directory
- download the openshift installer to the sub-directory
- the final structure will look like this:
$ tree ocp-install/
[...]
├── 419
│   ├── ocp-install.sh
│   ├── openshift-install
│   └── README.md
├── install-config-template.yaml
└── pull-secret.txt

- run the ocp-install.sh script with the -d flag to specify the base domain
$ ./ocp-install.sh -d <mycluster.mydomain.com>

Next steps:
- Automate the Gitops operator deployment
- Automate the dummy workload deployment
 - Dummy workload is available in my https://github.com/neywa/retro-arcade-hub repo
- Automate deployment of customized observability stack
