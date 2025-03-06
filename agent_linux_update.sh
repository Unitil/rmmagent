#!/usr/bin/env bash

# Set up logging
LOG_FILE="/var/log/tacticalrmm_update.log"
# Truncate log file
echo "Starting update script at $(date)" > ${LOG_FILE}

log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" | tee -a ${LOG_FILE}
}

log "Initializing TacticalRMM agent update script"

if [ $EUID -ne 0 ]; then
    log "ERROR: Must be run as root"
    exit 1
fi

HAS_SYSTEMD=$(ps --no-headers -o comm 1)
if [ "${HAS_SYSTEMD}" != 'systemd' ]; then
    log "This install script only supports systemd"
    log "Please install systemd or manually create the service using your systems's service manager"
    exit 1
fi

# Variables
agentBinPath='/usr/local/bin'
binName='tacticalagent'
agentBin="${agentBinPath}/${binName}"
agentSvcName='tacticalagent.service'
updateScriptPath="/tmp/tactical_update_helper.sh"

log "Using binary path: ${agentBin}"
log "Creating helper script at ${updateScriptPath}"

# Create a secondary script that will handle the actual update
cat > ${updateScriptPath} << 'EOF'
#!/usr/bin/env bash

# Set up logging
LOG_FILE="/var/log/tacticalrmm_update.log"

log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" | tee -a ${LOG_FILE}
}

# Set variables (these need to be duplicated in the helper script)
agentBinPath='/usr/local/bin'
binName='tacticalagent'
agentBin="${agentBinPath}/${binName}"
agentSvcName='tacticalagent.service'

# Function to install dependencies
install_dependencies() {
    set +e

    log "Checking dependencies..."

    OS=$(uname)
    if [ -f /etc/debian_version ]; then
        dependencies="curl wget jq"
        update_cmd='apt update'
        install_cmd='apt-get install -y'
    elif [ -f /etc/alpine-release ]; then
        dependencies="curl wget jq"
        update_cmd='apk update'
        install_cmd='apk --update add'
    elif [ -f /etc/centos-release ]; then
        dependencies="curl wget jq"
        update_cmd='yum update'
        install_cmd='yum install -y'
    elif [ -f /etc/fedora-release ]; then
        dependencies="curl wget jq"
        update_cmd='dnf update'
        install_cmd='dnf install -y'
    elif [ -f /etc/redhat-release ]; then
        dependencies="curl wget jq"
        update_cmd='yum update'
        install_cmd='yum install -y'
    elif [ -f /etc/arch-release ]; then
        dependencies="curl wget jq"
        update_cmd='pacman -Sy'
        install_cmd='pacman -S --noconfirm'
    elif [ "${OS}" = "FreeBSD" ]; then
        dependencies="curl wget jq"
        update_cmd='pkg update'
        install_cmd='pkg install -y'
    else
        install_cmd=''
    fi

    if [ -z "${install_cmd}" ]; then
        log "OS unsupported for automatic dependency install"
        exit 1
    fi
    set -- $dependencies

    log "Running: ${update_cmd}"
    ${update_cmd}

    while [ -n "$1" ]; do
        if [ "${OS}" = "FreeBSD" ]; then
            is_installed=$(pkg check -d $1 | grep "Checking" | grep "done")
            if [ "$is_installed" != "" ]; then
                log "$1 is installed"
            else
                log "$1 is not installed. Attempting install."
                ${install_cmd} $1
                sleep 5
                is_installed=$(pkg check -d $1 | grep "Checking" | grep "done")
                if [ "$is_installed" != "" ]; then
                    log "$1 is installed"
                elif [ -x "$(command -v $1)" ]; then
                    log "$1 is installed"
                else
                    log "FAILED TO INSTALL $1"
                    log "This may break functionality."
                fi
            fi
        else
            if [ "${OS}" = "OpenWRT" ] || [ "${OS}" = "TurrisOS" ]; then
                is_installed=$(opkg list-installed $1 | grep $1)
            else
                is_installed=$(dpkg-query -W --showformat='${Status}\n' $1 | grep "install ok installed")
            fi
            if [ "${is_installed}" != "" ]; then
                log "$1 is installed"
            else
                log "$1 is not installed. Attempting install."
                ${install_cmd} $1
                sleep 5
                if [ "${OS}" = "OpenWRT" ] || [ "${OS}" = "TurrisOS" ]; then
                    is_installed=$(opkg list-installed $1 | grep $1)
                else
                    is_installed=$(dpkg-query -W --showformat='${Status}\n' $1 | grep "install ok installed")
                fi
                if [ "${is_installed}" != "" ]; then
                    log "$1 is installed"
                elif [ -x "$(command -v $1)" ]; then
                    log "$1 is installed"
                else
                    log "FAILED TO INSTALL $1"
                    log "This may break functionality."
                fi
            fi
        fi
        shift
    done

    log "Dependency check complete"
}
set -e

