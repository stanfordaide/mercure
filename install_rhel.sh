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
echo "Data folder:         $DATA_PATH"
echo "Config folder:       $CONFIG_PATH"
echo "Database folder:     $DB_PATH"
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
    echo "POSTGRES_PASSWORD=$DB_PWD" > "$CONFIG_PATH"/db.env

    sed -i -e "s/mercure:ChangePasswordHere@localhost/mercure:$DB_PWD@db/" "$CONFIG_PATH"/bookkeeper.env
    sed -i -e "s/0.0.0.0:8080/bookkeeper:8080/" "$CONFIG_PATH"/mercure.json
    
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

while getopts ":hydbno" opt; do
  case ${opt} in
    h )
      echo "Usage:"
      echo ""
      echo "    install_rhel.sh -h                Display this help message."
      echo "    install_rhel.sh [-y] [-dbn]       Install with docker-compose."
      echo ""
      echo "Options:"
      echo "    -d                                Development mode."
      echo "    -b                                Build containers."
      echo "    -n                                Build containers with --no-cache."
      echo "    -y                                Force installation without prompting."
      echo "    -o                                Install Orthanc integration."
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
    \? )
      echo "Invalid Option: -$OPTARG" 1>&2
      exit 1
      ;;
    : )
      echo "Invalid Option: -$OPTARG requires an argument" 1>&2
      exit 1
      ;;
  esac
done
shift $((OPTIND -1))

while getopts ":u" opt; do
  case ${opt} in
    u )
      DO_OPERATION="update"
      ;;
    \? )
      echo "Invalid Option: -$OPTARG" 1>&2
      exit 1
      ;;
  esac
done

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