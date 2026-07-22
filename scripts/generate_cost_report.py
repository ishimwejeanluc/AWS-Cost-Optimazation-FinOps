#!/usr/bin/env python3
"""
generate_cost_report.py  -  Pull cost data from AWS Cost Explorer and produce
a structured FinOps report covering:

  1. Month-to-date spend by service
  2. Cost trend (last 6 months)
  3. Untagged resource cost breakdown
  4. Forecasted spend vs. budget
  5. Top 5 most expensive resources / services

Prerequisites:
  - IAM permissions: ce:GetCostAndUsage, ce:GetCostForecast, ce:GetTags
  - Cost Explorer must be enabled in the account (first-time activation can
    take up to 24 hours before data appears)

Usage:
    python generate_cost_report.py
    python generate_cost_report.py --budget 50 --output report.json
    python generate_cost_report.py --months 3
"""

import argparse
import json
import sys
from datetime import datetime, date, timedelta
from calendar import monthrange

import boto3
from botocore.exceptions import ClientError, NoCredentialsError
from tabulate import tabulate
from colorama import Fore, Style, init as colorama_init

colorama_init(autoreset=True)



def fmt_usd(amount: float) -> str:
    return f"${amount:,.2f}"


def month_start(offset: int = 0) -> str:
    """Return YYYY-MM-DD for the first day of a month (0 = this month, -1 = last month, ...)."""
    today = date.today()
    m = today.month - offset
    y = today.year
    while m <= 0:
        m += 12
        y -= 1
    return date(y, m, 1).isoformat()


def month_end(offset: int = 0) -> str:
    """Return YYYY-MM-DD for the last day of a month."""
    start = date.fromisoformat(month_start(offset))
    last_day = monthrange(start.year, start.month)[1]
    return date(start.year, start.month, last_day).isoformat()


def today_iso() -> str:
    return date.today().isoformat()


def first_day_of_this_month() -> str:
    d = date.today()
    return date(d.year, d.month, 1).isoformat()


def section(title: str) -> None:
    bar = "-" * (len(title) + 4)
    print(f"\n{Style.BRIGHT}{Fore.CYAN}{bar}")
    print(f"  {title}")
    print(f"{bar}{Style.RESET_ALL}")



def get_mtd_by_service(ce_client) -> list[dict]:
    """Month-to-date spend grouped by AWS service, descending."""
    try:
        response = ce_client.get_cost_and_usage(
            TimePeriod={"Start": first_day_of_this_month(), "End": today_iso()},
            Granularity="MONTHLY",
            Metrics=["UnblendedCost"],
            GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
        )
    except ClientError as exc:
        print(f"{Fore.YELLOW}  [WARN] MTD query failed: {exc.response['Error']['Message']}")
        return []

    results = []
    for group in response["ResultsByTime"][0].get("Groups", []):
        service = group["Keys"][0]
        amount  = float(group["Metrics"]["UnblendedCost"]["Amount"])
        if amount >= 0.01:  # skip sub-cent noise
            results.append({"service": service, "mtd_usd": round(amount, 4)})

    return sorted(results, key=lambda x: x["mtd_usd"], reverse=True)


def get_monthly_trend(ce_client, months: int = 6) -> list[dict]:
    """Total spend for each of the last N complete months."""
    start = month_start(months)
    end   = month_start(0)  # beginning of current month (exclusive)

    try:
        response = ce_client.get_cost_and_usage(
            TimePeriod={"Start": start, "End": end},
            Granularity="MONTHLY",
            Metrics=["UnblendedCost"],
        )
    except ClientError as exc:
        print(f"{Fore.YELLOW}  [WARN] Trend query failed: {exc.response['Error']['Message']}")
        return []

    results = []
    for period in response["ResultsByTime"]:
        total = float(period["Total"]["UnblendedCost"]["Amount"])
        results.append({
            "month": period["TimePeriod"]["Start"][:7],  # YYYY-MM
            "total_usd": round(total, 2),
        })
    return results


def get_untagged_cost(ce_client, tag_key: str = "CostCenter") -> dict:
    """Spend attributed to resources that lack the given tag key."""
    try:
        response = ce_client.get_cost_and_usage(
            TimePeriod={"Start": first_day_of_this_month(), "End": today_iso()},
            Granularity="MONTHLY",
            Metrics=["UnblendedCost"],
            Filter={
                "Tags": {
                    "Key":          tag_key,
                    "MatchOptions": ["ABSENT"],
                }
            },
        )
        amount = float(
            response["ResultsByTime"][0]["Total"]["UnblendedCost"]["Amount"]
        )
        return {"tag_key": tag_key, "untagged_usd": round(amount, 2)}
    except ClientError as exc:
        print(f"{Fore.YELLOW}  [WARN] Untagged cost query failed: {exc.response['Error']['Message']}")
        return {"tag_key": tag_key, "untagged_usd": 0.0}


def get_forecast(ce_client, budget: float) -> dict:
    """Forecasted end-of-month spend for the current month."""
    today = date.today()
    last  = date(today.year, today.month, monthrange(today.year, today.month)[1])

    if today >= last:
        return {"forecast_usd": 0.0, "budget_usd": budget, "over_budget": False}

    try:
        response = ce_client.get_cost_forecast(
            TimePeriod={"Start": today_iso(), "End": last.isoformat()},
            Metric="UNBLENDED_COST",
            Granularity="MONTHLY",
        )
        forecast = float(response["Total"]["Amount"])
    except ClientError as exc:
        print(f"{Fore.YELLOW}  [WARN] Forecast query failed: {exc.response['Error']['Message']}")
        forecast = 0.0

    return {
        "forecast_usd": round(forecast, 2),
        "budget_usd":   budget,
        "over_budget":  forecast > budget,
    }



