#!/usr/bin/env bash
#
# gc_ebs_volumes.sh - Garbage-collect unattached EBS volumes. (bash + AWS CLI + jq)
#
# Usage:
#     # Dry run (default)  -  lists volumes, deletes nothing
#     ./gc_ebs_volumes.sh
#
#     # Confirm deletion interactively
#     ./gc_ebs_volumes.sh --delete
#
#     # Delete all without prompting (use in CI after review)
#     ./gc_ebs_volumes.sh --delete --yes
#
#     # Target a specific region
#     ./gc_ebs_volumes.sh --region eu-west-1
#
#     # Skip volumes newer than N days
#     ./gc_ebs_volumes.sh --delete --min-age-days 30
#
#     # Skip volumes with a specific tag
#     ./gc_ebs_volumes.sh --delete --exclude-tag DoNotDelete=true
#
# Requires: aws (CLI v2), jq
#
set -uo pipefail

REGION=""
PROFILE=""
DELETE=0
YES=0
MIN_AGE_DAYS=0
EXCLUDE_TAG=""

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region)       REGION="$2"; shift 2 ;;
        --profile)      PROFILE="$2"; shift 2 ;;
        --delete)       DELETE=1; shift ;;
        --yes|-y)       YES=1; shift ;;
        --min-age-days) MIN_AGE_DAYS="$2"; shift 2 ;;
        --exclude-tag)  EXCLUDE_TAG="$2"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
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

if [[ -t 1 ]]; then
    C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'; C_BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BOLD=""; RESET=""
fi

DISPLAY_REGION="$REGION"
[[ -z "$DISPLAY_REGION" ]] && DISPLAY_REGION=$(aws configure get region ${PROFILE:+--profile "$PROFILE"} 2>/dev/null || true)
[[ -z "$DISPLAY_REGION" ]] && DISPLAY_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

# Parse optional exclude tag KEY=VALUE
EXCL_KEY=""; EXCL_VAL=""
if [[ -n "$EXCLUDE_TAG" ]]; then
    EXCL_KEY="${EXCLUDE_TAG%%=*}"
    [[ "$EXCLUDE_TAG" == *=* ]] && EXCL_VAL="${EXCLUDE_TAG#*=}"
fi

