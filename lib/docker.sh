#!/bin/bash
# docker.sh - Docker container and PostgreSQL operations
# Handles container discovery, credential reading, and pg_dump execution

# Source common utilities if not already loaded
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "${SCRIPT_DIR}/lib/common.sh"
fi

# Check if a Docker container exists and is running
# Usage: container_is_running "container_name"
container_is_running() {
    local container="$1"
    docker inspect -f '{{.State.Running}}' "${container}" 2>/dev/null | grep -q "true"
}

# Get list of all postgres containers (for discovery during setup)
# Returns container names matching *-postgres or *_postgres pattern
list_postgres_containers() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -E '[-_]postgres$' || true
}

# Read environment variable from a running container
# Usage: get_container_env "container_name" "VAR_NAME"
get_container_env() {
    local container="$1"
    local var_name="$2"

    if ! container_is_running "${container}"; then
        log_error "Container ${container} is not running"
        return 1
    fi

    docker exec "${container}" printenv "${var_name}" 2>/dev/null
}

# Get PostgreSQL credentials from container environment
# Usage: get_pg_credentials "container_name"
# Sets PG_USER, PG_DB, PG_PASSWORD variables
get_pg_credentials() {
    local container="$1"

    PG_USER=$(get_container_env "${container}" "POSTGRES_USER") || {
        log_error "Failed to get POSTGRES_USER from ${container}"
        return 1
    }

    PG_DB=$(get_container_env "${container}" "POSTGRES_DB") || {
        log_error "Failed to get POSTGRES_DB from ${container}"
        return 1
    }

    PG_PASSWORD=$(get_container_env "${container}" "POSTGRES_PASSWORD") || {
        log_error "Failed to get POSTGRES_PASSWORD from ${container}"
        return 1
    }

    if [[ -z "${PG_USER}" || -z "${PG_DB}" ]]; then
        log_error "Empty credentials retrieved from ${container}"
        return 1
    fi

    log_info "Retrieved credentials for database: ${PG_DB} (user: ${PG_USER})"
    return 0
}

# Execute pg_dump inside a container and save to local file
# Usage: run_pg_dump "container_name" "output_file"
# Uses PG_USER, PG_DB, PG_PASSWORD from get_pg_credentials
run_pg_dump() {
    local container="$1"
    local output_file="$2"

    if [[ -z "${PG_USER:-}" || -z "${PG_DB:-}" || -z "${PG_PASSWORD:-}" ]]; then
        log_error "PostgreSQL credentials not set. Call get_pg_credentials first."
        return 1
    fi

    if ! container_is_running "${container}"; then
        log_error "Container ${container} is not running"
        return 1
    fi

    log_info "Running pg_dump for database ${PG_DB}..."

    # Create output file with secure permissions
    touch "${output_file}"
    chmod 600 "${output_file}"

    # Run pg_dump inside the container
    # Using PGPASSWORD environment variable for authentication
    if docker exec -e PGPASSWORD="${PG_PASSWORD}" "${container}" \
        pg_dump -h localhost -p 5432 -U "${PG_USER}" "${PG_DB}" > "${output_file}" 2>/dev/null; then

        local size
        size=$(stat -c %s "${output_file}" 2>/dev/null || stat -f %z "${output_file}" 2>/dev/null)

        if [[ ${size} -lt 100 ]]; then
            log_error "Dump file suspiciously small (${size} bytes). Backup may have failed."
            return 1
        fi

        log_success "pg_dump completed: $(format_bytes "${size}")"

        # List tables that were backed up (for user reassurance)
        local tables
        tables=$(docker exec -e PGPASSWORD="${PG_PASSWORD}" "${container}" \
            psql -h localhost -p 5432 -U "${PG_USER}" -d "${PG_DB}" -t -c \
            "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;" 2>/dev/null | \
            sed 's/^[[:space:]]*//' | grep -v '^$' | tr '\n' ', ' | sed 's/,$//')
        if [[ -n "${tables}" ]]; then
            log_info "Tables backed up: ${tables}"
        fi

        echo "${size}"
        return 0
    else
        log_error "pg_dump failed for ${PG_DB}"
        rm -f "${output_file}"
        return 1
    fi
}

# Compress a backup file with gzip
# Usage: compress_backup "file.sql"
# Creates file.sql.gz and removes original
compress_backup() {
    local input_file="$1"

    if [[ ! -f "${input_file}" ]]; then
        log_error "File not found: ${input_file}"
        return 1
    fi

    log_info "Compressing backup..."

    if gzip -f "${input_file}"; then
        local compressed_file="${input_file}.gz"
        local size
        size=$(stat -c %s "${compressed_file}" 2>/dev/null || stat -f %z "${compressed_file}" 2>/dev/null)
        log_success "Compressed to: $(format_bytes "${size}")"
        echo "${size}"
        return 0
    else
        log_error "Compression failed for ${input_file}"
        return 1
    fi
}

# Full backup pipeline for a single container
# Usage: backup_container "container_name" "site_name"
# Returns the path to the compressed backup file
backup_container() {
    local container="$1"
    local site_name="$2"
    local backup_file="${BACKUP_DIR}/${site_name}.sql"
    local compressed_file="${backup_file}.gz"

    # Verify container is running
    if ! container_is_running "${container}"; then
        log_error "Container ${container} is not running"
        return 1
    fi

    # Get credentials from container
    if ! get_pg_credentials "${container}"; then
        return 1
    fi

    # Run pg_dump (discard size output, we only need success/failure)
    if ! run_pg_dump "${container}" "${backup_file}" > /dev/null; then
        rm -f "${backup_file}"
        return 1
    fi

    # Compress the backup (discard size output, we only need success/failure)
    if ! compress_backup "${backup_file}" > /dev/null; then
        rm -f "${backup_file}" "${compressed_file}"
        return 1
    fi

    # Return the path to the compressed file
    echo "${compressed_file}"
    return 0
}

# Validate that a backup file looks like valid PostgreSQL dump
# Usage: validate_backup_header "file.sql.gz"
validate_backup_header() {
    local backup_file="$1"

    if [[ ! -f "${backup_file}" ]]; then
        log_error "Backup file not found: ${backup_file}"
        return 1
    fi

    # Check for PostgreSQL dump header in first 1KB
    # Valid dumps start with comments like "-- PostgreSQL database dump"
    local header
    header=$(zcat "${backup_file}" 2>/dev/null | head -c 1024)

    if echo "${header}" | grep -q "PostgreSQL database dump"; then
        log_info "Backup header validation: OK"
        return 0
    else
        log_error "Backup does not appear to be a valid PostgreSQL dump"
        return 1
    fi
}
