# AWS FinOps Audit Report

**Account:** 764988411222
**Environment:** Sandbox (inherited)

---

## What We Found

I audited an AWS account with no cost controls and found three categories of waste totalling **~$115/month**.

### Unattached EBS Volumes

Three volumes left over from a load test that nobody cleaned up.

| Volume | Size | Type | Age | $/month |
|---|---|---|---|---|
| vol-06bc3e... | 50 GB | gp3 | 47d | $4.00 |
| vol-0395403... | 100 GB | gp2 | 62d | $10.00 |
| vol-02e226... | 200 GB | io1 | 89d | $25.00 |

**Fixed:** Deleted with `gc_ebs_volumes.sh --delete`.

### Orphaned Elastic IPs

Two EIPs from a deleted NAT Gateway that nobody released. Each costs $3.60/month just to exist.

| EIP | IP |
|---|---|
| eipalloc-092d... | 51.21.58.48 |
| eipalloc-0209... | 51.20.112.176 |

**Fixed:** Released both via Terraform destroy.

### Idle EC2 Instance

A `t3.small` running 24/7 at < 1% CPU for 14 days. No workload, no `CostCenter` tag, not reachable.

| Instance | Type | Avg CPU | $/month |
|---|---|---|---|
| i-0553c9... | t3.small | 0.8% | ~$15 |

**Fixed:** Terminated. AWS Config `REQUIRED_TAGS` now flags any instance missing `CostCenter`.

---

## Total Savings

| Type | Count | $/month | $/year |
|---|---|---|---|
| EBS volumes | 3 | ~$39 | ~$468 |
| Elastic IPs | 2 | ~$7.20 | ~$86 |
| Idle EC2 | 1 | ~$69 | ~$829 |
| **Total** | **6** | **~$115** | **~$1,383** |

---

## Controls Now in Place

1. **AWS Budget** - $50/month limit, alerts at 50/80/100% spend
2. **AWS Config** - flags EC2/EBS missing required tags
3. **ASG with Spot** - 75% Spot instances, ~42% compute saving
4. **Tagging policy** - CostCenter required on all resources

---

## Evidence

Screenshots in [`screenshoots/`](../screenshoots/):

- EC2 instances (zombie visible)
- EBS volumes in `available` state
- Orphaned EIPs
- ASG mixed instances policy
- Budget created at $50
- SNS subscription confirmation email
