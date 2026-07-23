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

variable "cost_center" {
  description = "Cost center tag value"
  type        = string

  validation {
    condition     = length(trimspace(var.cost_center)) > 0
    error_message = "cost_center must not be empty."
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

variable "vpc_id" {
  description = "VPC ID where the ASG will be launched"
  type        = string

  validation {
    condition     = length(trimspace(var.vpc_id)) > 0
    error_message = "vpc_id must not be empty."
  }
}

variable "subnet_ids" {
  description = "Subnet IDs for the ASG and ALB"
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "subnet_ids must contain at least one subnet ID."
  }
}

variable "asg_min_size" {
  description = "Minimum ASG size"
  type        = number
  default     = 1

  validation {
    condition     = var.asg_min_size >= 0
    error_message = "asg_min_size must be zero or greater."
  }
}

variable "asg_max_size" {
  description = "Maximum ASG size"
  type        = number
  default     = 6

  validation {
    condition     = var.asg_max_size >= 1
    error_message = "asg_max_size must be at least 1."
  }
}

variable "asg_desired_capacity" {
  description = "Desired ASG capacity"
  type        = number
  default     = 2

  validation {
    condition     = var.asg_desired_capacity >= 0
    error_message = "asg_desired_capacity must be zero or greater."
  }
}

variable "on_demand_base_capacity" {
  description = "Number of On-Demand instances always guaranteed in the ASG"
  type        = number
  default     = 1

  validation {
    condition     = var.on_demand_base_capacity >= 0
    error_message = "on_demand_base_capacity must be zero or greater."
  }
}

variable "on_demand_percentage_above_base" {
  description = "Percentage of On-Demand instances above base capacity (rest are Spot)"
  type        = number
  default     = 25

  validation {
    condition     = var.on_demand_percentage_above_base >= 0 && var.on_demand_percentage_above_base <= 100
    error_message = "on_demand_percentage_above_base must be between 0 and 100."
  }
}

# Spot pool of instance types for diversification
variable "spot_instance_types" {
  description = "List of instance types to consider for Spot capacity"
  type        = list(string)
  default = [
    "t3.micro",
    "t3.small",
    "t3a.micro",
    "t3a.small",
    "t2.micro",
    "t2.small",
  ]

  validation {
    condition     = length(var.spot_instance_types) > 0
    error_message = "spot_instance_types must contain at least one instance type."
  }
}

variable "health_check_path" {
  description = "ALB health check path"
  type        = string
  default     = "/"

  validation {
    condition     = length(trimspace(var.health_check_path)) > 0
    error_message = "health_check_path must not be empty."
  }
}

variable "app_port" {
  description = "Port the application listens on"
  type        = number
  default     = 80

  validation {
    condition     = var.app_port > 0 && var.app_port <= 65535
    error_message = "app_port must be a valid TCP port (1-65535)."
  }
}