JQ_LIB='
def tagval(tags; k): ((tags // []) | map({key:.Key, value:.Value}) | from_entries)[k] // "-";
def agedays(t): ((now - (t | sub("\\.[0-9]+";"") | sub("\\+00:00$";"Z") | fromdateiso8601)) / 86400 | floor);
def ebs_rate(vt): {"gp3":0.080,"gp2":0.100,"io1":0.125,"io2":0.125,"st1":0.045,"sc1":0.025}[vt] // 0.080;
def round2(x): (x * 100 | round) / 100;
def ebs_cost(size; vt): round2(ebs_rate(vt) * size);
def usd(x): (x * 100 | round) as $c | "$\($c/100|floor)." + (("00" + ($c % 100 | tostring)) | .[-2:]);
'

# Return matching unattached volumes as a compact JSON array
find_unattached_volumes() {
    aws_ec2 describe-volumes --filters Name=status,Values=available --output json \
    | jq -c "$JQ_LIB" --argjson minage "$MIN_AGE_DAYS" --arg ekey "$EXCL_KEY" --arg eval "$EXCL_VAL" '
        [ .Volumes[] | . as $v | (agedays(.CreateTime)) as $age
          | select($age >= $minage)
          | select( $ekey == "" or ( (tagval(.Tags; $ekey)) as $tv
                | if $eval != "" then ($tv != $eval) else ($tv == "-") end ) )
          | { id:.VolumeId, size:.Size, vtype:.VolumeType, az:.AvailabilityZone,
              age:$age, cost_center: tagval(.Tags;"CostCenter"),
              cost: ebs_cost(.Size; .VolumeType),
              created: (.CreateTime[0:10]) } ]'
}

printf '\n%s=== EBS Garbage Collector  |  region: %s ===%s\n\n' "$C_BOLD" "$DISPLAY_REGION" "$RESET"
[[ "$MIN_AGE_DAYS" -gt 0 ]] && printf '  Filter: volumes older than %s days\n' "$MIN_AGE_DAYS"
[[ -n "$EXCL_KEY" ]] && printf '  Filter: excluding tag %s=%s\n' "$EXCL_KEY" "${EXCL_VAL:-(any value)}"
[[ "$DELETE" -eq 0 ]] && printf '  %sDRY RUN  -  pass --delete to actually remove volumes%s\n' "$C_CYAN" "$RESET"

echo
echo "Scanning for unattached EBS volumes ..."
VOLS=$(find_unattached_volumes)
COUNT=$(jq 'length' <<<"$VOLS")

if [[ "$COUNT" -eq 0 ]]; then
    printf '%sNo unattached volumes found. Nothing to clean up.%s\n' "$C_GREEN" "$RESET"
    exit 0
fi

TOTAL_COST=$(jq '[.[].cost] | add // 0' <<<"$VOLS")

printf '\nFound %s%s%s unattached volume(s):\n\n' "$C_YELLOW" "$COUNT" "$RESET"
{
    printf 'Volume-ID\tSize(GB)\tType\tAZ\tAge(days)\tCostCenter\tEst.$/month\tCreated\n'
    jq -r "$JQ_LIB"'.[] | [ .id, (.size|tostring), .vtype, .az, (.age|tostring),
                            .cost_center, usd(.cost), .created ] | @tsv' <<<"$VOLS"
} | column -t -s $'\t'
printf '\n  %sTotal estimated monthly waste: %s$%s%s\n' "$C_BOLD" "$C_RED" \
    "$(awk -v c="$TOTAL_COST" 'BEGIN{printf "%.2f", c}')" "$RESET"

if [[ "$DELETE" -eq 0 ]]; then
    printf '\n  Run with %s--delete%s to remove these volumes.\n' "$C_BOLD" "$RESET"
    exit 0
fi

# Bulk confirmation unless --yes
if [[ "$YES" -eq 0 ]]; then
    printf '\n%sWARNING: This will permanently delete %s volume(s). Data cannot be recovered.%s\n' \
        "$C_YELLOW" "$COUNT" "$RESET"
    read -r -p "  Proceed? [y/N]: " confirm </dev/tty
    if [[ "${confirm,,}" != "y" ]]; then echo "Aborted."; exit 0; fi
fi

echo
echo "Deleting volumes ..."
DELETED=0; FAILED=0; SAVED=0

while IFS=$'\t' read -r vid size vtype cost; do
    [[ -z "$vid" ]] && continue
    if [[ "$YES" -eq 0 ]]; then
        read -r -p "$(printf '\n  Delete %s (%s GB %s, $%s/month)? [y/N]: ' "$vid" "$size" "$vtype" "$cost")" ans </dev/tty
        if [[ "${ans,,}" != "y" ]]; then
            printf '  %sSkipped %s%s\n' "$C_YELLOW" "$vid" "$RESET"
            continue
        fi
    fi
    if aws_ec2 delete-volume --volume-id "$vid" 2>/tmp/gc_err; then
        printf '  %sDeleted  %s  (saved $%s/month)%s\n' "$C_GREEN" "$vid" "$cost" "$RESET"
        DELETED=$(( DELETED + 1 ))
        SAVED=$(awk -v a="$SAVED" -v b="$cost" 'BEGIN{printf "%.2f", a+b}')
    else
        printf '  %sFAILED   %s  %s%s\n' "$C_RED" "$vid" "$(cat /tmp/gc_err)" "$RESET"
        FAILED=$(( FAILED + 1 ))
    fi
done < <(jq -r '.[] | [ .id, (.size|tostring), .vtype, (.cost*100|round/100|tostring) ] | @tsv' <<<"$VOLS")

ANNUAL=$(awk -v s="$SAVED" 'BEGIN{printf "%.2f", s*12}')
printf '\n%s\n' "$(printf -- '-%.0s' {1..50})"
printf '  Deleted : %s%s%s\n' "$C_GREEN" "$DELETED" "$RESET"
printf '  Failed  : %s%s%s\n' "$C_RED" "$FAILED" "$RESET"
printf '  Monthly savings: %s$%s%s\n' "$C_GREEN" "$SAVED" "$RESET"
printf '  Annual  savings: %s$%s%s\n' "$C_GREEN" "$ANNUAL" "$RESET"
printf '%s\n\n' "$(printf -- '-%.0s' {1..50})"
