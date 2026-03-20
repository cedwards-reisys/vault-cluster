output "alarm_arns" {
  description = "ARNs of all CloudWatch alarms for wiring up alerting later"
  value = concat(
    [
      aws_cloudwatch_metric_alarm.no_healthy_hosts.arn,
      aws_cloudwatch_metric_alarm.degraded_cluster.arn,
      aws_cloudwatch_metric_alarm.unhealthy_hosts.arn,
      aws_cloudwatch_metric_alarm.high_target_resets.arn,
    ],
    aws_cloudwatch_metric_alarm.ebs_read_latency[*].arn,
    aws_cloudwatch_metric_alarm.ebs_burst_balance[*].arn,
  )
}
