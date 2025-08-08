# Mercure Installation and Operations Guide

## Table of Contents
- [Overview](#overview)
- [System Architecture](#system-architecture)
- [Installation](#installation)
- [Directory Structure](#directory-structure)
- [Data Management](#data-management)
- [Network Configuration](#network-configuration)
- [Operations Guide](#operations-guide)
- [Addons](#addons)
- [Troubleshooting](#troubleshooting)
- [Cleanup and Maintenance](#cleanup-and-maintenance)

## Overview

Mercure is a flexible DICOM orchestration platform designed for integrating algorithms, AI models, and post-processing tools into clinical practice. It provides:

- DICOM routing with configurable rules
- Processing pipeline for AI/ML models
- Docker-based module system for extensibility
- User-friendly web interface
- Extensive monitoring capabilities
- Support for both single-server and cluster deployments

### Key Components
1. **Receiver**: Listens for incoming DICOM files and extracts metadata
2. **Router**: Routes DICOM series based on configurable rules
3. **Processor**: Executes processing modules (e.g., AI models) as Docker containers
4. **Dispatcher**: Handles outgoing DICOM transfers
5. **Cleaner**: Manages cleanup of processed files
6. **WebGUI**: User interface for configuration and monitoring
7. **Bookkeeper**: Central monitoring and database management

### Processing Capabilities
- AI model inference
- DICOM anonymization
- Custom processing modules
- Automated workflows
- Integration with MONAI Model Zoo
- Support for distributed processing

### Best Practices for Production Deployment

1. **System Configuration**
   ```json
   {
     "mercure": {
       "incoming_folder": "/opt/mercure/data/incoming",
       "processing_folder": "/opt/mercure/data/processing",
       "success_folder": "/opt/mercure/data/success",
       "error_folder": "/opt/mercure/data/error",
       "router_scan_interval": 1,
       "dispatcher_scan_interval": 1,
       "cleaner_scan_interval": 60,
       "retention_days": 7
     }
   }
   ```
   - Adjust scan intervals based on load (in seconds)
   - Set retention_days based on storage capacity
   - Configure paths for your storage layout
   - Use absolute paths for reliability

2. **Resource Planning**
   - CPU: One core per service (receiver, router, processor, dispatcher)
   - RAM: 16GB minimum for production
     * 4GB for PostgreSQL
     * 2GB for each AI processing module
     * 2GB for core services
   - Storage:
     * `/opt/mercure/data`: 100GB minimum
     * `/opt/mercure/db`: 20GB minimum
     * Separate volumes recommended

3. **Security Configuration**
   ```json
   {
     "webgui": {
       "auth_token_key": "generate_random_key_here",
       "ssl_certificate": "/path/to/cert.pem",
       "ssl_key": "/path/to/key.pem"
     }
   }
   ```
   - Generate strong auth tokens
   - Use SSL for WebGUI
   - Configure firewall for DICOM ports
   - Implement role-based access

4. **Performance Tuning**
   ```json
   {
     "processor": {
       "max_parallel_jobs": 4,
       "gpu_memory_limit": "4G",
       "cpu_limit": "4"
     }
   }
   ```
   - Adjust parallel jobs based on hardware
   - Set resource limits per processor
   - Monitor processing queue length
   - Configure job priorities

5. **Monitoring Setup**
   ```bash
   # Monitor processing queue
   watch -n 10 'ls -l /opt/mercure/data/processing | wc -l'
   
   # Check service health
   cd /opt/mercure && docker compose ps
   
   # Monitor resource usage
   docker stats $(docker ps --format={{.Names}})
   ```

6. **Useful Resources**
   - [Mercure Configuration Guide](https://mercure-imaging.org/docs/configuration)
   - [DICOM Standard](https://www.dicomstandard.org/)
   - [Docker Compose Reference](https://docs.docker.com/compose/compose-file/)
   - [PostgreSQL Tuning Guide](https://wiki.postgresql.org/wiki/Tuning_Your_PostgreSQL_Server)

## System Architecture

```mermaid
graph TD
    subgraph "Docker Environment"
        M[Mercure Services] --> |uses| D[Database]
        M --> |stores| V[Volumes]
        M --> |reads/writes| S[Shared Data]
        
        subgraph "Processing Pipeline"
            R[Receiver] --> |metadata| RT[Router]
            RT --> |routes| P[Processor]
            P --> |results| DS[Dispatcher]
            DS --> |sends| T[Target Systems]
        end
        
        subgraph "Monitoring"
            BK[Bookkeeper] --> |monitors| M
            WG[WebGUI] --> |manages| M
        end
        
        subgraph "Addons"
            O[Orthanc] --> |uses| OV[Orthanc Volumes]
            O --> |reads/writes| OS[Orthanc Data]
            AI[AI Modules] --> |process| P
        end
        
        O --> |connects| M
    end
    
    subgraph "Host System"
        D --> |persisted in| HD[/opt/mercure/db]
        V --> |mapped to| HV[/opt/mercure/data]
        S --> |stored in| HS[/opt/mercure/data/*]
        OV --> |mapped to| HOV[/opt/mercure/addons/orthanc/data]
    end
```

## Installation

### Prerequisites
- RHEL/CentOS 8 or higher
- Sudo access
- Internet connectivity
- At least 10GB free disk space
- Docker and Docker Compose

### Basic Installation
```bash
# Clone the repository
git clone https://github.com/mercure-imaging/mercure.git
cd mercure

# Recommended installation (builds containers, no cache, includes Orthanc, non-interactive)
./install_rhel.sh -b -y -o -n

# Minimal installation (not recommended for production)
./install_rhel.sh
```

### Installation Options
```bash
./install_rhel.sh -h                # Show help
./install_rhel.sh -y               # Force installation without prompting
./install_rhel.sh -d               # Development mode
./install_rhel.sh -b               # Build containers
./install_rhel.sh -n               # Build with --no-cache
./install_rhel.sh -o               # Install Orthanc integration
```

### Flag Combinations and Best Practices

Flags can be combined to customize the installation. Here are recommended combinations:

1. **Production Installation** (Recommended)
   ```bash
   ./install_rhel.sh -b -y -o -n
   ```
   - `-b`: Builds containers locally for better control
   - `-y`: Non-interactive mode for automated deployments
   - `-o`: Includes Orthanc for viewing and testing
   - `-n`: No-cache build for clean installation

2. **Development Setup**
   ```bash
   ./install_rhel.sh -d -b -o
   ```
   - `-d`: Development mode with source mounting
   - `-b`: Builds containers locally
   - `-o`: Includes Orthanc for testing

3. **Quick Test Installation** (Not for production)
   ```bash
   ./install_rhel.sh -y -o
   ```
   - `-y`: Non-interactive
   - `-o`: Basic Orthanc integration

## Directory Structure

```plaintext
/opt/mercure/
├── config/                 # Configuration files
│   ├── mercure.json       # Main configuration
│   ├── services.json      # Services configuration
│   ├── bookkeeper.env     # Bookkeeper environment
│   └── webgui.env         # Web GUI environment
├── data/                  # Main data directory
│   ├── incoming/          # Incoming DICOM files
│   ├── studies/          # Study data
│   ├── outgoing/         # Files ready for dispatch
│   ├── success/          # Successfully processed
│   ├── error/            # Failed processing
│   ├── discard/          # Discarded data
│   ├── jobs/             # Job information
│   └── processing/       # Currently processing
├── db/                    # Database files
├── addons/               # Addon services
│   └── orthanc/          # Orthanc addon (if installed)
│       ├── data/         # Orthanc data
│       ├── lua_scripts/  # Lua scripts
│       └── docker-compose.yml
├── docker-compose.yml     # Main services composition
└── cleanup.sh            # Cleanup utility
```

### Data Management Best Practices

1. **DICOM Data Flow Configuration**
   ```json
   {
     "rules": [
       {
         "name": "Process CT Studies",
         "condition": "@Modality@ == 'CT'",
         "action": "process",
         "target": "ai_processor",
         "timeout": 300
       }
     ],
     "targets": {
       "ai_processor": {
         "processing_module": "mercure-monaisegment",
         "settings": {
           "batch_size": 16,
           "timeout": 600
         }
       }
     }
   }
   ```
   - Define clear routing rules
   - Set appropriate timeouts
   - Configure batch processing
   - Handle errors gracefully

2. **Storage Management**
   ```bash
   # Monitor incoming queue
   du -sh /opt/mercure/data/incoming/*
   
   # Check processing status
   ls -lrt /opt/mercure/data/processing/
   
   # Review error cases
   tail -f /opt/mercure/data/error/*/error.log
   ```
   - Monitor queue sizes
   - Track processing times
   - Analyze error patterns
   - Archive completed studies

3. **Data Retention Configuration**
   ```json
   {
     "cleaner": {
       "success_retention_days": 7,
       "error_retention_days": 14,
       "discard_retention_days": 3,
       "min_free_space_gb": 10
     }
   }
   ```
   - Configure retention periods
   - Set space thresholds
   - Archive important data
   - Clean temporary files

4. **Performance Tips**
   - Use tmpfs for `/opt/mercure/data/processing`
   - Separate disks for incoming/outgoing
   - Configure I/O scheduling
   - Monitor disk performance:
     ```bash
     iostat -xd 5 # Monitor disk I/O every 5 seconds
     ```

5. **Useful Tools**
   ```bash
   # Find stuck studies
   find /opt/mercure/data/processing -mtime +1 -type d
   
   # Check study completion
   ./check_study_completion.sh study_uid
   
   # Monitor transfer rates
   iftop -i docker0
   ```

6. **Resources**
   - [DICOM File Handling Guide](https://mercure-imaging.org/docs/dicom)
   - [Storage Configuration](https://mercure-imaging.org/docs/storage)
   - [Performance Tuning](https://mercure-imaging.org/docs/performance)
   - [Error Handling](https://mercure-imaging.org/docs/errors)

## Data Management

### Volume Mapping
Docker volumes are used to persist data across container restarts:

1. **Main Data**
   - Host: `/opt/mercure/data/*`
   - Container: Mapped according to service needs
   - Purpose: Store DICOM files, processing results

2. **Database**
   - Host: `/opt/mercure/db`
   - Container: Internal DB paths
   - Purpose: Persist system state

3. **Addon Data**
   - Host: `/opt/mercure/addons/*/data`
   - Container: Addon-specific paths
   - Purpose: Store addon-specific data

### Data Lifecycle
1. Files arrive in `incoming/`
2. Router evaluates rules and routes to:
   - `processing/` for AI/processing tasks
   - `outgoing/` for direct forwarding
3. Processor handles files in `processing/`
4. Results move to `outgoing/` for dispatch
5. Dispatcher sends files to targets
6. Files move to `success/` or `error/`
7. Cleaner manages old files

### Network Configuration Best Practices
1. **Security**
   - Use internal Docker networks when possible
   - Limit exposed ports to necessary minimum
   - Configure firewall rules
   - Regular security audits
   - Monitor network traffic

2. **Performance**
   - Use host networking for high-throughput needs
   - Monitor network latency
   - Configure appropriate timeouts
   - Use connection pooling where applicable
   - Regular network performance testing

3. **Reliability**
   - Implement health checks
   - Configure automatic restarts
   - Monitor connection states
   - Set up failover mechanisms
   - Regular connectivity testing

## Network Configuration

### Docker Networks
- Network Name: `mercure_default`
- Type: Bridge network
- Purpose: Inter-container communication

### Service Discovery
- Services can reference each other by container name
- Example: Orthanc connects to Mercure via `mercure:8080`

### Exposed Ports
- Main UI: Port 8080
- Orthanc (if installed):
  - DICOM: Port 4242
  - Web UI: Port 8042
  - OHIF Viewer: Port 8008

### Operations Best Practices
1. **Monitoring**
   - Set up automated monitoring
   - Configure alerting thresholds
   - Regular log review
   - Performance baseline tracking
   - Resource usage monitoring

2. **Maintenance**
   - Schedule regular maintenance windows
   - Document all changes
   - Keep change log
   - Test changes in staging first
   - Have rollback plans

3. **Backup**
   - Regular automated backups
   - Test backup restoration
   - Off-site backup copies
   - Document recovery procedures
   - Monitor backup success

4. **Updates**
   - Regular security updates
   - Test updates in staging
   - Maintain update schedule
   - Document update procedures
   - Keep version history

## Operations Guide

### Checking Service Status
```bash
# View all running containers
cd /opt/mercure
docker compose ps

# Check addon status
cd /opt/mercure/addons/orthanc
docker compose ps
```

### Viewing Logs
```bash
# Main services logs
cd /opt/mercure
docker compose logs            # All logs
docker compose logs -f        # Follow logs
docker compose logs service   # Specific service

# Addon logs (e.g., Orthanc)
cd /opt/mercure/addons/orthanc
docker compose logs
```

### Service Management
```bash
# Restart all services
cd /opt/mercure
docker compose restart

# Restart specific service
docker compose restart service_name

# Restart addon
cd /opt/mercure/addons/orthanc
docker compose restart
```

### Configuration Changes
1. Edit files in `/opt/mercure/config`
2. Restart affected services:
   ```bash
   docker compose restart service_name
   ```

### Monitoring
1. **Container Health**
   ```bash
   docker compose ps
   docker stats
   ```

2. **Disk Usage**
   ```bash
   du -sh /opt/mercure/data/*
   docker system df
   ```

3. **Process Logs**
   ```bash
   tail -f /opt/mercure/data/processing/process.log
   ```

### Addon Management Best Practices
1. **Installation**
   - Test addons in staging first
   - Document addon configurations
   - Verify compatibility
   - Plan resource requirements
   - Test integration points

2. **Configuration**
   - Use version control for configs
   - Document custom settings
   - Maintain configuration backups
   - Test configuration changes
   - Monitor addon performance

3. **Updates**
   - Keep addons updated
   - Test updates separately
   - Maintain update schedule
   - Document update procedures
   - Monitor for security updates

4. **Troubleshooting**
   - Maintain addon-specific logs
   - Document common issues
   - Keep troubleshooting guides
   - Monitor addon health
   - Regular testing

## Addons

### Available Addons
1. **Orthanc Integration**
   - DICOM server and viewer
   - Web interface and OHIF viewer
   - Lua scripting support

2. **MONAI Segment**
   - AI model deployment from MONAI Model Zoo
   - Automated segmentation processing
   - DICOM SEG output

3. **Anonymizer**
   - DICOM anonymization
   - Configurable rules
   - Project-specific settings

### Managing Addons
```bash
# Start addon
cd /opt/mercure/addons/addon_name
docker compose up -d

# Stop addon
docker compose down

# Restart addon
docker compose restart
```

### Troubleshooting Best Practices
1. **Problem Identification**
   - Use systematic approach
   - Collect relevant logs
   - Check recent changes
   - Document symptoms
   - Verify environment

2. **Resolution Process**
   - Follow documented procedures
   - Test solutions in staging
   - Document resolution steps
   - Update documentation
   - Monitor for recurrence

3. **Prevention**
   - Regular health checks
   - Proactive monitoring
   - Update procedures
   - Staff training
   - Regular testing

4. **Documentation**
   - Keep troubleshooting guide
   - Document common issues
   - Maintain solution database
   - Update runbooks
   - Share knowledge

## Troubleshooting

### Common Issues

1. **Services Won't Start**
   - Check logs: `docker compose logs`
   - Verify permissions: `ls -la /opt/mercure/data`
   - Check disk space: `df -h`

2. **Network Issues**
   - Verify network: `docker network ls`
   - Check connectivity: `docker network inspect mercure_default`

3. **Data Problems**
   - Check permissions
   - Verify volume mounts
   - Inspect logs

### Debug Mode
```bash
# Enable debug logging
cd /opt/mercure
docker compose down
MERCURE_DEBUG=true docker compose up -d
```

## Cleanup and Maintenance

### Cleanup Options and Best Practices

The cleanup script supports flag combinations for better control. Here are common usage patterns:

1. **Safe Cleanup Operations** (Recommended first step)
   ```bash
   # Check what would be removed (dry run)
   /opt/mercure/cleanup.sh -n -d     # Dry run for data removal
   /opt/mercure/cleanup.sh -n -p     # Dry run for complete removal
   ```

2. **Service Management**
   ```bash
   # Just stop services
   /opt/mercure/cleanup.sh
   
   # Stop services and remove volumes
   /opt/mercure/cleanup.sh -v
   ```

3. **Data Cleanup**
   ```bash
   # Remove data and volumes
   /opt/mercure/cleanup.sh -d
   
   # Remove data with confirmation of what will be removed
   /opt/mercure/cleanup.sh -n -d && /opt/mercure/cleanup.sh -d
   ```

4. **Complete Removal**
   ```bash
   # Check and then remove everything
   /opt/mercure/cleanup.sh -n -p && /opt/mercure/cleanup.sh -p
   ```

Best Practices:
1. Always use `-n` (dry run) first to verify what will be removed
2. Combine flags to get precise control over the cleanup
3. Use `-d` for data cleanup while keeping configuration
4. Use `-p` only when you want to completely remove the installation
5. Consider backing up before destructive operations

### Regular Maintenance
1. **Log Rotation**
   - Docker handles log rotation automatically
   - Configure in daemon.json if needed

2. **Data Cleanup**
   - Regular cleanup of success/error folders
   - Monitor disk usage
   - Archive old studies if needed

3. **Database Maintenance**
   - Backup regularly
   - Monitor db size
   - Clean old records

### Backup Strategy
1. **Configuration Backup**
   ```bash
   tar -czf mercure-config-backup.tar.gz /opt/mercure/config
   ```

2. **Data Backup**
   ```bash
   # Stop services
   cd /opt/mercure
   docker compose down
   
   # Backup data
   tar -czf mercure-data-backup.tar.gz /opt/mercure/data
   
   # Restart services
   docker compose up -d
   ```

3. **Database Backup**
   ```bash
   # Use provided backup script or
   cd /opt/mercure
   docker compose exec db pg_dump -U mercure > backup.sql
   ```

### System Updates
1. Stop services
2. Backup data
3. Run update script
4. Verify services
5. Check logs for errors

## Additional Resources
- [Mercure Documentation](https://mercure-imaging.org/docs/index.html)
- [Docker Documentation](https://docs.docker.com/)
- [Orthanc Documentation](https://book.orthanc-server.com/)
- [MONAI Documentation](https://docs.monai.io/)