#!/bin/bash
# mercure-manager.sh - Management script for mercure Docker installation

set -euo pipefail

# Installation and repository paths
MERCURE_BASE="/opt/mercure"
MERCURE_REPO="/opt/projects/mercure"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-detect if we're running from the repo
if [ -f "$SCRIPT_DIR/app/VERSION" ] && [ -f "$SCRIPT_DIR/install.sh" ]; then
    MERCURE_REPO="$SCRIPT_DIR"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

error() {
    echo -e "${RED}Error: $1${NC}" >&2
    exit 1
}

info() {
    echo -e "${BLUE}Info: $1${NC}"
}

success() {
    echo -e "${GREEN}Success: $1${NC}"
}

warning() {
    echo -e "${YELLOW}Warning: $1${NC}"
}

check_installation() {
    if [ ! -f "$MERCURE_BASE/docker-compose.yml" ]; then
        error "mercure installation not found at $MERCURE_BASE"
    fi
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "This script must be run as root (use sudo)"
    fi
}

show_status() {
    info "Checking mercure status..."
    cd "$MERCURE_BASE"
    docker-compose ps
    echo ""
    info "Docker images:"
    docker images | grep -E "(mercure|postgres|redis)" || echo "No mercure-related images found"
}

start_services() {
    info "Starting mercure services..."
    cd "$MERCURE_BASE"
    docker-compose up -d
    success "mercure services started"
    show_status
}

stop_services() {
    info "Stopping mercure services..."
    cd "$MERCURE_BASE"
    docker-compose down
    success "mercure services stopped"
}

restart_services() {
    info "Restarting mercure services..."
    cd "$MERCURE_BASE"
    docker-compose restart
    success "mercure services restarted"
    show_status
}

rebuild_services() {
    local force_rebuild=""
    if [ "${1:-}" = "--force" ]; then
        force_rebuild="--no-cache"
        info "Force rebuilding mercure services..."
    else
        info "Rebuilding mercure services..."
    fi
    
    cd "$MERCURE_BASE"
    docker-compose down
    docker-compose build $force_rebuild
    docker-compose up -d
    success "mercure services rebuilt and started"
    show_status
}

show_logs() {
    local service="${1:-}"
    local follow="${2:-}"
    
    cd "$MERCURE_BASE"
    if [ -n "$service" ]; then
        info "Showing logs for service: $service"
        if [ "$follow" = "-f" ]; then
            docker-compose logs -f "$service"
        else
            docker-compose logs --tail=100 "$service"
        fi
    else
        info "Showing logs for all services"
        if [ "$follow" = "-f" ]; then
            docker-compose logs -f
        else
            docker-compose logs --tail=100
        fi
    fi
}

sync_from_repo() {
    info "Syncing changes from repository to installation..."
    
    # Check if repo directory exists
    if [ ! -d "$MERCURE_REPO" ]; then
        error "Repository directory not found at $MERCURE_REPO"
    fi
    
    if [ ! -f "$MERCURE_REPO/install.sh" ] || [ ! -f "$MERCURE_REPO/app/VERSION" ]; then
        error "Invalid repository directory at $MERCURE_REPO"
    fi
    
    info "Repository: $MERCURE_REPO"
    info "Installation: $MERCURE_BASE"
    
    # Stop services
    cd "$MERCURE_BASE"
    docker-compose down
    
    # Sync docker files and compose configuration
    info "Syncing docker files..."
    rsync -av --delete "$MERCURE_REPO/docker/" "$MERCURE_BASE/docker/"
    cp "$MERCURE_REPO/docker-compose.yml" "$MERCURE_BASE/" 2>/dev/null || true
    
    # Rebuild and restart
    info "Rebuilding services..."
    docker-compose build
    docker-compose up -d
    
    success "Sync completed and services restarted"
    show_status
}

