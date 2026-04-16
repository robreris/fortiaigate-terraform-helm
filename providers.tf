provider "aws" {
  region = var.aws_region
}

# Both the helm and kubernetes providers authenticate via the aws CLI exec plugin.
# This means the AWS CLI must be installed and configured with credentials that have
# eks:DescribeCluster and the ability to obtain a token for the cluster.
#
# NOTE: On the very first apply (when the cluster doesn't exist yet), Terraform
# defers provider initialization for helm/kubernetes until after the EKS module
# has been applied. If you see provider connection errors during 'terraform plan',
# run: terraform apply -target=module.eks -target=module.vpc first, then re-run
# terraform apply for the full deployment.

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}
