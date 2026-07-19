output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = aws_subnet.public[*].id
}

output "idle_instance_id" {
  description = "Instance ID of the zombie idle EC2 instance"
  value       = aws_instance.idle.id
}

output "idle_instance_type" {
  description = "Instance type of the zombie idle EC2 instance"
  value       = aws_instance.idle.instance_type
}

output "unattached_volume_ids" {
  description = "Volume IDs of all unattached EBS volumes"
  value       = aws_ebs_volume.unattached[*].id
}

output "unattached_volume_sizes_gb" {
  description = "Sizes in GB of all unattached EBS volumes"
  value       = aws_ebs_volume.unattached[*].size
}

output "unassociated_eip_addresses" {
  description = "Public IP addresses of all unassociated Elastic IPs"
  value       = aws_eip.orphaned[*].public_ip
}

output "unassociated_eip_allocation_ids" {
  description = "Allocation IDs of all unassociated Elastic IPs"
  value       = aws_eip.orphaned[*].id
}
