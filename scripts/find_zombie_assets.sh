#!/usr/bin/env bash
#
# find_zombie_assets.sh - Scan an AWS account for zombie / wasteful resources
# that incur cost without delivering value. (bash + AWS CLI + jq)
#
# Detects:
#   1. Unattached EBS volumes
#   2. Unassociated Elastic IPs
#   3. Idle EC2 instances (< 5% average CPU over 7 days)
#   4. Stopped EC2 instances (still paying for attached EBS)
#   5. Unused Elastic Network Interfaces
#   6. Old EBS snapshots (older than 90 days, no Name tag)
#   7. EC2 instances missing required cost tags
#
# Usage:
#     ./find_zombie_assets.sh
#     ./find_zombie_assets.sh --region us-west-2
#     ./find_zombie_assets.sh --output-json findings.json
#     ./find_zombie_assets.sh --cpu-threshold 5 --idle-days 14
#
# Requires: aws (CLI v2), jq
#
set -uo pipefail

REGION=""
PROFILE=""
CPU_THRESHOLD=5
IDLE_DAYS=7
SNAPSHOT_AGE=90
OUTPUT_JSON=""

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region)         REGION="$2"; shift 2 ;;
        --profile)        PROFILE="$2"; shift 2 ;;
        --cpu-threshold)  CPU_THRESHOLD="$2"; shift 2 ;;
        --idle-days)      IDLE_DAYS="$2"; shift 2 ;;
        --snapshot-age)   SNAPSHOT_AGE="$2"; shift 2 ;;
        --output-json)    OUTPUT_JSON="$2"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
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

AWS_ARGS=()
[[ -n "$REGION"  ]] && AWS_ARGS+=(--region "$REGION")
[[ -n "$PROFILE" ]] && AWS_ARGS+=(--profile "$PROFILE")
aws_ec2() { aws ec2 "${AWS_ARGS[@]}" "$@"; }
aws_cw()  { aws cloudwatch "${AWS_ARGS[@]}" "$@"; }

# Colors (only when stdout is a TTY)
if [[ -t 1 ]]; then
    C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'; C_BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BOLD=""; RESET=""
fi

# Resolve region for display
DISPLAY_REGION="$REGION"
[[ -z "$DISPLAY_REGION" ]] && DISPLAY_REGION=$(aws configure get region ${PROFILE:+--profile "$PROFILE"} 2>/dev/null || true)
[[ -z "$DISPLAY_REGION" ]] && DISPLAY_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

