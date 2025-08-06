# Installing mercure on RHEL/CentOS

This guide provides detailed instructions for installing mercure on Red Hat Enterprise Linux (RHEL) or CentOS 8 and higher.

## System Requirements

- RHEL/CentOS 8 or higher
- Minimum 4GB RAM
- At least 20GB free disk space
- Internet connectivity for package installation
- Root access or sudo privileges

## Pre-Installation Checks

1. Verify your RHEL/CentOS version:
```bash
cat /etc/redhat-release
```

2. Check available disk space:
```bash
df -h /opt
```

3. Ensure you have sudo privileges:
```bash
sudo whoami
```

## Installation Methods

### 1. Basic Installation

The simplest way to install mercure:

```bash
./install_rhel.sh
```

This will:
- Prompt for confirmation before proceeding
- Install with default settings
- Pull pre-built Docker images

### 2. Non-Interactive Installation

For automated/scripted installations:

```bash
./install_rhel.sh -y
```

This skips all prompts and proceeds with default settings.

### 3. Development Installation

For development environments:

```bash
./install_rhel.sh -d
```

This will:
- Mount source code into containers
- Enable live code reloading
- Set up development-specific configurations

### 4. Custom Build Installation

To build containers locally:

```bash
./install_rhel.sh -b          # Build with cache
./install_rhel.sh -b -n       # Build without cache (clean build)
```

## Installation Options

| Option | Description |
|--------|-------------|
| `-h` | Display help message |
| `-y` | Force installation without prompts |
| `-d` | Development mode |
| `-b` | Build containers locally |
| `-n` | Build without using cache |
| `-u` | Update existing installation |

## Directory Structure

After installation, mercure uses the following directory structure:

```
/opt/mercure/
├── config/               # Configuration files
│   ├── mercure.json     # Main configuration
│   ├── services.json    # Service definitions
│   ├── bookkeeper.env   # Bookkeeper settings
│   ├── webgui.env      # Web interface settings
│   └── db.env          # Database credentials
├── data/                # DICOM and processing data
│   ├── incoming/       # Incoming DICOM files
│   ├── studies/        # Organized studies
│   ├── outgoing/       # Files ready for dispatch
│   ├── success/        # Successfully processed
│   ├── error/          # Failed processing
│   └── processing/     # Currently processing
└── db/                  # Database storage
```

## Installing with Orthanc Integration

mercure can be integrated with Orthanc for enhanced DICOM functionality. Here's how to set up both systems:

### 1. Install mercure First

Complete the mercure installation as described above:
```bash
./install_rhel.sh -y
```

### 2. Install Orthanc

1. Create a directory for Orthanc:
```bash
sudo mkdir -p /opt/orthanc/{config,db}
```

2. Create a Docker Compose file for Orthanc (`/opt/orthanc/docker-compose.yml`):
```yaml
version: '3.1'

services:
  orthanc:
    image: jodogne/orthanc-python
    container_name: orthanc
    volumes:
      - ./config:/etc/orthanc
      - ./db:/var/lib/orthanc/db
    ports:
      - "8042:8042"      # Web interface
      - "4242:4242"      # DICOM port
    restart: always
    networks:
      - mercure_network

networks:
  mercure_network:
    external: true
    name: mercure_default
```

3. Create Orthanc configuration (`/opt/orthanc/config/orthanc.json`):
```json
{
  "Name": "Orthanc",
  "StorageDirectory": "/var/lib/orthanc/db",
  "IndexDirectory": "/var/lib/orthanc/db",
  "StorageCompression": false,
  "HttpPort": 8042,
  "DicomPort": 4242,
  "DicomAet": "ORTHANC",
  "DicomModalities": {
    "mercure": [ "MERCURE", "172.17.0.1", 11112 ]
  }
}
```

4. Start Orthanc:
```bash
cd /opt/orthanc
sudo docker compose up -d
```

### 3. Configure Integration

1. Add Orthanc as a DICOM target in mercure (`/opt/mercure/config/mercure.json`):
```json
{
  "targets": {
    "orthanc": {
      "name": "Orthanc Server",
      "aet_target": "ORTHANC",
      "ip": "orthanc",
      "port": 4242,
      "description": "Local Orthanc Server"
    }
  }
}
```

2. Restart mercure to apply changes:
```bash
cd /opt/mercure
sudo docker compose restart
```

### 4. Verify Integration

1. Access Points:
   - mercure Web Interface: `http://localhost:8000`
   - Orthanc Web Interface: `http://localhost:8042`

2. Test DICOM Communication:
   - Send a test DICOM file from mercure to Orthanc
   - Check if it appears in Orthanc's interface

3. Common Ports:
   - mercure DICOM: 11112
   - Orthanc DICOM: 4242
   - mercure Web: 8000
   - Orthanc Web: 8042

### Troubleshooting Integration

1. Network Issues:
```bash
# Check if containers can see each other
sudo docker network inspect mercure_default

# Check if Orthanc is running
sudo docker ps | grep orthanc
```

2. DICOM Communication:
```bash
# Check Orthanc logs
sudo docker logs orthanc

# Check mercure logs
cd /opt/mercure
sudo docker compose logs
```

3. Common Problems:
   - Ensure both services are on the same Docker network
   - Verify AET configurations match
   - Check firewall settings for DICOM ports
   - Ensure no port conflicts with other services

## Post-Installation

1. Access Points:
   - Web Interface: `http://localhost:8000`
   - DICOM Port: 11112

2. Default Credentials:
   - The web interface will prompt you to create an admin account on first access

3. Verify Installation:
   ```bash
   # Check service status
   sudo docker compose ps
   
   # View logs
   sudo docker compose logs
   ```

## Common Issues

1. **Docker Service Not Starting**
   ```bash
   sudo systemctl start docker
   sudo systemctl enable docker
   ```

2. **Permission Issues**
   ```bash
   # Add your user to docker group
   sudo usermod -aG docker $USER
   # Re-login for changes to take effect
   ```

3. **Port Conflicts**
   - Check if ports 8000 or 11112 are already in use:
   ```bash
   sudo netstat -tulpn | grep -E '8000|11112'
   ```

## Updating mercure

To update an existing installation:

```bash
./install_rhel.sh -u
```

**Note**: Always backup your configuration before updating:
```bash
sudo cp -r /opt/mercure/config /opt/mercure/config.backup
```

## Uninstalling

To completely remove mercure:

```bash
# Stop and remove containers
cd /opt/mercure
sudo docker compose down

# Remove data (optional)
sudo rm -rf /opt/mercure

# Remove Docker images (optional)
sudo docker rmi $(sudo docker images 'mercureimaging/*' -q)
```

## Getting Help

If you encounter issues:

1. Check the logs:
   ```bash
   cd /opt/mercure
   sudo docker compose logs
   ```

2. Visit our documentation: https://mercure-imaging.org/docs/

3. Join our chat: https://mercure-imaging.zulipchat.com

4. File an issue: https://github.com/mercure-imaging/mercure/issues