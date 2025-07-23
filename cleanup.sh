#!/bin/bash

# Cleanup script for Docker containers and networks
# Usage: ./cleanup.sh

echo "🧹 Cleaning up Docker resources..."

# Stop and remove all containers
echo "Stopping all containers..."
docker stop $(docker ps -aq) 2>/dev/null || echo "No running containers to stop"

echo "Removing all containers..."
docker rm $(docker ps -aq) 2>/dev/null || echo "No containers to remove"

# Remove all networks except default ones
echo "Removing custom networks..."
docker network prune -f

# Remove all volumes (optional - comment out if you want to keep data)
echo "Removing unused volumes..."
docker volume prune -f

# Remove all images (optional - comment out if you want to keep images)
echo "Removing unused images..."
docker image prune -a -f

echo "✅ Cleanup completed!"
echo "You can now run your Docker services fresh."