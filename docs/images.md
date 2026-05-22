# Container images

All FortiAIGate images are pulled from a single registry prefix configured via `var.image_repository` (set in your tfvars). Push these images into your registry before running `terraform apply`, otherwise pods will fail with `ImagePullBackOff`.

This list is derived from the chart templates under `fortiaigate/templates/`. If it drifts from reality, the source of truth is `grep -rE 'image:.*\.Values\.' fortiaigate/templates/`.

## Required images

`<repo>` below is the value of `var.image_repository`. `<tag>` is the value of `var.image_tag` (default `V8.0.0-build0024`).

| Image | Tag | Role | Required when |
|-------|-----|------|---------------|
| `<repo>/api:<tag>` | `var.image_tag` | REST API and OpenAPI control plane | Always |
| `<repo>/core:<tag>` | `var.image_tag` | AIFlow data plane — LLM proxy and policy enforcement | Always |
| `<repo>/webui:<tag>` | `var.image_tag` | Management UI | Always |
| `<repo>/logd:<tag>` | `var.image_tag` | Log aggregation daemon | Always |
| `<repo>/license_manager:<tag>` | `var.image_tag` | License-manager DaemonSet (one pod per licensed node) | When `var.licenses` is non-empty |
| `<repo>/scanner:<tag>` | `var.image_tag` | Single image used by all 8 scanner Deployments (different `SCANNER_TYPE` env per pod) | Always |
| `<repo>/custom-triton:25.11-onnx-trt-agt` | **hardcoded** | Triton inference server | Only when `gpu_enabled = true` |
| `<repo>/triton-models:0.1.4` | **hardcoded** | Init container that hydrates Triton's model repository | Only when `gpu_enabled = true` |

> **Note on hardcoded tags:** `custom-triton` and `triton-models` ignore `var.image_tag` and use the literal tags shown above (defined in `fortiaigate/templates/triton-server.yaml`). When you mirror images, you must push these specific tags — not whatever `image_tag` is set to.

## The 8 scanners share one image

All scanners pull `<repo>/scanner:<tag>` and differentiate via the `SCANNER_TYPE` env var. The scanner types are configured in `fortiaigate/values.yaml`:

| Scanner | `SCANNER_TYPE` |
|---------|----------------|
| Language detection | `language` |
| Code detection | `code` |
| Prompt injection | `promptinjection` |
| Sensitive data | `sensitive` |
| Toxicity | `toxicity` |
| Anonymize | `anonymize` |
| Deanonymize | `deanonymize` |
| Custom rule | `customrule` |

You only need to push the `scanner` image once.

## Bitnami subchart images

The chart depends on the Bitnami PostgreSQL and Redis subcharts, which by default pull from `docker.io/bitnami/postgresql` and `docker.io/bitnami/redis`. If your cluster has direct internet egress through the NAT gateway, no action is required. To mirror these into a private registry, override the image repository in an `extra_values_files` overlay:

```yaml
# my-bitnami-mirror.yaml
postgresql:
  image:
    registry: 123456789.dkr.ecr.us-east-1.amazonaws.com
    repository: bitnami/postgresql
redis:
  image:
    registry: 123456789.dkr.ecr.us-east-1.amazonaws.com
    repository: bitnami/redis
```

Pass via `extra_values_files = ["/path/to/my-bitnami-mirror.yaml"]` in your tfvars. Refer to the [Bitnami PostgreSQL](https://github.com/bitnami/charts/tree/main/bitnami/postgresql#parameters) and [Redis](https://github.com/bitnami/charts/tree/main/bitnami/redis#parameters) parameter docs for the full set of image-related keys (tag, pull policy, pull secrets).

## Pushing to ECR

Example for a minimal CPU-only deployment (skip the two Triton lines if `gpu_enabled = false`):

```bash
REGION=us-west-2
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
TAG="V8.0.0-build0024"

aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

# Create one ECR repository per image
for repo in api core webui logd license_manager scanner custom-triton triton-models; do
  aws ecr describe-repositories --repository-names "fortiaigate/${repo}" --region "${REGION}" \
    >/dev/null 2>&1 \
    || aws ecr create-repository --repository-name "fortiaigate/${repo}" --region "${REGION}"
done

# Tag and push from your local Fortinet-supplied images
for img in api core webui logd license_manager scanner; do
  docker tag "fortiaigate/${img}:${TAG}" "${REGISTRY}/fortiaigate/${img}:${TAG}"
  docker push "${REGISTRY}/fortiaigate/${img}:${TAG}"
done

# Triton images use fixed tags
docker tag fortiaigate/custom-triton:25.11-onnx-trt-agt \
  "${REGISTRY}/fortiaigate/custom-triton:25.11-onnx-trt-agt"
docker push "${REGISTRY}/fortiaigate/custom-triton:25.11-onnx-trt-agt"

docker tag fortiaigate/triton-models:0.1.4 \
  "${REGISTRY}/fortiaigate/triton-models:0.1.4"
docker push "${REGISTRY}/fortiaigate/triton-models:0.1.4"
```

Then set in your tfvars:

```hcl
image_repository = "123456789.dkr.ecr.us-west-2.amazonaws.com/fortiaigate"
image_tag        = "V8.0.0-build0024"
```

## EKS node permissions

The EKS managed node groups created by this stack get the `AmazonEC2ContainerRegistryReadOnly` policy attached automatically (via the upstream `terraform-aws-modules/eks/aws` module), so nodes can pull from any ECR repository in the same account without extra IAM configuration. If you push to a registry outside the cluster's account, attach `imagePullSecrets` via an `extra_values_files` overlay, or grant cross-account access on the ECR repository policy.
