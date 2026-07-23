output "vpc_id" {
  description = "ID of the VPC created for this audit"
  value       = module.wasteful_resources.vpc_id
}

output "zombie_instance_id" {
  description = "ID of the idle (zombie) EC2 instance created for demonstration"
  value       = module.wasteful_resources.idle_instance_id
}

output "unattached_ebs_volume_ids" {
  description = "IDs of unattached EBS volumes created for demonstration"
  value       = module.wasteful_resources.unattached_volume_ids
}

output "unassociated_eip_addresses" {
  description = "Elastic IP addresses that are unassociated (wasting money)"
  value       = module.wasteful_resources.unassociated_eip_addresses
}

output "budget_name" {
  description = "Name of the AWS Budget created"
  value       = module.governance.budget_name
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic used for budget alerts"
  value       = module.governance.sns_topic_arn
}

output "config_rule_arn" {
  description = "ARN of the AWS Config rule enforcing the CostCenter tag"
  value       = module.governance.config_rule_arn
}

output "asg_name" {
  description = "Name of the cost-optimized Auto Scaling Group"
  value       = module.compute_optimized.asg_name
}

output "asg_arn" {
  description = "ARN of the cost-optimized Auto Scaling Group"
  value       = module.compute_optimized.asg_arn
}

output "launch_template_id" {
  description = "ID of the Launch Template used by the ASG"
  value       = module.compute_optimized.launch_template_id
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer fronting the ASG"
  value       = module.compute_optimized.alb_dns_name
}
