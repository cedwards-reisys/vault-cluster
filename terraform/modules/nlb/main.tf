# Network Load Balancer for Vault
resource "aws_lb" "vault" {
  name               = "${var.cluster_name}-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = var.private_subnet_ids

  # NLB does not use security groups - traffic goes directly to targets
  # Source IP is preserved, so Vault SG must allow inbound from allowed CIDRs

  enable_deletion_protection = false

  # Enable cross-zone load balancing for even distribution
  enable_cross_zone_load_balancing = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-nlb"
  })
}

# Target group for Vault nodes (TLS re-encryption to HTTPS backends)
resource "aws_lb_target_group" "vault" {
  name     = "${var.cluster_name}-vault-tg"
  port     = 8200
  protocol = "TLS"
  vpc_id   = var.vpc_id

  # Health check configuration
  # Using HTTPS health check to verify Vault is actually responding
  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 10
    interval            = 30
    port                = "traffic-port"
    protocol            = "HTTPS"
    path                = "/v1/sys/health?standby=true&perfstandbyok=true"
    matcher             = "200,429,472,473"
  }

  # Preserve client IP (default for NLB, but explicit)
  preserve_client_ip = true

  # Deregistration delay for graceful failover
  deregistration_delay = 30

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-vault-tg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# TLS listener - terminates TLS with ACM cert, forwards TCP to targets
resource "aws_lb_listener" "tls" {
  load_balancer_arn = aws_lb.vault.arn
  port              = 443
  protocol          = "TLS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vault.arn
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-tls-listener"
  })
}
