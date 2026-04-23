output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "aws_region" {
  description = "AWS region used for the deployment"
  value       = var.aws_region
}

output "configure_kubectl" {
  description = "Run this command to configure kubectl for the new cluster"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "efs_filesystem_id" {
  description = "EFS filesystem ID backing the shared PVC"
  value       = aws_efs_file_system.fortiaigate.id
}

output "release_status" {
  description = "Helm release deployment status"
  value       = helm_release.fortiaigate.status
}

output "ingress_host" {
  description = "Configured ingress hostname (empty = matches all hosts)"
  value       = var.ingress_host
}
