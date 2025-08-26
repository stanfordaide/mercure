#!/bin/bash
set -euo pipefail

error() {
  local parent_lineno="$1"
  local code="${3:-1}"
  echo "Error on or near line ${parent_lineno}"
  exit "${code}"
}
trap 'error ${LINENO}' ERR

# Check if running on RHEL/CentOS
if [ ! -f "/etc/redhat-release" ]; then
  echo "Invalid operating system!"
  echo "This script requires Red Hat Enterprise Linux or CentOS"
  exit 1
fi

# Get RHEL version
RHEL_VERSION=$(cat /etc/redhat-release | grep -oE '[0-9]+\.[0-9]+' | cut -d. -f1)
if [ $RHEL_VERSION -lt 8 ]; then
  echo "Invalid operating system version!"
  echo "This mercure version requires RHEL/CentOS 8 or higher"
  echo "Detected version = $RHEL_VERSION"
  exit 1
fi

if [ ! -f "app/VERSION" ]; then
    echo "Error: VERSION file missing. Unable to proceed."
    exit 1
fi
VERSION=`cat app/VERSION`
IMAGE_TAG=":${MERCURE_TAG:-$VERSION}"
VER_LENGTH=${#VERSION}+28
echo ""
echo "mercure Installer - Version $VERSION"
for ((i=1;i<=VER_LENGTH;i++)); do
    echo -n "="
done
echo ""
echo ""

OWNER=$USER
if [ $OWNER = "root" ]
then
  OWNER=$(logname)
  echo "Running as root, but setting $OWNER as owner."
fi

SECRET="${MERCURE_SECRET:-unset}"
if [ "$SECRET" = "unset" ]
then
  SECRET=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1 || true)
fi

BOOKKEEPER_SECRET=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1 || true)

DB_PWD="${MERCURE_PASSWORD:-unset}"
if [ "$DB_PWD" = "unset" ]
then
  DB_PWD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1 || true)
fi

# Initialize DB_PERSISTENCE_PATH
DB_PERSISTENCE_PATH=""

MERCURE_BASE=/opt/mercure
DATA_PATH=$MERCURE_BASE/data
CONFIG_PATH=$MERCURE_BASE/config
DB_PATH=$MERCURE_BASE/db
MERCURE_SRC=$(readlink -f .)

if [ -f "$CONFIG_PATH"/db.env ]; then 
  sudo chown $USER "$CONFIG_PATH"/db.env 
  source "$CONFIG_PATH"/db.env # Don't accidentally generate a new database password
  sudo chown $OWNER "$CONFIG_PATH"/db.env 
  DB_PWD=$POSTGRES_PASSWORD
fi

echo "Installation folder:  $MERCURE_BASE"
echo "Source folder:       $MERCURE_SRC"
echo ""

create_user () {
  id -u mercure &>/dev/null || sudo useradd -ms /bin/bash mercure
  OWNER=mercure
}

create_folder () {
    for folder in "$@"; do
        if [[ ! -e "$folder" ]]; then
            echo "## Creating $folder"
            sudo mkdir -p "$folder"
            sudo chown "$OWNER:$OWNER" "$folder"
            sudo chmod a+x "$folder"
        else
            echo "## $folder already exists."
        fi
    done
}

create_folders () {
  create_folder $MERCURE_BASE $CONFIG_PATH $DB_PATH

  if [[ ! -e $DATA_PATH ]]; then
      echo "## Creating $DATA_PATH..."
      create_folder "$DATA_PATH"
      local paths=("incoming" "studies" "outgoing" "success" "error" "discard" "jobs" "processing")
      for path in "${paths[@]}"; do
        create_folder "$DATA_PATH"/$path
      done
      sudo chown -R $OWNER:$OWNER $DATA_PATH
      sudo chmod a+x $DATA_PATH
  else
    echo "## $DATA_PATH already exists."
  fi

  # Create addons directory
  create_folder "$MERCURE_BASE/addons"
  
  # Fix NFS permissions if using custom persistence path
  if [ -n "$DB_PERSISTENCE_PATH" ]; then
    fix_nfs_permissions "$DB_PERSISTENCE_PATH"
  fi
}

