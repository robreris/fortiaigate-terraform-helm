module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Public endpoint allows kubectl access from outside the VPC.
  # For production, restrict cluster_endpoint_public_access_cidrs or disable public access.
  cluster_endpoint_public_access = true

  # Core addons. The EFS CSI driver is managed separately in storage.tf
  # to avoid a circular dependency with its IRSA role.
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
  }

  eks_managed_node_groups = merge(
    {
      app = {
        instance_types = [var.app_node_instance_type]
        min_size       = 1
        max_size       = var.app_node_count + 2
        desired_size   = var.app_node_count
        labels = {
          fortiaigate-role = "app"
        }
      }
    },
    var.gpu_enabled ? {
      gpu = {
        instance_types = [var.gpu_node_instance_type]
        # Amazon Linux 2 GPU-optimized AMI with NVIDIA drivers and container toolkit
        ami_type     = "AL2_x86_64_GPU"
        min_size     = 0
        max_size     = 1
        desired_size = 1
        labels = {
          fortiaigate-role = "gpu"
        }
        taints = {
          fortiaigate_gpu = {
            key    = "fortiaigate-gpu"
            value  = "true"
            effect = "NO_SCHEDULE"
          }
        }
      }
    } : {}
  )
}
