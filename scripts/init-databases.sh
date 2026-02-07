#!/bin/bash
# scripts/init-databases.sh
# Run ONCE after RDS is created to set up databases and users.
# Run from a machine that can reach RDS (bastion / SSM Session Manager).
# Requires: psql, aws cli

set -euo pipefail

PROJECT="dgx"
REGION="us-east-2"

echo "=== Fetching connection details from SSM ==="
DB_HOST=$(aws ssm get-parameter --name "/${PROJECT}/shared/db/host" --region $REGION --query 'Parameter.Value' --output text)
DB_PORT=$(aws ssm get-parameter --name "/${PROJECT}/shared/db/port" --region $REGION --query 'Parameter.Value' --output text)
MASTER_PASS=$(aws ssm get-parameter --name "/${PROJECT}/shared/db/master_password" --region $REGION --with-decryption --query 'Parameter.Value' --output text)
STAGING_PASS=$(aws ssm get-parameter --name "/${PROJECT}/staging/db/password" --region $REGION --with-decryption --query 'Parameter.Value' --output text)
PROD_PASS=$(aws ssm get-parameter --name "/${PROJECT}/production/db/password" --region $REGION --with-decryption --query 'Parameter.Value' --output text)

export PGPASSWORD="$MASTER_PASS"

echo "=== Creating staging database + user ==="
psql -h "$DB_HOST" -p "$DB_PORT" -U dgx_admin -d postgres <<SQL
SELECT 'CREATE DATABASE dgx_staging' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'dgx_staging')\gexec

DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'dgx_staging_user') THEN
    CREATE ROLE dgx_staging_user WITH LOGIN PASSWORD '${STAGING_PASS}';
  END IF;
END
\$\$;

GRANT ALL PRIVILEGES ON DATABASE dgx_staging TO dgx_staging_user;
SQL

psql -h "$DB_HOST" -p "$DB_PORT" -U dgx_admin -d dgx_staging <<SQL
GRANT ALL ON SCHEMA public TO dgx_staging_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO dgx_staging_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO dgx_staging_user;
SQL

echo "=== Creating production database + user ==="
psql -h "$DB_HOST" -p "$DB_PORT" -U dgx_admin -d postgres <<SQL
SELECT 'CREATE DATABASE dgx_production' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'dgx_production')\gexec

DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'dgx_production_user') THEN
    CREATE ROLE dgx_production_user WITH LOGIN PASSWORD '${PROD_PASS}';
  END IF;
END
\$\$;

GRANT ALL PRIVILEGES ON DATABASE dgx_production TO dgx_production_user;
SQL

psql -h "$DB_HOST" -p "$DB_PORT" -U dgx_admin -d dgx_production <<SQL
GRANT ALL ON SCHEMA public TO dgx_production_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO dgx_production_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO dgx_production_user;
SQL

echo ""
echo "=== Done! ==="
echo "Staging:    dgx_staging    / dgx_staging_user"
echo "Production: dgx_production / dgx_production_user"
echo "Host:       ${DB_HOST}:${DB_PORT}"
