#!/usr/bin/env python3
"""
gc_ebs_volumes.py  -  Garbage-collect unattached EBS volumes.

Usage:
    # Dry run (default)  -  lists volumes, deletes nothing
    python gc_ebs_volumes.py

    # Confirm deletion interactively
    python gc_ebs_volumes.py --delete

    # Delete all without prompting (use in CI after review)
    python gc_ebs_volumes.py --delete --yes

    # Target a specific region
    python gc_ebs_volumes.py --region eu-west-1

    # Skip volumes newer than N days
    python gc_ebs_volumes.py --delete --min-age-days 30

    # Skip volumes with a specific tag
    python gc_ebs_volumes.py --delete --exclude-tag DoNotDelete=true
"""

import argparse
import sys
from datetime import datetime, timezone, timedelta

import boto3
from botocore.exceptions import ClientError, NoCredentialsError
from tabulate import tabulate
from colorama import Fore, Style, init as colorama_init

colorama_init(autoreset=True)



def get_tag(tags: list, key: str) -> str:
    """Return the value of the first matching tag or '-'."""
    if not tags:
        return "-"
    for t in tags:
        if t["Key"] == key:
            return t["Value"]
    return "-"


def volume_age_days(volume: dict) -> int:
    """Return how many days ago the volume was created."""
    created = volume["CreateTime"]
    if created.tzinfo is None:
        created = created.replace(tzinfo=timezone.utc)
    return (datetime.now(timezone.utc) - created).days


def monthly_cost_usd(volume: dict) -> float:
    """
    Rough monthly cost estimate.
    Pricing (us-east-1, 2025):
        gp3  = $0.080/GB  |  gp2  = $0.100/GB
        io1  = $0.125/GB  |  io2  = $0.125/GB
        st1  = $0.045/GB  |  sc1  = $0.025/GB
    """
    prices = {
        "gp3": 0.080, "gp2": 0.100,
        "io1": 0.125, "io2": 0.125,
        "st1": 0.045, "sc1": 0.025,
    }
    rate = prices.get(volume.get("VolumeType", "gp3"), 0.080)
    return round(rate * volume["Size"], 2)


def fmt_usd(amount: float) -> str:
    return f"${amount:,.2f}"



def find_unattached_volumes(
    ec2_client,
    min_age_days: int = 0,
    exclude_tag_key: str | None = None,
    exclude_tag_value: str | None = None,
) -> list[dict]:
    """
    Return all EBS volumes in 'available' state, applying optional filters.
    """
    paginator = ec2_client.get_paginator("describe_volumes")
    pages = paginator.paginate(Filters=[{"Name": "status", "Values": ["available"]}])

    results = []
    for page in pages:
        for vol in page["Volumes"]:
            age = volume_age_days(vol)

            if age < min_age_days:
                continue

            if exclude_tag_key:
                tag_val = get_tag(vol.get("Tags", []), exclude_tag_key)
                if exclude_tag_value:
                    if tag_val == exclude_tag_value:
                        continue
                elif tag_val != "-":
                    continue

            results.append(vol)

    return results


def build_table(volumes: list[dict]) -> tuple[list, list, float]:
    """Return table rows, headers, and total monthly waste estimate."""
    headers = [
        "Volume ID", "Size (GB)", "Type", "AZ",
        "Age (days)", "CostCenter Tag", "Est. $/month", "Created",
    ]
    rows = []
    total_cost = 0.0

    for vol in volumes:
        cost = monthly_cost_usd(vol)
        total_cost += cost
        rows.append([
            vol["VolumeId"],
            vol["Size"],
            vol["VolumeType"],
            vol["AvailabilityZone"],
            volume_age_days(vol),
            get_tag(vol.get("Tags", []), "CostCenter"),
            fmt_usd(cost),
            vol["CreateTime"].strftime("%Y-%m-%d"),
        ])

    return rows, headers, total_cost


