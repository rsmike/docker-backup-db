# Database Backup service for TI

- finds the latest automatic snapshot for a given RDS instance
- restores a temporary RDS instance
- backs up all databases via mysqldump
- uploads compressed dumps to S3
- sorts out monthly, daily, weekly
- destroys the temporary RDS instance

## Directory structure:
for each database: `S3://<bucket>/database/<rds-instance-name>-<db_name>`

- `.../daily`: 2 recent weeks
- `.../weekly`: 52 recent Mondays
- `.../monthly`: every 1st of month, unlimited depth

## Install via compose file:

```
services:
  backup-db:
    image: ghcr.io/rsmike/backup-db:latest
    container_name: backup-db
    restart: "no"
    profiles: ["tools"]
    environment:
      # AWS credentials
      AWS_ACCESS_KEY_ID: ...
      AWS_SECRET_ACCESS_KEY: ...
      AWS_DEFAULT_REGION: eu-west-2
      BUCKET: (backup bucket name)
      RDS_INSTANCE: (instance name)
      # Script configuration
      MYSQL_USER: (mysqlbackup user)
      MYSQL_PASSWORD: (mysqlbackup user password)
      STATUS_URL: ... (UptimeKuma ping URL)
  ```

## Run the script:

`docker compose pull backup-db` - explicitly update image

`docker compose run --rm backup-db` - one off command

`0 4 * * * cronic /usr/bin/docker compose -f /files/docker/docker-compose.yml run --rm backup-db` - crontab

Make sure it runs shortly after the recent RDS snapshot.

## Sample IAM policy required:

```
{
	"Version": "2012-10-17",
	"Statement": [
		{
			"Sid": "AllowBucketListingAndObjectActions",
			"Effect": "Allow",
			"Action": [
				"s3:ListBucket",
				"s3:GetObject",
				"s3:PutObject",
				"s3:DeleteObject",
				"s3:GetObjectTagging",
				"s3:PutObjectTagging",
				"s3:DeleteObjectTagging"
			],
			"Resource": [
				"arn:aws:s3:::tutors-international-backups",
				"arn:aws:s3:::tutors-international-backups/*"
			]
		},
		{
			"Sid": "DenyDeleteOfMonthlyDatabaseBackups",
			"Effect": "Deny",
			"Action": "s3:DeleteObject",
			"Resource": "arn:aws:s3:::tutors-international-backups/database/*/monthly/*"
		}
	]
}
```