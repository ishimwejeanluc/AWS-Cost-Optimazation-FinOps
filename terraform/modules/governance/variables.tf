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

variable "budget_amount" {
  description = "Monthly budget ceiling in USD"
  type        = number

  validation {
    condition     = var.budget_amount > 0
    error_message = "budget_amount must be greater than zero."
  }
}

variable "alert_email" {
  description = "Email address for budget breach notifications"
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

variable "required_tag_keys" {
  description = "Tag keys that must be present on every EC2 instance and EBS volume"
  type        = list(string)
  default     = ["CostCenter", "Environment", "Project", "Owner"]

  validation {
    condition     = length(var.required_tag_keys) > 0
    error_message = "required_tag_keys must contain at least one tag key."
  }
}

variable "enable_config" {
  description = "Whether to deploy AWS Config recorder and rules (requires config:PutConfigurationRecorder; disable if org SCP blocks it)"
  type        = bool
  default     = false
}

variable "config_resource_types" {
  description = "AWS resource types that Config will record and evaluate"
  type        = list(string)
  default = [
    "AWS::EC2::Instance",
    "AWS::EC2::Volume",
    "AWS::EC2::EIP",
    "AWS::EC2::SecurityGroup",
    "AWS::S3::Bucket",
  ]

  validation {
    condition     = length(var.config_resource_types) > 0
    error_message = "config_resource_types must contain at least one resource type."
  }
}
