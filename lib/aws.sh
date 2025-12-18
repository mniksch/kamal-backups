#!/bin/bash
# aws.sh - AWS S3 operations for backup storage
# Handles bucket creation, upload, download, deletion, and verification

# Source common utilities if not already loaded
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "${SCRIPT_DIR}/lib/common.sh"
fi

# Configure AWS CLI with credentials from config
configure_aws_credentials() {
    if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        log_error "AWS credentials not loaded. Call load_config 'aws' first."
        return 1
    fi

    export AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY
    export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-2}"

    log_info "AWS configured for region: ${AWS_DEFAULT_REGION}"
    return 0
}

# Test AWS connectivity
test_aws_connection() {
    log_info "Testing AWS connection..."

    if aws sts get-caller-identity &>/dev/null; then
        log_success "AWS connection successful"
        return 0
    else
        log_error "AWS connection failed. Check your credentials."
        return 1
    fi
}

# Check if an S3 bucket exists
bucket_exists() {
    local bucket="$1"
    aws s3api head-bucket --bucket "${bucket}" 2>/dev/null
}

# Create an S3 bucket if it doesn't exist
create_bucket_if_needed() {
    local bucket="$1"

    if bucket_exists "${bucket}"; then
        log_info "Bucket ${bucket} already exists"
        return 0
    fi

    log_info "Creating bucket: ${bucket}"

    # For us-east-2, we can't specify LocationConstraint
    if [[ "${AWS_DEFAULT_REGION}" == "us-east-2" ]]; then
        if aws s3api create-bucket --bucket "${bucket}" 2>/dev/null; then
            log_success "Bucket ${bucket} created"
            return 0
        fi
    else
        if aws s3api create-bucket \
            --bucket "${bucket}" \
            --create-bucket-configuration LocationConstraint="${AWS_DEFAULT_REGION}" 2>/dev/null; then
            log_success "Bucket ${bucket} created"
            return 0
        fi
    fi

    log_error "Failed to create bucket ${bucket}"
    return 1
}

# Generate S3 key (path) for a backup
# Usage: generate_s3_key "site_name"
# Returns: backups/YYYY/MM/DD/site_name.sql.gz
generate_s3_key() {
    local site_name="$1"
    echo "backups/$(date_year)/$(date_month)/$(date_day)/${site_name}.sql.gz"
}

# Upload a file to S3
# Usage: upload_to_s3 "local_file" "bucket" "s3_key"
upload_to_s3() {
    local local_file="$1"
    local bucket="$2"
    local s3_key="$3"
    local s3_uri="s3://${bucket}/${s3_key}"

    if [[ ! -f "${local_file}" ]]; then
        log_error "Local file not found: ${local_file}"
        return 1
    fi

    log_info "Uploading to ${s3_uri}..."

    if aws s3 cp "${local_file}" "${s3_uri}" --quiet; then
        log_success "Upload complete: ${s3_uri}"
        return 0
    else
        log_error "Upload failed: ${s3_uri}"
        return 1
    fi
}

# Verify an uploaded backup by downloading and checking its header
# Usage: verify_s3_backup "bucket" "s3_key"
verify_s3_backup() {
    local bucket="$1"
    local s3_key="$2"
    local s3_uri="s3://${bucket}/${s3_key}"
    local temp_file
    temp_file=$(mktemp)

    log_info "Verifying backup integrity..."

    # Download first 1KB of the file
    if ! aws s3api get-object \
        --bucket "${bucket}" \
        --key "${s3_key}" \
        --range "bytes=0-1023" \
        "${temp_file}" &>/dev/null; then
        log_error "Failed to download backup header from ${s3_uri}"
        rm -f "${temp_file}"
        return 1
    fi

    # Check if it's a valid gzip file and contains PostgreSQL dump header
    local header
    if header=$(zcat "${temp_file}" 2>/dev/null | head -c 512); then
        if echo "${header}" | grep -q "PostgreSQL database dump"; then
            log_success "Backup verification: OK"
            rm -f "${temp_file}"
            return 0
        fi
    fi

    log_error "Backup verification failed: not a valid PostgreSQL dump"
    rm -f "${temp_file}"
    return 1
}

# List all backup objects in a bucket
# Usage: list_backups "bucket"
# Returns: list of S3 keys (one per line)
list_backups() {
    local bucket="$1"

    aws s3api list-objects-v2 \
        --bucket "${bucket}" \
        --prefix "backups/" \
        --query 'Contents[].Key' \
        --output text 2>/dev/null | tr '\t' '\n' | grep -v '^None$' || true
}

# Delete an object from S3
# Usage: delete_from_s3 "bucket" "s3_key"
delete_from_s3() {
    local bucket="$1"
    local s3_key="$2"

    log_info "Deleting s3://${bucket}/${s3_key}"

    if aws s3 rm "s3://${bucket}/${s3_key}" --quiet; then
        return 0
    else
        log_error "Failed to delete s3://${bucket}/${s3_key}"
        return 1
    fi
}

# Get the size of an S3 object
# Usage: get_s3_object_size "bucket" "s3_key"
# Returns: size in bytes
get_s3_object_size() {
    local bucket="$1"
    local s3_key="$2"

    aws s3api head-object \
        --bucket "${bucket}" \
        --key "${s3_key}" \
        --query 'ContentLength' \
        --output text 2>/dev/null || echo "0"
}

# Full upload pipeline for a backup
# Usage: upload_backup "local_file" "bucket" "site_name"
upload_backup() {
    local local_file="$1"
    local bucket="$2"
    local site_name="$3"
    local s3_key

    s3_key=$(generate_s3_key "${site_name}")

    # Ensure bucket exists
    if ! create_bucket_if_needed "${bucket}"; then
        return 1
    fi

    # Upload the file
    if ! upload_to_s3 "${local_file}" "${bucket}" "${s3_key}"; then
        return 1
    fi

    # Verify the upload
    if ! verify_s3_backup "${bucket}" "${s3_key}"; then
        log_warn "Backup uploaded but verification failed"
        return 1
    fi

    # Get and return the size
    local size
    size=$(get_s3_object_size "${bucket}" "${s3_key}")
    echo "${size}"
    return 0
}

# Test S3 permissions with a small test file
# Usage: test_s3_permissions "bucket"
test_s3_permissions() {
    local bucket="$1"
    local test_key="test/permission-check-$(date +%s).txt"
    local test_content="kamal-backups permission test"

    log_info "Testing S3 permissions for bucket: ${bucket}"

    # Try to create bucket
    if ! create_bucket_if_needed "${bucket}"; then
        return 1
    fi

    # Try to upload
    if ! echo "${test_content}" | aws s3 cp - "s3://${bucket}/${test_key}" --quiet; then
        log_error "Failed to upload test file"
        return 1
    fi

    # Try to read
    if ! aws s3 cp "s3://${bucket}/${test_key}" - --quiet &>/dev/null; then
        log_error "Failed to read test file"
        return 1
    fi

    # Try to delete
    if ! aws s3 rm "s3://${bucket}/${test_key}" --quiet; then
        log_error "Failed to delete test file"
        return 1
    fi

    log_success "S3 permissions OK for bucket: ${bucket}"
    return 0
}