# Function to fix NFS permissions for Docker containers
fix_nfs_permissions () {
  local persistence_path="$1"
  
  if [ -n "$persistence_path" ]; then
    echo "## Checking and fixing NFS permissions for persistence path: $persistence_path"
    
    # Check if this is an NFS mount
    if mount | grep -q "$persistence_path"; then
      echo "## Detected NFS mount, fixing permissions for Docker containers..."
      
      # Create postgres user locally if it doesn't exist (PostgreSQL runs as UID 999)
      if ! id -u postgres &>/dev/null; then
        echo "## Creating local postgres user for PostgreSQL container..."
        sudo useradd -u 999 -g 999 postgres 2>/dev/null || true
      fi
      
      # Fix PostgreSQL directory permissions
      if [ -d "$persistence_path/postgres-db" ]; then
        echo "## Fixing PostgreSQL directory permissions..."
        sudo chown -R 999:999 "$persistence_path/postgres-db"
        sudo chmod -R 700 "$persistence_path/postgres-db"
        echo "✅ PostgreSQL directory permissions fixed"
      fi
      
      # Fix Orthanc storage directory permissions
      if [ -d "$persistence_path/orthanc-storage" ]; then
        echo "## Fixing Orthanc storage directory permissions..."
        sudo chown -R $OWNER:$OWNER "$persistence_path/orthanc-storage"
        sudo chmod -R 755 "$persistence_path/orthanc-storage"
        echo "✅ Orthanc storage directory permissions fixed"
      fi
      
      # Test PostgreSQL write access
      if sudo -u postgres touch "$persistence_path/postgres-db/test.txt" 2>/dev/null; then
        sudo rm -f "$persistence_path/postgres-db/test.txt"
        echo "✅ PostgreSQL user can write to persistence directory"
      else
        echo "⚠️  Warning: PostgreSQL user cannot write to persistence directory"
        echo "   This may cause container startup issues"
      fi
      
    else
      echo "## Not an NFS mount, using standard permissions"
    fi
  fi
}

install_scripts () {
  echo "## Installing utility scripts..."
  # Copy cleanup script
  sudo cp "$MERCURE_SRC/cleanup.sh" "$MERCURE_BASE/"
  sudo chown $OWNER:$OWNER "$MERCURE_BASE/cleanup.sh"
  sudo chmod +x "$MERCURE_BASE/cleanup.sh"
  echo "✓ Installed cleanup script to $MERCURE_BASE/cleanup.sh"
}

install_configuration () {
  if [ ! -f "$CONFIG_PATH"/mercure.json ]; then
    echo "## Copying configuration files..."
    sudo chown $USER "$CONFIG_PATH" 
    cp "$MERCURE_SRC"/configuration/default_bookkeeper.env "$CONFIG_PATH"/bookkeeper.env
    cp "$MERCURE_SRC"/configuration/default_mercure.json "$CONFIG_PATH"/mercure.json
    cp "$MERCURE_SRC"/configuration/default_services.json "$CONFIG_PATH"/services.json
    cp "$MERCURE_SRC"/configuration/default_webgui.env "$CONFIG_PATH"/webgui.env
    cp "$MERCURE_SRC"/configuration/timezone.env "$CONFIG_PATH"/timezone.env
    echo "POSTGRES_PASSWORD=$DB_PWD" > "$CONFIG_PATH"/db.env

    # Update Bookkeeper password depending on install mode (docker vs non-docker)
    if [ -f "$MERCURE_BASE/docker-compose.yml" ]; then
      # Docker-based install
      sed -i -e "s/mercure:ChangePasswordHere@localhost/mercure:$DB_PWD@db/" "$CONFIG_PATH"/bookkeeper.env
      sed -i -e "s/0.0.0.0:8080/bookkeeper:8080/" "$CONFIG_PATH"/mercure.json
    else
      # Systemd/non-docker install
      sed -i -e "s/mercure:ChangePasswordHere@localhost/mercure:$DB_PWD@localhost/" "$CONFIG_PATH"/bookkeeper.env
    fi
    
    sed -i -e "s/BOOKKEEPER_TOKEN_PLACEHOLDER/$BOOKKEEPER_SECRET/" "$CONFIG_PATH"/mercure.json
    sed -i -e "s/PutSomethingRandomHere/$SECRET/" "$CONFIG_PATH"/webgui.env
    sudo chown -R $OWNER:$OWNER "$CONFIG_PATH"
    sudo chmod -R o-r "$CONFIG_PATH"
    sudo chmod a+xr "$CONFIG_PATH"
  fi
}

