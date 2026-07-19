output "asg_name" {
  description = "Name of the Auto Scaling Group"
  value       = aws_autoscaling_group.app.name
}

output "asg_arn" {
  description = "ARN of the Auto Scaling Group"
  value       = aws_autoscaling_group.app.arn
}

output "launch_template_id" {
  description = "ID of the Launch Template"
  value       = aws_launch_template.app.id
}

output "launch_template_latest_version" {
  description = "Latest version number of the Launch Template"
  value       = aws_launch_template.app.latest_version
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.app.dns_name
}

output "alb_arn" {
  description = "ARN of the Application Load Balancer"
  value       = aws_lb.app.arn
}

output "target_group_arn" {
  description = "ARN of the ALB Target Group"
  value       = aws_lb_target_group.app.arn
}

output "app_security_group_id" {
  description = "ID of the application security group"
  value       = aws_security_group.app.id
}

output "on_demand_base_capacity" {
  description = "Guaranteed On-Demand instance floor"
  value       = var.on_demand_base_capacity
}

output "on_demand_percentage_above_base" {
  description = "On-Demand percentage above base (rest are Spot)"
  value       = var.on_demand_percentage_above_base
}
