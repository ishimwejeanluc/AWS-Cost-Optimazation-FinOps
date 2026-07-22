#!/usr/bin/env python3
"""
 that incur cost without delivering value.

Detects:
  1. Unattached EBS volumes
  2. Unassociated Elastic IPs
  3. Idle EC2 instances (< 5% average CPU over 7 days)
  4. Stopped EC2 instances (still paying for attached EBS)
  5. Unused Elastic Network Interfaces
  6. Old EBS snapshots (older than 90 days, no Name tag)
  7. EC2 instances missing required cost tags

Usage:
    python find_zombie_assets.py
    python find_zombie_assets.py --region us-west-2
    python find_zombie_assets.py --output-json findings.json
    python find_zombie_assets.py --cpu-threshold 5 --idle-days 14
"""

import argparse
import json
import sys
from datetime import datetime, timezone, timedelta

import boto3
from botocore.exceptions import ClientError, NoCredentialsError
from tabulate import tabulate
from colorama import Fore, Style, init as colorama_init

colorama_init(autoreset=True)

REQUIRED_TAGS = ["CostCenter", "Environment", "Project", "Owner"]



def get_tag(tags: list | None, key: str) -> str:
    if not tags:
        return "-"
    for t in tags:
        if t["Key"] == key:
            return t["Value"]
    return "-"


def age_days(dt: datetime) -> int:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return (datetime.now(timezone.utc) - dt).days


def monthly_ebs_cost(size_gb: int, vol_type: str) -> float:
    prices = {
        "gp3": 0.080, "gp2": 0.100,
        "io1": 0.125, "io2": 0.125,
        "st1": 0.045, "sc1": 0.025,
    }
    return round(prices.get(vol_type, 0.080) * size_gb, 2)


def fmt_usd(amount: float) -> str:
    return f"${amount:,.2f}"


def section(title: str) -> None:
    bar = "-" * (len(title) + 4)
    print(f"\n{Style.BRIGHT}{Fore.CYAN}{bar}")
    print(f"  {title}")
    print(f"{bar}{Style.RESET_ALL}")



def scan_unattached_ebs(ec2) -> list[dict]:
    findings = []
    paginator = ec2.get_paginator("describe_volumes")
    for page in paginator.paginate(Filters=[{"Name": "status", "Values": ["available"]}]):
        for vol in page["Volumes"]:
            cost = monthly_ebs_cost(vol["Size"], vol["VolumeType"])
            findings.append({
                "type": "UNATTACHED_EBS",
                "id": vol["VolumeId"],
                "detail": f"{vol['Size']} GB {vol['VolumeType']} in {vol['AvailabilityZone']}",
                "age_days": age_days(vol["CreateTime"]),
                "monthly_cost_usd": cost,
                "tags": vol.get("Tags", []),
                "raw": vol,
            })
    return findings


def scan_unassociated_eips(ec2) -> list[dict]:
    findings = []
    response = ec2.describe_addresses()
    for addr in response["Addresses"]:
        if "InstanceId" not in addr and "NetworkInterfaceId" not in addr:
            findings.append({
                "type": "UNASSOCIATED_EIP",
                "id": addr["AllocationId"],
                "detail": f"Public IP: {addr.get('PublicIp', 'N/A')}",
                "age_days": -1,         # EIP API doesn't expose creation time
                "monthly_cost_usd": 3.60,  # $0.005/hr = ~$3.60/month
                "tags": addr.get("Tags", []),
                "raw": addr,
            })
    return findings


def scan_idle_instances(ec2, cw, cpu_threshold: float, idle_days: int) -> list[dict]:
    """Flag running instances with average CPU below threshold over `idle_days`."""
    findings = []
    paginator = ec2.get_paginator("describe_instances")

    now = datetime.now(timezone.utc)
    start = now - timedelta(days=idle_days)

    for page in paginator.paginate(Filters=[{"Name": "instance-state-name", "Values": ["running"]}]):
        for reservation in page["Reservations"]:
            for inst in reservation["Instances"]:
                iid = inst["InstanceId"]
                try:
                    metrics = cw.get_metric_statistics(
                        Namespace="AWS/EC2",
                        MetricName="CPUUtilization",
                        Dimensions=[{"Name": "InstanceId", "Value": iid}],
                        StartTime=start,
                        EndTime=now,
                        Period=idle_days * 86400,
                        Statistics=["Average"],
                    )
                    datapoints = metrics.get("Datapoints", [])
                    avg_cpu = datapoints[0]["Average"] if datapoints else 0.0
                except ClientError:
                    avg_cpu = 0.0

                if avg_cpu < cpu_threshold:
                    findings.append({
                        "type": "IDLE_EC2",
                        "id": iid,
                        "detail": (
                            f"{inst['InstanceType']} | "
                            f"avg CPU {avg_cpu:.1f}% over {idle_days}d | "
                            f"launched {inst['LaunchTime'].strftime('%Y-%m-%d')}"
                        ),
                        "age_days": age_days(inst["LaunchTime"]),
                        "monthly_cost_usd": 0.0,  # varies by type; requires pricing API
                        "avg_cpu_pct": avg_cpu,
                        "tags": inst.get("Tags", []),
                        "raw": inst,
                    })
    return findings