install_docker () {
  if [ ! -x "$(command -v docker)" ]; then 
    echo "## Installing Docker..."
    sudo dnf config-manager --add-repo=https://download.docker.com/linux/centos/docker-ce.repo
    sudo dnf -y install docker-ce docker-ce-cli containerd.io
    sudo systemctl start docker
    sudo systemctl enable docker
    # Make sure we can actually use docker as the user
    sudo usermod -a -G docker $OWNER
    sudo docker --version
  fi

  # Check if docker compose plugin is installed
  if ! docker compose version &>/dev/null; then
    echo "## Installing Docker Compose plugin..."
    sudo dnf install -y docker-compose-plugin
  fi
}

setup_docker () {
  local overwrite=${1:-false}
  if [ "$overwrite" = true ] || [ ! -f "$MERCURE_BASE"/docker-compose.yml ]; then
    echo "## Copying docker-compose.yml..."
    sudo cp $MERCURE_SRC/docker/docker-compose.yml $MERCURE_BASE
    sudo sed -i -e "s/\${DOCKER_GID}/$(getent group docker | cut -d: -f3)/g" $MERCURE_BASE/docker-compose.yml
    sudo sed -i -e "s/\${UID}/$(getent passwd mercure | cut -d: -f3)/g" $MERCURE_BASE/docker-compose.yml
    sudo sed -i -e "s/\${GID}/$(getent passwd mercure | cut -d: -f4)/g" $MERCURE_BASE/docker-compose.yml

    if [[ -v MERCURE_TAG ]]; then # a custom tag was provided
      sudo sed -i "s/\${IMAGE_TAG}/\:$MERCURE_TAG/g" $MERCURE_BASE/docker-compose.yml
    else
      sudo sed -i "s/\${IMAGE_TAG}/$IMAGE_TAG/g" $MERCURE_BASE/docker-compose.yml
    fi
    
    if [ -n "$DB_PERSISTENCE_PATH" ]; then
      echo "## Setting custom database persistence path: $DB_PERSISTENCE_PATH"
      sudo sed -i -e "s;device: '/opt/mercure/db';device: '$DB_PERSISTENCE_PATH/postgres-db';g" $MERCURE_BASE/docker-compose.yml
      # Keep data and config volumes at default locations
    fi

    sudo chown $OWNER:$OWNER "$MERCURE_BASE"/docker-compose.yml
  fi
}

setup_docker_dev () {
  if [ ! -f "$MERCURE_BASE"/docker-compose.override.yml ]; then
    echo "## Copying docker-compose.override.yml..."
    sudo cp $MERCURE_SRC/docker/docker-compose.override.yml $MERCURE_BASE
    sudo sed -i -e "s;MERCURE_SRC;$(readlink -f $MERCURE_SRC)/app;" "$MERCURE_BASE"/docker-compose.override.yml
    if [[ -v MERCURE_TAG ]]; then # a custom tag was provided
      sudo sed -i "s/\${IMAGE_TAG}/\:$MERCURE_TAG/g" $MERCURE_BASE/docker-compose.override.yml
    else # no custom tag was provided, use latest
      sudo sed -i "s/\${IMAGE_TAG}/\:latest/g" $MERCURE_BASE/docker-compose.override.yml
    fi
    sudo chown $OWNER:$OWNER "$MERCURE_BASE"/docker-compose.override.yml
  fi
}

