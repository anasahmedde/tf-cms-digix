# DGX Infrastructure — Step-by-Step Deployment Guide

**Domain:** `cms.wizioners.com`
**Region:** `us-east-2` (Ohio)
**Account:** `746393610736`

---

## Prerequisites

```bash
aws --version          # AWS CLI v2+
terraform --version    # v1.7.0+
terragrunt --version   # v0.55.0+
docker --version       # Docker 20+
git --version
node --version         # Node 20+
psql --version         # PostgreSQL client
```

---

## STEP 1: Configure AWS CLI

```bash
aws configure
# AWS Access Key ID:     <your-key>
# AWS Secret Access Key: <your-secret>
# Default region name:   us-east-2
# Default output format: json

# Verify
aws sts get-caller-identity
# Should show Account: "746393610736"
```

---

## STEP 2: Create GitHub Repository & Push Code

```bash
mkdir dgx-project && cd dgx-project
git init

# Copy your code into backend/ and frontend/
# Copy all infra files from the zip I gave you:
#   .github/  docker/  scripts/  terraform/  terragrunt/  README.md

# Your structure should be:
# dgx-project/
# ├── .github/workflows/ (3 files)
# ├── backend/           (your FastAPI code)
# ├── frontend/          (your React code)
# ├── docker/Dockerfile
# ├── scripts/init-databases.sh
# ├── terraform/modules/ (7 modules)
# ├── terragrunt/        (root + 3 environments)
# └── README.md

# Push to GitHub
git add .
git commit -m "Initial commit"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/dgx-project.git
git push -u origin main

# Create staging branch
git checkout -b staging
git push -u origin staging
git checkout main
```

---

## STEP 3: Create Terraform State Backend

```bash
# S3 bucket for state
aws s3 mb s3://dgx-terraform-state --region us-east-2

aws s3api put-bucket-versioning \
  --bucket dgx-terraform-state \
  --versioning-configuration Status=Enabled

aws s3api put-public-access-block \
  --bucket dgx-terraform-state \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# DynamoDB for state locking
aws dynamodb create-table \
  --table-name dgx-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-2
```

Verify:

```bash
aws s3 ls | grep dgx-terraform
aws dynamodb describe-table --table-name dgx-terraform-locks --query 'Table.TableStatus'
# → "ACTIVE"
```

---

## STEP 4: Setup GitHub OIDC + IAM Role

### 4a. Create OIDC Provider

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

### 4b. Create IAM Policy

```bash
cat > /tmp/github-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECSandECR",
      "Effect": "Allow",
      "Action": ["ecs:*", "ecr:*"],
      "Resource": "*"
    },
    {
      "Sid": "S3",
      "Effect": "Allow",
      "Action": "s3:*",
      "Resource": "*"
    },
    {
      "Sid": "CloudFront",
      "Effect": "Allow",
      "Action": "cloudfront:*",
      "Resource": "*"
    },
    {
      "Sid": "IAM",
      "Effect": "Allow",
      "Action": [
        "iam:PassRole", "iam:GetRole", "iam:CreateRole", "iam:DeleteRole",
        "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PutRolePolicy",
        "iam:DeleteRolePolicy", "iam:GetRolePolicy", "iam:ListAttachedRolePolicies",
        "iam:ListRolePolicies", "iam:ListInstanceProfilesForRole",
        "iam:TagRole", "iam:UntagRole"
      ],
      "Resource": "arn:aws:iam::*:role/dgx-*"
    },
    {
      "Sid": "Terraform",
      "Effect": "Allow",
      "Action": [
        "ec2:*", "rds:*", "elasticloadbalancing:*", "logs:*", "ssm:*",
        "route53:*", "acm:*",
        "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"
      ],
      "Resource": "*"
    },
    {
      "Sid": "TerraformState",
      "Effect": "Allow",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::dgx-terraform-state-*",
        "arn:aws:s3:::dgx-terraform-state-*/*"
      ]
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name dgx-github-actions-policy \
  --policy-document file:///tmp/github-policy.json
```

### 4c. Create IAM Role

Replace `YOUR_GITHUB_USERNAME` and `YOUR_REPO_NAME`:

```bash
GITHUB_ORG="YOUR_GITHUB_USERNAME"
GITHUB_REPO="dgx-project"

cat > /tmp/trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::746393610736:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:${GITHUB_ORG}/${GITHUB_REPO}:*"
      }
    }
  }]
}
EOF

aws iam create-role \
  --role-name dgx-github-actions-role \
  --assume-role-policy-document file:///tmp/trust-policy.json

aws iam attach-role-policy \
  --role-name dgx-github-actions-role \
  --policy-arn arn:aws:iam::746393610736:policy/dgx-github-actions-policy

# Get the Role ARN (save this!)
aws iam get-role --role-name dgx-github-actions-role --query 'Role.Arn' --output text
# → arn:aws:iam::746393610736:role/dgx-github-actions-role
```