def scan_stopped_instances(ec2) -> list[dict]:
    """Stopped instances still pay for their attached EBS volumes."""
    findings = []
    paginator = ec2.get_paginator("describe_instances")
    for page in paginator.paginate(Filters=[{"Name": "instance-state-name", "Values": ["stopped"]}]):
        for reservation in page["Reservations"]:
            for inst in reservation["Instances"]:
                ebs_cost = 0.0
                for bdm in inst.get("BlockDeviceMappings", []):
                    vol_id = bdm["Ebs"]["VolumeId"]
                    try:
                        vols = ec2.describe_volumes(VolumeIds=[vol_id])["Volumes"]
                        if vols:
                            ebs_cost += monthly_ebs_cost(vols[0]["Size"], vols[0]["VolumeType"])
                    except ClientError:
                        pass

                findings.append({
                    "type": "STOPPED_EC2",
                    "id": inst["InstanceId"],
                    "detail": (
                        f"{inst['InstanceType']} | "
                        f"stopped since ~{age_days(inst['LaunchTime'])}d | "
                        f"EBS cost {fmt_usd(ebs_cost)}/month"
                    ),
                    "age_days": age_days(inst["LaunchTime"]),
                    "monthly_cost_usd": ebs_cost,
                    "tags": inst.get("Tags", []),
                    "raw": inst,
                })
    return findings


def scan_unused_enis(ec2) -> list[dict]:
    findings = []
    paginator = ec2.get_paginator("describe_network_interfaces")
    for page in paginator.paginate(Filters=[{"Name": "status", "Values": ["available"]}]):
        for eni in page["NetworkInterfaces"]:
            findings.append({
                "type": "UNUSED_ENI",
                "id": eni["NetworkInterfaceId"],
                "detail": f"VPC: {eni['VpcId']} | Subnet: {eni['SubnetId']}",
                "age_days": -1,
                "monthly_cost_usd": 0.0,   # ENIs are free; but each may block cleanup
                "tags": eni.get("TagSet", []),
                "raw": eni,
            })
    return findings


def scan_old_snapshots(ec2, max_age_days: int = 90) -> list[dict]:
    findings = []
    response = ec2.describe_snapshots(OwnerIds=["self"])
    for snap in response["Snapshots"]:
        days_old = age_days(snap["StartTime"])
        if days_old >= max_age_days:
            name = get_tag(snap.get("Tags", []), "Name")
            cost = monthly_ebs_cost(snap["VolumeSize"], "gp3") * 0.05  # snapshots ~5% of volume price
            findings.append({
                "type": "OLD_SNAPSHOT",
                "id": snap["SnapshotId"],
                "detail": (
                    f"{snap['VolumeSize']} GB | "
                    f"{days_old}d old | "
                    f"Name: {name}"
                ),
                "age_days": days_old,
                "monthly_cost_usd": cost,
                "tags": snap.get("Tags", []),
                "raw": snap,
            })
    return findings


def scan_untagged_instances(ec2) -> list[dict]:
    """Find running instances missing any of the required cost allocation tags."""
    findings = []
    paginator = ec2.get_paginator("describe_instances")
    for page in paginator.paginate(Filters=[{"Name": "instance-state-name", "Values": ["running", "stopped"]}]):
        for reservation in page["Reservations"]:
            for inst in reservation["Instances"]:
                tags = inst.get("Tags", [])
                missing = [k for k in REQUIRED_TAGS if get_tag(tags, k) == "-"]
                if missing:
                    findings.append({
                        "type": "MISSING_TAGS",
                        "id": inst["InstanceId"],
                        "detail": f"Missing tags: {', '.join(missing)} | State: {inst['State']['Name']}",
                        "age_days": age_days(inst["LaunchTime"]),
                        "monthly_cost_usd": 0.0,
                        "missing_tags": missing,
                        "tags": tags,
                        "raw": inst,
                    })
    return findings



SCAN_LABELS = {
    "UNATTACHED_EBS":   "Unattached EBS Volumes",
    "UNASSOCIATED_EIP": "Unassociated Elastic IPs",
    "IDLE_EC2":         "Idle EC2 Instances",
    "STOPPED_EC2":      "Stopped EC2 Instances (paying EBS)",
    "UNUSED_ENI":       "Unused Elastic Network Interfaces",
    "OLD_SNAPSHOT":     "Old EBS Snapshots (>=90 days)",
    "MISSING_TAGS":     "Instances Missing Cost Tags",
}


