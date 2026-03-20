# Security group for Vault nodes
# Note: NLB does not use security groups - traffic flows directly to targets
# with source IP preserved. Vault SG must allow inbound from allowed CIDRs.
resource "aws_security_group" "vault" {
  name        = "${var.cluster_name}-vault-sg"
  description = "Security group for Vault nodes"
  vpc_id      = var.vpc_id

  # API/UI from allowed CIDRs (via NLB - source IP preserved)
  ingress {
    description = "Vault API/UI from allowed CIDRs"
    from_port   = 8200
    to_port     = 8200
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  # Raft cluster communication (node-to-node)
  ingress {
    description = "Raft cluster communication"
    from_port   = 8201
    to_port     = 8201
    protocol    = "tcp"
    self        = true
  }

  # Allow nodes to reach each other on 8200 for Raft join
  ingress {
    description = "Vault API for Raft join"
    from_port   = 8200
    to_port     = 8200
    protocol    = "tcp"
    self        = true
  }

  # Egress - allow all outbound
  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-vault-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}
