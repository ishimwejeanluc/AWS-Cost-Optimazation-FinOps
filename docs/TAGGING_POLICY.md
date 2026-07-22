# AWS Resource Tagging Policy

---

## Purpose

Tags are required so I can attribute cost, enforce cleanup, and prevent unowned resources.

---

## Required Tags

Every EC2 instance, EBS volume, RDS instance, EKS cluster, S3 bucket, and Load Balancer needs all four:

| Tag | What to put | Example |
|---|---|---|
| `CostCenter` | Finance code | `CC-ENG-001` |
| `Environment` | Stage of deployment | `sandbox`, `prod` |
| `Project` | Product or project name | `finops-audit` |
| `Owner` | Team or person responsible | `platform-team` |

Optional but useful: `Name`, `ExpiresOn`, `DataClassification`.

---

## Enforcement

Terraform `default_tags` applies `Project`, `Environment`, `ManagedBy`, and `Owner` automatically. I expect engineers to set `CostCenter` manually.

AWS Config uses `REQUIRED_TAGS` to mark missing tags as `NON_COMPLIANT` and generate SNS alerts.

For AWS Organizations, use an SCP to deny EC2 launches without `CostCenter`. For standalone accounts, use the equivalent IAM condition.

```json
{
  "Effect": "Deny",
  "Action": ["ec2:RunInstances"],
  "Resource": "arn:aws:ec2:*:*:instance/*",
  "Condition": {
    "Null": { "aws:RequestTag/CostCenter": "true" }
  }
}
```

---

## Non-compliance process

1. Config flags the resource and SNS sends an alert
2. I review CloudTrail to identify the owner
3. Owner has **48 hours** to add missing tags
4. After 7 days, the instance is stopped
5. After 14 days, the instance is terminated

---

## Cost Explorer

Activate tags in Cost Explorer under Billing > Cost Allocation Tags. Allow up to 24 hours.
