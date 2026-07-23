output "sns_topic_arn" {
  description = "ARN of the SNS cost-alert topic"
  value       = aws_sns_topic.alerts.arn
}

output "budget_name" {
  description = "Name of the monthly AWS Budget"
  value       = aws_budgets_budget.monthly.name
}

output "budget_amount_usd" {
  description = "Budget monthly limit in USD"
  value       = var.budget_amount
}

output "config_rule_arn" {
  description = "ARN of the REQUIRED_TAGS Config rule (empty string if enable_config=false)"
  value       = var.enable_config ? aws_config_config_rule.required_tags[0].arn : ""
}

output "config_recorder_name" {
  description = "Name of the AWS Config recorder (empty string if enable_config=false)"
  value       = var.enable_config ? aws_config_configuration_recorder.main[0].name : ""
}

output "config_s3_bucket" {
  description = "S3 bucket used for Config delivery"
  value       = aws_s3_bucket.config.id
}

output "iam_role_arn" {
  description = "ARN of the IAM role created for AWS Config"
  value       = aws_iam_role.config.arn
}