# Shared jq helpers
JQ_LIB='
def tagval(tags; k): ((tags // []) | map({key:.Key, value:.Value}) | from_entries)[k] // "-";
def agedays(t): if t == null then -1
    else ((now - (t | sub("\\.[0-9]+";"") | sub("\\+00:00$";"Z") | fromdateiso8601)) / 86400 | floor) end;
def ebs_rate(vt): {"gp3":0.080,"gp2":0.100,"io1":0.125,"io2":0.125,"st1":0.045,"sc1":0.025}[vt] // 0.080;
def round2(x): (x * 100 | round) / 100;
def ebs_cost(size; vt): round2(ebs_rate(vt) * size);
def usd(x): (x * 100 | round) as $c | "$\($c/100|floor)." + (("00" + ($c % 100 | tostring)) | .[-2:]);
'

TOTAL_MONTHLY="0"
TOTAL_FINDINGS=0
declare -A FTYPE_JSON

section() {
    local title="$1" bar
    bar=$(printf '%*s' $(( ${#title} + 4 )) '' | tr ' ' '-')
    printf '\n%s%s%s\n  %s\n%s%s\n' "$C_BOLD$C_CYAN" "$bar" "$RESET" "$title" "$C_CYAN$bar" "$RESET"
}

# process KEY LABEL JSON_ARRAY
process() {
    local key="$1" label="$2" json="$3" count cost
    count=$(jq 'length' <<<"$json")
    section "$label  ($count found)"
    if [[ "$count" -eq 0 ]]; then
        printf '  %sNone  -  clean!%s\n' "$C_GREEN" "$RESET"
    else
        {
            printf 'Resource-ID\tDetail\tAge(days)\t$/month\tCostCenter\tOwner\n'
            jq -r "$JQ_LIB"'
                .[] | [ .id, (.detail[0:70]),
                        (if .age_days >= 0 then (.age_days|tostring) else "n/a" end),
                        usd(.monthly_cost_usd), .cost_center, .owner ] | @tsv' <<<"$json"
        } | column -t -s $'\t'
    fi
    cost=$(jq '[.[].monthly_cost_usd] | add // 0' <<<"$json")
    TOTAL_MONTHLY=$(awk -v a="$TOTAL_MONTHLY" -v b="$cost" 'BEGIN{printf "%.2f", a+b}')
    TOTAL_FINDINGS=$(( TOTAL_FINDINGS + count ))
    FTYPE_JSON["$key"]="$json"
}

# ---- Scans -----------------------------------------------------------------

scan_unattached_ebs() {
    aws_ec2 describe-volumes --filters Name=status,Values=available --output json \
    | jq -c "$JQ_LIB"'
        [ .Volumes[] | {
            type:"UNATTACHED_EBS", id:.VolumeId,
            detail:"\(.Size) GB \(.VolumeType) in \(.AvailabilityZone)",
            age_days: agedays(.CreateTime),
            monthly_cost_usd: ebs_cost(.Size; .VolumeType),
            cost_center: tagval(.Tags;"CostCenter"), owner: tagval(.Tags;"Owner")
        } ]'
}

scan_unassociated_eips() {
    aws_ec2 describe-addresses --output json \
    | jq -c "$JQ_LIB"'
        [ .Addresses[] | select((has("InstanceId")|not) and (has("NetworkInterfaceId")|not)) | {
            type:"UNASSOCIATED_EIP", id:.AllocationId,
            detail:"Public IP: \(.PublicIp // "N/A")",
            age_days:-1, monthly_cost_usd:3.60,
            cost_center: tagval(.Tags;"CostCenter"), owner: tagval(.Tags;"Owner")
        } ]'
}

scan_idle_instances() {
    local running now_iso start_iso items=() f iid itype launch tags avg
    running=$(aws_ec2 describe-instances \
        --filters Name=instance-state-name,Values=running \
        --query 'Reservations[].Instances[]' --output json)
    now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if date -u -d "-1 day" +%s >/dev/null 2>&1; then
        start_iso=$(date -u -d "-${IDLE_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)
    else
        start_iso=$(date -u -v-"${IDLE_DAYS}"d +%Y-%m-%dT%H:%M:%SZ)
    fi

    while IFS=$'\t' read -r iid itype launch tags; do
        [[ -z "$iid" ]] && continue
        avg=$(aws_cw get-metric-statistics --namespace AWS/EC2 --metric-name CPUUtilization \
            --dimensions Name=InstanceId,Value="$iid" \
            --start-time "$start_iso" --end-time "$now_iso" \
            --period $(( IDLE_DAYS * 86400 )) --statistics Average \
            --query 'Datapoints[0].Average' --output text 2>/dev/null)
        [[ "$avg" == "None" || -z "$avg" ]] && avg=0
        if awk "BEGIN{exit !($avg < $CPU_THRESHOLD)}"; then
            f=$(jq -nc "$JQ_LIB" --arg id "$iid" --arg itype "$itype" --arg launch "$launch" \
                --argjson avg "$avg" --argjson idays "$IDLE_DAYS" --arg tags "$tags" '
                {type:"IDLE_EC2", id:$id,
                 detail:"\($itype) | avg CPU \(($avg*10|round)/10)% over \($idays)d | launched \($launch[0:10])",
                 age_days: agedays($launch), monthly_cost_usd:0, avg_cpu_pct:$avg,
                 cost_center: tagval(($tags|fromjson);"CostCenter"),
                 owner: tagval(($tags|fromjson);"Owner")}')
            items+=("$f")
        fi
    done < <(jq -r '.[] | [.InstanceId, .InstanceType, .LaunchTime, (.Tags // [] | tojson)] | @tsv' <<<"$running")

    if [[ ${#items[@]} -eq 0 ]]; then echo '[]'; else printf '%s\n' "${items[@]}" | jq -sc '.'; fi
}

scan_stopped_instances() {
    local stopped items=() iid itype launch tags volids cost
    stopped=$(aws_ec2 describe-instances \
        --filters Name=instance-state-name,Values=stopped \
        --query 'Reservations[].Instances[]' --output json)

    while IFS=$'\t' read -r iid itype launch tags volids; do
        [[ -z "$iid" ]] && continue
        cost=0
        if [[ -n "$volids" ]]; then
            cost=$(aws_ec2 describe-volumes --volume-ids $volids \
                    --query 'Volumes[].[Size,VolumeType]' --output json 2>/dev/null \
                   | jq "$JQ_LIB"'[.[] | ebs_cost(.[0]; .[1])] | add // 0')
        fi
        items+=("$(jq -nc "$JQ_LIB" --arg id "$iid" --arg itype "$itype" --arg launch "$launch" \
            --arg tags "$tags" --argjson cost "${cost:-0}" '
            {type:"STOPPED_EC2", id:$id,
             detail:"\($itype) | stopped since ~\(agedays($launch))d | EBS cost \(usd($cost))/month",
             age_days: agedays($launch), monthly_cost_usd:$cost,
             cost_center: tagval(($tags|fromjson);"CostCenter"),
             owner: tagval(($tags|fromjson);"Owner")}')")
    done < <(jq -r '.[] | [.InstanceId, .InstanceType, .LaunchTime, (.Tags // [] | tojson),
                           ([.BlockDeviceMappings[]?.Ebs.VolumeId] | join(" "))] | @tsv' <<<"$stopped")

    if [[ ${#items[@]} -eq 0 ]]; then echo '[]'; else printf '%s\n' "${items[@]}" | jq -sc '.'; fi
}

scan_unused_enis() {
    aws_ec2 describe-network-interfaces --filters Name=status,Values=available --output json \
    | jq -c "$JQ_LIB"'
        [ .NetworkInterfaces[] | {
            type:"UNUSED_ENI", id:.NetworkInterfaceId,
            detail:"VPC: \(.VpcId) | Subnet: \(.SubnetId)",
            age_days:-1, monthly_cost_usd:0,
            cost_center: tagval(.TagSet;"CostCenter"), owner: tagval(.TagSet;"Owner")
        } ]'
}

scan_old_snapshots() {
    aws_ec2 describe-snapshots --owner-ids self --output json \
    | jq -c "$JQ_LIB" --argjson maxage "$SNAPSHOT_AGE" '
        [ .Snapshots[] | (agedays(.StartTime)) as $d | select($d >= $maxage) | {
            type:"OLD_SNAPSHOT", id:.SnapshotId,
            detail:"\(.VolumeSize) GB | \($d)d old | Name: \(tagval(.Tags;"Name"))",
            age_days:$d,
            monthly_cost_usd: round2(ebs_rate("gp3") * .VolumeSize * 0.05),
            cost_center: tagval(.Tags;"CostCenter"), owner: tagval(.Tags;"Owner")
        } ]'
}

scan_untagged_instances() {
    aws_ec2 describe-instances \
        --filters Name=instance-state-name,Values=running,stopped \
        --query 'Reservations[].Instances[]' --output json \
    | jq -c "$JQ_LIB"'
        [ .[] | . as $i
          | (["CostCenter","Environment","Project","Owner"] | map(select(tagval($i.Tags; .) == "-"))) as $missing
          | select(($missing|length) > 0) | {
                type:"MISSING_TAGS", id:$i.InstanceId,
                detail:"Missing tags: \($missing|join(", ")) | State: \($i.State.Name)",
                age_days: agedays($i.LaunchTime), monthly_cost_usd:0, missing_tags:$missing,
                cost_center: tagval($i.Tags;"CostCenter"), owner: tagval($i.Tags;"Owner")
        } ]'
}

# ---- Main ------------------------------------------------------------------

printf '\n%s%s\n' "$C_BOLD" "$(printf '=%.0s' {1..60})"
printf '  ZOMBIE ASSET SCANNER  |  region: %s\n' "$DISPLAY_REGION"
printf '  Scan time: %s\n' "$(date -u +'%Y-%m-%d %H:%M UTC')"
printf '%s%s\n' "$(printf '=%.0s' {1..60})" "$RESET"

process UNATTACHED_EBS   "Unattached EBS Volumes"               "$(scan_unattached_ebs)"
process UNASSOCIATED_EIP "Unassociated Elastic IPs"             "$(scan_unassociated_eips)"
process IDLE_EC2         "Idle EC2 Instances"                   "$(scan_idle_instances)"
process STOPPED_EC2      "Stopped EC2 Instances (paying EBS)"   "$(scan_stopped_instances)"
process UNUSED_ENI       "Unused Elastic Network Interfaces"    "$(scan_unused_enis)"
process OLD_SNAPSHOT     "Old EBS Snapshots (>=${SNAPSHOT_AGE} days)" "$(scan_old_snapshots)"
process MISSING_TAGS     "Instances Missing Cost Tags"          "$(scan_untagged_instances)"

TOTAL_ANNUAL=$(awk -v m="$TOTAL_MONTHLY" 'BEGIN{printf "%.2f", m*12}')

printf '\n%s\n' "$(printf '=%.0s' {1..60})"
printf '%s  SUMMARY%s\n' "$C_BOLD" "$RESET"
printf '%s\n' "$(printf '=%.0s' {1..60})"
printf '  Total zombie assets found : %s%s%s\n' "$C_YELLOW" "$TOTAL_FINDINGS" "$RESET"
printf '  Estimated monthly waste   : %s$%s%s\n' "$C_RED" "$TOTAL_MONTHLY" "$RESET"
printf '  Estimated annual waste    : %s$%s%s\n' "$C_RED" "$TOTAL_ANNUAL" "$RESET"
printf '%s\n\n' "$(printf '=%.0s' {1..60})"

if [[ -n "$OUTPUT_JSON" ]]; then
    { for k in "${!FTYPE_JSON[@]}"; do printf '%s\t%s\n' "$k" "${FTYPE_JSON[$k]}"; done; } \
    | jq -Rs 'split("\n") | map(select(length>0) | split("\t") | {key:.[0], value:(.[1]|fromjson)}) | from_entries' \
    > "$OUTPUT_JSON"
    printf '  Findings saved to %s\n' "$OUTPUT_JSON"
fi

# Exit 1 if any findings so CI pipelines can flag the issue
[[ "$TOTAL_FINDINGS" -eq 0 ]] && exit 0 || exit 1
