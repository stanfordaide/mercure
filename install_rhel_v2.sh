#!/bin/bash
set -euo pipefail

error() {
  local parent_lineno="$1"
  local code="${3:-1}"
  echo "Error on or near line ${parent_lineno}"
  exit "${code}"
}
trap 'error ${LINENO}' ERR

# Check for RHEL version
if [ -f /etc/redhat-release ]; then
  RHEL_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | cut -d. -f1)
  if [ "$RHEL_VERSION" != "8" ] && [ "$RHEL_VERSION" != "9" ]; then
    echo "Invalid operating system!"
    echo "This mercure version requires RHEL 8 or RHEL 9"
    echo "Detected operating system = RHEL $RHEL_VERSION"
    exit 1
  fi
else
  echo "Invalid operating system!"
  echo "This mercure version requires RHEL 8 or RHEL 9"
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
  OWNER=$(logname 2>/dev/null || echo "root")
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
echo "Data folder:          $DATA_PATH"
echo "Config folder:        $CONFIG_PATH"
echo "Database folder:      $DB_PATH"
echo "Source folder:        $MERCURE_SRC"
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
    sudo dnf remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine || true
    sudo dnf install -y dnf-plugins-core
    sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
    sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    # Restart docker to make sure we get the latest version of the daemon if there is an upgrade
    sudo systemctl enable docker
    sudo systemctl start docker
    # Make sure we can actually use docker as the vagrant user
    sudo usermod -a -G docker $OWNER
    sudo docker --version
  fi

  if [ ! -x "$(command -v docker-compose)" ]; then 
    echo "## Installing Docker-Compose..."
    sudo curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    sudo docker-compose --version
  fi
}

setup_docker () {
  local overwrite=${1:-false}
  if [ "$overwrite" = true ] || [ ! -f "$MERCURE_BASE"/docker-compose.yml ]; then
    echo "## Copying docker-compose.yml..."
    sudo cp $MERCURE_SRC/docker/docker-compose.yml $MERCURE_BASE
    sudo sed -i -e "s/\\\${DOCKER_GID}/$(getent group docker | cut -d: -f3)/g" $MERCURE_BASE/docker-compose.yml
    sudo sed -i -e "s/\\\${UID}/$(getent passwd mercure | cut -d: -f3)/g" $MERCURE_BASE/docker-compose.yml
    sudo sed -i -e "s/\\\${GID}/$(getent passwd mercure | cut -d: -f4)/g" $MERCURE_BASE/docker-compose.yml

    if [[ -v MERCURE_TAG ]]; then # a custom tag was provided
      sudo sed -i "s/\\\${IMAGE_TAG}/\:$MERCURE_TAG/g" $MERCURE_BASE/docker-compose.yml
    else
      sudo sed -i "s/\\\${IMAGE_TAG}/$IMAGE_TAG/g" $MERCURE_BASE/docker-compose.yml
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
      sudo sed -i "s/\\\${IMAGE_TAG}/\:$MERCURE_TAG/g" $MERCURE_BASE/docker-compose.override.yml
    else # no custom tag was provided, use latest
      sudo sed -i "s/\\\${IMAGE_TAG}/\:latest/g" $MERCURE_BASE/docker-compose.override.yml
    fi
    sudo chown $OWNER:$OWNER "$MERCURE_BASE"/docker-compose.override.yml
  fi
}

build_docker () {
  echo "## Building mercure docker containers..."  
  sudo $MERCURE_SRC/build-docker.sh -y
}

start_docker () {
  echo "## Starting docker compose..."  
  pushd $MERCURE_BASE
  sudo docker-compose up -d
  popd
}

docker_install () {
  echo "## Performing docker-type mercure installation..."
  create_user
  create_folders
  install_configuration
  install_docker
  if [ $DOCKER_BUILD = true ]; then
    build_docker
  fi
  setup_docker
  if [ $DO_DEV_INSTALL = true ]; then
    setup_docker_dev
  fi
  start_docker
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
  pushd $MERCURE_BASE
  sudo docker-compose down || true
  popd
  setup_docker true
  start_docker
}

# Initialize default values
FORCE_INSTALL="n"
DO_DEV_INSTALL=false
DOCKER_BUILD=false
DO_OPERATION="install"
INSTALL_METABASE=false

# Parse all options in one go
while getopts ":hydbum" opt; do
  case ${opt} in
    h )
      echo "Usage:"
      echo ""
      echo "    install.sh -h                      Display this help message."
      echo "    install.sh [-y] [-dbum]            Install with docker-compose."
      echo ""
      echo "Options:   "
      echo "                      -y               Force install (no prompts)."
      echo "                      -d               Development mode."
      echo "                      -b               Build containers."
      echo "                      -u               Update installation."
      echo "                      -m               Install Metabase for reporting."
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
    u )
      DO_OPERATION="update"
      ;;
    m )
      INSTALL_METABASE=true
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
  read -p "Install with docker (y/n)? " ANS
  if [ "$ANS" = "y" ]; then
    echo "Installing mercure..."
  else
    echo "Installation aborted."
    exit 0
  fi
fi

docker_install

echo "Installation complete"

if [ $INSTALL_METABASE == true ]; then
  sudo dnf install -y jq
  echo "Initializing Metabase setup..."
  pushd addons/metabase
  sudo ./metabase_install.sh docker
  popd
fi