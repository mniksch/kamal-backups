# kamal-backups

Automated PostgreSQL backup scripts for Kamal-deployed Django sites. Backs up to AWS S3 with tiered retention and optional email notifications.

## Features

- **Automated daily backups** via cron
- **Kamal-compatible**: Works with standard Kamal v2 PostgreSQL accessories
- **Secure by design**: No credentials in code, config files are gitignored
- **Auto-discovery**: Reads database credentials from running Docker containers
- **Tiered retention policy**:
  - Daily: Keep last 7 days
  - Weekly: Keep every Sunday for 5 weeks
  - Monthly: Keep first Sunday of each month indefinitely
- **Email notifications** via AWS SES (optional):
  - Immediate alerts on backup failure
  - Weekly digest every Sunday
- **Backup verification**: Validates uploaded backups contain valid PostgreSQL data

## Quick Start

### On Your VPS (as root)

```bash
# Clone the repository (or clone your fork)
cd ~
git clone https://github.com/mniksch/kamal-backups.git
cd kamal-backups

# Make scripts executable
chmod +x setup.sh backup.sh

# Run the setup wizard
./setup.sh
```

The setup wizard will guide you through:
1. Checking prerequisites (Docker, AWS CLI, gzip)
2. Configuring AWS credentials
3. Setting up which databases to back up
4. Optionally configuring email notifications
5. Running a test backup
6. Setting up the cron job

## Prerequisites

- **Docker**: Your Kamal deployment is running
- **AWS CLI v2**: For S3 uploads ([Install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html))
- **gzip**: Usually pre-installed
- **jq**: Required for email notifications (`apt-get install jq`)

## AWS Setup

### Required IAM Policy

Create an IAM user with programmatic access and attach this policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3BackupBucketAccess",
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket",
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": [
        "arn:aws:s3:::*-pg",
        "arn:aws:s3:::*-pg/*"
      ]
    },
    {
      "Sid": "SESEmailNotifications",
      "Effect": "Allow",
      "Action": [
        "ses:SendEmail",
        "ses:SendRawEmail"
      ],
      "Resource": "*"
    }
  ]
}
```

**Security Notes:**
- The `*-pg` pattern limits access to buckets ending in `-pg`
- For tighter security, replace with specific bucket ARNs after setup
- SES permission is only needed if using email notifications

### For Email Notifications

If you want email alerts:
1. Configure AWS SES in your region
2. Verify the sender email address in SES
3. If in SES sandbox mode, also verify the recipient address

## Configuration Files

After running `setup.sh`, these files will be created:

### `config/aws.conf`
```bash
AWS_ACCESS_KEY_ID=your-access-key-id
AWS_SECRET_ACCESS_KEY=your-secret-access-key
AWS_DEFAULT_REGION=us-east-2
```

### `config/sites.conf`
```bash
# Format: CONTAINER_NAME:BUCKET_NAME
cja_dash-postgres:cja-dash-pg
ausl_dash-postgres:ausl-dash-pg
```

### `config/email.conf`
```bash
EMAIL_ENABLED=true
EMAIL_FROM=backups@yourdomain.com
EMAIL_TO=you@yourdomain.com
EMAIL_ON_FAILURE=true
EMAIL_WEEKLY_DIGEST=true
```

## Usage

### Run Backup Manually

```bash
# Backup all configured sites
./backup.sh

# Test mode (backup first site only)
./backup.sh --test

# Backup specific site
./backup.sh --site myapp
```

### View Logs

```bash
tail -f logs/backup.log
```

### Cron Schedule

The setup wizard can add this automatically:

```cron
# Daily backup at 3 AM
0 3 * * * /root/kamal-backups/backup.sh >> /root/kamal-backups/logs/backup.log 2>&1
```

To add manually:
```bash
crontab -e
```

## S3 Bucket Structure

Backups are organized by date:

```
your-site-pg/
└── backups/
    └── 2025/
        └── 01/
            ├── 15/
            │   └── your_site.sql.gz
            ├── 16/
            │   └── your_site.sql.gz
            └── ...
```

## How It Works

1. **Backup Creation**
   - Reads database credentials from the Docker container environment
   - Runs `pg_dump` inside the container
   - Compresses output with gzip

2. **Upload to S3**
   - Creates bucket if it doesn't exist
   - Uploads compressed backup
   - Verifies backup integrity by checking PostgreSQL header

3. **Retention**
   - Lists all backups in the bucket
   - Applies retention policy (7 daily, 5 weekly, monthly forever)
   - Deletes expired backups

4. **Notifications**
   - On failure: Immediate email alert
   - On Sunday: Weekly digest summary

## Kamal Container Naming

This script expects PostgreSQL containers named following Kamal conventions:
- `{service}-postgres` (e.g., `myapp-postgres`)
- `{service}_postgres` (e.g., `myapp_postgres`)

Find your containers:
```bash
docker ps --format '{{.Names}}' | grep postgres
```

## Troubleshooting

### "Container not running"

```bash
# Check if container exists
docker ps -a | grep postgres

# Check Kamal accessory status
kamal accessory details postgres
```

### "Failed to get credentials"

The container must have these environment variables set:
- `POSTGRES_USER`
- `POSTGRES_DB`
- `POSTGRES_PASSWORD`

Check with:
```bash
docker exec your-container-postgres printenv | grep POSTGRES
```

### "AWS connection failed"

```bash
# Test AWS credentials
aws sts get-caller-identity

# Check configured region
aws configure list
```

### "Backup verification failed"

The backup may be corrupted. Check:
```bash
# Download and inspect
aws s3 cp s3://your-bucket/backups/2025/01/15/site.sql.gz .
zcat site.sql.gz | head -20
```

Valid PostgreSQL dumps start with:
```sql
--
-- PostgreSQL database dump
--
```

## Security Considerations

- **Config files**: Stored with 600 permissions (root-only readable)
- **No credentials in code**: All secrets in gitignored config files
- **Minimal IAM permissions**: Limited to specific bucket patterns
- **Temp files**: Created with restricted permissions, deleted after upload
- **Database credentials**: Read at runtime from Docker, never stored

## File Structure

```
kamal-backups/
├── README.md              # This file
├── LICENSE                # MIT License
├── .gitignore             # Excludes config and temp files
├── setup.sh               # Interactive setup wizard
├── backup.sh              # Main backup script
├── config/
│   ├── aws.conf.example   # AWS credentials template
│   ├── sites.conf.example # Sites configuration template
│   └── email.conf.example # Email settings template
├── lib/
│   ├── common.sh          # Shared utilities
│   ├── docker.sh          # Docker/PostgreSQL operations
│   ├── aws.sh             # S3 operations
│   ├── retention.sh       # Retention policy
│   └── email.sh           # Email notifications
├── backups/               # Temporary backup storage (gitignored)
└── logs/                  # Log files (gitignored)
```

## Restoring a Backup

To restore a backup to your Kamal deployment:

```bash
# 1. Download the backup
aws s3 cp s3://your-bucket/backups/2025/01/15/site.sql.gz .

# 2. Decompress
gunzip site.sql.gz

# 3. Copy to container
docker cp site.sql your-container-postgres:/tmp/

# 4. Restore
docker exec your-container-postgres \
  psql -U your_user -d your_database < /tmp/site.sql
```

## License

MIT License - see [LICENSE](LICENSE)

## Contributing

Contributions welcome! Please open an issue or pull request.
