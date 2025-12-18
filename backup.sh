#!/bin/bash
# backup.sh - Main backup script for kamal-backups
# Run this daily via cron to backup all configured PostgreSQL databases
#
# Usage:
#   ./backup.sh              # Backup all sites
#   ./backup.sh --test       # Backup first site only (for testing)
#   ./backup.sh --site NAME  # Backup specific site only

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all library functions
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/docker.sh"
source "${SCRIPT_DIR}/lib/aws.sh"
source "${SCRIPT_DIR}/lib/retention.sh"
source "${SCRIPT_DIR}/lib/email.sh"

# Parse command line arguments
TEST_MODE=false
SINGLE_SITE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --test)
            TEST_MODE=true
            shift
            ;;
        --site)
            SINGLE_SITE="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --test        Backup first site only (for testing)"
            echo "  --site NAME   Backup specific site only"
            echo "  --help        Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Main backup function for a single site
backup_site() {
    local container="$1"
    local bucket="$2"
    local site_name

    # Extract site name from container name (remove -postgres suffix)
    site_name="${container%-postgres}"

    log_info "=========================================="
    log_info "Backing up: ${site_name}"
    log_info "Container: ${container}"
    log_info "Bucket: ${bucket}"
    log_info "=========================================="

    local backup_file=""
    local backup_size=0
    local error_msg=""

    # Step 1: Create backup
    if backup_file=$(backup_container "${container}" "${site_name}"); then
        log_success "Backup created: ${backup_file}"
    else
        error_msg="Failed to create backup from container ${container}"
        log_error "${error_msg}"
        send_failure_notification "${site_name}" "${error_msg}"
        record_backup_status "${site_name}" "failure" "0" "${error_msg}"
        return 1
    fi

    # Step 2: Upload to S3
    if backup_size=$(upload_backup "${backup_file}" "${bucket}" "${site_name}"); then
        log_success "Backup uploaded to S3: $(format_bytes "${backup_size}")"
    else
        error_msg="Failed to upload backup to S3 bucket ${bucket}"
        log_error "${error_msg}"
        send_failure_notification "${site_name}" "${error_msg}"
        record_backup_status "${site_name}" "failure" "0" "${error_msg}"
        # Clean up local file
        rm -f "${backup_file}"
        return 1
    fi

    # Step 3: Clean up local file
    rm -f "${backup_file}"
    log_info "Cleaned up local backup file"

    # Step 4: Apply retention policy
    local deleted_count
    deleted_count=$(apply_retention "${bucket}")
    log_info "Retention policy applied: ${deleted_count} old backups deleted"

    # Record success
    record_backup_status "${site_name}" "success" "${backup_size}" ""

    log_success "Backup complete for ${site_name}"
    return 0
}

# Main execution
main() {
    log_info "=========================================="
    log_info "KAMAL-BACKUPS starting at $(date)"
    log_info "=========================================="

    # Check prerequisites
    if ! check_prerequisites; then
        die "Prerequisites check failed"
    fi

    # Load configuration
    load_all_configs

    # Configure AWS
    if ! configure_aws_credentials; then
        die "Failed to configure AWS credentials"
    fi

    # Get sites to backup
    local sites
    sites=$(get_sites)

    if [[ -z "${sites}" ]]; then
        die "No sites configured in ${CONFIG_DIR}/sites.conf"
    fi

    # Track overall success/failure
    local total_sites=0
    local successful_sites=0
    local failed_sites=0

    # Process each site
    while IFS= read -r site_entry; do
        [[ -z "${site_entry}" ]] && continue

        parse_site "${site_entry}"

        # Skip if we're doing a single site and this isn't it
        if [[ -n "${SINGLE_SITE}" && "${SITE_CONTAINER}" != *"${SINGLE_SITE}"* ]]; then
            continue
        fi

        total_sites=$((total_sites + 1))

        # In test mode, only backup first site
        if [[ "${TEST_MODE}" == "true" && ${total_sites} -gt 1 ]]; then
            log_info "Test mode: skipping remaining sites"
            break
        fi

        if backup_site "${SITE_CONTAINER}" "${SITE_BUCKET}"; then
            successful_sites=$((successful_sites + 1))
        else
            failed_sites=$((failed_sites + 1))
        fi

        echo ""
    done <<< "${sites}"

    # Summary
    log_info "=========================================="
    log_info "BACKUP SUMMARY"
    log_info "=========================================="
    log_info "Total sites: ${total_sites}"
    log_success "Successful: ${successful_sites}"
    if [[ ${failed_sites} -gt 0 ]]; then
        log_error "Failed: ${failed_sites}"
    else
        log_info "Failed: ${failed_sites}"
    fi

    # Send weekly digest if it's Sunday
    if is_digest_day; then
        log_info "Sunday detected - sending weekly digest"
        send_weekly_digest
    fi

    log_info "=========================================="
    log_info "KAMAL-BACKUPS completed at $(date)"
    log_info "=========================================="

    # Exit with error if any backups failed
    if [[ ${failed_sites} -gt 0 ]]; then
        exit 1
    fi

    exit 0
}

# Run main function
main "$@"
