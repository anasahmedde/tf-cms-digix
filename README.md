# DGX Infrastructure — AWS + Terragrunt + GitHub Actions

## Architecture

```
                         ┌─── DNS (Route53: cms.wizioners.com) ──────────┐
                         │                                                │
                         │  api-staging-cms.wizioners.com ──┐             │
                         │  api-cms.wizioners.com ──────────┤──→ ALB     │
                         │                                  │             │
                         │  staging-cms.wizioners.com ──→ CloudFront     │
                         │  cms.wizioners.com ──────────→ CloudFront     │
                         └────────────────────────────────────────────────┘

┌──────────────────── Single VPC (10.0.0.0/16) ──────────────────────────┐
│                                                                         │
│  ┌── Public Subnets ──────────────────────────────────────────┐        │
│  │                                                            │        │
│  │  ┌────────────── Shared ALB (HTTPS) ────────────────────┐  │        │
│  │  │  api-staging-cms.wizioners.com → Staging TG          │  │        │
│  │  │  api-cms.wizioners.com         → Production TG       │  │        │
│  │  └──────────┬───────────────┬───────────────────────────┘  │        │
│  │  NAT GW     │               │                              │        │
│  └─────────────┼───────────────┼──────────────────────────────┘        │
│                │               │                                        │
│  ┌── Private Subnets ──────────┼──────────────────────────────┐        │
│  │  ┌──────────▼────┐  ┌──────▼──────┐  ┌─────────────────┐  │        │
│  │  │ ECS Fargate   │  │ ECS Fargate  │  │ RDS PostgreSQL  │  │        │
│  │  │  (staging)    │  │ (production) │  │ ├ dgx_staging   │  │        │
│  │  │  0.25 vCPU    │  │  0.5 vCPU    │  │ └ dgx_production│  │        │
│  │  └───────────────┘  └─────────────┘  └─────────────────┘  │        │
│  └────────────────────────────────────────────────────────────┘        │
└─────────────────────────────────────────────────────────────────────────┘
```

## URLs

| URL | Environment | Service |
|-----|-------------|---------|
| `https://cms.wizioners.com` | Production | React frontend |
| `https://staging-cms.wizioners.com` | Staging | React frontend |
| `https://api-cms.wizioners.com` | Production | FastAPI backend |
| `https://api-staging-cms.wizioners.com` | Staging | FastAPI backend |

## Monthly Cost: ~$78

| Service | Cost |
|---------|------|
| NAT Gateway (1) | ~$32 |
| ALB (1) | ~$16 |
| ECS Fargate × 2 | ~$27 |
| RDS db.t3.micro (1) | ~$0 (free tier) |
| S3 + CloudFront × 2 | ~$3 |
| Route53 hosted zone | ~$0.50 |
| ACM certificates | $0 (free) |
| **Total** | **~$78/mo** |

## Deploy Order

```
Step 1:  shared/vpc          (VPC, subnets, NAT)
Step 2:  shared/rds          (PostgreSQL, SSM params)
Step 3:  shared/alb          (ALB with HTTP only - no cert yet)
Step 4:  shared/dns-ssl      (Route53 zone, ACM certs, DNS records)
Step 5:  >> Update parent domain NS records <<
Step 6:  >> Re-apply shared/alb with certificate_arn <<
Step 7:  staging/*           (ECR, ECS, S3+CloudFront)
Step 8:  production/*        (ECR, ECS, S3+CloudFront)
Step 9:  >> Re-apply shared/dns-ssl with CloudFront domains <<
```

## Directory Structure

```
├── .github/workflows/
│   ├── deploy-backend.yml
│   ├── deploy-frontend.yml
│   └── infra.yml
├── docker/Dockerfile
├── scripts/init-databases.sh
├── terraform/modules/
│   ├── vpc/
│   ├── rds/
│   ├── alb/            ← host-based routing, 2 target groups
│   ├── dns-ssl/        ← Route53 zone, ACM certs, DNS records
│   ├── ecr/
│   ├── ecs/
│   └── s3-cloudfront/  ← custom domain + HTTPS via ACM
├── terragrunt/
│   ├── terragrunt.hcl
│   ├── account.hcl
│   └── environments/
│       ├── shared/     (vpc, rds, alb, dns-ssl)
│       ├── staging/    (ecr, ecs, s3-cloudfront)
│       └── production/ (ecr, ecs, s3-cloudfront)
├── backend/
└── frontend/
```
