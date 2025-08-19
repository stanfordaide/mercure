#!/bin/bash
set -e

echo "=== NFS Docker Permission Fix Script ==="
echo ""

# Check if /data is mounted
echo "1. Checking NFS mount status..."
if mount | grep -q "/data"; then
    echo "✅ /data is mounted"
    mount | grep "/data"
else
    echo "❌ /data is not mounted!"
    exit 1
fi

echo ""
echo "2. Checking mount permissions..."
ls -la /data

echo ""
echo "3. Checking available space..."
df -h /data

echo ""
echo "4. Testing write access..."
if touch /data/test_write 2>/dev/null; then
    echo "✅ Root can write to /data"
    rm -f /data/test_write
else
    echo "❌ Root cannot write to /data"
fi

echo ""
echo "5. Getting mercure user info..."
if id mercure &>/dev/null; then
    MERCURE_UID=$(id -u mercure)
    MERCURE_GID=$(id -g mercure)
    echo "Mercure user: UID=$MERCURE_UID, GID=$MERCURE_GID"
else
    echo "❌ Mercure user not found"
    exit 1
fi

echo ""
echo "6. Testing mercure user write access..."
if sudo -u mercure touch /data/test_mercure 2>/dev/null; then
    echo "✅ Mercure user can write to /data"
    sudo rm -f /data/test_mercure
else
    echo "❌ Mercure user cannot write to /data"
fi

echo ""
echo "7. Testing Docker access..."
if sudo docker run --rm -v /data:/test alpine sh -c "echo test > /test/docker_test.txt" 2>/dev/null; then
    echo "✅ Docker can write to /data"
    sudo docker run --rm -v /data:/test alpine rm /test/docker_test.txt
else
    echo "❌ Docker cannot write to /data"
fi

echo ""
echo "8. Checking PostgreSQL directory..."
if [ -d "/data/postgres-db" ]; then
    echo "✅ PostgreSQL directory exists"
    ls -la /data/postgres-db
else
    echo "❌ PostgreSQL directory missing"
    echo "Creating PostgreSQL directory..."
    sudo mkdir -p /data/postgres-db
    sudo chown $MERCURE_UID:$MERCURE_GID /data/postgres-db
    sudo chmod 755 /data/postgres-db
fi

echo ""
echo "9. Final permission fix..."
echo "Setting proper ownership and permissions..."
sudo chown -R $MERCURE_UID:$MERCURE_GID /data
sudo chmod -R 755 /data

echo ""
echo "10. Verifying final permissions..."
ls -la /data

echo ""
echo "=== Script completed ==="
echo "If all tests passed, try starting your Docker containers again:"
echo "cd /opt/mercure && sudo docker compose up -d" 