build_docker () {
  echo "## Building mercure docker containers..."
  if [ "$NO_CACHE" = true ]; then
    sudo "$MERCURE_SRC/docker-build.sh" -y -n
  else
    sudo "$MERCURE_SRC/docker-build.sh" -y
  fi
}

start_docker () {
  echo "## Starting docker compose..."  
  pushd $MERCURE_BASE
  # Set environment variables for docker compose
  MERCURE_UID=$(getent passwd mercure | cut -d: -f3)
  MERCURE_GID=$(getent passwd mercure | cut -d: -f4)
  MERCURE_DOCKER_GID=$(getent group docker | cut -d: -f3)
  
  # Create .env file for docker compose
  cat > .env << EOF
UID=$MERCURE_UID
GID=$MERCURE_GID
DOCKER_GID=$MERCURE_DOCKER_GID
IMAGE_TAG=:${MERCURE_TAG:-$VERSION}
EOF
  
  sudo docker compose up -d
  popd
}

install_packages() {
  echo "## Installing required packages..."
  sudo dnf -y update
  sudo dnf -y install epel-release
  sudo dnf -y install wget git jq iputils sshpass rsync python3-wheel python3-devel python3 python3-pip redis
}

docker_install () {
  echo "## Performing docker-type mercure installation..."
  create_user
  create_folders
  install_configuration
  install_scripts
  install_packages
  install_docker
  if [ $DOCKER_BUILD = true ]; then
    build_docker
  fi
  setup_docker
  if [ $DO_DEV_INSTALL = true ]; then
    setup_docker_dev
  fi
  start_docker
  # Clean up the .env file after docker compose is up
  rm -f $MERCURE_BASE/.env
}

docker_update () {
  if [ ! -f $MERCURE_BASE/docker-compose.yml ]; then
    echo "ERROR: $MERCURE_BASE/docker-compose.yml does not exist; is Mercure installed?"
    exit 1
  fi
  if [ -f $MERCURE_BASE/docker-compose.override.yml ]; then
    echo "ERROR: $MERCURE_BASE/docker-compose.override.yml exists. Updating a dev install is not supported."
    exit 1  
  fi
  if [ $FORCE_INSTALL != "y" ]; then
    echo "Update mercure to ${MERCURE_TAG:-VERSION} (y/n)?"
    read -p "WARNING: Server may require manual fixes after update. Taking backups beforehand is recommended. " ANS
    if [ "$ANS" != "y" ]; then
      echo "Update aborted."
      exit 0
    fi
  fi

  # Stop addons first if they exist
  if [ -d "$MERCURE_BASE/addons" ]; then
    echo "## Stopping addons..."
    for addon in "$MERCURE_BASE/addons"/*/ ; do
      if [ -f "$addon/docker-compose.yml" ]; then
        addon_name=$(basename "$addon")
        echo "## Stopping $addon_name addon..."
        pushd "$addon"
        sudo docker compose down || true
        popd
      fi
    done
  fi

  # Stop main services
  echo "## Stopping main services..."
  pushd $MERCURE_BASE
  sudo docker compose down || true
  popd

  # Update main services
  setup_docker true
  start_docker

  # Restart addons if they exist
  if [ -d "$MERCURE_BASE/addons" ]; then
    echo "## Restarting addons..."
    for addon in "$MERCURE_BASE/addons"/*/ ; do
      if [ -f "$addon/docker-compose.yml" ]; then
        addon_name=$(basename "$addon")
        echo "## Starting $addon_name addon..."
        pushd "$addon"
        sudo docker compose up -d
        echo "✓ $addon_name restarted"
        popd
      fi
    done
  fi
}

FORCE_INSTALL="n"
DO_DEV_INSTALL=false
DOCKER_BUILD=false
NO_CACHE=false
DO_OPERATION="install"
INSTALL_ORTHANC=false
DB_PERSISTENCE_PATH=""