update_mercure() {
    info "Updating mercure installation from repository..."
    
    # Check if repo directory exists
    if [ ! -d "$MERCURE_REPO" ]; then
        error "Repository directory not found at $MERCURE_REPO"
    fi
    
    if [ ! -f "$MERCURE_REPO/app/VERSION" ]; then
        error "Invalid repository directory. app/VERSION not found at $MERCURE_REPO"
    fi
    
    # Detect OS and choose appropriate install script
    local INSTALL_SCRIPT="install.sh"
    local INSTALL_ARGS="docker -u"
    
    if [ -f /etc/redhat-release ]; then
        if [ -f "$MERCURE_REPO/install_rhel_v2.sh" ]; then
            INSTALL_SCRIPT="install_rhel_v2.sh"
            INSTALL_ARGS="-u"
            info "Detected RHEL/CentOS system, using install_rhel_v2.sh"
        elif [ -f "$MERCURE_REPO/install_rhel.sh" ]; then
            INSTALL_SCRIPT="install_rhel.sh"
            info "Detected RHEL/CentOS system, using install_rhel.sh"
        fi
    fi
    
    if [ ! -f "$MERCURE_REPO/$INSTALL_SCRIPT" ]; then
        error "Install script not found: $MERCURE_REPO/$INSTALL_SCRIPT"
    fi
    
    local OLD_VERSION=$(cat "$MERCURE_BASE/docker/base/Dockerfile" | grep "LABEL version=" | cut -d'"' -f2 || echo "unknown")
    local NEW_VERSION=$(cat "$MERCURE_REPO/app/VERSION")
    
    info "Current version: $OLD_VERSION"
    info "New version: $NEW_VERSION"
    info "Source: $MERCURE_REPO"
    info "Using: $INSTALL_SCRIPT"
    
    cd "$MERCURE_REPO"
    ./$INSTALL_SCRIPT $INSTALL_ARGS
    success "mercure updated successfully"
}

backup_data() {
    local backup_dir="/opt/mercure-backup-$(date +%Y%m%d-%H%M%S)"
    info "Creating backup at $backup_dir..."
    
    # Stop services first
    cd "$MERCURE_BASE"
    docker-compose down
    
    # Create backup
    mkdir -p "$backup_dir"
    cp -r "$MERCURE_BASE/config" "$backup_dir/"
    cp -r "$MERCURE_BASE/data" "$backup_dir/"
    cp "$MERCURE_BASE/docker-compose.yml" "$backup_dir/"
    
    # Backup database
    docker-compose up -d db
    sleep 5
    docker-compose exec -T db pg_dump -U mercure mercure > "$backup_dir/database.sql"
    docker-compose down
    
    # Restart services
    docker-compose up -d
    
    success "Backup created at $backup_dir"
}

restore_data() {
    local backup_dir="$1"
    if [ -z "$backup_dir" ] || [ ! -d "$backup_dir" ]; then
        error "Please specify a valid backup directory"
    fi
    
    warning "This will overwrite current data. Are you sure? (y/N)"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        info "Restore cancelled"
        return
    fi
    
    info "Restoring from backup: $backup_dir"
    
    # Stop services
    cd "$MERCURE_BASE"
    docker-compose down
    
    # Restore files
    cp -r "$backup_dir/config/"* "$MERCURE_BASE/config/"
    cp -r "$backup_dir/data/"* "$MERCURE_BASE/data/"
    
    # Start database and restore
    docker-compose up -d db
    sleep 10
    if [ -f "$backup_dir/database.sql" ]; then
        docker-compose exec -T db psql -U mercure -c "DROP DATABASE IF EXISTS mercure;"
        docker-compose exec -T db psql -U mercure -c "CREATE DATABASE mercure;"
        docker-compose exec -T db psql -U mercure mercure < "$backup_dir/database.sql"
    fi
    
    # Start all services
    docker-compose up -d
    
    success "Restore completed"
}

purge_installation() {
    warning "This will completely remove mercure and ALL DATA. Are you sure? (y/N)"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        info "Purge cancelled"
        return
    fi
    
    warning "Last chance! Type 'DELETE EVERYTHING' to confirm:"
    read -r confirmation
    if [ "$confirmation" != "DELETE EVERYTHING" ]; then
        info "Purge cancelled"
        return
    fi
    
    info "Purging mercure installation..."
    
    # Stop and remove containers
    if [ -f "$MERCURE_BASE/docker-compose.yml" ]; then
        cd "$MERCURE_BASE"
        docker-compose down -v || true
    fi
    
    # Remove Docker images
    docker image prune -f || true
    docker rmi $(docker images "mercure*" -q) 2>/dev/null || true
    docker rmi $(docker images "*mercure*" -q) 2>/dev/null || true
    
    # Remove installation directory
    rm -rf "$MERCURE_BASE"
    
    # Remove mercure user
    userdel -r mercure 2>/dev/null || true
    
    success "mercure installation purged"
}

