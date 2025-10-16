# Mercure Development and Deployment Workflow

## Directory Structure

```
/opt/projects/mercure/    <- Your repository/development directory
                             (Make all code changes here)

/opt/mercure/             <- Installation/runtime directory
                             (Services run from here)
```

## Setup

### Initial Installation

Run the install script from your repository directory:

```bash
cd /opt/projects/mercure
sudo ./install_rhel_v2.sh
```

This will:
- Copy files from repository → `/opt/mercure`
- Set up Docker containers
- Install the management script
- Start services

## Daily Development Workflow

### 1. Make Changes in Repository

```bash
cd /opt/projects/mercure
# Edit your code files
vim app/router.py
vim docker/receiver/Dockerfile
# etc.
```

### 2. Deploy Changes to Runtime

**Option A: Quick Sync (recommended for development)**

```bash
sudo /opt/mercure/mercure-manager.sh sync
```

This will:
- Stop services
- Sync docker files from repo → install
- Rebuild containers
- Restart services

**Option B: Full Update (for major changes/migrations)**

```bash
sudo /opt/mercure/mercure-manager.sh update
```

This runs the full install script update process.

### 3. Monitor and Debug

```bash
# Check status
sudo /opt/mercure/mercure-manager.sh status

# View logs (follow mode)
sudo /opt/mercure/mercure-manager.sh logs receiver -f

# View logs for specific service
sudo /opt/mercure/mercure-manager.sh logs dispatcher

# Check repo and installation info
sudo /opt/mercure/mercure-manager.sh info
```

## Management Commands

All commands are run from the manager script at `/opt/mercure/mercure-manager.sh`:

```bash
# Service control
sudo mercure-manager.sh start          # Start all services
sudo mercure-manager.sh stop           # Stop all services
sudo mercure-manager.sh restart        # Restart all services
sudo mercure-manager.sh rebuild        # Rebuild containers

# Deployment
sudo mercure-manager.sh sync           # Quick sync from repo
sudo mercure-manager.sh update         # Full update from repo

# Information
sudo mercure-manager.sh status         # Show service status
sudo mercure-manager.sh info           # Show repo/install info
sudo mercure-manager.sh logs [service] # View logs

# Maintenance
sudo mercure-manager.sh backup         # Backup data and config
sudo mercure-manager.sh restore <dir>  # Restore from backup
sudo mercure-manager.sh cleanup        # Clean up Docker
sudo mercure-manager.sh purge          # Remove everything

# Help
sudo mercure-manager.sh help           # Show all commands
```

## Key Features

### Auto-detection
The manager script automatically detects:
- If it's running from the repository directory
- The operating system (RHEL/Ubuntu)
- The correct install script to use

### Repository Tracking
Use `mercure-manager.sh info` to see:
- Installed version vs repository version
- Git branch and commit
- Uncommitted changes detection

### Separation of Concerns
- **Repository (`/opt/projects/mercure`)**: Source code, version control, development
- **Installation (`/opt/mercure`)**: Runtime, data, configuration, services

Configuration files (`/opt/mercure/config/`) are preserved during sync/update.

## Quick Reference

```bash
# Typical development iteration:
cd /opt/projects/mercure
vim app/router.py                          # Make changes
sudo /opt/mercure/mercure-manager.sh sync  # Deploy
sudo /opt/mercure/mercure-manager.sh logs router -f  # Monitor

# Check everything is in sync:
sudo /opt/mercure/mercure-manager.sh info
```

## Services

Available services:
- `receiver` - Receives DICOM files
- `router` - Routes studies based on rules
- `dispatcher` - Dispatches to targets
- `processor` - Processes studies
- `bookkeeper` - Tracks events
- `ui` - Web interface
- `db` - PostgreSQL database
- `redis` - Redis cache

## Tips

1. **Use `sync` for quick iterations** - Much faster than full update
2. **Use `info` to check versions** - Ensures repo and install are aligned
3. **Monitor logs during deployment** - Catch issues early
4. **Backup before major changes** - Use `mercure-manager.sh backup`
5. **Run manager from anywhere** - It auto-detects the correct paths

## Troubleshooting

### Services won't start
```bash
sudo /opt/mercure/mercure-manager.sh logs
sudo /opt/mercure/mercure-manager.sh rebuild --force
```

### Out of sync with repository
```bash
sudo /opt/mercure/mercure-manager.sh sync
```

### Need fresh start
```bash
sudo /opt/mercure/mercure-manager.sh stop
sudo /opt/mercure/mercure-manager.sh rebuild --force
```

### Config issues
Configuration files are in `/opt/mercure/config/` and are NOT overwritten by sync/update.