# Temporarily disable set -u for argument parsing to avoid OPTARG issues
set +u

while getopts ":hydbnop:u" opt; do
  case ${opt} in
    h )
      echo "Usage:"
      echo ""
      echo "    install_rhel.sh -h                Display this help message."
      echo "    install_rhel.sh [-y] [-dbn]       Install with docker-compose."
      echo "    install_rhel.sh [-u]              Update an existing installation."
      echo "    install_rhel.sh orthanc           Install Orthanc addon on existing installation."
      echo ""
      echo "Options:"
      echo "    -d                                Development mode."
      echo "    -b                                Build containers."
      echo "    -n                                Build containers with --no-cache."
      echo "    -y                                Force installation without prompting."
      echo "    -o                                Install Orthanc integration."
      echo "    -p DB_PERSISTENCE_PATH            Specify a path for persistent storage."
      echo "    -u                                Update an existing installation."
      echo ""      
      exit 0
      ;;
    y )
      FORCE_INSTALL="y"
      ;;
    d )
      DO_DEV_INSTALL=true
      ;;
    b )
      DOCKER_BUILD=true
      ;;
    n )
      NO_CACHE=true
      ;;
    o )
      INSTALL_ORTHANC=true
      ;;
    p )
      echo "DEBUG: Processing -p option, OPTARG='$OPTARG'"
      DB_PERSISTENCE_PATH=$OPTARG
      echo "DEBUG: Set DB_PERSISTENCE_PATH='$DB_PERSISTENCE_PATH'"
      ;;
    u )
      DO_OPERATION="update"
      ;;
    \? )
      echo "Invalid Option: -${OPTARG:-?}" 1>&2
      exit 1
      ;;
    : )
      echo "Invalid Option: -${OPTARG:-?} requires an argument" 1>&2
      exit 1
      ;;
  esac
done

# Re-enable set -u for the rest of the script
set -u

# Debug output to see what was parsed
echo "DEBUG: Arguments processed: $@"
echo "DEBUG: DB_PERSISTENCE_PATH = '$DB_PERSISTENCE_PATH'"
echo "DEBUG: OPTIND = $OPTIND"

# Update paths based on DB_PERSISTENCE_PATH if it was set
if [ -n "$DB_PERSISTENCE_PATH" ]; then
  echo "DB_PERSISTENCE_PATH is set to $DB_PERSISTENCE_PATH. PostgreSQL data for Mercure and Orthanc will be stored there."
  DB_PATH=$DB_PERSISTENCE_PATH/postgres-db
  # Keep DATA_PATH and CONFIG_PATH at default locations
  echo "Updated paths:"
  echo "  Data folder:     $DATA_PATH (default location)"
  echo "  Config folder:   $CONFIG_PATH (default location)"
  echo "  Mercure DB:      $DB_PATH (custom persistence)"
  echo "  Orthanc storage:      $DB_PERSISTENCE_PATH/orthanc-storage (custom persistence)"
  # echo "  Orthanc Storage: $DB_PERSISTENCE_PATH/orthanc-storage (custom persistence)"
  echo ""
  
  # Fix NFS permissions if this is an NFS mount
  fix_nfs_permissions "$DB_PERSISTENCE_PATH"
else
  echo "Using default paths:"
  echo "  Data folder:     $DATA_PATH"
  echo "  Config folder:   $CONFIG_PATH"
  echo "  Database folder: $DB_PATH"
  echo ""
fi

if [ $DO_DEV_INSTALL == true ] && [ $DO_OPERATION == "update" ]; then 
  echo "Invalid option: cannot update a dev installation" 1>&2
  exit 1
fi

if [ $DO_OPERATION == "update" ]; then 
  docker_update
  exit 0
fi

if [ $FORCE_INSTALL = "y" ]; then
  echo "Forcing installation"
else
  read -p "Install mercure with Docker (y/n)? " ANS
  if [ "$ANS" = "y" ]; then
    echo "Installing mercure..."
  else
    echo "Installation aborted."
    exit 0
  fi
