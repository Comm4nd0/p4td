#!/bin/bash
# AWS Infrastructure Setup Script for p4td
# Run this after configuring AWS CLI with proper permissions

set -e

# Configuration - CHANGE THESE
REGION="eu-west-1"
APP_NAME="p4td"
DB_PASSWORD="$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)"
DJANGO_SECRET_KEY="$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 50)"

echo "=== P4TD AWS Infrastructure Setup ==="
echo "Region: $REGION"
echo ""

# ============================================================================
# 1. Create VPC and Security Groups
# ============================================================================
echo "1. Setting up VPC and Security Groups..."

# Get default VPC
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text --region $REGION)
echo "   Using VPC: $VPC_ID"

# Get first subnet
SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[0].SubnetId' --output text --region $REGION)
echo "   Using Subnet: $SUBNET_ID"

# Create Security Group for EC2
EC2_SG_ID=$(aws ec2 create-security-group \
    --group-name "${APP_NAME}-ec2-sg" \
    --description "Security group for ${APP_NAME} EC2" \
    --vpc-id $VPC_ID \
    --region $REGION \
    --query 'GroupId' --output text 2>/dev/null || \
    aws ec2 describe-security-groups --filters "Name=group-name,Values=${APP_NAME}-ec2-sg" --query 'SecurityGroups[0].GroupId' --output text --region $REGION)
echo "   EC2 Security Group: $EC2_SG_ID"

# Allow SSH and HTTP
aws ec2 authorize-security-group-ingress --group-id $EC2_SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0 --region $REGION 2>/dev/null || true
aws ec2 authorize-security-group-ingress --group-id $EC2_SG_ID --protocol tcp --port 8000 --cidr 0.0.0.0/0 --region $REGION 2>/dev/null || true
aws ec2 authorize-security-group-ingress --group-id $EC2_SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $REGION 2>/dev/null || true

# Create Security Group for RDS
RDS_SG_ID=$(aws ec2 create-security-group \
    --group-name "${APP_NAME}-rds-sg" \
    --description "Security group for ${APP_NAME} RDS" \
    --vpc-id $VPC_ID \
    --region $REGION \
    --query 'GroupId' --output text 2>/dev/null || \
    aws ec2 describe-security-groups --filters "Name=group-name,Values=${APP_NAME}-rds-sg" --query 'SecurityGroups[0].GroupId' --output text --region $REGION)
echo "   RDS Security Group: $RDS_SG_ID"

# Allow PostgreSQL from EC2
aws ec2 authorize-security-group-ingress --group-id $RDS_SG_ID --protocol tcp --port 5432 --source-group $EC2_SG_ID --region $REGION 2>/dev/null || true

# ============================================================================
# 2. Create S3 Bucket for Media
# ============================================================================
echo ""
echo "2. Creating S3 Bucket..."

BUCKET_NAME="${APP_NAME}-media-$(aws sts get-caller-identity --query 'Account' --output text)"
aws s3 mb "s3://${BUCKET_NAME}" --region $REGION 2>/dev/null || echo "   Bucket may already exist"
echo "   S3 Bucket: $BUCKET_NAME"