# Wait a moment to ensure the parent script has exited
log "Helper script started, waiting 2 seconds before continuing..."
sleep 2

# Install dependencies
install_dependencies

# Stop tactical agent service
log "Stopping TacticalRMM agent service (${agentSvcName})..."
systemctl stop ${agentSvcName}
log "Service stopped"

# Check architecture and set agentDL download URL
log "Fetching latest version information..."
AGENTVER=$(curl -s "https://api.github.com/repos/Unitil/rmmagent/releases/latest" | jq -r ".tag_name")
baseURL="https://github.com/Unitil/rmmagent/releases/download/${AGENTVER}"
log "Latest agent version: ${AGENTVER}"

ARCH=$(uname -m)
log "Detected architecture: ${ARCH}"

case "$ARCH" in
    i386 | i486 | i586 | i686)
        agentDL="${baseURL}/rmmagent-linux-386"
        ;;
    x86_64)
        agentDL="${baseURL}/rmmagent-linux-amd64"
        ;;
    arm64 | aarch64)
        agentDL="${baseURL}/rmmagent-linux-arm64"
        ;;
    armv5*)
        agentDL="${baseURL}/rmmagent-linux-armv5"
        ;;
    armv6*)
        agentDL="${baseURL}/rmmagent-linux-armv6"
        ;;
    armv7*)
        agentDL="${baseURL}/rmmagent-linux-armv7"
        ;;
    *)
        log "Unsupported OS/architecture combination: linux/$ARCH"
        exit 1
        ;;
esac

log "Using download URL: ${agentDL}"

if [ ! -d "${agentBinPath}" ]; then
    log "Creating ${agentBinPath}"
    mkdir -p ${agentBinPath}
fi

log "Backing up existing agent binary..."
if [ -f "${agentBin}" ]; then
    cp ${agentBin} ${agentBin}.bak
    log "Backup created at ${agentBin}.bak"
fi

log "Downloading new tactical agent..."
wget -q -O ${agentBin}.new "${agentDL}"
if [ $? -ne 0 ]; then
    log "ERROR: Unable to download tactical agent"
    if [ -f "${agentBin}.bak" ]; then
        log "Restoring from backup..."
        mv ${agentBin}.bak ${agentBin}
    fi
    exit 1
fi

log "Setting executable permissions..."
chmod +x ${agentBin}.new

log "Replacing binary..."
mv ${agentBin}.new ${agentBin}
log "Binary updated successfully"

# Start the service
log "Starting TacticalRMM agent service..."
systemctl start ${agentSvcName}
log "Service started"

# Check if service is running
sleep 2
if systemctl is-active --quiet ${agentSvcName}; then
    log "Service is running correctly"
else
    log "WARNING: Service failed to start properly"
    systemctl status ${agentSvcName} >> ${LOG_FILE} 2>&1
fi

# Clean up this script
log "Update completed successfully, cleaning up..."
rm -- "$0"
EOF

# Make the helper script executable
chmod +x ${updateScriptPath}

# Run the helper script in the background
log "Starting update process in the background..."
nohup ${updateScriptPath} > /dev/null 2>&1 &

# Exit so this script can terminate without affecting the update
log "Main script exiting. Check ${LOG_FILE} for progress."
exit 0