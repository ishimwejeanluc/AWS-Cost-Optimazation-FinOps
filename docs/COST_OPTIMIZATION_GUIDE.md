# AWS Cost Optimization Guide

I use a data-driven cost optimization process: measure first, then reduce spend.

---

## Step 1 - Find the waste

Start with Cost Explorer and answer:
1. What are the top 5 services by spend?
2. How much cost is untagged? (filter `CostCenter = ABSENT`)
3. What resources are idle? Use Trusted Advisor cost optimization.

---

## Step 2 - Remove zombie assets

Remove resources that incur cost but deliver no value.

```bash
# Scan everything
./scripts/find_zombie_assets.sh --region us-east-1

# Delete unattached EBS volumes
./scripts/gc_ebs_volumes.sh --region us-east-1          # dry run
./scripts/gc_ebs_volumes.sh --region us-east-1 --delete # delete

# Release orphaned EIPs
aws ec2 describe-addresses \
  --query 'Addresses[?!InstanceId && !NetworkInterfaceId].[AllocationId,PublicIp]' \
  --output table
aws ec2 release-address --allocation-id eipalloc-XXXXXXXXXX
```

Common zombie costs:

| Resource | Monthly Cost |
|---|---|
| Unattached EBS (gp3, 100 GB) | $8/month |
| Orphaned EIP | $3.60/month |
| Idle m5.large (24/7, 0% CPU) | $69/month |
| Stopped EC2 (EBS still attached) | Varies |

---

## Step 3 - Use Spot instances

For stateless workloads, use Spot to reduce compute cost. This repo deploys a Mixed Instances ASG with:
- one On-Demand base instance
- 75% Spot capacity on scale-out
- `capacity-optimized` allocation
- multiple instance types for pool diversity

This approach reduces cost without losing availability.

---

## Step 4 - Set a budget and alerts

Deploy the governance module to create a $50 monthly budget, SNS alerts, and forecast notifications.
Confirm the SNS subscription before relying on alerts.

---

## Step 5 - Enforce tags

Untagged resources are hard to attribute and expensive to clean up.
- Terraform `default_tags` applies common tags automatically
- AWS Config `REQUIRED_TAGS` enforces compliance
- IAM or SCP denies block launches without `CostCenter`

---

## Step 6 - Monitor regularly

Run the cost report weekly:
```bash
./scripts/generate_cost_report.sh --budget 50
```
It shows spend by service, trend, untagged cost, and forecast vs budget.
Enable Cost Anomaly Detection for alerts between reports.

---

## What’s next

| Action | Impact | Effort |
|---|---|---|
| Savings Plans | 30-40% on steady compute | Low |
| Compute Optimizer rightsizing | 15-30% on EC2/RDS | Low |
| S3 Intelligent-Tiering | 40-90% on cold data | Low |
| RDS auto-stop (dev/test) | ~100% night/weekend savings | Medium |
| VPC Endpoints for S3/DynamoDB | reduce NAT transfer cost | Medium |
| CloudWatch log retention (30d) | lower log cost | Low |

Start with Savings Plans once spend is stable.
