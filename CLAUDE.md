# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo deploys

A single Terraform stack that stands up FortiAIGate on AWS EKS:

- VPC + EKS cluster + app/GPU node groups
- EFS filesystem (required — the chart's shared PVC is `ReadWriteMany`, which EBS cannot satisfy)
- AWS Load Balancer Controller (conditional)
- The `fortiaigate/` Helm chart (local path), which bundles Bitnami PostgreSQL and Redis subcharts

There is no application source code here — this repo is purely IaC. FortiAIGate container images come from an external registry referenced via `var.image_repository`.

## Common commands

```bash
# Per-account init (switching accounts uses -reconfigure, NOT -migrate-state)
terraform init -backend-config=backends/<account>.hcl -reconfigure

# First-time deploy MUST be two-step — see "Two-step apply" below
terraform apply -target=module.vpc -target=module.eks -var-file=tfvars/<account>.tfvars
terraform apply -var-file=tfvars/<account>.tfvars

# Configure kubectl after cluster exists
$(terraform output -raw configure_kubectl)

# Verify the deployment
kubectl get pods,pvc,ingress -n fortiaigate
terraform output alb_dns_name
```

Teardown order matters — uninstall Helm releases first, then `terraform destroy`. Otherwise Terraform deletes infra out from under finalizers (ALB, PVCs) and times out. The EFS filesystem is `Retain` and survives destroy; delete it manually if no longer needed. Full steps in `README.md`.

## Two-step apply (critical)

The `helm` and `kubernetes` providers in `providers.tf` authenticate via `aws eks get-token`. On a first apply the cluster doesn't exist yet, so any single-shot `terraform apply` will fail with `Unauthorized`. Always bootstrap VPC + EKS first, then apply the rest. Subsequent applies can be single-step.

If a previous apply errored partway through `module.vpc`, the EKS module can still create the cluster against an incomplete VPC (e.g., no NAT gateway, no public subnets). Nodes will launch but never register because they have no egress. Re-run `terraform apply -target=module.vpc` before re-attempting the full apply.

## Per-account layout

State, backend, and variables are partitioned by AWS account, not by workspace:

- `backends/<account>.hcl` — committed; bucket/table names only, no secrets
- `tfvars/<account>.tfvars` — gitignored; `.tfvars.example` files are committed templates

To switch accounts: change AWS credentials, then `terraform init -backend-config=backends/<new>.hcl -reconfigure`. Each account uses its own state bucket and DynamoDB lock table (one-time bootstrap in `README.md`).

## Architecture quirks worth knowing

**EFS CSI is in `storage.tf`, not `eks.tf`.** The driver needs an IRSA role that depends on the EKS module's OIDC provider, while the EKS module also wants to manage cluster addons. Putting the EFS addon under `cluster_addons` creates a cycle. The workaround is a standalone `aws_eks_addon "efs_csi"` resource with a separate IRSA module — keep it that way.

**Helm values are composed by `concat()` of `yamlencode`'d locals in `helm.tf`.** Set blocks can't handle YAML lists (tolerations) or keys with dots/slashes (ingress annotations), so structured values go through `yamlencode`. Order matters — later entries win. Currently: `extra_values_files` → `gpu_values` → `internal_alb_values` → `ingress_annotation_values` → `tls_values` → `license_node_values`. When adding a new structured override, decide where it belongs in that precedence chain.

**TLS is self-signed at apply time** (`tls.tf`). The cert's SHA256 is passed to the Helm release as `tls.existingSecretChecksum` so pod template annotations trigger a rollout when the cert is regenerated. For production, replace with ACM or cert-manager.

**ACM cert region must match `var.aws_region`.** ACM is regional and doesn't replicate. A cert ARN in `us-east-1` cannot be attached to an ALB in `us-west-2` — the ALB controller will create target groups and the load balancer successfully, then fail on `CreateListener` with a `ValidationError`. The result is an ALB with no listeners.

**Licenses are node-keyed.** `var.licenses` maps EC2 private DNS names (e.g. `ip-10-0-1-100.us-east-1.compute.internal`) to local license file paths. `licenses.tf` reads each file and stuffs it in a `fortiaigate-license-config` ConfigMap; the license-manager DaemonSet uses node affinity on the names to deliver the right license to each node. Node names must match `kubectl get nodes` output exactly — they're discovered post-apply, so the initial deploy runs without licenses and a second apply adds them.

**GPU is optional and tainted.** `var.gpu_enabled = true` adds a single-node `g5.2xlarge` group on the `AL2_x86_64_GPU` AMI, tainted `fortiaigate-gpu=true:NoSchedule`. Terraform also installs the NVIDIA device plugin Helm release with matching tolerations. Triton is the only workload scheduled there.

**ALB controller installation is conditional.** `local.manage_aws_load_balancer_controller = var.aws_load_balancer_controller_enabled && var.ingress_class == "alb"` in `aws-load-balancer-controller.tf`. If `false`, the ingress resource still gets created but stays without an address until an externally-managed controller picks it up.

**Internal vs internet-facing ALB.** `var.internal = true` injects an `alb.ingress.kubernetes.io/scheme: internal` annotation via `local.internal_alb_values`. Placed *before* `ingress_annotation_values` in the merge order so explicit user annotations still override. Internal ALBs need no ACM cert and no Route 53 entry.

## File map (terraform root)

| File | What it owns |
|------|--------------|
| `vpc.tf` | VPC, subnets, NAT — uses `terraform-aws-modules/vpc/aws` |
| `eks.tf` | EKS cluster, app + GPU node groups, core addons (coredns, kube-proxy, vpc-cni) |
| `storage.tf` | EFS filesystem, mount targets, EFS CSI driver addon + IRSA, `efs-sc` StorageClass |
| `aws-load-balancer-controller.tf` | ALB controller IRSA + Helm release (conditional) |
| `helm.tf` | `fortiaigate` namespace, NVIDIA device plugin, fortiaigate Helm release, value composition |
| `licenses.tf` | `fortiaigate-license-config` ConfigMap from `var.licenses` |
| `tls.tf` | Self-signed cert + `fortiaigate-tls-secret` |
| `providers.tf` | AWS + helm + kubernetes providers (the last two use `aws eks get-token` exec auth) |
| `backend.tf` | Empty S3 backend; values supplied via `-backend-config` |
| `outputs.tf` | Cluster name, kubectl command, EFS ID, ALB DNS name (data-source lookup of the ingress) |
