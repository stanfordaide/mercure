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

# Stop all addons first
if [ -d "$MERCURE_BASE/addons" ]; then
    echo "Found addons directory, checking for active services..."
    for addon in "$MERCURE_BASE/addons"/*/ ; do
        if [ -f "$addon/docker-compose.yml" ]; then
            addon_name=$(basename "$addon")
            echo "Stopping $addon_name addon..."
            pushd "$addon" > /dev/null
            sudo docker compose down
            echo "✓ $addon_name stopped successfully"
            popd > /dev/null
        fi
    done
fi

# Stop main services
if [ -f "$MERCURE_BASE/docker-compose.yml" ]; then
    echo "Stopping main mercure services..."
    pushd "$MERCURE_BASE" > /dev/null
    sudo docker compose down
    echo "✓ Main services stopped successfully"
    popd > /dev/null
fi

if [ "$REMOVE_DATA" = true ] || [ "$PURGE" = true ]; then
    echo "Removing data directory..."
    sudo rm -rf "$MERCURE_BASE/data"/*
    echo "✓ Data directory cleaned"
fi

if [ "$PURGE" = true ]; then
    echo "Performing complete removal of mercure..."
    sudo rm -rf "$MERCURE_BASE"
    echo "✓ Complete removal successful"
fi

echo "Cleanup complete!"