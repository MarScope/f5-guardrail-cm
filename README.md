# F5 AI Security on Amazon EKS

This repository automates an Amazon EKS proof of concept for F5 AI Security Guardrails, with optional Red Team.

The PoC uses:

- Amazon EKS with one Guardrails GPU managed node group
- Optional second GPU managed node group for Red Team
- F5 AI Security Operator installed from Harbor
- Guardrails inference enabled
- Red Team optional and disabled by default
- In-cluster PostgreSQL
- F5 NGINX Ingress Controller for NGINX Open Source
- Optional Route 53 DNS management
- Self-signed TLS for lab access
- Ingress load balancer restricted to your source addresses
- Initial admin password replaced during deployment, before the ingress exists

For a step-by-step, instructor-led walkthrough (deploy, connect Amazon Bedrock, test with LobeChat and a multi-agent app), see the [AI Security - EKS Lab Guide](docs/ai-security-eks-lab-guide.md). The guide uses three supporting files in this repository: `config/lab.env.example` (the student's values file), `scripts/labvar` with `scripts/lab-helpers.sh` (helper commands that store values and secrets without hand-editing files), and `docs/iam/lab-scoped-policy.json` (a scoped IAM policy for the lab, not yet run end to end).

Route 53 is optional. If you do not use Route 53, the script still deploys the environment and `status` shows the ingress load balancer hostname. Point your hostname at it with another DNS provider or, for a single machine, a local hosts-file entry.

## Architecture

```text
Browser
  |
  | https://guardrails.f5demo.io
  v
DNS record
  |
  v
AWS Network Load Balancer  (internet-facing)
  |
  | node security group: only ALLOWED_SOURCE_CIDRS
  v
NGINX Ingress Controller  (TLS, self-signed certificate)
  |
  +-- /auth -> cai-moderator:8080  (Keycloak)
  |
  +-- /     -> cai-moderator:5500  (F5 AI Security UI/API)
```

## Application Namespaces

| Namespace | Purpose |
| --- | --- |
| `f5-ai-sec` | F5 AI Security Operator |
| `cai-moderator` | Guardrails UI/API, Keycloak auth, PostgreSQL |
| `prefect` | Prefect server, worker, workflow registration |
| `f5-ai-sec-inference` | Inference service, Guardrails scanner model, and the Red Team model when enabled |
| `nginx-ingress` | F5 NGINX Ingress Controller and AWS load balancer |

## Sizing Note

The F5 runbook recommends more headroom for single-node deployments. For Guardrails only, this PoC uses `g5.4xlarge` as the smallest practical AWS GPU instance because it provides:

- 1 NVIDIA A10G GPU with 24 GiB VRAM
- 16 vCPU
- 64 GiB memory

For Guardrails only, `g5.4xlarge` worked in this PoC. For Guardrails and Red Team together, the F5 runbook calls for dedicated GPUs per product:

- Guardrails: 1 GPU with at least 24 GB VRAM
- Red Team: 1 GPU with at least 48 GB VRAM

That means both products together need two GPUs. This script keeps cost lower by using two managed node groups when Red Team is enabled: `g5.4xlarge` for Guardrails and `g6e.2xlarge` for Red Team. The F5 operator image includes the inference chart, where Guardrails uses KubeAI resource profile `nvidia-gpu-a10g:1` and Red Team uses `nvidia-gpu-l40s:1`. The script adds node selectors to those KubeAI resource profiles so each model lands on the intended EKS managed node group.

## Prerequisites and Preflight

The script checks prerequisites before deployment. You do not need to manually run every AWS and Kubernetes verification command unless troubleshooting.

Required local tools:

- `aws`
- `kubectl`
- `helm`
- `eksctl`
- `openssl`
- `python3`
- `curl`

Required inputs:

- AWS CLI credentials with permissions for EKS, EC2, IAM, CloudFormation, ELB, and EBS, plus Route 53 if `ROUTE53_ENABLED=true`. `AdministratorAccess` in a sandbox account is the simplest choice. For a scoped alternative, attach `AmazonEC2FullAccess`, `AWSCloudFormationFullAccess`, and a customer managed policy made from `docs/iam/lab-scoped-policy.json`. Step 1.4 of the lab guide lists what each permission is for.
- Route 53 hosted zone for the selected hostname, only if `ROUTE53_ENABLED=true`
- Outbound HTTPS to `checkip.amazonaws.com` so the script can detect your public IP, unless you list addresses in `ALLOWED_SOURCE_CIDRS` yourself
- Harbor registry credentials for `harbor.calypsoai.app`
- F5 AI Security license string
- LLM provider credentials for post-install app configuration

Configure AWS CLI:

```bash
aws configure
```

Run preflight:

```bash
./scripts/guardrails-poc.sh preflight
```

The preflight check validates local tools, secret inputs, the source addresses the load balancer will accept, the admin password plan, AWS identity, region, optional Route 53 settings, GPU instance availability, GPU quota visibility, Harbor login, license input, and `eksctl` cluster configuration.

Two limits to know about:

- The GPU quota check only reports the quota value. It does not compare it with what the node groups need (16 vCPUs for Guardrails, 8 more for Red Team).
- When `ROUTE53_HOSTED_ZONE_ID` is set, preflight accepts it as written and does not confirm the zone exists in your account. A wrong ID fails later, during `up`.

## Script Deployment

Use the script for normal PoC lifecycle operations.

```bash
./scripts/guardrails-poc.sh preflight
./scripts/guardrails-poc.sh up
./scripts/guardrails-poc.sh status
./scripts/guardrails-poc.sh access
./scripts/guardrails-poc.sh down --yes
```

| Action | Purpose |
| --- | --- |
| `preflight` | Check tools, inputs, and AWS access. Changes nothing. |
| `up` | Deploy, or continue a partial deployment |
| `status` | Print a health summary |
| `access` | Re-apply the allowed source addresses, for example after your IP changes. See `scripts/allowed-ips.sh` to view and edit the list. |
| `down` | Delete the environment. Asks you to type `DELETE` unless `--yes` is given. |

Options: `--config FILE` uses a config file other than `config/guardrails-poc.env`. `--dry-run` prints the commands `up`, `down`, `status`, or `access` would run without changing anything. If `config/guardrails-poc.env` does not exist, the script falls back to the example file.

The script is idempotent. If deployment stops partway through, rerun `up`; it reuses existing AWS and Kubernetes resources and continues from the current state.

### Estimate the Cost

`scripts/cost-estimate.sh` reads the same config file and prints the hourly cost of the requested resources, the cost for a session, and what it costs if left running. It is read-only.

```bash
./scripts/cost-estimate.sh                 # 4 hours, one deployment
./scripts/cost-estimate.sh --hours 8
./scripts/cost-estimate.sh --students 12   # total for a class
./scripts/cost-estimate.sh --offline       # built-in prices only
```

Server prices come from the AWS Price List API when the role allows `pricing:GetProducts`; otherwise the script uses built-in us-east-1 list prices recorded on 2026-11-20. Bedrock usage, data transfer, F5 licensing and account discounts are not included.

`preflight` also checks the account's VPC limit (each deployment creates one VPC; the default limit is 5 per region) and looks for a CloudFormation stack left behind by an earlier failed attempt.

### Configure Inputs

Copy the example config:

```bash
cp config/guardrails-poc.env.example config/guardrails-poc.env
```

Edit `config/guardrails-poc.env` if you need to change region, cluster name, hostname, hosted zone, node groups, Red Team, Route 53, ingress, access control, or secret file paths.

Default secret paths:

```bash
HARBOR_CREDENTIALS_FILE="config/harbor.txt"
F5_LICENSE_FILE="config/license.txt"
```

File formats:

- `config/harbor.txt`: Harbor username on the first line, password on the second.
- `config/license.txt`: the license string and nothing else.

Both files are ignored by git. Instead of files you can export `HARBOR_USERNAME` and `HARBOR_PASSWORD`, and `F5_LICENSE_STRING`. Environment variables take precedence over the files.

Important feature toggles and their defaults in the example config:

```bash
ROUTE53_ENABLED="false"
ENABLE_RED_TEAM="false"
RESTRICT_INGRESS_SOURCE="true"
ROTATE_DEFAULT_PASSWORD="true"
```

When Route 53 is disabled, the script still creates the ingress load balancer and `status` shows its hostname. You can then create DNS manually with any DNS provider or use a hosts-file entry.

Set `ROUTE53_ENABLED=true` to let the script create a CNAME for `HOSTNAME` in your hosted zone. Set `ROUTE53_ZONE_NAME` and `ROUTE53_HOSTED_ZONE_ID` to your own zone. The example file contains the zone name and ID of the original author's zone, which will not work in your account. If you leave `ROUTE53_HOSTED_ZONE_ID` empty, the script looks the zone up by name.

When Red Team is enabled, make sure the license covers Red Team. Default node groups:

```bash
GUARDRAIL_NODEGROUP_NAME="guardrails-gpu-ng"
GUARDRAIL_NODE_TYPE="g5.4xlarge"

RED_TEAM_NODEGROUP_NAME="redteam-gpu-ng"
RED_TEAM_NODE_TYPE="g6e.2xlarge"
```

Relative paths are resolved from the repository root.

### Check Available Operator Chart Versions

To verify or update to the latest F5 AI Security Operator version in Harbor before installing:

```bash
# Log in to Harbor
sed -n '2p' config/harbor.txt | helm registry login harbor.calypsoai.app --username "$(sed -n '1p' config/harbor.txt)" --password-stdin

# Check latest chart version
helm show chart oci://harbor.calypsoai.app/calypsoai/f5-ai-security-operator-helm
```

Update `OPERATOR_CHART_VERSION` in `config/guardrails-poc.env` with the desired version tag. The example config pins `1.10.0`. If the setting is missing altogether, the script falls back to `1.4.1`.

### Deploy

```bash
./scripts/guardrails-poc.sh up
```

Expected runtime is roughly 25-45 minutes for a new environment because EKS control plane, GPU node, add-ons, images, model pod, ingress load balancer, and DNS all need time to come online.

Before it creates the ingress, the script replaces the initial admin password and restricts the load balancer to your source addresses. See [Access Control and First Login](#access-control-and-first-login).

At the end, the script prints a concise status summary with component health, UI URL, where the admin password is stored, and password-change links.

### Status

```bash
./scripts/guardrails-poc.sh status
```

Example:

```text
Guardrails PoC status
=====================
Environment:               running
Public URL:                online (https://guardrails.f5demo.io)
DNS:                       present -> <load-balancer>
Ingress LB:                ready -> <load-balancer>
Ingress access:            ready (restricted to 198.51.100.7/32; this machine is 198.51.100.7)
Admin password:            ready (initial password rejected)
EKS cluster:               ACTIVE, Kubernetes 1.35, region us-east-1
Node:                      1/1 Ready, type g5.4xlarge
Guardrails node group:     ACTIVE, 1 desired (1-1), type g5.4xlarge
Storage:                   ready (EBS CSI active, gp2 default)
f5-ai-security-operator:   ready (1/1 replicas)
cai-moderator:             ready (2/2 pods)
f5-ai-sec-inference:       ready (2/2 pods)
Red Team:                  disabled
prefect:                   ready (3/3 pods)
nginx-ingress:             ready (1/1 replicas)
EBS leftovers:             none found
```

The summary is followed by an **Access** block (UI URL, username, where the password is stored) and suggested next actions.

With `ROUTE53_ENABLED=false` the first two lines read `Public URL: not verified (DNS not managed by script)` and `DNS: disabled ...`, and the next-actions hint still suggests running `up`. That is expected: the script does not test a hostname it did not create. With `ENABLE_RED_TEAM=true` a `Red Team node group` line appears and `Node` shows `2/2 Ready`.

### Stop and Delete

```bash
./scripts/guardrails-poc.sh down --yes
```

This deletes the Route 53 record when enabled, the EKS cluster, GPU node groups, load balancer, EBS volumes created through the cluster, available leftover cluster-owned EBS volumes, and `eksctl` CloudFormation stacks.

It does not delete local files. `.secrets/admin-password` and `.secrets/postgres-password` stay on your machine and are reused by the next `up`. Delete the `.secrets/` folder yourself when you are finished with the PoC.

## Access Control and First Login

The platform ships with published initial credentials (`admin` / `pass`) and the ingress is an internet-facing load balancer. `up` addresses both before anything is reachable from outside the cluster.

> **Verification status:** these two safeguards were tested against local stand-ins (a stub of the Keycloak endpoints, and fake `kubectl` and `helm` commands). They have not yet been run against a live cluster. On your first deployment, confirm both with `status` and the checks below.

### Source address restriction

The ingress controller service is created with `loadBalancerSourceRanges` set from the first install, so the load balancer is not created open to every address. Kubernetes enforces the list by writing inbound rules for the service's node ports into the security group on the cluster nodes.

| Setting | Default | Meaning |
| --- | --- | --- |
| `RESTRICT_INGRESS_SOURCE` | `true` | Set to `false` to accept any address (not recommended) |
| `ALLOWED_SOURCE_CIDRS` | `auto` | `auto` is the public IP of the machine running the script. Add more IPv4 addresses or CIDRs separated by spaces or commas, for example `auto 203.0.113.0/24`. |

To view or change the list on a running deployment, use `scripts/allowed-ips.sh`. It updates `ALLOWED_SOURCE_CIDRS` in the config file and applies the change in one step, without a redeploy:

```bash
./scripts/allowed-ips.sh show                 # configured list, live list, your IP, and the security group rules
./scripts/allowed-ips.sh refresh              # your public IP changed (VPN, different network)
./scripts/allowed-ips.sh add 203.0.113.10     # allow another address or CIDR
./scripts/allowed-ips.sh remove 203.0.113.10
./scripts/allowed-ips.sh set me 203.0.113.10  # replace the whole list ("me" is this machine)
```

`./scripts/guardrails-poc.sh access` is equivalent to `refresh`. Add `--dry-run` to preview a change.

To allow an address from the AWS console instead, add inbound rules to the cluster security group (EKS > Clusters > your cluster > Networking > Cluster security group). Create one **Custom TCP** rule per ingress node port, which are the two ports on the existing rules described `kubernetes.io/rule/nlb/client=...`, with the address as the source. Leave the `kubernetes.io/` rules alone, because Kubernetes recreates them. Console rules are additive and are not written back to the config. Appendix D of the [lab guide](docs/ai-security-eks-lab-guide.md) has the click-by-click steps.

`status` shows the current list and whether this machine is in it. `auto` is resolved each time `up` or `access` runs, so rerunning either from a new address replaces the old one.

To check what AWS enforces, list the inbound rules of the cluster security group. No rule for the ingress node ports should have `0.0.0.0/0` as its source:

```bash
SG_ID=$(aws eks describe-cluster --name f5-guardrails-poc --region us-east-1 \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
aws ec2 describe-security-group-rules --region us-east-1 \
  --filters "Name=group-id,Values=$SG_ID" \
  --query 'SecurityGroupRules[?IsEgress==`false`].[FromPort,ToPort,CidrIpv4,Description]' --output table
```

### Initial password replacement

After the platform pods are up and **before** the ingress is installed, the script reaches the embedded Keycloak through `kubectl port-forward` to `svc/cai-moderator` port `8080`. It signs in to the `master` realm with the initial credentials, replaces the password of `admin` in the `master` realm and in every realm in `GUARDRAILS_AUTH_REALMS`, and then checks that the initial password is rejected. A realm that does not exist is skipped.

| Setting | Default | Meaning |
| --- | --- | --- |
| `ROTATE_DEFAULT_PASSWORD` | `true` | Set to `false` to keep the initial password until you change it by hand |
| `ADMIN_PASSWORD_FILE` | `.secrets/admin-password` | First line is the admin password. Generated if the file does not exist. |
| `GUARDRAILS_ADMIN_PASSWORD` (environment) | unset | Overrides the file |
| `ALLOW_DEFAULT_PASSWORD` | `false` | By default `up` stops before creating the ingress if the password could not be replaced. Set to `true` to continue anyway. |

Read the password:

```bash
cat .secrets/admin-password
```

Then log in at `https://<HOSTNAME>` as `admin`. The file is not written when `GUARDRAILS_ADMIN_PASSWORD` is used.

If the password was already changed by hand on an existing deployment, put the current password on the first line of `.secrets/admin-password` before rerunning `up`. Otherwise the script cannot sign in and stops.

The Guardrails UI account page does not expose password management. To choose your own password, use the embedded Keycloak account console for each realm, then put the new password on the first line of `.secrets/admin-password` so later `up` runs can still sign in:

```text
https://<HOSTNAME>/auth/realms/master/account/#/security/signingin
https://<HOSTNAME>/auth/realms/calypsoai/account/#/security/signingin
```

Keycloak passwords are realm-specific.

## Manual Deployment Reference

The script is the recommended path. Use this section only if you want to understand or manually reproduce what the script does.

### 1. Create EKS

```bash
eksctl create cluster \
  --name f5-guardrails-poc \
  --region us-east-1 \
  --version 1.35 \
  --managed \
  --nodegroup-name guardrails-gpu-ng \
  --node-type g5.4xlarge \
  --nodes 1 \
  --nodes-min 1 \
  --nodes-max 1 \
  --node-volume-size 150 \
  --node-ami-family AmazonLinux2023 \
  --install-nvidia-plugin \
  --vpc-nat-mode Disable
```

If Red Team is enabled, add a second managed GPU node group:

```bash
eksctl create nodegroup \
  --cluster f5-guardrails-poc \
  --region us-east-1 \
  --name redteam-gpu-ng \
  --node-type g6e.2xlarge \
  --nodes 1 \
  --nodes-min 1 \
  --nodes-max 1 \
  --node-volume-size 150 \
  --node-ami-family AmazonLinux2023 \
  --managed \
  --install-nvidia-plugin
```

### 2. Prepare Storage

```bash
eksctl create addon \
  --cluster f5-guardrails-poc \
  --region us-east-1 \
  --name eks-pod-identity-agent \
  --force

eksctl create addon \
  --cluster f5-guardrails-poc \
  --region us-east-1 \
  --name aws-ebs-csi-driver \
  --auto-apply-pod-identity-associations \
  --force

kubectl patch storageclass gp2 \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

### 3. Install Operator and Guardrails

```bash
kubectl create namespace f5-ai-sec

kubectl create secret docker-registry regcred \
  --docker-server='harbor.calypsoai.app' \
  --docker-username='<HARBOR_USERNAME>' \
  --docker-password='<HARBOR_PASSWORD>' \
  -n f5-ai-sec

helm registry login harbor.calypsoai.app

helm upgrade --install f5-ai-security-operator \
  oci://harbor.calypsoai.app/calypsoai/f5-ai-security-operator-helm \
  --version 1.10.0 \
  -n f5-ai-sec
```

Apply a `SecurityOperator` custom resource with:

- `registryAuth.existingSecret: regcred`
- in-cluster PostgreSQL enabled
- `CAI_MODERATOR_BASE_URL` set to `https://guardrails.f5demo.io`
- `CAI_MODERATOR_DEFAULT_LICENSE` set to your F5 license string
- Guardrails inference enabled
- Red Team enabled only if your license and GPU capacity support it
- KubeAI resource profile node selectors for `nvidia-gpu-a10g` and, when enabled, `nvidia-gpu-l40s`

### 4. Complete Supporting Services

The first manual deployment required these steps, which are now automated by the script:

- Wait for Prefect API health before recreating the workflow registration job.
- Replace the initial `admin` password in Keycloak before any ingress exists (see [Access Control and First Login](#access-control-and-first-login)).
- Install F5 NGINX Ingress Controller with an internet-facing AWS NLB, with `controller.service.loadBalancerSourceRanges` set to the addresses that may connect.
- Create a self-signed TLS secret for `guardrails.f5demo.io`.
- Create an ingress routing `/auth` to port `8080` and `/` to port `5500` on `cai-moderator`.
- Optionally create a Route 53 CNAME from `guardrails.f5demo.io` to the ingress load balancer.

## Troubleshooting

Use the script summary first:

```bash
./scripts/guardrails-poc.sh status
```

Useful detailed commands:

```bash
kubectl get pods -A
kubectl get svc -n nginx-ingress nginx-ingress-controller -o wide
kubectl get ingress -n cai-moderator -o wide
kubectl logs -n cai-moderator deploy/cai-moderator --tail=100
kubectl logs -n f5-ai-sec deploy/controller-manager --tail=100
kubectl logs -n f5-ai-sec-inference deploy/f5-ai-sec-inference --tail=100
kubectl logs -n prefect deploy/prefect-server --tail=100
```

If Route 53 is enabled and the public URL is not reachable immediately after the record is updated, wait a few minutes for DNS propagation and local resolver cache refresh. If Route 53 is disabled, create a DNS record manually, or a hosts-file entry, that points your hostname to the ingress load balancer.

Access-control problems:

| Symptom | Cause | Fix |
| --- | --- | --- |
| The UI or `curl` hangs and times out | Your public IP is not in the allowed list, often after a VPN or network change | `./scripts/guardrails-poc.sh access`, then wait about a minute |
| `status` shows `Ingress access: failed (open to every address ...)` | The service has no source restriction, for example a deployment made before this feature | `./scripts/guardrails-poc.sh access` |
| `up` stops with "Could not reach the login service" | Platform pods were not ready | Check `kubectl get pods -n cai-moderator`, then rerun `up` |
| `up` stops with "Could not sign in to replace the admin password" | The password was changed by hand and the file does not match | Put the current password on the first line of `.secrets/admin-password`, then rerun `up` |
| `status` shows `Admin password: unknown` | `https://<HOSTNAME>` does not resolve or is not reachable from this machine | Fix DNS or the allowed list, then rerun `status` |
| Preflight cannot detect your public IP | `checkip.amazonaws.com` is blocked | Set `ALLOWED_SOURCE_CIDRS` to your address |