fi

docker_install

install_orthanc () {
  if [ $INSTALL_ORTHANC = true ]; then
    echo "## Installing Orthanc addon..."
    # Create orthanc directory
    create_folder "$MERCURE_BASE/addons/orthanc"
    
    # Copy orthanc files
    echo "## Copying Orthanc configuration files..."
    sudo cp -r "$MERCURE_SRC/addons/orthanc"/* "$MERCURE_BASE/addons/orthanc/"
    
    if [ -n "$DB_PERSISTENCE_PATH" ]; then
      echo "## Setting custom Orthanc persistence paths:"
      echo "  Storage:  $DB_PERSISTENCE_PATH/orthanc-storage"
            
      # Update storage volume path
      sudo sed -i -e "s;device: '/opt/mercure/addons/orthanc/orthanc-storage';device: '$DB_PERSISTENCE_PATH/orthanc-storage';g" "$MERCURE_BASE/addons/orthanc/docker-compose.yml"
      
      # Create directory
      create_folder "$DB_PERSISTENCE_PATH/orthanc-storage"
    fi

    # Update Orthanc configuration with generated database password
    echo "## Configuring Orthanc with database credentials..."
    if [ -f "$CONFIG_PATH/db.env" ]; then
      # Source the database environment to get the password
      source "$CONFIG_PATH/db.env"
      # Update Orthanc configuration with the actual password
      sudo sed -i "s/ChangePasswordHere/$POSTGRES_PASSWORD/g" "$MERCURE_BASE/addons/orthanc/orthanc.json"
      echo "✓ Updated Orthanc configuration with database password"
      
      # Create Orthanc database in PostgreSQL
      echo "## Creating Orthanc database..."
      if sudo docker ps | grep -q mercure_db_1; then
        # Wait for database to be ready
        echo "Waiting for database to be ready..."
        timeout 30s bash -c 'until sudo docker exec mercure_db_1 pg_isready -U mercure; do sleep 1; done' || true
        
        # Create Orthanc database
        sudo docker exec mercure_db_1 psql -U mercure -d mercure -c "CREATE DATABASE orthanc;" 2>/dev/null || echo "Database 'orthanc' may already exist"
        echo "✓ Orthanc database created"
      else
        echo "Warning: Database container not running. Orthanc database will be created when services start."
      fi
    else
      echo "Warning: Database configuration not found. Orthanc may not connect to database."
    fi
    
    # Set permissions
    sudo chown -R $OWNER:$OWNER "$MERCURE_BASE/addons/orthanc"
    
    # Ensure network exists
    echo "## Setting up Docker network..."
    sudo docker network inspect mercure_default >/dev/null 2>&1 || \
      sudo docker network create mercure_default
    
    # Start orthanc
    echo "## Starting Orthanc services..."
    pushd "$MERCURE_BASE/addons/orthanc"
    sudo docker compose up -d
    echo "✓ Orthanc addon installed successfully"
    popd
  fi
}

# Install Orthanc if requested
install_orthanc

echo "Installation complete"

# Function to install Orthanc on existing installations
install_orthanc_standalone() {
  echo "## Installing Orthanc addon on existing installation..."
  
  # Check if Mercure is installed
  if [ ! -d "$MERCURE_BASE" ]; then
    echo "Error: Mercure not found at $MERCURE_BASE. Please install Mercure first."
    exit 1
  fi
  
  # Check if database configuration exists
  if [ ! -f "$CONFIG_PATH/db.env" ]; then
    echo "Error: Database configuration not found. Please run Mercure installation first."
    exit 1
  fi
  
  # Set installation variables
  INSTALL_ORTHANC=true
  OWNER=mercure
  
  # Install Orthanc
  install_orthanc
  
  echo "Orthanc installation complete!"
}

# Check if this is a standalone Orthanc installation
if [ $# -eq 1 ] && [ "$1" = "orthanc" ]; then
  install_orthanc_standalone
  exit 0
fi