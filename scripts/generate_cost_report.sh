#!/usr/bin/env bash
#
# generate_cost_report.sh - Pull cost data from AWS Cost Explorer and produce
# a structured FinOps report covering: (bash + AWS CLI + jq)
#
#   1. Month-to-date spend by service
#   2. Cost trend (last 6 months)
#   3. Untagged resource cost breakdown
#   4. Forecasted spend vs. budget
#
# Prerequisites:
#   - IAM permissions: ce:GetCostAndUsage, ce:GetCostForecast, ce:GetTags
#   - Cost Explorer must be enabled in the account (first-time activation can
#     take up to 24 hours before data appears)
#   - aws (CLI v2), jq
#
# Usage:
#     ./generate_cost_report.sh
#     ./generate_cost_report.sh --budget 50 --output report.json
#     ./generate_cost_report.sh --months 3
#
set -uo pipefail

PROFILE=""
BUDGET=50
MONTHS=6
TAG_KEY="CostCenter"
OUTPUT=""

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region)   shift 2 ;;              # accepted for compatibility; CE is us-east-1
        --profile)  PROFILE="$2"; shift 2 ;;
        --budget)   BUDGET="$2"; shift 2 ;;
        --months)   MONTHS="$2"; shift 2 ;;
        --tag-key)  TAG_KEY="$2"; shift 2 ;;
        --output)   OUTPUT="$2"; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

ensure_deps() {
    if ! command -v aws >/dev/null 2>&1; then
        echo "ERROR: aws CLI v2 is required but not installed." >&2
        echo "       Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" >&2
        exit 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "jq not found - attempting to install it ..." >&2
        if   command -v brew    >/dev/null 2>&1; then brew install jq
        elif command -v apt-get >/dev/null 2>&1; then sudo apt-get update -y && sudo apt-get install -y jq
        elif command -v dnf     >/dev/null 2>&1; then sudo dnf install -y jq
        elif command -v yum     >/dev/null 2>&1; then sudo yum install -y jq
        elif command -v apk     >/dev/null 2>&1; then sudo apk add --no-cache jq
        elif command -v pacman  >/dev/null 2>&1; then sudo pacman -Sy --noconfirm jq
        else
            echo "ERROR: no supported package manager found. Please install jq manually: https://jqlang.github.io/jq/download/" >&2
            exit 1
        fi
        command -v jq >/dev/null 2>&1 || { echo "ERROR: jq installation failed." >&2; exit 1; }
    fi
}
ensure_deps

# Cost Explorer is always us-east-1 regardless of resource region
CE_ARGS=(--region us-east-1)
[[ -n "$PROFILE" ]] && CE_ARGS+=(--profile "$PROFILE")
aws_ce() { aws ce "${CE_ARGS[@]}" "$@"; }

if [[ -t 1 ]]; then
    C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'; C_BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BOLD=""; RESET=""
fi

# --- Date helpers (portable GNU / BSD) --------------------------------------
HAS_GNU_DATE=0
date -u -d "2020-01-01 -1 month" +%s >/dev/null 2>&1 && HAS_GNU_DATE=1

# First day of the month `offset` months in the past (offset 0 = this month)
month_first() {
    local off="$1"
    if [[ "$HAS_GNU_DATE" -eq 1 ]]; then
        date -u -d "$(date -u +%Y-%m-01) -${off} months" +%Y-%m-01
    else
        date -u -v1d -v-"${off}"m +%Y-%m-01
    fi
}
# Last day of the current month
month_last() {
    if [[ "$HAS_GNU_DATE" -eq 1 ]]; then
        date -u -d "$(date -u -d "$(date -u +%Y-%m-01) +1 month" +%Y-%m-01) -1 day" +%Y-%m-%d
    else
        date -u -v1d -v+1m -v-1d +%Y-%m-%d
    fi
}

TODAY=$(date -u +%Y-%m-%d)
FIRST=$(month_first 0)
LAST=$(month_last)

fmt_usd() { awk -v x="$1" 'BEGIN{printf "$%.2f", x}'; }