### 4d. Add GitHub Secret

GitHub repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**:

| Name | Value |
|------|-------|
| `AWS_ROLE_ARN` | `arn:aws:iam::746393610736:role/dgx-github-actions-role` |

---

## STEP 5: Deploy Shared VPC

```bash
cd terragrunt/environments/shared/vpc
terragrunt plan     # Preview
terragrunt apply    # Create VPC, subnets, NAT Gateway
```

**~3 minutes.** Creates: VPC, 2 public subnets, 2 private subnets, IGW, NAT Gateway, route tables.

---

## STEP 6: Deploy Shared RDS

```bash
cd ../rds
terragrunt plan
terragrunt apply
```

**~10 minutes** (RDS creation is slow). Creates: PostgreSQL db.t3.micro, security group, SSM parameters for passwords.

---

## STEP 7: Deploy Shared ALB (HTTP only, no cert yet)

```bash
cd ../alb
terragrunt plan
terragrunt apply
```

**~3 minutes.** Creates: ALB, 2 target groups, HTTP listener with host-based rules.

Save the ALB DNS name:

```bash
terragrunt output alb_dns_name
# Example: dgx-shared-alb-123456.us-east-2.elb.amazonaws.com
```

---

## STEP 8: Deploy DNS + SSL Certificates

```bash
cd ../dns-ssl
terragrunt plan
terragrunt apply
```

**~5-10 minutes** (ACM validation can take time). Creates:
- Route53 hosted zone for `cms.wizioners.com`
- ACM certificate (wildcard `*-cms.wizioners.com`) in `us-east-2` (for ALB)
- ACM certificate (wildcard `*-cms.wizioners.com`) in `us-east-1` (for CloudFront)
- DNS records: `api-cms.wizioners.com` → ALB, `api-staging-cms.wizioners.com` → ALB

### ⚠️ CRITICAL: Update Parent Domain NS Records

This step is **required** or nothing will work!

```bash
# Get the nameservers for your new hosted zone
cd dns-ssl
terragrunt output name_servers
```

You'll see 4 nameservers like:

```
ns-1234.awsdns-12.org
ns-567.awsdns-34.net
ns-890.awsdns-56.co.uk
ns-1011.awsdns-12.com
```

Now go to **Route53** → find the hosted zone for **`wizioners.com`** (your parent domain) and add an **NS record**:

```
Name:  cms
Type:  NS
Value:
  ns-1234.awsdns-12.org
  ns-567.awsdns-34.net
  ns-890.awsdns-56.co.uk
  ns-1011.awsdns-12.com
TTL:   300
```

This delegates `cms.wizioners.com` to the new hosted zone.

**Wait 2-5 minutes** for DNS to propagate. Verify:

```bash
dig cms.wizioners.com NS +short
# Should return the 4 nameservers above
```

---

## STEP 9: Enable HTTPS on ALB

Now that ACM cert is validated, update the ALB to use it.

Get the cert ARN:

```bash
cd ../dns-ssl
terragrunt output alb_certificate_arn
# Example: arn:aws:acm:us-east-2:746393610736:certificate/abc-123-def
```

Edit `terragrunt/environments/shared/alb/terragrunt.hcl` — change the last line:

```hcl
  # Change from:
  certificate_arn = ""

  # To:
  certificate_arn = "arn:aws:acm:us-east-2:746393610736:certificate/abc-123-def"
```

Re-apply:

```bash
cd ../alb
terragrunt apply
```

Now the ALB serves HTTPS and redirects HTTP → HTTPS.

---

## STEP 10: Initialize Databases

RDS is in a private subnet. You need to access it from inside the VPC.

### Quick method: Temporary bastion EC2

