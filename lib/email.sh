#!/bin/bash
# email.sh - Email notifications via AWS SES
# Sends failure alerts and weekly digest emails

# Source common utilities if not already loaded
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    source "${SCRIPT_DIR}/lib/common.sh"
fi

# Check if email notifications are enabled
email_enabled() {
    [[ "${EMAIL_ENABLED:-false}" == "true" ]]
}

# Send an email via AWS SES
# Usage: send_email "subject" "body"
send_email() {
    local subject="$1"
    local body="$2"

    if ! email_enabled; then
        log_info "Email notifications disabled, skipping"
        return 0
    fi

    if [[ -z "${EMAIL_FROM:-}" || -z "${EMAIL_TO:-}" ]]; then
        log_error "Email configuration incomplete (EMAIL_FROM or EMAIL_TO not set)"
        return 1
    fi

    log_info "Sending email: ${subject}"

    # Create JSON payload for SES
    local json_body
    json_body=$(cat <<EOF
{
    "Source": "${EMAIL_FROM}",
    "Destination": {
        "ToAddresses": ["${EMAIL_TO}"]
    },
    "Message": {
        "Subject": {
            "Data": "${subject}",
            "Charset": "UTF-8"
        },
        "Body": {
            "Text": {
                "Data": $(echo "${body}" | jq -Rs .),
                "Charset": "UTF-8"
            }
        }
    }
}
EOF
)

    if aws ses send-email --cli-input-json "${json_body}" &>/dev/null; then
        log_success "Email sent successfully"
        return 0
    else
        log_error "Failed to send email"
        return 1
    fi
}

# Send a failure notification
# Usage: send_failure_notification "site_name" "error_message"
send_failure_notification() {
    local site="$1"
    local error="$2"
    local today
    today=$(date '+%Y-%m-%d')

    if ! email_enabled || [[ "${EMAIL_ON_FAILURE:-true}" != "true" ]]; then
        return 0
    fi

    local subject="[BACKUP FAILED] ${site} - ${today}"

    # Get last 20 lines of log
    local log_excerpt=""
    if [[ -f "${LOG_DIR}/backup.log" ]]; then
        log_excerpt=$(tail -20 "${LOG_DIR}/backup.log")
    fi

    local body
    body=$(cat <<EOF
BACKUP FAILURE ALERT

Site: ${site}
Date: ${today}
Time: $(date '+%H:%M:%S %Z')

Error:
${error}

Log excerpt (last 20 lines):
----------------------------------------
${log_excerpt}
----------------------------------------

This is an automated message from kamal-backups.
Check your VPS for more details.
EOF
)

    send_email "${subject}" "${body}"
}

# Send weekly digest email
# Usage: send_weekly_digest
send_weekly_digest() {
    if ! email_enabled || [[ "${EMAIL_WEEKLY_DIGEST:-true}" != "true" ]]; then
        return 0
    fi

    local week_start
    week_start=$(date -d 'last Sunday - 6 days' '+%Y-%m-%d' 2>/dev/null || \
                 date -v-sunday -v-6d '+%Y-%m-%d' 2>/dev/null || \
                 date '+%Y-%m-%d')

    local subject="[BACKUP DIGEST] Week of ${week_start}"

    # Build digest from status log
    local body
    body=$(cat <<EOF
WEEKLY BACKUP DIGEST
Week of ${week_start}

EOF
)

    # Get weekly status
    local status_data
    status_data=$(get_weekly_status)

    if [[ -z "${status_data}" ]]; then
        body+="No backup activity recorded this week.\n"
    else
        # Group by site
        local current_site=""
        local success_count=0
        local failure_count=0
        local total_size=0

        while IFS='|' read -r date site status size error; do
            if [[ "${site}" != "${current_site}" ]]; then
                if [[ -n "${current_site}" ]]; then
                    body+="\n"
                fi
                current_site="${site}"
                body+="\nSite: ${current_site}\n"
            fi

            local day_name
            day_name=$(date -d "${date}" '+%a' 2>/dev/null || date -j -f "%Y-%m-%d" "${date}" '+%a' 2>/dev/null)

            if [[ "${status}" == "success" ]]; then
                body+="  ${day_name}: ✓ $(format_bytes "${size}")\n"
                success_count=$((success_count + 1))
                total_size=$((total_size + size))
            else
                body+="  ${day_name}: ✗ ${error}\n"
                failure_count=$((failure_count + 1))
            fi
        done <<< "${status_data}"

        body+="\n"
        body+="----------------------------------------\n"
        body+="Summary:\n"
        body+="  Successful backups: ${success_count}\n"
        body+="  Failed backups: ${failure_count}\n"
        body+="  Total data backed up: $(format_bytes "${total_size}")\n"
    fi

    body+="\n"
    body+="This is an automated message from kamal-backups.\n"

    send_email "${subject}" "${body}"
}

# Check if today is Sunday (for triggering weekly digest)
is_digest_day() {
    [[ "$(date '+%u')" == "7" ]]
}

# Test email configuration
# Usage: test_email_config
test_email_config() {
    if ! email_enabled; then
        log_info "Email notifications are disabled"
        return 0
    fi

    log_info "Testing email configuration..."

    local subject="[BACKUP TEST] Email configuration test"
    local body
    body=$(cat <<EOF
This is a test email from kamal-backups.

If you received this message, your email notifications are configured correctly.

Configuration:
  From: ${EMAIL_FROM}
  To: ${EMAIL_TO}
  Region: ${AWS_DEFAULT_REGION:-us-east-2}

Sent at: $(date)
EOF
)

    if send_email "${subject}" "${body}"; then
        log_success "Test email sent successfully"
        return 0
    else
        log_error "Test email failed"
        return 1
    fi
}

# Verify SES sending permissions
verify_ses_permissions() {
    log_info "Verifying SES permissions..."

    # Check if the email identity is verified
    if aws ses get-identity-verification-attributes \
        --identities "${EMAIL_FROM}" \
        --query "VerificationAttributes.\"${EMAIL_FROM}\".VerificationStatus" \
        --output text 2>/dev/null | grep -q "Success"; then
        log_success "Email ${EMAIL_FROM} is verified in SES"
        return 0
    else
        log_warn "Email ${EMAIL_FROM} may not be verified in SES"
        log_warn "You need to verify this email address in AWS SES before sending"
        return 1
    fi
}
