variable "project_name" {
  description = "Project name prefix"
  type        = string

  validation {
    condition     = length(trimspace(var.project_name)) > 0
    error_message = "project_name must not be empty."
  }
}

variable "environment" {
  description = "Environment name"
  type        = string

  validation {
    condition     = length(trimspace(var.environment)) > 0
    error_message = "environment must not be empty."
  }
}

variable "owner" {
  description = "Owning team"
  type        = string

  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "owner must not be empty."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the demo VPC"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid CIDR block."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the two public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == 2 && alltrue([for cidr in var.public_subnet_cidrs : can(cidrnetmask(cidr))])
    error_message = "public_subnet_cidrs must contain exactly two valid CIDR blocks."
  }
}

variable "idle_instance_type" {
  description = "Instance type for the idle zombie EC2 instance"
  type        = string
  default     = "m5.large"

  validation {
    condition     = length(trimspace(var.idle_instance_type)) > 0
    error_message = "idle_instance_type must not be empty."
  }
}

variable "ebs_volume_sizes_gb" {
  description = "Sizes in GB for the three unattached EBS volumes"
  type        = list(number)
  default     = [50, 100, 200]

  validation {
    condition     = length(var.ebs_volume_sizes_gb) > 0 && alltrue([for size in var.ebs_volume_sizes_gb : size > 0])
    error_message = "ebs_volume_sizes_gb must contain positive values."
  }
}

variable "ebs_volume_types" {
  description = "EBS volume types matching ebs_volume_sizes_gb"
  type        = list(string)
  default     = ["gp3", "gp2", "io1"]

  validation {
    condition     = length(var.ebs_volume_types) > 0
    error_message = "ebs_volume_types must contain at least one type."
  }
}
