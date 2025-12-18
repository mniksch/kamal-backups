#!/bin/bash
# common.sh - Shared utilities for kamal-backups
# Provides logging, error handling, and configuration loading

set -euo pipefail

# Script directory (where kamal-backups is installed)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"
BACKUP_DIR="${SCRIPT_DIR}/backups"
LOG_DIR="${SCRIPT_DIR}/logs"

# Ensure directories exist
mkdir -p "${BACKUP_DIR}" "${LOG_DIR}"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Current date/time for logging
timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Date components for S3 paths
date_year() { date '+%Y'; }
date_month() { date '+%m'; }
date_day() { date '+%d'; }
day_of_week() { date '+%u'; }  # 1=Monday, 7=Sunday

# Logging functions
log_info() {
    echo -e "[$(timestamp)] ${BLUE}INFO${NC}: $*"
    echo "[$(timestamp)] INFO: $*" >> "${LOG_DIR}/backup.log"
}

log_success() {
    echo -e "[$(timestamp)] ${GREEN}SUCCESS${NC}: $*"
    echo "[$(timestamp)] SUCCESS: $*" >> "${LOG_DIR}/backup.log"
}

log_warn() {
    echo -e "[$(timestamp)] ${YELLOW}WARN${NC}: $*" >&2
    echo "[$(timestamp)] WARN: $*" >> "${LOG_DIR}/backup.log"
}

log_error() {
    echo -e "[$(timestamp)] ${RED}ERROR${NC}: $*" >&2
    echo "[$(timestamp)] ERROR: $*" >> "${LOG_DIR}/backup.log"
}

# Die with error message
die() {
    log_error "$*"
    exit 1
}

# Check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Load configuration file
# Usage: load_config "aws" (loads config/aws.conf)
load_config() {
    local config_name="$1"
    local config_file="${CONFIG_DIR}/${config_name}.conf"

    if [[ ! -f "${config_file}" ]]; then
        die "Configuration file not found: ${config_file}"
    fi

    # Check file permissions (should be 600 for security)
    local perms
    perms=$(stat -c %a "${config_file}" 2>/dev/null || stat -f %Lp "${config_file}" 2>/dev/null)
    if [[ "${perms}" != "600" ]]; then
        log_warn "Config file ${config_file} has insecure permissions (${perms}). Should be 600."
    fi

    # Source the config file
    # shellcheck source=/dev/null
    source "${config_file}"
}

# Load all required configurations
load_all_configs() {
    load_config "aws"
    load_config "sites"

    # Email config is optional
    if [[ -f "${CONFIG_DIR}/email.conf" ]]; then
        load_config "email"
    else
        EMAIL_ENABLED=false
    fi
}

# Read sites configuration into an array
# Returns array of "CONTAINER:BUCKET" pairs
get_sites() {
    local sites_file="${CONFIG_DIR}/sites.conf"

    if [[ ! -f "${sites_file}" ]]; then
        die "Sites configuration not found: ${sites_file}"
    fi

    # Read non-comment, non-empty lines
    grep -v '^\s*#' "${sites_file}" | grep -v '^\s*$' || true
}

# Parse site entry into container and bucket
# Usage: parse_site "container:bucket"
# Sets SITE_CONTAINER and SITE_BUCKET variables
parse_site() {
    local entry="$1"
    SITE_CONTAINER="${entry%%:*}"
    SITE_BUCKET="${entry##*:}"

    if [[ -z "${SITE_CONTAINER}" || -z "${SITE_BUCKET}" ]]; then
        die "Invalid site entry format: ${entry}. Expected CONTAINER:BUCKET"
    fi
}

# Check prerequisites
check_prerequisites() {
    local missing=()

    if ! command_exists docker; then
        missing+=("docker")
    fi

    if ! command_exists aws; then
        missing+=("aws (AWS CLI v2)")
    fi

    if ! command_exists gzip; then
        missing+=("gzip")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        log_error "Please install them before running this script."
        return 1
    fi

    # Check AWS CLI version
    local aws_version
    aws_version=$(aws --version 2>&1 | head -1)
    log_info "AWS CLI: ${aws_version}"

    return 0
}

# Secure file creation (chmod 600)
create_secure_file() {
    local filepath="$1"
    touch "${filepath}"
    chmod 600 "${filepath}"
}

# Clean up temporary files on exit
cleanup_temp_files() {
    local pattern="${1:-}"
    if [[ -n "${pattern}" && -d "${BACKUP_DIR}" ]]; then
        find "${BACKUP_DIR}" -name "${pattern}" -type f -delete 2>/dev/null || true
    fi
}

# Track backup status for weekly digest
# Usage: record_backup_status "site_name" "success|failure" "size_bytes" "error_message"
record_backup_status() {
    local site="$1"
    local status="$2"
    local size="${3:-0}"
    local error="${4:-}"
    local status_file="${LOG_DIR}/backup_status.log"

    echo "$(date '+%Y-%m-%d')|${site}|${status}|${size}|${error}" >> "${status_file}"
}

# Get backup status for the past week (for weekly digest)
get_weekly_status() {
    local status_file="${LOG_DIR}/backup_status.log"
    local week_ago
    week_ago=$(date -d '7 days ago' '+%Y-%m-%d' 2>/dev/null || date -v-7d '+%Y-%m-%d' 2>/dev/null)

    if [[ -f "${status_file}" ]]; then
        awk -F'|' -v since="${week_ago}" '$1 >= since' "${status_file}"
    fi
}

# Format bytes to human readable
format_bytes() {
    local bytes="$1"
    if [[ ${bytes} -ge 1073741824 ]]; then
        echo "$(( bytes / 1073741824 ))GB"
    elif [[ ${bytes} -ge 1048576 ]]; then
        echo "$(( bytes / 1048576 ))MB"
    elif [[ ${bytes} -ge 1024 ]]; then
        echo "$(( bytes / 1024 ))KB"
    else
        echo "${bytes}B"
    fi
}