```bash
# Get subnet and VPC IDs
cd terragrunt/environments/shared/vpc
VPC_ID=$(terragrunt output -raw vpc_id)
PUBLIC_SUBNET=$(terragrunt output -json public_subnet_ids | jq -r '.[0]')

# Create bastion security group
BASTION_SG=$(aws ec2 create-security-group \
  --group-name dgx-bastion-temp \
  --description "Temporary bastion" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text \
  --region us-east-2)

aws ec2 authorize-security-group-ingress \
  --group-id $BASTION_SG \
  --protocol tcp --port 22 --cidr 0.0.0.0/0 \
  --region us-east-2

# Allow bastion → RDS
cd ../rds
RDS_SG=$(terragrunt output -raw db_security_group_id)

aws ec2 authorize-security-group-ingress \
  --group-id $RDS_SG \
  --protocol tcp --port 5432 --source-group $BASTION_SG \
  --region us-east-2

# Launch bastion (Amazon Linux 2023, free tier)
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id ami-0ea3c35c5c3284d82 \
  --instance-type t3.micro \
  --subnet-id $PUBLIC_SUBNET \
  --security-group-ids $BASTION_SG \
  --key-name YOUR_KEY_PAIR \
  --associate-public-ip-address \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=dgx-bastion-temp}]' \
  --query 'Instances[0].InstanceId' --output text \
  --region us-east-2)

echo "Instance ID: $INSTANCE_ID"

# Get public IP (wait ~30s for instance to start)
sleep 30
BASTION_IP=$(aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text \
  --region us-east-2)

echo "SSH: ssh -i your-key.pem ec2-user@${BASTION_IP}"
```

SSH into bastion and run init script:

```bash
ssh -i your-key.pem ubuntu@${BASTION_IP}

# On the bastion:
sudo dnf install -y postgresql15 awscli

# Run the database init script (copy it or paste it)
# The script reads passwords from SSM and creates:
#   - dgx_staging database + dgx_staging_user
#   - dgx_production database + dgx_production_user
```

You can paste the script content directly, or SCP the file:

```bash
# From your local machine:
scp -i your-key.pem scripts/init-databases.sh ec2-user@${BASTION_IP}:~/

# On the bastion:
chmod +x init-databases.sh
./init-databases.sh
```

Expected output:

```
=== Done! ===
Staging:    dgx_staging    / dgx_staging_user
Production: dgx_production / dgx_production_user
```

**Clean up bastion immediately:**

```bash
aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region us-east-2
aws ec2 delete-security-group --group-id $BASTION_SG --region us-east-2
```

---

## STEP 11: Deploy Staging Environment

```bash
cd terragrunt/environments/staging

# Deploy all 3 modules (ECR, ECS, S3+CloudFront)
terragrunt run-all plan
terragrunt run-all apply
```

**~5 minutes.** Save the outputs:

```bash
# S3 bucket name
cd s3-cloudfront
terragrunt output bucket_name
# → dgx-staging-frontend-a1b2c3d4

terragrunt output cloudfront_distribution_id
# → E1A2B3C4D5E6F7

terragrunt output cloudfront_domain_name
# → d1234567890.cloudfront.net

# ECR URL
cd ../ecr
terragrunt output repository_url
# → 746393610736.dkr.ecr.us-east-2.amazonaws.com/dgx-staging-backend
```

---

## STEP 12: Deploy Production Environment

```bash
cd terragrunt/environments/production

terragrunt run-all plan
terragrunt run-all apply
```

Save the same outputs as Step 11 (for production).

---

## STEP 13: Wire CloudFront Domains into DNS

Now that CloudFront distributions exist, add their DNS records.

Edit `terragrunt/environments/shared/dns-ssl/terragrunt.hcl` — update the CloudFront domains:

```hcl
inputs = {
  domain       = local.account_vars.locals.domain
  alb_dns_name = dependency.alb.outputs.alb_dns_name
  alb_zone_id  = dependency.alb.outputs.alb_zone_id

  # Now fill these in with actual CloudFront domains from Steps 11-12:
  staging_cloudfront_domain    = "d1234567890.cloudfront.net"    # ← staging CF domain
  production_cloudfront_domain = "d0987654321.cloudfront.net"    # ← production CF domain
}
```

Re-apply:

```bash
cd terragrunt/environments/shared/dns-ssl
terragrunt apply
```

This creates:
- `cms.wizioners.com` → production CloudFront
- `staging-cms.wizioners.com` → staging CloudFront

---

## STEP 14: Push First Docker Image

```bash
# Login to ECR
aws ecr get-login-password --region us-east-2 | \
  docker login --username AWS --password-stdin 746393610736.dkr.ecr.us-east-2.amazonaws.com

# Build
cd backend
docker build -t dgx-backend -f ../docker/Dockerfile .

# Push to staging ECR
docker tag dgx-backend:latest \
  746393610736.dkr.ecr.us-east-2.amazonaws.com/dgx-staging-backend:latest
docker push 746393610736.dkr.ecr.us-east-2.amazonaws.com/dgx-staging-backend:latest

# Push to production ECR
docker tag dgx-backend:latest \
  746393610736.dkr.ecr.us-east-2.amazonaws.com/dgx-production-backend:latest
docker push 746393610736.dkr.ecr.us-east-2.amazonaws.com/dgx-production-backend:latest

# Force ECS to use the new image
aws ecs update-service --cluster dgx-staging-cluster --service dgx-staging-backend \
  --force-new-deployment --region us-east-2
aws ecs update-service --cluster dgx-production-cluster --service dgx-production-backend \
  --force-new-deployment --region us-east-2
```

