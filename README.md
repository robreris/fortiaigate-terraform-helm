# FortiAIGate Terraform + Helm Deployment

Deploys a FortiAIGate cluster on AWS EKS using Terraform and the bundled Helm chart. A single `terraform apply` provisions the VPC, EKS cluster, EFS storage, and the FortiAIGate application stack.

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

FortiAIGate services deployed by the Helm chart:

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

### Tools

| Tool | Minimum version | Notes |
|------|----------------|-------|
| [Terraform](https://developer.hashicorp.com/terraform/install) | 1.5 | |
| [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) | 2.x | Must be in `PATH` — used by the EKS exec auth plugin |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | 1.28+ | For verifying the deployment |
| [Helm](https://helm.sh/docs/intro/install/) | 3.x | For chart management if needed |

### AWS

- AWS credentials configured (`aws configure`, environment variables, or an IAM instance/pod role)
- Sufficient IAM permissions to create VPC, EKS, EFS, IAM roles, and EC2 instances
- FortiAIGate container images pushed to a registry accessible from EKS (e.g. ECR)

### Images

All FortiAIGate images must be available at `<image_repository>/<service>:<image_tag>`. The expected service names are:

```
api
core
webui
logd
license_manager
scanner
custom-triton
triton-models
```

Example for ECR with repository prefix `123456789.dkr.ecr.us-east-1.amazonaws.com/fortiaigate`:
```
123456789.dkr.ecr.us-east-1.amazonaws.com/fortiaigate/api:V8.0.0-build0024
123456789.dkr.ecr.us-east-1.amazonaws.com/fortiaigate/core:V8.0.0-build0024
...
```

---

## Deployment

### 1. Configure variables

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and set at minimum:

```hcl
image_repository = "123456789.dkr.ecr.us-east-1.amazonaws.com/fortiaigate"
```

See [Variable reference](#variable-reference) for all options.

### 2. Initialize Terraform

```bash
terraform init
```

### 3. Deploy the cluster and application

```bash
terraform apply
```

This takes approximately 15–20 minutes. Terraform provisions resources in order:
1. VPC, subnets, NAT gateway
2. EKS cluster and node groups
3. EFS filesystem and CSI driver
4. FortiAIGate namespace, license ConfigMap, and Helm release

### 4. Configure kubectl

```bash
$(terraform output -raw configure_kubectl)
# equivalent to:
# aws eks update-kubeconfig --region us-east-1 --name fortiaigate
```

### 5. Verify the deployment

```bash
kubectl get pods -n fortiaigate
kubectl get ingress -n fortiaigate
kubectl get pvc -n fortiaigate
```

All pods should reach `Running` state within a few minutes of the Helm release completing.

---

## Adding licenses

Licenses are mapped per node. Node names are not known until after the cluster is created.

**Step 1** — retrieve node names after the initial apply:

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name --no-headers
```

**Step 2** — add the `licenses` map to `terraform.tfvars`:

```hcl
licenses = {
  "ip-10-0-1-100.us-east-1.compute.internal" = "/path/to/node1.lic"
  "ip-10-0-2-200.us-east-1.compute.internal" = "/path/to/node2.lic"
}
```

**Step 3** — re-apply:

```bash
terraform apply
```

Terraform creates a `fortiaigate-license-config` ConfigMap in the `fortiaigate` namespace and updates the Helm release to reference it. The license-manager DaemonSet picks up the new ConfigMap automatically.

---

## GPU support

GPU is disabled by default. To enable a GPU node group (one `g5.2xlarge` node running the Triton inference server):

```hcl
gpu_enabled = true
```

The GPU node group uses the `AL2_x86_64_GPU` AMI (Amazon Linux 2 with NVIDIA drivers and the container toolkit pre-installed). The node is tainted `fortiaigate-gpu=true:NoSchedule` and Triton is scheduled there exclusively.

> **Note:** GPU nodes are expensive (~$1.20/hr). Set `gpu_enabled = false` for development and testing. Without GPU, Triton is disabled and AI model inference will not function.

---

## Ingress options

### NGINX (default)

```hcl
ingress_class = "nginx"
ingress_host  = "fortiaigate.example.com"  # optional
```

The NGINX ingress controller must be installed in the cluster separately (e.g. via the `ingress-nginx` Helm chart).

### AWS ALB

```hcl
ingress_class = "alb"
ingress_host  = "fortiaigate.example.com"
ingress_annotations = {
  "kubernetes.io/ingress.class"                = "alb"
  "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
  "alb.ingress.kubernetes.io/target-type"      = "ip"
  "alb.ingress.kubernetes.io/listen-ports"     = "[{\"HTTPS\":443}]"
  "alb.ingress.kubernetes.io/backend-protocol" = "HTTPS"
  "alb.ingress.kubernetes.io/certificate-arn"  = "arn:aws:acm:us-east-1:123456789:certificate/..."
}
```

The AWS Load Balancer Controller must be installed in the cluster. See the [AWS Load Balancer Controller docs](https://kubernetes-sigs.github.io/aws-load-balancer-controller/).

---

## Advanced: extra values files

For configuration not exposed as Terraform variables, pass additional Helm values files:

```hcl
extra_values_files = ["/path/to/my-overlay.yaml"]
```

Files are merged left-to-right before the built-in `set {}` blocks, so Terraform variables take precedence over values files.

---

## Variable reference

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `aws_region` | string | `"us-east-1"` | AWS region |
| `cluster_name` | string | `"fortiaigate"` | EKS cluster name |
| `cluster_version` | string | `"1.31"` | Kubernetes version |
| `app_node_instance_type` | string | `"m7i.4xlarge"` | App node instance type |
| `app_node_count` | number | `2` | Number of app nodes |
| `gpu_enabled` | bool | `false` | Add GPU node group for Triton |
| `gpu_node_instance_type` | string | `"g5.2xlarge"` | GPU node instance type |
| `image_repository` | string | **required** | Registry prefix for FortiAIGate images |
| `image_tag` | string | `"V8.0.0-build0024"` | Image tag |
| `namespace` | string | `"fortiaigate"` | Kubernetes namespace |
| `ingress_class` | string | `"nginx"` | Ingress class (`nginx` or `alb`) |
| `ingress_host` | string | `""` | Ingress hostname (empty = match all) |
| `ingress_annotations` | map(string) | `{}` | Extra ingress annotations |
| `storage_size` | string | `"100Gi"` | Shared EFS PVC size |
| `licenses` | map(string) | `{}` | Node name → local license file path |
| `update_strategy` | string | `"Recreate"` | `Recreate` or `RollingUpdate` |
| `extra_values_files` | list(string) | `[]` | Additional Helm values files to merge |

---

## Teardown

```bash
terraform destroy
```

> **Note:** The EFS filesystem has `reclaim_policy = Retain`. After `terraform destroy`, the EFS filesystem and its data remain in AWS and must be deleted manually if no longer needed.

---

## Troubleshooting

**Provider connection errors during `terraform plan`**

The helm and kubernetes providers need a live cluster endpoint. On the first run, the cluster doesn't exist yet. Target the infrastructure first:

```bash
terraform apply -target=module.vpc -target=module.eks
terraform apply
```

**Pods stuck in `Pending`**

Check node capacity and EFS mount status:

```bash
kubectl describe pod <pod-name> -n fortiaigate
kubectl get pvc -n fortiaigate
```

**License manager not starting**

Verify node names in the `licenses` variable match exactly what `kubectl get nodes` returns. The license-manager DaemonSet uses node affinity keyed on the names in the ConfigMap.

**EFS CSI driver not ready**

The StorageClass waits for the addon and mount targets, but the addon pods take a minute to start after the cluster is created. If PVCs are stuck in `Pending`, check:

```bash
kubectl get pods -n kube-system | grep efs
```
