variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-north-1"
}

variable "environment" {
  description = "Environment name (sandbox, dev, staging, prod)"
  type        = string
  default     = "sandbox"

  validation {
    condition     = contains(["sandbox", "dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: sandbox, dev, staging, prod."
  }
}

variable "project_name" {
  description = "Project name used as a prefix for all resource names"
  type        = string
  default     = "finops-audit"

  validation {
    condition     = length(trimspace(var.project_name)) > 0
    error_message = "project_name must not be empty."
  }
}

variable "owner" {
  description = "Team or individual responsible for these resources"
  type        = string
  default     = "platform-team"

  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "owner must not be empty."
  }
}

# Governance variables
variable "budget_amount" {
  description = "Monthly budget threshold in USD before alerts fire"
  type        = number
  default     = 50

  validation {
    condition     = var.budget_amount > 0
    error_message = "budget_amount must be greater than zero."
  }
}

variable "alert_email" {
  description = "Email address that receives budget breach notifications"
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}

variable "budget_alert_thresholds" {
  description = "Percentage thresholds at which budget alerts are sent"
  type        = list(number)
  default     = [50, 80, 100]

  validation {
    condition     = length(var.budget_alert_thresholds) > 0 && alltrue([for t in var.budget_alert_thresholds : t > 0 && t <= 100])
    error_message = "budget_alert_thresholds must contain values between 1 and 100."
  }
}

# Compute / ASG variables
variable "asg_min_size" {
  description = "Minimum number of instances in the Auto Scaling Group"
  type        = number
  default     = 1

  validation {
    condition     = var.asg_min_size >= 0
    error_message = "asg_min_size must be zero or greater."
  }
}

variable "asg_max_size" {
  description = "Maximum number of instances in the Auto Scaling Group"
  type        = number
  default     = 6

  validation {
    condition     = var.asg_max_size >= 1
    error_message = "asg_max_size must be at least 1."
  }
}

variable "asg_desired_capacity" {
  description = "Desired number of instances in the Auto Scaling Group"
  type        = number
  default     = 2

  validation {
    condition     = var.asg_desired_capacity >= 0
    error_message = "asg_desired_capacity must be zero or greater."
  }
}

variable "on_demand_base_capacity" {
  description = "Minimum number of On-Demand instances that must always run"
  type        = number
  default     = 1

  validation {
    condition     = var.on_demand_base_capacity >= 0
    error_message = "on_demand_base_capacity must be zero or greater."
  }
}

variable "on_demand_percentage_above_base" {
  description = "Percentage of On-Demand instances above the base capacity (remainder is Spot)"
  type        = number
  default     = 25

  validation {
    condition     = var.on_demand_percentage_above_base >= 0 && var.on_demand_percentage_above_base <= 100
    error_message = "on_demand_percentage_above_base must be between 0 and 100."
  }
}

variable "cost_center" {
  description = "Cost center tag value applied to all compute resources"
  type        = string
  default     = "CC-PLATFORM-001"

  validation {
    condition     = length(trimspace(var.cost_center)) > 0
    error_message = "cost_center must not be empty."
  }
}

variable "spot_instance_types" {
  description = "Instance types to use in the Spot pool (must be available in the target region)"
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