cleanup_docker() {
    info "Cleaning up Docker system..."
    docker system prune -f
    docker volume prune -f
    docker image prune -f
    success "Docker cleanup completed"
}

show_repo_info() {
    info "Repository and Installation Information:"
    echo ""
    echo "  Installation: $MERCURE_BASE"
    if [ -f "$MERCURE_BASE/docker/base/Dockerfile" ]; then
        local INSTALLED_VERSION=$(cat "$MERCURE_BASE/docker/base/Dockerfile" | grep "LABEL version=" | cut -d'"' -f2 || echo "unknown")
        echo "  Installed Version: $INSTALLED_VERSION"
    fi
    echo ""
    echo "  Repository: $MERCURE_REPO"
    if [ -d "$MERCURE_REPO" ] && [ -f "$MERCURE_REPO/app/VERSION" ]; then
        local REPO_VERSION=$(cat "$MERCURE_REPO/app/VERSION")
        echo "  Repository Version: $REPO_VERSION"
        
        if [ -d "$MERCURE_REPO/.git" ]; then
            cd "$MERCURE_REPO"
            local BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
            local COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
            echo "  Git Branch: $BRANCH"
            echo "  Git Commit: $COMMIT"
            
            # Check for uncommitted changes
            if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
                warning "Uncommitted changes detected in repository"
            fi
        fi
    else
        warning "Repository not found or invalid at $MERCURE_REPO"
    fi
}

show_help() {
    echo "mercure Management Script"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  status                    Show service status"
    echo "  start                     Start all services"
    echo "  stop                      Stop all services"
    echo "  restart                   Restart all services"
    echo "  rebuild [--force]         Rebuild and restart services"
    echo "  logs [service] [-f]       Show logs (optionally follow)"
    echo "  sync                      Sync changes from repo and rebuild"
    echo "  update                    Full update from repo (runs install script)"
    echo "  info                      Show repo and installation info"
    echo "  backup                    Create backup of data and config"
    echo "  restore <backup_dir>      Restore from backup"
    echo "  purge                     Completely remove installation"
    echo "  cleanup                   Clean up Docker system"
    echo "  help                      Show this help"
    echo ""
    echo "Workflow:"
    echo "  - Edit code in: $MERCURE_REPO"
    echo "  - Run 'sync' to deploy changes to: $MERCURE_BASE"
    echo "  - Run 'update' for full reinstall/migration"
    echo ""
    echo "Examples:"
    echo "  $0 status"
    echo "  $0 info"
    echo "  $0 sync"
    echo "  $0 logs receiver -f"
    echo "  $0 rebuild --force"
    echo "  $0 restore /opt/mercure-backup-20231201-143000"
    echo ""
    echo "Services: receiver, router, dispatcher, processor, bookkeeper, ui, db, redis"
}

# Main script logic
case "${1:-help}" in
    status)
        check_root
        check_installation
        show_status
        ;;
    start)
        check_root
        check_installation
        start_services
        ;;
    stop)
        check_root
        check_installation
        stop_services
        ;;
    restart)
        check_root
        check_installation
        restart_services
        ;;
    rebuild)
        check_root
        check_installation
        rebuild_services "${2:-}"
        ;;
    logs)
        check_root
        check_installation
        show_logs "${2:-}" "${3:-}"
        ;;
    sync)
        check_root
        check_installation
        sync_from_repo
        ;;
    update)
        check_root
        check_installation
        update_mercure
        ;;
    info)
        show_repo_info
        ;;
    backup)
        check_root
        check_installation
        backup_data
        ;;
    restore)
        check_root
        check_installation
        restore_data "${2:-}"
        ;;
    purge)
        check_root
        purge_installation
        ;;
    cleanup)
        check_root
        cleanup_docker
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        error "Unknown command: ${1:-}. Use '$0 help' for usage information."
        ;;
esac