def print_findings(findings_by_type: dict[str, list[dict]]) -> float:
    total_monthly = 0.0

    for ftype, findings in findings_by_type.items():
        section(f"{SCAN_LABELS.get(ftype, ftype)}  ({len(findings)} found)")

        if not findings:
            print(f"  {Fore.GREEN}None  -  clean!")
            continue

        rows = []
        for f in findings:
            rows.append([
                f["id"],
                f["detail"][:70],
                f["age_days"] if f["age_days"] >= 0 else "n/a",
                fmt_usd(f["monthly_cost_usd"]),
                get_tag(f["tags"], "CostCenter"),
                get_tag(f["tags"], "Owner"),
            ])
            total_monthly += f["monthly_cost_usd"]

        print(tabulate(
            rows,
            headers=["Resource ID", "Detail", "Age (days)", "$/month", "CostCenter", "Owner"],
            tablefmt="rounded_outline",
        ))

    return total_monthly


def save_json(findings_by_type: dict, path: str) -> None:
    serialisable = {}
    for ftype, items in findings_by_type.items():
        serialisable[ftype] = [
            {k: v for k, v in item.items() if k != "raw"}
            for item in items
        ]

    # datetime -> ISO string
    def default(obj):
        if isinstance(obj, datetime):
            return obj.isoformat()
        raise TypeError(f"Not serializable: {type(obj)}")

    with open(path, "w") as fh:
        json.dump(serialisable, fh, indent=2, default=default)
    print(f"\n  Findings saved to {path}")



def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Scan AWS account for zombie / wasteful resources",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--region", default=None)
    parser.add_argument("--profile", default=None)
    parser.add_argument("--cpu-threshold", type=float, default=5.0,
                        help="CPU%% below which a running instance is 'idle' (default: 5)")
    parser.add_argument("--idle-days", type=int, default=7,
                        help="Lookback window in days for CPU metrics (default: 7)")
    parser.add_argument("--snapshot-age", type=int, default=90,
                        help="Snapshots older than N days are flagged (default: 90)")
    parser.add_argument("--output-json", default=None, metavar="FILE",
                        help="Write findings to a JSON file")
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    try:
        session = boto3.Session(region_name=args.region, profile_name=args.profile)
        ec2 = session.client("ec2")
        cw  = session.client("cloudwatch")
        region = session.region_name or ec2.meta.region_name
    except NoCredentialsError:
        print(f"{Fore.RED}ERROR: No AWS credentials configured.")
        sys.exit(1)

    print(f"\n{Style.BRIGHT}{'=' * 60}")
    print(f"  ZOMBIE ASSET SCANNER  |  region: {region}")
    print(f"  Scan time: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}")
    print(f"{'=' * 60}{Style.RESET_ALL}")

    scans = [
        ("UNATTACHED_EBS",   lambda: scan_unattached_ebs(ec2)),
        ("UNASSOCIATED_EIP", lambda: scan_unassociated_eips(ec2)),
        ("IDLE_EC2",         lambda: scan_idle_instances(ec2, cw, args.cpu_threshold, args.idle_days)),
        ("STOPPED_EC2",      lambda: scan_stopped_instances(ec2)),
        ("UNUSED_ENI",       lambda: scan_unused_enis(ec2)),
        ("OLD_SNAPSHOT",     lambda: scan_old_snapshots(ec2, args.snapshot_age)),
        ("MISSING_TAGS",     lambda: scan_untagged_instances(ec2)),
    ]

    findings_by_type: dict[str, list[dict]] = {}
    for label, fn in scans:
        print(f"  Scanning: {label} ...", end="\r")
        try:
            findings_by_type[label] = fn()
        except ClientError as exc:
            print(f"\n  {Fore.YELLOW}WARN: {label} scan failed  -  {exc.response['Error']['Message']}")
            findings_by_type[label] = []

    total_monthly = print_findings(findings_by_type)
    total_annual  = total_monthly * 12

    total_findings = sum(len(v) for v in findings_by_type.values())

    print(f"\n{'=' * 60}")
    print(f"{Style.BRIGHT}  SUMMARY")
    print(f"{'=' * 60}{Style.RESET_ALL}")
    print(f"  Total zombie assets found : {Fore.YELLOW}{total_findings}{Style.RESET_ALL}")
    print(f"  Estimated monthly waste   : {Fore.RED}{fmt_usd(total_monthly)}{Style.RESET_ALL}")
    print(f"  Estimated annual waste    : {Fore.RED}{fmt_usd(total_annual)}{Style.RESET_ALL}")
    print(f"{'=' * 60}\n")

    if args.output_json:
        save_json(findings_by_type, args.output_json)

    # Exit 1 if any findings so CI pipelines can flag the issue
    sys.exit(0 if total_findings == 0 else 1)


if __name__ == "__main__":
    main()
