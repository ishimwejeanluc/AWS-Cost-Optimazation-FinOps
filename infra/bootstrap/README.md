# Remote-state bootstrap

This folder creates the **remote backend** that the root `infra/` configuration
uses: an S3 bucket for the Terraform state file and a DynamoDB table for state
locking.

It runs **once**, **before** the root config, and keeps its own **local** state
(there is deliberately no `backend` block here — you can't store state remotely
before the remote store exists).

## What it creates

| Resource | Default name | Purpose |
|---|---|---|
| S3 bucket | `finops-audit-terraform-state` | Stores `terraform.tfstate` (versioned, encrypted, private, TLS-only) |
| DynamoDB table | `finops-audit-terraform-locks` | Prevents concurrent `apply` via a lock (`LockID`) |

The defaults match [`../backend.tf`](../backend.tf), so no edits are needed
unless the bucket name is already taken globally.

## Usage

```bash
# 1. Create the remote-state resources (local state)
cd infra/bootstrap
terraform init
terraform apply            # type "yes"

# 2. Now initialise the root config against that backend
cd ..
terraform init             # reads backend.tf -> uses the new S3 bucket + lock table
terraform plan -out=tfplan
terraform apply tfplan
```

If you changed `state_bucket_name`, `lock_table_name`, or `aws_region`, copy the
`backend_config` output into `../backend.tf` first:

```bash
terraform output -raw backend_config
```

## Tearing it down

The state bucket has `prevent_destroy = true` so it can't be deleted by accident.
To remove the backend **after** you have destroyed the root infra:

1. Destroy the root config first: `cd .. && terraform destroy`
2. Empty the bucket (delete all object versions) in the console or via `aws s3`.
3. Remove the `lifecycle { prevent_destroy = true }` block from `main.tf`.
4. `terraform destroy` here.