section() {
    local title="$1" bar
    bar=$(printf '%*s' $(( ${#title} + 4 )) '' | tr ' ' '-')
    printf '\n%s%s%s\n  %s\n%s%s\n' "$C_BOLD$C_CYAN" "$bar" "$RESET" "$title" "$C_CYAN$bar" "$RESET"
}

# --- Data pulls -------------------------------------------------------------

get_mtd_by_service() {
    aws_ce get-cost-and-usage \
        --time-period Start="$FIRST",End="$TODAY" \
        --granularity MONTHLY --metrics UnblendedCost \
        --group-by Type=DIMENSION,Key=SERVICE --output json 2>/dev/null \
    | jq -c '
        [ .ResultsByTime[0].Groups[]
          | {service:.Keys[0], mtd_usd:(.Metrics.UnblendedCost.Amount|tonumber|(.*10000|round)/10000)}
          | select(.mtd_usd >= 0.01) ] | sort_by(.mtd_usd) | reverse' 2>/dev/null || echo '[]'
}

get_monthly_trend() {
    local start end
    start=$(month_first "$MONTHS")
    end=$(month_first 0)
    aws_ce get-cost-and-usage \
        --time-period Start="$start",End="$end" \
        --granularity MONTHLY --metrics UnblendedCost --output json 2>/dev/null \
    | jq -c '
        [ .ResultsByTime[]
          | {month:(.TimePeriod.Start[0:7]),
             total_usd:(.Total.UnblendedCost.Amount|tonumber|(.*100|round)/100)} ]' 2>/dev/null || echo '[]'
}

get_untagged_cost() {
    aws_ce get-cost-and-usage \
        --time-period Start="$FIRST",End="$TODAY" \
        --granularity MONTHLY --metrics UnblendedCost \
        --filter "{\"Tags\":{\"Key\":\"$TAG_KEY\",\"MatchOptions\":[\"ABSENT\"]}}" \
        --output json 2>/dev/null \
    | jq -c --arg k "$TAG_KEY" '
        {tag_key:$k,
         untagged_usd:(.ResultsByTime[0].Total.UnblendedCost.Amount|tonumber|(.*100|round)/100)}' \
      2>/dev/null || echo "{\"tag_key\":\"$TAG_KEY\",\"untagged_usd\":0}"
}

get_forecast() {
    # If we are already at/after month end, there is nothing to forecast
    if [[ "$TODAY" > "$LAST" || "$TODAY" == "$LAST" ]]; then
        jq -nc --argjson b "$BUDGET" '{forecast_usd:0, budget_usd:$b, over_budget:false}'
        return
    fi
    local fc
    fc=$(aws_ce get-cost-forecast \
            --time-period Start="$TODAY",End="$LAST" \
            --metric UNBLENDED_COST --granularity MONTHLY \
            --query 'Total.Amount' --output text 2>/dev/null || echo 0)
    [[ -z "$fc" || "$fc" == "None" ]] && fc=0
    jq -nc --argjson f "$fc" --argjson b "$BUDGET" '
        {forecast_usd:(($f*100|round)/100), budget_usd:$b, over_budget:($f > $b)}'
}

# --- Renderers --------------------------------------------------------------

render_mtd() {
    local services="$1" grand
    section "Month-to-Date Spend by Service (Top 10)"
    if [[ "$(jq 'length' <<<"$services")" -eq 0 ]]; then echo "  No data available."; return; fi
    grand=$(jq '[.[].mtd_usd] | add // 0' <<<"$services")
    {
        printf 'Service\tMTD-Cost\t%%-of-Total\tRunning-Total\n'
        jq -r --argjson g "$grand" '
            . as $all | [range(0; ([10,length]|min))] | map($all[.])
            | reduce .[] as $s ({run:0, rows:[]};
                .run += $s.mtd_usd
                | .rows += [[ $s.service,
                              ("$"+($s.mtd_usd*100|round/100|tostring)),
                              (($s.mtd_usd/(if $g>0 then $g else 1 end)*1000|round/10|tostring)+"%"),
                              ("$"+(.run*100|round/100|tostring)) ]])
            | .rows[] | @tsv' <<<"$services"
    } | column -t -s $'\t'
    printf '\n  %sGrand Total MTD: %s%s%s\n' "$C_BOLD" "$C_YELLOW" "$(fmt_usd "$grand")" "$RESET"
}

render_trend() {
    local trend="$1" maxv n
    section "Monthly Spend Trend (Last $MONTHS Complete Months)"
    n=$(jq 'length' <<<"$trend")
    if [[ "$n" -eq 0 ]]; then echo "  No data available."; return; fi
    maxv=$(jq '([.[].total_usd] | max) as $m | if $m>0 then $m else 1 end' <<<"$trend")
    {
        printf 'Month\tTotal\tRelative-Spend\n'
        jq -r --argjson max "$maxv" '
            .[] | [ .month, ("$"+(.total_usd*100|round/100|tostring)),
                    ( (.total_usd/$max*30 | floor) as $l | ("#" * (if $l>0 then $l else 0 end)) ) ] | @tsv' <<<"$trend"
    } | column -t -s $'\t'
    if [[ "$n" -ge 2 ]]; then
        local delta color sign
        delta=$(jq '(.[-1].total_usd - .[-2].total_usd)' <<<"$trend")
        if awk "BEGIN{exit !($delta > 0)}"; then color="$C_RED"; sign="+"; else color="$C_GREEN"; sign=""; fi
        printf '\n  MoM change (last 2 months): %s%s%s%s\n' "$color" "$sign" "$(fmt_usd "$delta")" "$RESET"
    fi
}

render_untagged() {
    local data="$1" grand="$2" amount pct color
    section "Untagged Cost (missing '$TAG_KEY' tag)"
    amount=$(jq '.untagged_usd' <<<"$data")
    pct=$(awk -v a="$amount" -v g="$grand" 'BEGIN{ if(g>0) printf "%.1f", a/g*100; else print "0.0" }')
    if awk "BEGIN{exit !($pct > 20)}"; then color="$C_RED"
    elif awk "BEGIN{exit !($pct > 5)}"; then color="$C_YELLOW"
    else color="$C_GREEN"; fi
    printf '  Untagged MTD cost : %s%s%s\n' "$color" "$(fmt_usd "$amount")" "$RESET"
    printf '  As %% of total     : %s%s%%%s\n' "$color" "$pct" "$RESET"
    if awk "BEGIN{exit !($pct > 20)}"; then
        printf '\n  %sACTION REQUIRED: >20%% of spend is untagged.%s\n' "$C_RED" "$RESET"
        printf '  Run find_zombie_assets.sh to locate missing-tag resources.\n'
    fi
}

render_forecast() {
    local data="$1" over fc bud color status overage
    section "End-of-Month Forecast vs. Budget"
    over=$(jq -r '.over_budget' <<<"$data")
    fc=$(jq '.forecast_usd' <<<"$data")
    bud=$(jq '.budget_usd' <<<"$data")
    if [[ "$over" == "true" ]]; then color="$C_RED"; status="OVER BUDGET"; else color="$C_GREEN"; status="within budget"; fi
    printf '  Budget limit    : %s\n' "$(fmt_usd "$bud")"
    printf '  Forecasted spend: %s%s%s\n' "$color" "$(fmt_usd "$fc")" "$RESET"
    printf '  Status          : %s%s%s%s\n' "$color" "$C_BOLD" "$status" "$RESET"
    if [[ "$over" == "true" ]]; then
        overage=$(awk -v f="$fc" -v b="$bud" 'BEGIN{printf "%.2f", f-b}')
        printf '  Forecasted overage: %s%s%s\n' "$C_RED" "$(fmt_usd "$overage")" "$RESET"
        printf '\n  %sALERT: Review cost drivers above and consider rightsizing or shutdown of idle resources.%s\n' "$C_RED" "$RESET"
    fi
}

# --- Main -------------------------------------------------------------------

printf '\n%s%s\n' "$C_BOLD" "$(printf '=%.0s' {1..60})"
printf '  AWS FINOPS COST REPORT\n'
printf '  Generated: %s\n' "$(date -u +'%Y-%m-%d %H:%M UTC')"
printf '  Budget: %s/month\n' "$(fmt_usd "$BUDGET")"
printf '%s%s\n' "$(printf '=%.0s' {1..60})" "$RESET"

SERVICES=$(get_mtd_by_service)
TREND=$(get_monthly_trend)
UNTAGGED=$(get_untagged_cost)
FORECAST=$(get_forecast)

GRAND_TOTAL_MTD=$(jq '[.[].mtd_usd] | add // 0' <<<"$SERVICES")

render_mtd "$SERVICES"
render_trend "$TREND"
render_untagged "$UNTAGGED" "$GRAND_TOTAL_MTD"
render_forecast "$FORECAST"

printf '\n%s\n\n' "$(printf '=%.0s' {1..60})"

if [[ -n "$OUTPUT" ]]; then
    jq -n \
        --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson budget "$BUDGET" \
        --argjson mtd "$SERVICES" \
        --argjson trend "$TREND" \
        --argjson untagged "$UNTAGGED" \
        --argjson forecast "$FORECAST" '
        {generated_at:$gen, budget_usd:$budget, mtd_by_service:$mtd,
         monthly_trend:$trend, untagged_cost:$untagged, forecast:$forecast}' \
        > "$OUTPUT"
    printf '  Report saved to %s\n\n' "$OUTPUT"
fi
