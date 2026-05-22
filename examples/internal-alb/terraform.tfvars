# Internal ALB: reachable only inside the VPC and connected networks
# (VPN, Direct Connect, Transit Gateway, FortiGate-as-VPC-gateway).
# No ACM certificate required, no Route 53 entry needed.

aws_region   = "us-west-2"
cluster_name = "fortiaigate-internal"

# REQUIRED — your FortiAIGate image registry.
image_repository = "123456789.dkr.ecr.us-west-2.amazonaws.com/fortiaigate"

ingress_class                        = "alb"
internal                             = true
aws_load_balancer_controller_enabled = true

# ingress_host is optional for internal ALBs — callers use the ALB DNS name directly.
# Surface it after apply with:  terraform output alb_dns_name

gpu_enabled    = false
app_node_count = 2
