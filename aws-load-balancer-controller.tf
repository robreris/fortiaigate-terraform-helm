locals {
  manage_aws_load_balancer_controller = var.aws_load_balancer_controller_enabled && var.ingress_class == "alb"
}

module "aws_load_balancer_controller_irsa" {
  count = local.manage_aws_load_balancer_controller ? 1 : 0

  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                              = "${var.cluster_name}-aws-load-balancer-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  count = local.manage_aws_load_balancer_controller ? 1 : 0

  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = var.aws_load_balancer_controller_chart_version
  timeout    = 600

  values = [
    yamlencode({
      clusterName = module.eks.cluster_name
      region      = var.aws_region
      vpcId       = module.vpc.vpc_id

      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"
        annotations = {
          "eks.amazonaws.com/role-arn" = module.aws_load_balancer_controller_irsa[0].iam_role_arn
        }
      }
    })
  ]

  depends_on = [
    module.eks,
    module.aws_load_balancer_controller_irsa,
  ]
}
