#!/bin/bash
# Deploy p4td to EC2
# Run this after setup-aws.sh has completed

set -e

# Load configuration
if [ -f "aws-config.env" ]; then
    source aws-config.env
else
    echo "Error: aws-config.env not found. Run setup-aws.sh first."
    exit 1
fi

echo "=== Deploying P4TD to EC2 ==="
echo "Server: $EC2_PUBLIC_IP"
echo ""

# Build Docker image locally
echo "1. Building Docker image..."
docker build -t p4td:latest .

# Save and transfer image
echo ""
echo "2. Transferring to EC2..."
docker save p4td:latest | gzip > /tmp/p4td-image.tar.gz
scp -i $EC2_KEY_FILE -o StrictHostKeyChecking=no /tmp/p4td-image.tar.gz ec2-user@$EC2_PUBLIC_IP:/tmp/

# Create .env file on server
echo ""
echo "3. Setting up environment..."
ssh -i $EC2_KEY_FILE ec2-user@$EC2_PUBLIC_IP << EOF
cat > /tmp/p4td.env << 'ENVFILE'
DJANGO_SECRET_KEY=$DJANGO_SECRET_KEY
DJANGO_DEBUG=False
DJANGO_ALLOWED_HOSTS=$EC2_PUBLIC_IP
RDS_HOSTNAME=$RDS_HOSTNAME
RDS_DB_NAME=$RDS_DB_NAME
RDS_USERNAME=$RDS_USERNAME
RDS_PASSWORD=$RDS_PASSWORD
RDS_PORT=$RDS_PORT
AWS_STORAGE_BUCKET_NAME=$AWS_STORAGE_BUCKET_NAME
AWS_S3_REGION_NAME=$AWS_S3_REGION_NAME
AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
CORS_ALLOWED_ORIGINS=$CORS_ALLOWED_ORIGINS
ENVFILE
EOF

# Load and run container
echo ""
echo "4. Starting application..."
ssh -i $EC2_KEY_FILE ec2-user@$EC2_PUBLIC_IP << 'EOF'
# Load Docker image
docker load < /tmp/p4td-image.tar.gz

# Stop existing container if running
docker stop p4td 2>/dev/null || true
docker rm p4td 2>/dev/null || true

# Run new container
docker run -d \
    --name p4td \
    --restart unless-stopped \
    --env-file /tmp/p4td.env \
    -p 8000:8000 \
    p4td:latest

# Wait for container to start
sleep 5

# Run migrations
docker exec p4td python manage.py migrate --noinput

# Create superuser if needed (optional)
# docker exec -it p4td python manage.py createsuperuser

echo "Container status:"
docker ps | grep p4td
EOF

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "Your API is now live at: http://$EC2_PUBLIC_IP:8000"
echo ""
echo "Test it with:"
echo "  curl http://$EC2_PUBLIC_IP:8000/admin/"
echo ""
echo "Build your Flutter app for production:"
echo "  cd my_app && flutter build apk --dart-define=API_URL=http://$EC2_PUBLIC_IP:8000"
