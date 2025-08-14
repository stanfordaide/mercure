#!/bin/bash
set -euo pipefail

MERCURE_BASE=/opt/mercure
REMOVE_DATA=false
PURGE=false

print_usage() {
    echo "Usage: cleanup.sh [OPTIONS]"
    echo "Stops all mercure services and optionally removes data"
    echo ""
    echo "Options:"
    echo "  -h, --help        Show this help message"
    echo "  -d, --remove-data Remove all data in /opt/mercure/data"
    echo "  -p, --purge       Complete removal of /opt/mercure (includes data)"
    echo ""
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            print_usage
            exit 0
            ;;
        -d|--remove-data)
            REMOVE_DATA=true
            shift
            ;;
        -p|--purge)
            PURGE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

if [ ! -d "$MERCURE_BASE" ]; then
    echo "Error: $MERCURE_BASE not found. Is mercure installed?"
    exit 1
fi

echo "Stopping mercure services..."

# Stop systemd services if they exist
echo "Stopping systemd services..."
for service in mercure_receiver mercure_router mercure_processor mercure_dispatcher mercure_cleaner mercure_bookkeeper mercure_ui; do
    if systemctl is-active --quiet "$service.service" 2>/dev/null; then
        echo "Stopping $service.service..."
        sudo systemctl stop "$service.service" || true
        echo "✓ $service.service stopped"
    fi
done

# Stop worker services (template services)
for worker_type in fast slow; do
    for instance in 1 2; do
        service_name="mercure_worker_${worker_type}@${instance}"
        if systemctl is-active --quiet "$service_name.service" 2>/dev/null; then
            echo "Stopping $service_name.service..."
            sudo systemctl stop "$service_name.service" || true
            echo "✓ $service_name.service stopped"
        fi
    done
done

# Stop all addons first
if [ -d "$MERCURE_BASE/addons" ]; then
    echo "Found addons directory, checking for active services..."
    for addon in "$MERCURE_BASE/addons"/*/ ; do
        if [ -f "$addon/docker-compose.yml" ]; then
            addon_name=$(basename "$addon")
            echo "Stopping $addon_name addon..."
            pushd "$addon" > /dev/null
            sudo docker compose down --volumes --remove-orphans || true
            echo "✓ $addon_name stopped successfully"
            popd > /dev/null
        fi
    done
fi

# Stop main services
if [ -f "$MERCURE_BASE/docker-compose.yml" ]; then
    echo "Stopping main mercure services..."
    pushd "$MERCURE_BASE" > /dev/null
    sudo docker compose down --volumes --remove-orphans || true
    echo "✓ Main services stopped successfully"
    popd > /dev/null
fi

# Remove any remaining mercure containers
echo "Removing any remaining mercure containers..."
sudo docker ps -a --filter "name=mercure_" --format "{{.Names}}" | while read container; do
    echo "Removing container: $container"
    sudo docker rm -f "$container" || true
done

# Remove any remaining orthanc containers
echo "Removing any remaining orthanc containers..."
sudo docker ps -a --filter "name=orthanc" --format "{{.Names}}" | while read container; do
    echo "Removing container: $container"
    sudo docker rm -f "$container" || true
done

# Remove any remaining ohif containers
echo "Removing any remaining OHIF containers..."
sudo docker ps -a --filter "name=ohif" --format "{{.Names}}" | while read container; do
    echo "Removing container: $container"
    sudo docker rm -f "$container" || true
done

# Remove any dangling containers that might be related to mercure
echo "Removing any dangling containers..."
sudo docker ps -a --filter "label=com.docker.compose.project=mercure" --format "{{.Names}}" | while read container; do
    echo "Removing dangling container: $container"
    sudo docker rm -f "$container" || true
done

if [ "$REMOVE_DATA" = true ] || [ "$PURGE" = true ]; then
    echo "Removing data directory..."
    sudo rm -rf "$MERCURE_BASE/data"/*
    echo "✓ Data directory cleaned"
fi

if [ "$PURGE" = true ]; then
    echo "Performing complete removal of mercure..."
    
    # Remove Docker volumes
    echo "Removing Docker volumes..."
    sudo docker volume ls --filter "name=mercure" --format "{{.Name}}" | while read volume; do
        echo "Removing volume: $volume"
        sudo docker volume rm "$volume" || true
    done
    
    # Remove Docker networks
    echo "Removing Docker networks..."
    sudo docker network ls --filter "name=mercure" --format "{{.Name}}" | while read network; do
        echo "Removing network: $network"
        sudo docker network rm "$network" || true
    done
    
    # Remove systemd service files
    echo "Removing systemd service files..."
    for service in mercure_receiver mercure_router mercure_processor mercure_dispatcher mercure_cleaner mercure_bookkeeper mercure_ui; do
        if [ -f "/etc/systemd/system/$service.service" ]; then
            echo "Removing $service.service"
            sudo rm -f "/etc/systemd/system/$service.service" || true
        fi
    done
    
    # Remove worker service files
    for worker_type in fast slow; do
        service_file="mercure_worker_${worker_type}@.service"
        if [ -f "/etc/systemd/system/$service_file" ]; then
            echo "Removing $service_file"
            sudo rm -f "/etc/systemd/system/$service_file" || true
        fi
    done
    
    # Reload systemd daemon
    sudo systemctl daemon-reload || true
    
    # Remove Docker images (optional - uncomment if you want to remove images too)
    echo "Removing Docker images..."
    sudo docker images --filter "reference=mercureimaging/*" --format "{{.Repository}}:{{.Tag}}" | while read image; do
        echo "Removing image: $image"
        sudo docker rmi "$image" || true
    done
    
    # Remove Orthanc and OHIF images
    sudo docker images --filter "reference=jodogne/*" --format "{{.Repository}}:{{.Tag}}" | while read image; do
        echo "Removing image: $image"
        sudo docker rmi "$image" || true
    done
    
    # Remove database files and other artifacts
    echo "Removing database files and artifacts..."
    sudo rm -rf /opt/mercure/db || true
    sudo rm -rf /var/lib/postgresql/data/pgdata || true
    
    # Remove any remaining configuration files
    sudo rm -rf /etc/mercure || true
    
    # Remove any Docker secrets that might have been created (only in swarm mode)
    if sudo docker info >/dev/null 2>&1 && sudo docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q "active" 2>/dev/null; then
        echo "Removing Docker secrets..."
        sudo docker secret ls --filter "name=orthanc" --format "{{.Name}}" 2>/dev/null | while read secret; do
            echo "Removing secret: $secret"
            sudo docker secret rm "$secret" || true
        done
    else
        echo "Docker swarm not active, skipping secrets cleanup"
    fi
    
    # Remove mercure base directory
    echo "Removing mercure base directory..."
    
    # Change to parent directory if we're currently in the mercure directory
    if [ "$(pwd)" = "$MERCURE_BASE" ]; then
        echo "Changing to parent directory to allow removal..."
        cd "$(dirname "$MERCURE_BASE")"
    fi
    
    # Force remove the directory and all contents
    if [ -d "$MERCURE_BASE" ]; then
        echo "Removing directory: $MERCURE_BASE"
        sudo rm -rf "$MERCURE_BASE"/*
        sudo rm -rf "$MERCURE_BASE"/.* 2>/dev/null || true  # Remove hidden files
        sudo rmdir "$MERCURE_BASE" 2>/dev/null || true
        echo "✓ Complete removal successful"
    else
        echo "Directory $MERCURE_BASE not found or already removed"
    fi
fi

echo "Cleanup complete!"