def render_mtd(services: list[dict]) -> None:
    section("Month-to-Date Spend by Service (Top 10)")
    if not services:
        print("  No data available.")
        return

    rows = []
    running_total = 0.0
    grand_total   = sum(s["mtd_usd"] for s in services)

    for svc in services[:10]:
        pct = (svc["mtd_usd"] / grand_total * 100) if grand_total else 0
        running_total += svc["mtd_usd"]
        rows.append([
            svc["service"],
            fmt_usd(svc["mtd_usd"]),
            f"{pct:.1f}%",
            fmt_usd(running_total),
        ])

    print(tabulate(rows,
                   headers=["Service", "MTD Cost", "% of Total", "Running Total"],
                   tablefmt="rounded_outline"))
    print(f"\n  {Style.BRIGHT}Grand Total MTD: {Fore.YELLOW}{fmt_usd(grand_total)}")


def render_trend(trend: list[dict]) -> None:
    section("Monthly Spend Trend (Last 6 Complete Months)")
    if not trend:
        print("  No data available.")
        return

    max_val = max(t["total_usd"] for t in trend) or 1
    rows = []
    for t in trend:
        bar_len = int(t["total_usd"] / max_val * 30)
        bar = "#" * bar_len
        rows.append([t["month"], fmt_usd(t["total_usd"]), bar])

    print(tabulate(rows, headers=["Month", "Total", "Relative Spend"], tablefmt="rounded_outline"))

    if len(trend) >= 2:
        delta = trend[-1]["total_usd"] - trend[-2]["total_usd"]
        color = Fore.RED if delta > 0 else Fore.GREEN
        sign  = "+" if delta >= 0 else ""
        print(f"\n  MoM change (last 2 months): {color}{sign}{fmt_usd(delta)}")


def render_untagged(data: dict, grand_total_mtd: float) -> None:
    section(f"Untagged Cost (missing '{data['tag_key']}' tag)")
    amount = data["untagged_usd"]
    pct    = (amount / grand_total_mtd * 100) if grand_total_mtd else 0
    color  = Fore.RED if pct > 20 else (Fore.YELLOW if pct > 5 else Fore.GREEN)

    print(f"  Untagged MTD cost : {color}{fmt_usd(amount)}{Style.RESET_ALL}")
    print(f"  As % of total     : {color}{pct:.1f}%{Style.RESET_ALL}")

    if pct > 20:
        print(f"\n  {Fore.RED}ACTION REQUIRED: >20% of spend is untagged.")
        print(f"  Run find_zombie_assets.py to locate missing-tag resources.")


def render_forecast(data: dict) -> None:
    section("End-of-Month Forecast vs. Budget")

    color = Fore.RED if data["over_budget"] else Fore.GREEN
    status = "OVER BUDGET" if data["over_budget"] else "within budget"

    print(f"  Budget limit    : {fmt_usd(data['budget_usd'])}")
    print(f"  Forecasted spend: {color}{fmt_usd(data['forecast_usd'])}{Style.RESET_ALL}")
    print(f"  Status          : {color}{Style.BRIGHT}{status}{Style.RESET_ALL}")

    if data["over_budget"]:
        overage = data["forecast_usd"] - data["budget_usd"]
        print(f"  Forecasted overage: {Fore.RED}{fmt_usd(overage)}")
        print(f"\n  {Fore.RED}ALERT: Review cost drivers above and consider rightsizing or shutdown of idle resources.")



def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate FinOps cost report from AWS Cost Explorer",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--region",  default="us-east-1", help="AWS region (default: us-east-1)")
    parser.add_argument("--profile", default=None)
    parser.add_argument("--budget",  type=float, default=50.0,
                        help="Monthly budget ceiling in USD (default: 50)")
    parser.add_argument("--months",  type=int, default=6,
                        help="Number of historical months for trend (default: 6)")
    parser.add_argument("--tag-key", default="CostCenter",
                        help="Tag key used for untagged cost analysis (default: CostCenter)")
    parser.add_argument("--output",  default=None, metavar="FILE",
                        help="Write JSON report to FILE")
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    try:
        session = boto3.Session(region_name=args.region, profile_name=args.profile)
        # Cost Explorer is always us-east-1 regardless of resource region
        ce = session.client("ce", region_name="us-east-1")
    except NoCredentialsError:
        print(f"{Fore.RED}ERROR: No AWS credentials configured.")
        sys.exit(1)

    print(f"\n{Style.BRIGHT}{'=' * 60}")
    print(f"  AWS FINOPS COST REPORT")
    print(f"  Generated: {datetime.utcnow().strftime('%Y-%m-%d %H:%M UTC')}")
    print(f"  Budget: {fmt_usd(args.budget)}/month")
    print(f"{'=' * 60}{Style.RESET_ALL}")

    services = get_mtd_by_service(ce)
    trend    = get_monthly_trend(ce, args.months)
    untagged = get_untagged_cost(ce, args.tag_key)
    forecast = get_forecast(ce, args.budget)

    grand_total_mtd = sum(s["mtd_usd"] for s in services)

    render_mtd(services)
    render_trend(trend)
    render_untagged(untagged, grand_total_mtd)
    render_forecast(forecast)

    print(f"\n{'=' * 60}\n")

    if args.output:
        report = {
            "generated_at":    datetime.utcnow().isoformat(),
            "budget_usd":      args.budget,
            "mtd_by_service":  services,
            "monthly_trend":   trend,
            "untagged_cost":   untagged,
            "forecast":        forecast,
        }
        with open(args.output, "w") as fh:
            json.dump(report, fh, indent=2)
        print(f"  Report saved to {args.output}\n")


if __name__ == "__main__":
    main()