Wait ~2 minutes, verify:

```bash
aws ecs describe-services \
  --cluster dgx-staging-cluster \
  --services dgx-staging-backend \
  --query 'services[0].deployments[0].runningCount' \
  --region us-east-2
# → 1
```

---

## STEP 15: Deploy Frontend to S3

```bash
cd frontend
npm ci

# Build staging
REACT_APP_API_BASE_URL=https://api-staging-cms.wizioners.com \
REACT_APP_ENVIRONMENT=staging \
npm run build

# Upload to staging S3
aws s3 sync build/ s3://dgx-staging-frontend-XXXXXXXX/ --delete --region us-east-2
aws cloudfront create-invalidation --distribution-id EXXXXXXXXXX --paths "/*"

# Build production
REACT_APP_API_BASE_URL=https://api-cms.wizioners.com \
REACT_APP_ENVIRONMENT=production \
npm run build

# Upload to production S3
aws s3 sync build/ s3://dgx-production-frontend-XXXXXXXX/ --delete --region us-east-2
aws cloudfront create-invalidation --distribution-id EXXXXXXXXXX --paths "/*"
```

---

## STEP 16: Add Remaining GitHub Secrets

GitHub repo → **Settings** → **Secrets** → add these:

| Secret | Value |
|--------|-------|
| `AWS_ROLE_ARN` | `arn:aws:iam::746393610736:role/dgx-github-actions-role` |
| `STAGING_API_URL` | `https://api-staging-cms.wizioners.com` |
| `PROD_API_URL` | `https://api-cms.wizioners.com` |
| `STAGING_S3_BUCKET` | `dgx-staging-frontend-XXXXXXXX` (from Step 11) |
| `PROD_S3_BUCKET` | `dgx-production-frontend-XXXXXXXX` (from Step 12) |
| `STAGING_CF_DISTRIBUTION_ID` | `EXXXXXXXXXX` (from Step 11) |
| `PROD_CF_DISTRIBUTION_ID` | `EXXXXXXXXXX` (from Step 12) |

---

## STEP 17: Test CI/CD

### Test staging deployment:

```bash
git checkout staging

# Small backend change
echo "# trigger deploy" >> backend/requirement.txt
git add . && git commit -m "Test staging deploy" && git push origin staging
```

Go to GitHub → **Actions** → watch both workflows run.

### Test production deployment:

```bash
git checkout main
git merge staging
git push origin main
```

---

## STEP 18: Verify Everything Works

```bash
# Backend health check
curl https://api-staging-cms.wizioners.com/docs
curl https://api-cms.wizioners.com/docs

# Frontend
curl -I https://staging-cms.wizioners.com
curl -I https://cms.wizioners.com

# DNS
dig api-cms.wizioners.com +short
dig api-staging-cms.wizioners.com +short
dig staging-cms.wizioners.com +short
dig cms.wizioners.com +short
```

---

## ✅ You're Done!

### Your URLs:

| URL | What |
|-----|------|
| `https://cms.wizioners.com` | Production frontend |
| `https://staging-cms.wizioners.com` | Staging frontend |
| `https://api-cms.wizioners.com` | Production API |
| `https://api-staging-cms.wizioners.com` | Staging API |

### Daily Workflow:

```
1. git checkout -b feature/my-feature  (from staging)
2. Code + commit + push
3. Create PR → staging
4. Merge → auto-deploys to staging
5. Test on staging-cms.wizioners.com
6. Create PR → main
7. Merge → auto-deploys to production
```

---

## Troubleshooting

### ACM certificate stuck on "Pending validation"
```bash
# Verify DNS delegation is working
dig cms.wizioners.com NS +short
# Must show the 4 Route53 nameservers from Step 8

# If not, your parent domain NS records are wrong
```

### ECS task keeps crashing
```bash
aws logs tail /ecs/dgx-staging --follow --region us-east-2
```

### "Service Unavailable" on ALB
```bash
# Check target group health
aws elbv2 describe-target-health \
  --target-group-arn <TG_ARN> \
  --region us-east-2
```

### CloudFront returns "Bad Request" with custom domain
- Verify ACM cert in `us-east-1` is "Issued" (not "Pending")
- Verify CloudFront distribution has the domain in "Aliases"
- Verify Route53 A record alias points to the correct CloudFront distribution

### GitHub Actions permission denied
- Verify OIDC trust policy has correct `repo:ORG/REPO:*`
- Verify IAM policy has all required permissions
- Check the GitHub Actions logs for specific error
