# Root module
# Orchestrates child modules: wasteful_resources, governance, compute_optimized

module "wasteful_resources" {
  source = "./modules/wasteful_resources"

  project_name = var.project_name
  environment  = var.environment
  owner        = var.owner
}

module "governance" {
  source = "./modules/governance"

  project_name            = var.project_name
  environment             = var.environment
  budget_amount           = var.budget_amount
  alert_email             = var.alert_email
  budget_alert_thresholds = var.budget_alert_thresholds
}

module "compute_optimized" {
  source = "./modules/compute_optimized"

  project_name                    = var.project_name
  environment                     = var.environment
  cost_center                     = var.cost_center
  owner                           = var.owner
  vpc_id                          = module.wasteful_resources.vpc_id
  subnet_ids                      = module.wasteful_resources.public_subnet_ids
  asg_min_size                    = var.asg_min_size
  asg_max_size                    = var.asg_max_size
  asg_desired_capacity            = var.asg_desired_capacity
  on_demand_base_capacity         = var.on_demand_base_capacity
  on_demand_percentage_above_base = var.on_demand_percentage_above_base
  spot_instance_types             = var.spot_instance_types
}
