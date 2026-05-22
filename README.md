# FortiAIGate on AWS EKS — Terraform + Helm

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](./LICENSE)
[![Terraform](https://img.shields.io/badge/terraform-%E2%89%A51.5-623CE4.svg)](https://www.terraform.io/)
[![Kubernetes](https://img.shields.io/badge/kubernetes-1.31-326CE5.svg)](https://kubernetes.io/)

Deploy a [FortiAIGate](https://www.fortinet.com/products/fortiaigate) cluster on Amazon EKS with a single Terraform stack. Provisions the VPC, EKS cluster, EFS filesystem, optional GPU node group, and installs the bundled Helm chart — including PostgreSQL, Redis, and the AWS Load Balancer Controller when needed.

Use this repo when you want to **stand up a working FortiAIGate environment in one place** without hand-wiring infrastructure. The defaults favor ease of evaluation; see [`SECURITY.md`](./SECURITY.md) for production hardening.

---

## Architecture

```
AWS
├── VPC (10.0.0.0/16)
│   ├── Private subnets ×3  — EKS nodes, EFS mount targets
│   └── Public subnets  ×3  — NAT gateway, load balancers
├── EKS cluster
│   ├── App node group      — API, WebUI, Core, Scanners, PostgreSQL, Redis, LogD
│   └── GPU node group      — Triton inference server (optional, g5.2xlarge)
└── EFS filesystem          — shared ReadWriteMany PVC for all services
```

| Service | Role |
|---------|------|
| API | Control plane — REST API and OpenAPI endpoint |
| Core (AIFlow) | Data plane — LLM proxy and policy enforcement |
| WebUI | Management UI |
| Triton | GPU inference server for all 5 AI security models |
| Scanners (×8) | CPU-only scanner clients (language, code, prompt injection, sensitive, toxicity, anonymize, deanonymize, custom rule) |
| License Manager | DaemonSet — one pod per licensed node |
| LogD | Log aggregation daemon |
| PostgreSQL | Bitnami subchart |
| Redis | Bitnami subchart |

---

## Prerequisites

| Tool | Minimum | Notes |
|------|---------|-------|
| [Terraform](https://developer.hashicorp.com/terraform/install) | 1.5 | |
| [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) | 2.x | Used by the EKS exec auth plugin |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | 1.28+ | Verifying the deployment |
| [Helm](https://helm.sh/docs/intro/install/) | 3.x | Chart management |

You also need:

- AWS credentials with permission to create VPC, EKS, EFS, IAM, and EC2 resources
- An S3 bucket and DynamoDB lock table for Terraform state — see [`docs/remote-state.md`](./docs/remote-state.md) for one-time bootstrap
- FortiAIGate container images pushed to a registry accessible from EKS (ECR is typical). Images are proprietary to Fortinet, Inc. and require a valid entitlement. See [`docs/images.md`](./docs/images.md) for the required image list and a push-to-ECR walkthrough
- For an internet-facing ALB: an ACM certificate **in the same region as `aws_region`** and a Route 53 hosted zone for `ingress_host`

---

## Quickstart

Pick a scenario from [`examples/`](./examples) — each one is a runnable `terraform.tfvars` snippet:

| Scenario | Path |
|----------|------|
| nginx ingress, no GPU, no ALB controller | [`examples/minimal/`](./examples/minimal) |
| Internal ALB (no ACM, no Route 53) | [`examples/internal-alb/`](./examples/internal-alb) |
| Internet-facing ALB with HTTPS | [`examples/internet-facing-alb/`](./examples/internet-facing-alb) |

Copy the one closest to your target, edit the placeholder values (account ID, region, ACM ARN, hostname), then deploy:

```bash
# 1. One-time per account: bootstrap the state backend (see docs/remote-state.md)

# 2. Initialize with your backend
terraform init -backend-config=backends/<account>.hcl -reconfigure

# 3. First-time apply MUST be two-step (see "Two-step bootstrap" below)
terraform apply -target=module.vpc -target=module.eks \
  -var-file=examples/<scenario>/terraform.tfvars

# 4. Apply the rest
terraform apply -var-file=examples/<scenario>/terraform.tfvars

# 5. Configure kubectl and verify
$(terraform output -raw configure_kubectl)
kubectl get pods,pvc,ingress -n fortiaigate
terraform output alb_dns_name
```

For internet-facing ALB deployments, finish by creating a Route 53 alias record — see [`docs/route53-setup.md`](./docs/route53-setup.md).

---

## Two-step bootstrap (first deploy)

The `helm` and `kubernetes` providers authenticate via `aws eks get-token`. On a first deploy the cluster doesn't exist yet, so a single `terraform apply` fails with `Unauthorized` errors. Bootstrap VPC + EKS first, then apply the rest:

```bash
# Stage 1: VPC + EKS (≈10–15 min)
terraform apply -target=module.vpc -target=module.eks -var-file=<your.tfvars>

# Sanity check the cluster is reachable
aws eks update-kubeconfig --region <aws_region> --name <cluster_name>
aws eks get-token --cluster-name <cluster_name> --region <aws_region>

# Stage 2: EFS, controllers, Helm release (≈5–10 min)
terraform apply -var-file=<your.tfvars>
```

Subsequent applies (variable updates, license refreshes) can run as a single step.

---

## License management

Licenses are mapped per node. After the cluster is up, retrieve node names:

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name --no-headers
```

Add a `licenses` map to your tfvars:

```hcl
licenses = {
  "ip-10-0-1-100.us-east-1.compute.internal" = "/path/to/node1.lic"
  "ip-10-0-2-200.us-east-1.compute.internal" = "/path/to/node2.lic"
}
```

Re-apply with `terraform apply -var-file=<your.tfvars>`. Terraform writes a `fortiaigate-license-config` ConfigMap and the license-manager DaemonSet picks it up automatically. Node names must match `kubectl get nodes` output exactly — the license-manager uses node affinity keyed on these names.

---

## GPU support

Disabled by default. Set `gpu_enabled = true` to add a single `g5.2xlarge` node on the `AL2_x86_64_GPU` AMI, tainted `fortiaigate-gpu=true:NoSchedule`. Triton runs there exclusively.

Terraform also installs the [NVIDIA Kubernetes device plugin](https://github.com/NVIDIA/k8s-device-plugin) as a Helm release in `kube-system` with matching tolerations — no manual setup needed. Without the device plugin, Triton pods stay `Pending` with `Insufficient nvidia.com/gpu`.

> **Cost note:** GPU nodes are ~$1.20/hr. Keep `gpu_enabled = false` for development unless you specifically need AI model inference.

Verify after deploy:

```bash
kubectl describe node -l fortiaigate-role=gpu | grep -A10 "Capacity:"
# Expect: nvidia.com/gpu: 1
```

---

## Ingress options

| Class | Use when | ACM cert? | Route 53? |
|-------|----------|-----------|-----------|
| `nginx` | nginx-ingress-controller already in the cluster | No | Optional |
| `alb` (`internal = true`) | All traffic enters via VPN/Direct Connect/Transit Gateway/FortiGate | No | No |
| `alb` (`internal = false`) | Public internet | Yes, same region as `aws_region` | Yes |

The AWS Load Balancer Controller is installed automatically when `ingress_class = "alb"` and `aws_load_balancer_controller_enabled = true` (the default). Set `aws_load_balancer_controller_enabled = false` if a controller is already managed elsewhere.

All three services share the same listener via path-based routing:

| Caller | Path | Backend |
|--------|------|---------|
| FortiGate → WebUI | `/` | webui (port 3000) |
| Chatbot → API | `/api/` | api (port 8000) |
| Chatbot → Core | `/v1/` | core (port 8080) |

See [`examples/`](./examples) for full annotation blocks for each scenario.

---

## Advanced: extra values files

For configuration not exposed as Terraform variables, pass additional Helm values files:

```hcl
extra_values_files = ["/path/to/my-overlay.yaml"]
```

Files merge left-to-right before the built-in `set {}` blocks, so Terraform variables take precedence over values files.

---

## Teardown

Always uninstall Helm releases before `terraform destroy`. Destroying infrastructure while finalizers are still running causes `context deadline exceeded` errors.

```bash
# 1. Point kubectl at the cluster
$(terraform output -raw configure_kubectl)

# 2. Uninstall the application
helm uninstall fortiaigate -n fortiaigate --wait --timeout 20m
kubectl wait --for=delete ingress/fortiaigate-ingress -n fortiaigate --timeout=20m
kubectl wait --for=delete pod --all -n fortiaigate --timeout=20m

# 3. Uninstall the ALB controller if installed
helm uninstall aws-load-balancer-controller -n kube-system --wait --timeout 10m

# 4. Destroy infrastructure
terraform destroy -var-file=<your.tfvars>
```

> **EFS is retained.** The StorageClass uses `reclaim_policy = Retain`. After destroy, the EFS filesystem and its data remain in AWS and must be deleted manually if no longer needed.

---

## Troubleshooting

**`Unauthorized` on first apply** — You skipped the two-step bootstrap. See [Two-step bootstrap](#two-step-bootstrap-first-deploy).

**Node groups stuck in `Creating` for 20+ minutes** — Nodes booted but can't register with the control plane. Most common cause: incomplete VPC (no NAT gateway, no public subnets, missing default route). Check `aws ec2 describe-nat-gateways` and the private subnet route tables. If the VPC is partial, re-run `terraform apply -target=module.vpc` first.

**ALB has target groups but no listeners** — The `CreateListener` call failed AWS-side validation. The most frequent cause is an ACM certificate ARN in the wrong region; ACM is regional and doesn't replicate. Check `kubectl describe ingress -n fortiaigate fortiaigate-ingress` for the exact error, then issue a cert in the same region as `aws_region` and update `alb.ingress.kubernetes.io/certificate-arn`.

**Pods stuck in `Pending`** — Check node capacity and EFS mount status:

```bash
kubectl describe pod <pod-name> -n fortiaigate
kubectl get pvc -n fortiaigate
kubectl get pods -n kube-system | grep efs
```

**License manager not starting** — Node names in the `licenses` variable must match `kubectl get nodes` output exactly. The license-manager DaemonSet uses node affinity.

---

## Documentation

- [`examples/`](./examples) — runnable deployment scenarios
- [`docs/images.md`](./docs/images.md) — required container images and push-to-ECR walkthrough
- [`docs/remote-state.md`](./docs/remote-state.md) — S3 + DynamoDB backend bootstrap
- [`docs/route53-setup.md`](./docs/route53-setup.md) — Route 53 alias for internet-facing ALB
- [`SECURITY.md`](./SECURITY.md) — vulnerability reporting + production hardening checklist
- [`CONTRIBUTING.md`](./CONTRIBUTING.md) — dev setup, local checks, PR conventions
- [`ROADMAP.md`](./ROADMAP.md) — known gaps and planned improvements
- [`CHANGELOG.md`](./CHANGELOG.md) — release notes

---

## License

Apache License 2.0 — see [LICENSE](./LICENSE) and [NOTICE](./NOTICE).

FortiAIGate container images themselves are proprietary to Fortinet, Inc. and require a valid entitlement.

---

## Inputs and outputs

The block below is regenerated by [terraform-docs](https://terraform-docs.io/) via the pre-commit hook in `.pre-commit-config.yaml`. Do not edit by hand — update `variables.tf` / `outputs.tf` instead.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 2.15 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.35 |
| <a name="requirement_tls"></a> [tls](#requirement\_tls) | ~> 4.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 5.0 |
| <a name="provider_helm"></a> [helm](#provider\_helm) | ~> 2.15 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 2.35 |
| <a name="provider_tls"></a> [tls](#provider\_tls) | ~> 4.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_aws_load_balancer_controller_irsa"></a> [aws\_load\_balancer\_controller\_irsa](#module\_aws\_load\_balancer\_controller\_irsa) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks | ~> 5.0 |
| <a name="module_eks"></a> [eks](#module\_eks) | terraform-aws-modules/eks/aws | ~> 20.0 |
| <a name="module_irsa_efs_csi"></a> [irsa\_efs\_csi](#module\_irsa\_efs\_csi) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks | ~> 5.0 |
| <a name="module_vpc"></a> [vpc](#module\_vpc) | terraform-aws-modules/vpc/aws | ~> 5.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_efs_file_system.fortiaigate](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_file_system) | resource |
| [aws_efs_mount_target.fortiaigate](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_mount_target) | resource |
| [aws_eks_addon.efs_csi](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon) | resource |
| [aws_security_group.efs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [helm_release.aws_load_balancer_controller](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.fortiaigate](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.nvidia_device_plugin](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubernetes_config_map.licenses](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/config_map) | resource |
| [kubernetes_namespace.fortiaigate](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace) | resource |
| [kubernetes_secret.tls](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_storage_class.efs](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/storage_class) | resource |
| [tls_private_key.fortiaigate](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/private_key) | resource |
| [tls_self_signed_cert.fortiaigate](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/self_signed_cert) | resource |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones) | data source |
| [kubernetes_ingress_v1.fortiaigate](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/data-sources/ingress_v1) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_image_repository"></a> [image\_repository](#input\_image\_repository) | Container registry prefix for FortiAIGate images (e.g. 123456789.dkr.ecr.us-east-1.amazonaws.com/fortiaigate) | `string` | n/a | yes |
| <a name="input_app_node_count"></a> [app\_node\_count](#input\_app\_node\_count) | Number of application nodes | `number` | `2` | no |
| <a name="input_app_node_instance_type"></a> [app\_node\_instance\_type](#input\_app\_node\_instance\_type) | EC2 instance type for application node group | `string` | `"m7i.4xlarge"` | no |
| <a name="input_aws_load_balancer_controller_chart_version"></a> [aws\_load\_balancer\_controller\_chart\_version](#input\_aws\_load\_balancer\_controller\_chart\_version) | Helm chart version for aws-load-balancer-controller from the AWS EKS charts repository. | `string` | `"1.14.0"` | no |
| <a name="input_aws_load_balancer_controller_enabled"></a> [aws\_load\_balancer\_controller\_enabled](#input\_aws\_load\_balancer\_controller\_enabled) | Install AWS Load Balancer Controller when ingress\_class is 'alb'. Disable if a controller is already managed outside this Terraform stack. | `bool` | `true` | no |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region to deploy into | `string` | `"us-east-1"` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | EKS cluster name | `string` | `"fortiaigate"` | no |
| <a name="input_cluster_version"></a> [cluster\_version](#input\_cluster\_version) | Kubernetes version for the EKS cluster | `string` | `"1.31"` | no |
| <a name="input_efs_encrypted"></a> [efs\_encrypted](#input\_efs\_encrypted) | Encrypt the EFS file system at rest with a KMS key. Disable if no suitable KMS key is available in the account. | `bool` | `true` | no |
| <a name="input_extra_values_files"></a> [extra\_values\_files](#input\_extra\_values\_files) | Additional Helm values YAML files to merge (applied left-to-right, later files take precedence) | `list(string)` | `[]` | no |
| <a name="input_gpu_enabled"></a> [gpu\_enabled](#input\_gpu\_enabled) | Add a GPU node group (g5.2xlarge) for Triton inference. When false, triton is disabled and all workloads run CPU-only. | `bool` | `false` | no |
| <a name="input_gpu_node_instance_type"></a> [gpu\_node\_instance\_type](#input\_gpu\_node\_instance\_type) | EC2 instance type for the GPU node group | `string` | `"g5.2xlarge"` | no |
| <a name="input_image_tag"></a> [image\_tag](#input\_image\_tag) | Image tag for all FortiAIGate service images | `string` | `"V8.0.0-build0024"` | no |
| <a name="input_ingress_annotations"></a> [ingress\_annotations](#input\_ingress\_annotations) | Additional ingress annotations. Used for ALB configuration (e.g. certificate ARN, scheme). Keys with dots/slashes are handled correctly via values YAML merge. | `map(string)` | `{}` | no |
| <a name="input_ingress_class"></a> [ingress\_class](#input\_ingress\_class) | Ingress class name. Use 'nginx' for nginx-ingress or 'alb' for AWS Load Balancer Controller. | `string` | `"nginx"` | no |
| <a name="input_ingress_host"></a> [ingress\_host](#input\_ingress\_host) | Hostname for the ingress rule. Leave empty to match all hosts. | `string` | `""` | no |
| <a name="input_internal"></a> [internal](#input\_internal) | Deploy as an internal (private) service. Sets the ALB scheme to 'internal' so it is only reachable within the VPC and connected networks. Requires ingress\_class = 'alb'. | `bool` | `false` | no |
| <a name="input_licenses"></a> [licenses](#input\_licenses) | Map of EKS node name to local license file path. Node names are available after cluster creation via 'kubectl get nodes'. Example: { "ip-10-0-1-100.us-east-1.compute.internal" = "/path/to/license.lic" } | `map(string)` | `{}` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Kubernetes namespace for the FortiAIGate deployment | `string` | `"fortiaigate"` | no |
| <a name="input_storage_size"></a> [storage\_size](#input\_storage\_size) | Size of the shared EFS-backed PVC | `string` | `"100Gi"` | no |
| <a name="input_update_strategy"></a> [update\_strategy](#input\_update\_strategy) | Deployment update strategy. 'Recreate' avoids GPU deadlock on single-GPU nodes; 'RollingUpdate' for zero-downtime when spare capacity exists. | `string` | `"Recreate"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_alb_dns_name"></a> [alb\_dns\_name](#output\_alb\_dns\_name) | ALB hostname assigned by AWS — use this to configure the FortiGate and chatbot |
| <a name="output_aws_region"></a> [aws\_region](#output\_aws\_region) | AWS region used for the deployment |
| <a name="output_cluster_name"></a> [cluster\_name](#output\_cluster\_name) | EKS cluster name |
| <a name="output_configure_kubectl"></a> [configure\_kubectl](#output\_configure\_kubectl) | Run this command to configure kubectl for the new cluster |
| <a name="output_efs_filesystem_id"></a> [efs\_filesystem\_id](#output\_efs\_filesystem\_id) | EFS filesystem ID backing the shared PVC |
| <a name="output_ingress_host"></a> [ingress\_host](#output\_ingress\_host) | Configured ingress hostname (empty = matches all hosts) |
| <a name="output_release_status"></a> [release\_status](#output\_release\_status) | Helm release deployment status |
<!-- END_TF_DOCS -->
