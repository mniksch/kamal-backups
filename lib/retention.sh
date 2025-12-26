#!/bin/bash
# retention.sh - Backup retention policy implementation
# Implements tiered retention:
#   - Daily: Keep last 7 days
#   - Weekly: Keep every Sunday for 5 weeks
#   - Monthly: Keep first Sunday of each month indefinitely

# Source common utilities if not already loaded
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "${SCRIPT_DIR}/lib/common.sh"
    source "${SCRIPT_DIR}/lib/aws.sh"
fi

# Calculate the epoch timestamp for a date string
# Usage: date_to_epoch "2025-01-15"
date_to_epoch() {
    local date_str="$1"
    date -d "${date_str}" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "${date_str}" +%s 2>/dev/null
}

# Get the day of week for a date (1=Monday, 7=Sunday)
# Usage: get_day_of_week "2025-01-15"
get_day_of_week() {
    local date_str="$1"
    date -d "${date_str}" +%u 2>/dev/null || date -j -f "%Y-%m-%d" "${date_str}" +%u 2>/dev/null
}

# Check if a date is the first Sunday of its month
# Usage: is_first_sunday "2025-01-05"
is_first_sunday() {
    local date_str="$1"
    local day_of_week day_of_month

    day_of_week=$(get_day_of_week "${date_str}")
    day_of_month=$(date -d "${date_str}" +%d 2>/dev/null || date -j -f "%Y-%m-%d" "${date_str}" +%d 2>/dev/null)

    # Sunday (7) and day 1-7 means first Sunday
    [[ "${day_of_week}" == "7" && "${day_of_month}" -le 7 ]]
}

# Check if a date is a Sunday
# Usage: is_sunday "2025-01-05"
is_sunday() {
    local date_str="$1"
    [[ "$(get_day_of_week "${date_str}")" == "7" ]]
}

# Extract date from S3 key
# Input: backups/2025/01/15/site_name.sql.gz
# Output: 2025-01-15
extract_date_from_key() {
    local s3_key="$1"

    # Extract YYYY/MM/DD from the path
    if [[ "${s3_key}" =~ backups/([0-9]{4})/([0-9]{2})/([0-9]{2})/ ]]; then
        echo "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
    else
        echo ""
    fi
}

# Determine if a backup should be kept based on retention policy
# Usage: should_keep_backup "2025-01-15"
# Returns 0 (true) if backup should be kept, 1 (false) if it should be deleted
should_keep_backup() {
    local backup_date="$1"
    local today_epoch backup_epoch days_old

    today_epoch=$(date +%s)
    backup_epoch=$(date_to_epoch "${backup_date}")

    if [[ -z "${backup_epoch}" ]]; then
        log_warn "Could not parse date: ${backup_date}"
        return 0  # Keep if we can't parse (be conservative)
    fi

    days_old=$(( (today_epoch - backup_epoch) / 86400 ))

    # Rule 1: Keep last 7 days
    if [[ ${days_old} -le 7 ]]; then
        return 0
    fi

    # Rule 2: Keep Sundays for 5 weeks (35 days)
    if is_sunday "${backup_date}" && [[ ${days_old} -le 35 ]]; then
        return 0
    fi

    # Rule 3: Keep first Sunday of each month indefinitely
    if is_first_sunday "${backup_date}"; then
        return 0
    fi

    # Does not match any retention rule - should be deleted
    return 1
}

# Apply retention policy to a bucket
# Usage: apply_retention "bucket"
# Returns: number of backups deleted
apply_retention() {
    local bucket="$1"
    local deleted_count=0
    local kept_count=0

    log_info "Applying retention policy to bucket: ${bucket}"

    # Get list of all backups
    local backups
    backups=$(list_backups "${bucket}")

    if [[ -z "${backups}" ]]; then
        log_info "No backups found in bucket ${bucket}"
        echo "0"
        return 0
    fi

    # Process each backup
    while IFS= read -r s3_key; do
        [[ -z "${s3_key}" ]] && continue

        local backup_date
        backup_date=$(extract_date_from_key "${s3_key}")

        if [[ -z "${backup_date}" ]]; then
            log_warn "Could not extract date from: ${s3_key}"
            continue
        fi

        if should_keep_backup "${backup_date}"; then
            kept_count=$((kept_count + 1))
        else
            log_info "Deleting old backup: ${s3_key} (date: ${backup_date})"
            if delete_from_s3 "${bucket}" "${s3_key}"; then
                deleted_count=$((deleted_count + 1))
            fi
        fi
    done <<< "${backups}"

    log_info "Retention complete: kept ${kept_count}, deleted ${deleted_count}"
    echo "${deleted_count}"
}

# Get retention statistics for a bucket
# Usage: get_retention_stats "bucket"
# Returns: JSON-like summary of backup counts by tier
get_retention_stats() {
    local bucket="$1"
    local daily_count=0
    local weekly_count=0
    local monthly_count=0
    local today_epoch

    today_epoch=$(date +%s)

    local backups
    backups=$(list_backups "${bucket}")

    while IFS= read -r s3_key; do
        [[ -z "${s3_key}" ]] && continue

        local backup_date backup_epoch days_old
        backup_date=$(extract_date_from_key "${s3_key}")

        if [[ -z "${backup_date}" ]]; then
            continue
        fi

        backup_epoch=$(date_to_epoch "${backup_date}")
        days_old=$(( (today_epoch - backup_epoch) / 86400 ))

        if [[ ${days_old} -le 7 ]]; then
            daily_count=$((daily_count + 1))
        elif is_sunday "${backup_date}" && [[ ${days_old} -le 35 ]]; then
            weekly_count=$((weekly_count + 1))
        elif is_first_sunday "${backup_date}"; then
            monthly_count=$((monthly_count + 1))
        fi
    done <<< "${backups}"

    echo "daily:${daily_count} weekly:${weekly_count} monthly:${monthly_count}"
}

# Preview what would be deleted (dry run)
# Usage: preview_retention "bucket"
preview_retention() {
    local bucket="$1"
    local to_delete=()
    local to_keep=()

    log_info "Previewing retention policy for bucket: ${bucket}"

    local backups
    backups=$(list_backups "${bucket}")

    if [[ -z "${backups}" ]]; then
        log_info "No backups found"
        return 0
    fi

    while IFS= read -r s3_key; do
        [[ -z "${s3_key}" ]] && continue

        local backup_date
        backup_date=$(extract_date_from_key "${s3_key}")

        if [[ -z "${backup_date}" ]]; then
            continue
        fi

        if should_keep_backup "${backup_date}"; then
            to_keep+=("${backup_date}: ${s3_key}")
        else
            to_delete+=("${backup_date}: ${s3_key}")
        fi
    done <<< "${backups}"

    echo ""
    echo "=== Backups to KEEP (${#to_keep[@]}) ==="
    for item in "${to_keep[@]}"; do
        echo "  ✓ ${item}"
    done

    echo ""
    echo "=== Backups to DELETE (${#to_delete[@]}) ==="
    for item in "${to_delete[@]}"; do
        echo "  ✗ ${item}"
    done
}
