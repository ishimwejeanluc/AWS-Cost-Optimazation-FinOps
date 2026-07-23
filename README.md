# AWS FinOps Audit

> **Terraform + Python toolkit** for detecting zombie cloud resources, enforcing cost governance, and optimising compute spend on AWS.



---

## Overview

This project implements a full **FinOps audit cycle** against an AWS sandbox account:

1. **Baseline** — deploys intentional "zombie" resources (unattached EBS volumes, orphaned EIPs, idle EC2) via Terraform to simulate real waste.
2. **Detect** — Python/Boto3 scripts scan the account and surface all zombie assets.
3. **Remediate** — automated garbage-collection scripts delete or release wasteful resources.
4. **Govern** — AWS Budgets, SNS alerts, AWS Config tag-compliance rules, and a cost-optimised Auto Scaling Group (Spot + On-Demand) enforce ongoing hygiene.

**Demonstrated monthly saving: ~$115 / month (~$1,383 / year) in a minimal demo environment.**

---

## Repository Structure

```
finops/
├── infra/
│   ├── providers.tf                   # AWS provider + default tags
│   ├── variables.tf                   # Root input variables
│   ├── main.tf                        # Root module orchestration
│   ├── outputs.tf                     # Key resource IDs and ARNs
│   ├── backend.tf                     # S3 remote state + DynamoDB lock
│   ├── terraform.tfvars.example       # Variable template
│   ├── bootstrap/                     # Creates the S3/DynamoDB remote backend (run first)
│   └── modules/
│       ├── wasteful_resources/        # Zombie asset baseline (demo)
│       ├── governance/                # Budgets, SNS, Config rules, S3
│       └── compute_optimized/         # Mixed-Instance ASG (Spot + On-Demand)
├── scripts/
│   ├── find_zombie_assets.sh          # Full zombie asset scanner
│   ├── gc_ebs_volumes.sh              # Unattached EBS garbage collector
│   └── generate_cost_report.sh        # Cost Explorer FinOps report
├── docs/
│   ├── AUDIT_REPORT.md                # Findings, remediation log, evidence
│   ├── TAGGING_POLICY.md              # Mandatory tags, SCP, enforcement
│   └── COST_OPTIMIZATION_GUIDE.md    # End-to-end FinOps playbook
├── audit-evidence/                    # Raw evidence collected during audit
├── screenshoots/                      # AWS Console screenshots
└── .github/workflows/terraform-ci.yml # Format → Validate → TFLint pipeline
```

---

## Quick Start

### Prerequisites

- Terraform ≥ 1.5
- AWS CLI v2 and `jq` (the scripts auto-install `jq` if it is missing)
- AWS credentials configured (`aws configure` or environment variables)
- An AWS account with billing access enabled

### 1 — Bootstrap the Remote State Backend (run once)

```bash
cd infra/bootstrap/
terraform init
terraform apply        # creates the S3 state bucket + DynamoDB lock table
```

> Skip this only if you prefer local state — in that case rename `infra/backend.tf`
> before the next step so Terraform falls back to a local state file.

### 2 — Deploy the Infrastructure

```bash
cd infra/
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set alert_email, aws_region, and enable_config = true

terraform init         # uses the S3 backend created by the bootstrap
terraform plan -out=tfplan
terraform apply tfplan
```

> After `terraform apply`, confirm the SNS subscription email that arrives in your inbox to activate budget alerts.

### 3 — Prepare the Scripts

```bash
cd scripts/
chmod +x *.sh   # make the scripts executable (first time only)
# aws CLI v2 and jq are required; the scripts auto-install jq if it is missing.
```

### 4 — Detect Zombie Assets

```bash
# Scan for all zombie asset types
./find_zombie_assets.sh --region us-east-1

# Export findings to JSON (CI-friendly: exits 1 if findings exist)
./find_zombie_assets.sh --region us-east-1 --output-json reports/findings.json
```

### 5 — Remediate

```bash
# Dry-run: preview EBS volumes that would be deleted
./gc_ebs_volumes.sh --region us-east-1

# Live delete (irreversible — use with care)
./gc_ebs_volumes.sh --region us-east-1 --delete --yes
```

### 6 — Generate Cost Report

```bash
./generate_cost_report.sh --budget 50 --months 3 --output reports/$(date +%Y-%m).json
```

### 7 — Teardown

```bash
cd infra/
terraform destroy
# The remote-state bucket/table in infra/bootstrap/ persist by design;
# see infra/bootstrap/README.md to remove them.
```

---

## What Gets Deployed

### `wasteful_resources` — Zombie Asset Baseline

Intentional waste used to validate detection scripts:

| Resource | Type | Monthly Cost |
|---|---|---|
| 3× EBS volumes (50 / 100 / 200 GB, unattached) | gp3, gp2, io1 | ~$39 |
| 2× Elastic IPs (unassociated) | EIP | ~$7.20 |
| 1× EC2 instance (idle, no workload, `CostCenter = UNKNOWN`) | m5.large | ~$69 |
| **Total waste** | | **~$115 / month** |

### `governance` — Cost Controls

| Control | Detail |
|---|---|
| AWS Budget | $50/month COST budget, alerts at 50 / 80 / 100% actual + 100% forecasted |
| SNS topic | Routes all budget and Config alerts to a confirmed email endpoint |
| AWS Config | `REQUIRED_TAGS` rule (CostCenter, Environment, Project, Owner) + `EC2_INSTANCE_NO_PUBLIC_IP` |
| S3 bucket | Config delivery destination — encrypted, versioned, public-access blocked |