# Set bucket policy to allow public read for media files
cat > /tmp/bucket-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "PublicReadGetObject",
            "Effect": "Allow",
            "Principal": "*",
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::${BUCKET_NAME}/*"
        }
    ]
}
EOF
aws s3api put-public-access-block --bucket $BUCKET_NAME --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false" --region $REGION 2>/dev/null || true
aws s3api put-bucket-policy --bucket $BUCKET_NAME --policy file:///tmp/bucket-policy.json --region $REGION 2>/dev/null || true

# ============================================================================
# 3. Create RDS PostgreSQL Instance
# ============================================================================
echo ""
echo "3. Creating RDS PostgreSQL Instance (this takes 5-10 minutes)..."

# Get subnet IDs for DB subnet group
SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[*].SubnetId' --output text --region $REGION | tr '\t' ',')

# Create DB Subnet Group
aws rds create-db-subnet-group \
    --db-subnet-group-name "${APP_NAME}-db-subnet" \
    --db-subnet-group-description "Subnet group for ${APP_NAME}" \
    --subnet-ids $(echo $SUBNET_IDS | tr ',' ' ') \
    --region $REGION 2>/dev/null || echo "   DB Subnet group may already exist"

# Create RDS instance
aws rds create-db-instance \
    --db-instance-identifier "${APP_NAME}-db" \
    --db-instance-class db.t3.micro \
    --engine postgres \
    --engine-version 15 \
    --master-username postgres \
    --master-user-password "$DB_PASSWORD" \
    --allocated-storage 20 \
    --db-name p4td \
    --vpc-security-group-ids $RDS_SG_ID \
    --db-subnet-group-name "${APP_NAME}-db-subnet" \
    --no-publicly-accessible \
    --backup-retention-period 7 \
    --region $REGION 2>/dev/null || echo "   RDS instance may already exist"

echo "   Waiting for RDS to be available..."
aws rds wait db-instance-available --db-instance-identifier "${APP_NAME}-db" --region $REGION

RDS_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier "${APP_NAME}-db" --query 'DBInstances[0].Endpoint.Address' --output text --region $REGION)
echo "   RDS Endpoint: $RDS_ENDPOINT"

# ============================================================================
# 4. Create EC2 Instance
# ============================================================================
echo ""
echo "4. Creating EC2 Instance..."

# Get latest Amazon Linux 2023 AMI
AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text --region $REGION)
echo "   Using AMI: $AMI_ID"

# Create key pair if it doesn't exist
aws ec2 create-key-pair --key-name "${APP_NAME}-key" --query 'KeyMaterial' --output text --region $REGION > ~/.ssh/${APP_NAME}-key.pem 2>/dev/null && chmod 600 ~/.ssh/${APP_NAME}-key.pem || echo "   Key pair may already exist"

# Create user data script
cat > /tmp/userdata.sh << 'USERDATA'
#!/bin/bash
yum update -y
yum install -y docker git
systemctl start docker
systemctl enable docker
usermod -a -G docker ec2-user
USERDATA

# Launch EC2 instance
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id $AMI_ID \
    --instance-type t3.micro \
    --key-name "${APP_NAME}-key" \
    --security-group-ids $EC2_SG_ID \
    --subnet-id $SUBNET_ID \
    --user-data file:///tmp/userdata.sh \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${APP_NAME}-server}]" \
    --query 'Instances[0].InstanceId' \
    --output text --region $REGION)
echo "   Instance ID: $INSTANCE_ID"

echo "   Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID --region $REGION

# Allocate and associate Elastic IP
ALLOC_ID=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text --region $REGION)
PUBLIC_IP=$(aws ec2 describe-addresses --allocation-ids $ALLOC_ID --query 'Addresses[0].PublicIp' --output text --region $REGION)
aws ec2 associate-address --instance-id $INSTANCE_ID --allocation-id $ALLOC_ID --region $REGION
echo "   Public IP: $PUBLIC_IP"

# ============================================================================
# 5. Save Configuration
# ============================================================================
echo ""
echo "5. Saving configuration..."

cat > aws-config.env << EOF
# AWS Infrastructure Configuration for ${APP_NAME}
# Generated on $(date)

# EC2
EC2_INSTANCE_ID=$INSTANCE_ID
EC2_PUBLIC_IP=$PUBLIC_IP
EC2_KEY_FILE=~/.ssh/${APP_NAME}-key.pem

# RDS PostgreSQL
RDS_HOSTNAME=$RDS_ENDPOINT
RDS_DB_NAME=p4td
RDS_USERNAME=postgres
RDS_PASSWORD=$DB_PASSWORD
RDS_PORT=5432

# S3
AWS_STORAGE_BUCKET_NAME=$BUCKET_NAME
AWS_S3_REGION_NAME=$REGION

# Django
DJANGO_SECRET_KEY=$DJANGO_SECRET_KEY
DJANGO_DEBUG=False
DJANGO_ALLOWED_HOSTS=$PUBLIC_IP
CORS_ALLOWED_ORIGINS=http://$PUBLIC_IP:8000
EOF

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Configuration saved to: aws-config.env"
echo ""
echo "Next steps:"
echo "1. Wait 2-3 minutes for EC2 to finish initializing"
echo "2. SSH to your server:  ssh -i ~/.ssh/${APP_NAME}-key.pem ec2-user@$PUBLIC_IP"
echo "3. Deploy your app using the deploy-to-ec2.sh script"
echo ""
echo "Your API will be available at: http://$PUBLIC_IP:8000"
