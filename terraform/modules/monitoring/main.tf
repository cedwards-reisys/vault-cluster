# =============================================================================
# NLB Alarms
# =============================================================================

# No healthy targets — all nodes down or deregistered
resource "aws_cloudwatch_metric_alarm" "no_healthy_hosts" {
  alarm_name          = "${var.cluster_name}-no-healthy-hosts"
  alarm_description   = "No healthy Vault nodes behind the NLB"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/NetworkELB"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  treat_missing_data  = "breaching"

  dimensions = {
    LoadBalancer = var.nlb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  tags = var.tags
}

# Degraded cluster — fewer than 3 healthy nodes
resource "aws_cloudwatch_metric_alarm" "degraded_cluster" {
  alarm_name          = "${var.cluster_name}-degraded-cluster"
  alarm_description   = "Fewer than 3 healthy Vault nodes behind the NLB"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/NetworkELB"
  period              = 60
  statistic           = "Minimum"
  threshold           = 3
  treat_missing_data  = "breaching"

  dimensions = {
    LoadBalancer = var.nlb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  tags = var.tags
}

# Unhealthy targets present
resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${var.cluster_name}-unhealthy-hosts"
  alarm_description   = "One or more Vault nodes failing NLB health checks"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/NetworkELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.nlb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  tags = var.tags
}

# High TCP reset count from targets — Vault rejecting connections
resource "aws_cloudwatch_metric_alarm" "high_target_resets" {
  alarm_name          = "${var.cluster_name}-high-target-resets"
  alarm_description   = "High number of TCP resets from Vault nodes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "TCP_Target_Reset_Count"
  namespace           = "AWS/NetworkELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 100
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.nlb_arn_suffix
  }

  tags = var.tags
}

# =============================================================================
# EBS Volume Alarms — one per volume
# =============================================================================

# High EBS read latency (potential disk issues)
resource "aws_cloudwatch_metric_alarm" "ebs_read_latency" {
  count = length(var.ebs_volume_ids)

  alarm_name          = "${var.cluster_name}-ebs-read-latency-${count.index}"
  alarm_description   = "High EBS read latency on Vault data volume ${count.index}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  threshold           = 0.1 # 100ms

  metric_query {
    id          = "latency"
    expression  = "total_time / ops"
    label       = "Read Latency"
    return_data = true
  }

  metric_query {
    id = "total_time"
    metric {
      metric_name = "VolumeTotalReadTime"
      namespace   = "AWS/EBS"
      period      = 300
      stat        = "Sum"
      dimensions = {
        VolumeId = var.ebs_volume_ids[count.index]
      }
    }
  }

  metric_query {
    id = "ops"
    metric {
      metric_name = "VolumeReadOps"
      namespace   = "AWS/EBS"
      period      = 300
      stat        = "Sum"
      dimensions = {
        VolumeId = var.ebs_volume_ids[count.index]
      }
    }
  }

  treat_missing_data = "notBreaching"

  tags = var.tags
}

# EBS burst balance low (running out of IOPS credits)
resource "aws_cloudwatch_metric_alarm" "ebs_burst_balance" {
  count = length(var.ebs_volume_ids)

  alarm_name          = "${var.cluster_name}-ebs-burst-balance-${count.index}"
  alarm_description   = "Low EBS burst balance on Vault data volume ${count.index}"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "BurstBalance"
  namespace           = "AWS/EBS"
  period              = 300
  statistic           = "Average"
  threshold           = 20
  treat_missing_data  = "notBreaching"

  dimensions = {
    VolumeId = var.ebs_volume_ids[count.index]
  }

  tags = var.tags
}