### `compute_optimized` — Cost-Aware Auto Scaling Group

| Setting | Value |
|---|---|
| On-Demand base capacity | 1 instance (always guaranteed) |
| On-Demand % above base | 25% |
| Spot % above base | 75% |
| Spot allocation strategy | `capacity-optimized` |
| Instance pool | t3.micro, t3.small, t3.medium, t3.large |
| Scale-out trigger | CPU ≥ 70% |
| Scale-in trigger | CPU ≤ 30% |

---

## Scripts Reference

| Script | Purpose | Key Flags |
|---|---|---|
| `find_zombie_assets.sh` | Scans for idle EC2, unattached EBS, orphaned EIPs, unused snapshots | `--cpu-threshold`, `--idle-days`, `--output-json FILE` |
| `gc_ebs_volumes.sh` | Deletes unattached EBS volumes | `--delete`, `--min-age-days N`, `--exclude-tag KEY=VALUE`, `--yes` |
| `generate_cost_report.sh` | Pulls Cost Explorer data into a structured FinOps report | `--budget FLOAT`, `--months INT`, `--output FILE` |

All scripts exit with code `1` when findings exist — suitable as CI quality gates.

---

## Cost Impact Summary

| Initiative | Monthly Saving | Annual Saving |
|---|---|---|
| Delete zombie EBS volumes | ~$39 | ~$468 |
| Release orphaned Elastic IPs | ~$7 | ~$86 |
| Terminate idle EC2 instance | ~$69 | ~$829 |
| Spot Instances (vs. all On-Demand) | 42–70% compute reduction | Varies by fleet size |
| **Total (demo environment)** | **~$115+** | **~$1,383+** |

---

## Audit Screenshots

All screenshots are in [`screenshoots/`](screenshoots/).

### EC2 — Running Instances (Zombie + ASG)
![EC2 Instances](screenshoots/Screenshot%20from%202026-04-27%2009-24-10.png)

Three instances: the intentional zombie (idle, `CostCenter = UNKNOWN`) alongside ASG-managed instances.

---

### EBS — Unattached Volumes
![EBS Volumes](screenshoots/Screenshot%20from%202026-04-27%2009-25-41.png)

Three volumes in `available` state (50 GB gp3, 100 GB gp2, 200 GB io1) — ~$39/month of pure waste.

---

### EIP — Orphaned Elastic IPs
![Elastic IPs](screenshoots/Screenshot%20from%202026-04-27%2009-25-59.png)

Two unassociated EIPs tagged `ZOMBIE-orphan`, each costing ~$3.60/month.

---

### ASG — Group Details
![ASG Details](screenshoots/Screenshot%20from%202026-04-27%2009-26-41.png)

`finops-audit-sandbox-asg` with desired/min/max capacity visible.

---

### ASG — Spot vs On-Demand Instances
![ASG Instance Lifecycle](screenshoots/Screenshot%20from%202026-04-27%2009-26-59.png)

Live instances showing `spot` and `normal` (On-Demand) lifecycle columns.

---

### ASG — Mixed Instances Policy
![ASG Mixed Instances Policy](screenshoots/Screenshot%20from%202026-04-27%2009-27-59.png)

25% On-Demand / 75% Spot with `capacity-optimized` strategy across a 4-type instance pool.

---

### S3 — Config Delivery Bucket
![S3 Config Bucket](screenshoots/Screenshot%20from%202026-04-27%2009-23-39.png)

Governance module bucket: encrypted, versioned, public-access blocked.

---

### AWS Budgets — Overview
![Budgets Overview](screenshoots/Screenshot%20from%202026-04-27%2009-30-37.png)

`finops-audit-sandbox-monthly-budget` at $50/month alongside other account budgets.

---

### AWS Budgets — Detail
![Budget Detail](screenshoots/Screenshot%20from%202026-04-27%2009-30-44.png)

Health panel: current spend vs. MTD forecast, alert thresholds at 50 / 80 / 100% actual + 100% forecasted.

---

### SNS — Subscription Confirmation
![SNS Confirmation Email](screenshoots/Screenshot%20from%202026-04-27%2009-31-22.png)

Confirmation email for `finops-audit-sandbox-cost-alerts` topic — clicking activates alert delivery.

---

## CI/CD Pipeline

`.github/workflows/terraform-ci.yml` runs on every push and pull request:

```
terraform fmt --check  →  terraform validate  →  TFLint
```

The pipeline fails fast on formatting issues, validation errors, or lint warnings before any code reaches a deployment environment.

---

## Documentation

| Document | Purpose |
|---|---|
| [docs/AUDIT_REPORT.md](docs/AUDIT_REPORT.md) | Full findings, remediation log, evidence checklist |
| [docs/TAGGING_POLICY.md](docs/TAGGING_POLICY.md) | Mandatory tag keys, SCP JSON, enforcement mechanisms |
| [docs/COST_OPTIMIZATION_GUIDE.md](docs/COST_OPTIMIZATION_GUIDE.md) | End-to-end FinOps playbook (7 sections) |

---

## License

MIT — see [LICENSE](LICENSE) for details.