def delete_volumes(ec2_client, volumes: list[dict], yes: bool) -> tuple[int, int]:
    """
    Delete each volume, optionally asking for confirmation.
    Returns (deleted_count, failed_count).
    """
    deleted = failed = 0

    for vol in volumes:
        vol_id = vol["VolumeId"]
        cost = fmt_usd(monthly_cost_usd(vol))

        if not yes:
            answer = input(
                f"\n  Delete {vol_id} ({vol['Size']} GB {vol['VolumeType']}, "
                f"{cost}/month)? [y/N]: "
            ).strip().lower()
            if answer != "y":
                print(f"  {Fore.YELLOW}Skipped {vol_id}")
                continue

        try:
            ec2_client.delete_volume(VolumeId=vol_id)
            print(f"  {Fore.GREEN}Deleted  {vol_id}  (saved {cost}/month)")
            deleted += 1
        except ClientError as exc:
            code = exc.response["Error"]["Code"]
            print(f"  {Fore.RED}FAILED   {vol_id}  [{code}] {exc.response['Error']['Message']}")
            failed += 1

    return deleted, failed



def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Garbage-collect unattached EBS volumes",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--region", default=None, help="AWS region (default: profile default)")
    parser.add_argument("--profile", default=None, help="AWS CLI profile name")
    parser.add_argument("--delete", action="store_true", help="Actually delete volumes (default: dry run)")
    parser.add_argument("--yes", "-y", action="store_true", help="Skip per-volume confirmation prompts")
    parser.add_argument("--min-age-days", type=int, default=0,
                        help="Only target volumes older than N days (default: 0 = all)")
    parser.add_argument("--exclude-tag", default=None, metavar="KEY=VALUE",
                        help="Skip volumes with this tag (e.g. DoNotDelete=true)")
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    # Parse optional exclude tag
    excl_key = excl_val = None
    if args.exclude_tag:
        parts = args.exclude_tag.split("=", 1)
        excl_key = parts[0]
        excl_val = parts[1] if len(parts) > 1 else None

    # Create AWS session
    try:
        session = boto3.Session(
            region_name=args.region,
            profile_name=args.profile,
        )
        ec2 = session.client("ec2")
        region = session.region_name or ec2.meta.region_name
    except NoCredentialsError:
        print(f"{Fore.RED}ERROR: No AWS credentials found. Configure via env vars, ~/.aws/credentials, or IAM role.")
        sys.exit(1)

    print(f"\n{Style.BRIGHT}=== EBS Garbage Collector  |  region: {region} ===\n")

    if args.min_age_days:
        print(f"  Filter: volumes older than {args.min_age_days} days")
    if excl_key:
        print(f"  Filter: excluding tag {excl_key}={excl_val or '(any value)'}")
    if not args.delete:
        print(f"  {Fore.CYAN}DRY RUN  -  pass --delete to actually remove volumes\n")

    # Discover volumes
    print("Scanning for unattached EBS volumes ...")
    volumes = find_unattached_volumes(ec2, args.min_age_days, excl_key, excl_val)

    if not volumes:
        print(f"{Fore.GREEN}No unattached volumes found. Nothing to clean up.")
        return

    rows, headers, total_cost = build_table(volumes)

    print(f"\nFound {Fore.YELLOW}{len(volumes)}{Style.RESET_ALL} unattached volume(s):\n")
    print(tabulate(rows, headers=headers, tablefmt="rounded_outline"))
    print(f"\n  {Style.BRIGHT}Total estimated monthly waste: {Fore.RED}{fmt_usd(total_cost)}")

    if not args.delete:
        print(f"\n  Run with {Style.BRIGHT}--delete{Style.RESET_ALL} to remove these volumes.")
        return

    # Confirm bulk deletion unless --yes
    if not args.yes:
        print(f"\n{Fore.YELLOW}WARNING: This will permanently delete {len(volumes)} volume(s). Data cannot be recovered.")
        confirm = input("  Proceed? [y/N]: ").strip().lower()
        if confirm != "y":
            print("Aborted.")
            return

    print("\nDeleting volumes ...")
    deleted, failed = delete_volumes(ec2, volumes, args.yes)

    # Summary
    saved = sum(monthly_cost_usd(v) for v in volumes[:deleted]) if deleted else 0.0
    print(f"\n{'-' * 50}")
    print(f"  Deleted : {Fore.GREEN}{deleted}")
    print(f"  Failed  : {Fore.RED}{failed}")
    print(f"  Monthly savings: {Fore.GREEN}{fmt_usd(saved)}")
    print(f"  Annual  savings: {Fore.GREEN}{fmt_usd(saved * 12)}")
    print(f"{'-' * 50}\n")


if __name__ == "__main__":
    main()
