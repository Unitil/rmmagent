#!/usr/bin/env bash

siteURL='siteURLChange' # ex:// example.com

# MeshCentral Info
meshID='meshIDChange'   # Login to meshcentral > My Devices > TacticalRMM > Add Agent > Linux / BSD > Copy long string
meshDL="https://mesh.${siteURL}/meshagents?id=${meshID}&installflags=0&meshinstall=6"

# TacticalRMM Info
# Login to tacticalrmm > menu > Agents > Install Agent > Select Client/Site > Windows > Manual > Show Manual Installation Instructions
# auth > token
# client-id > clientID
# site-id > siteID
# agent-type > agnetType

apiURL="https://api.${siteURL}"
token='tokenChange'
clientID='clientIDChange'
siteID='siteIDChange'
agentType='workstation'
proxy=''

agentBinPath='/usr/local/bin'
binName='tacticalagent'
agentBin="${agentBinPath}/${binName}"
agentConf='/etc/tacticalagent'
agentSvcName='tacticalagent.service'
agentSysD="/etc/systemd/system/${agentSvcName}"
meshDir='/opt/tacticalmesh'
meshSystemBin="${meshDir}/meshagent"
meshSvcName='meshagent.service'
meshSysD="/lib/systemd/system/${meshSvcName}"

deb=(ubuntu debian raspbian kali linuxmint)
rhe=(fedora rocky centos rhel amzn arch opensuse)

set_locale_deb() {
    locale-gen "en_US.UTF-8"
    localectl set-locale LANG=en_US.UTF-8
    . /etc/default/locale
}

set_locale_rhel() {
    localedef -c -i en_US -f UTF-8 en_US.UTF-8 >/dev/null 2>&1
    localectl set-locale LANG=en_US.UTF-8
    . /etc/locale.conf
}

# install_dependencies - install necessary packages to run this script
install_dependencies() {
    set +e

	echo "checking dependencies..."

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
		echo "OS unsupported for automatic dependency install"
		exit 1
	fi
	set -- $dependencies

	${update_cmd}

	while [ -n "$1" ]; do
		if [ "${OS}" = "FreeBSD" ]; then
			is_installed=$(pkg check -d $1 | grep "Checking" | grep "done")
			if [ "$is_installed" != "" ]; then
				echo "  " $1 is installed
			else
				echo "  " $1 is not installed. Attempting install.
				${install_cmd} $1
				sleep 5
				is_installed=$(pkg check -d $1 | grep "Checking" | grep "done")
				if [ "$is_installed" != "" ]; then
					echo "  " $1 is installed
				elif [ -x "$(command -v $1)" ]; then
					echo "  " $1 is installed
				else
					echo "  " FAILED TO INSTALL $1
					echo "  " This may break functionality.
				fi
			fi
		else
			if [ "${OS}" = "OpenWRT" ] || [ "${OS}" = "TurrisOS" ]; then
				is_installed=$(opkg list-installed $1 | grep $1)
			else
				is_installed=$(dpkg-query -W --showformat='${Status}\n' $1 | grep "install ok installed")
			fi
			if [ "${is_installed}" != "" ]; then
				echo "    " $1 is installed
			else
				echo "    " $1 is not installed. Attempting install.
				${install_cmd} $1
				sleep 5
				if [ "${OS}" = "OpenWRT" ] || [ "${OS}" = "TurrisOS" ]; then
					is_installed=$(opkg list-installed $1 | grep $1)
				else
					is_installed=$(dpkg-query -W --showformat='${Status}\n' $1 | grep "install ok installed")
				fi
				if [ "${is_installed}" != "" ]; then
					echo "    " $1 is installed
				elif [ -x "$(command -v $1)" ]; then
					echo "  " $1 is installed
				else
					echo "  " FAILED TO INSTALL $1
					echo "  " This may break functionality.
				fi
			fi
		fi
		shift
	done

	echo "-----------------------------------------------------"
	echo "dependency check complete"
	echo "-----------------------------------------------------"
}
set -e

hostCheckandAdd() {
    local ip="$1"
    local host="$2"

    if ! grep -q "${ip} ${host}" /etc/hosts; then
        echo "${ip} ${host}" | sudo tee -a /etc/hosts
        echo "Entry ${ip} ${host} added to the hostfile."
    else
        echo "Entry ${ip} ${host} is already in the hostfile."
    fi
}

RemoveOldAgent() {
    if [ -f "${agentSysD}" ]; then
        systemctl disable ${agentSvcName}
        systemctl stop ${agentSvcName}
        rm -f ${agentSysD}
        systemctl daemon-reload
    fi

    if [ -f "${agentConf}" ]; then
        rm -f ${agentConf}
    fi

    if [ -f "${agentBin}" ]; then
        rm -f ${agentBin}
    fi
}

InstallMesh() {
    if [ -f /etc/os-release ]; then
        distroID=$(
            . /etc/os-release
            echo $ID
        )
        distroIDLIKE=$(
            . /etc/os-release
            echo $ID_LIKE
        )
        if [[ " ${deb[*]} " =~ " ${distroID} " ]]; then
            set_locale_deb
        elif [[ " ${deb[*]} " =~ " ${distroIDLIKE} " ]]; then
            set_locale_deb
        elif [[ " ${rhe[*]} " =~ " ${distroID} " ]]; then
            set_locale_rhel
        else
            set_locale_rhel
        fi
    fi

    meshTmpDir='/root/meshtemp'
    mkdir -p $meshTmpDir

    meshTmpBin="${meshTmpDir}/meshagent"
    wget --no-check-certificate -q -O ${meshTmpBin} ${meshDL}
    chmod +x ${meshTmpBin}
    mkdir -p ${meshDir}
    env LC_ALL=en_US.UTF-8 LANGUAGE=en_US XAUTHORITY=foo DISPLAY=bar ${meshTmpBin} -install --installPath=${meshDir}
    sleep 1
    rm -rf ${meshTmpDir}
}

RemoveMesh() {
    if [ -f "${meshSystemBin}" ]; then
        env XAUTHORITY=foo DISPLAY=bar ${meshSystemBin} -uninstall
        sleep 1
    fi

    if [ -f "${meshSysD}" ]; then
        systemctl stop ${meshSvcName} >/dev/null 2>&1
        systemctl disable ${meshSvcName} >/dev/null 2>&1
        rm -f ${meshSysD}
    fi

    rm -rf ${meshDir}
    systemctl daemon-reload
}

Uninstall() {
    RemoveMesh
    RemoveOldAgent
}

if [ $EUID -ne 0 ]; then
    echo "ERROR: Must be run as root"
    exit 1
fi

HAS_SYSTEMD=$(ps --no-headers -o comm 1)
if [ "${HAS_SYSTEMD}" != 'systemd' ]; then
    echo "This install script only supports systemd"
    echo "Please install systemd or manually create the service using your systems's service manager"
    exit 1
fi

# Script dependencies install
install_dependencies

# Check architecture and set agentDL download URL
ARCH=$(uname -m)

AGENTVER=$(curl -s "https://api.github.com/repos/Unitil/rmmagent/releases/latest" | jq -r ".tag_name")
baseURL="https://github.com/Unitil/rmmagent/releases/download/${AGENTVER}"

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
        echo "Unsupported OS/architecture combination: linux/$ARCH"
        exit 1
        ;;
esac

if [ $# -ne 0 ] && [ $1 == 'uninstall' ]; then
    Uninstall
    exit 0
fi

RemoveOldAgent

# Uncomment to check for and modify host file
# hostCheckandAdd "192.168.10.252" "mesh.${siteURL}"
# hostCheckandAdd "192.168.10.252" "api.${siteURL}"
# hostCheckandAdd "192.168.10.252" "rmm.${siteURL}"

echo "Downloading tactical agent..."
wget -q -O ${agentBin} "${agentDL}"
if [ $? -ne 0 ]; then
    echo "ERROR: Unable to download tactical agent"
    exit 1
fi
chmod +x ${agentBin}

MESH_NODE_ID=""

if [ $# -ne 0 ] && [ $1 == '--nomesh' ]; then
    echo "Skipping mesh install"
else
    if [ -f "${meshSystemBin}" ]; then
        RemoveMesh
    fi
    echo "Downloading and installing mesh agent..."
    InstallMesh
    sleep 2
    echo "Getting mesh node id..."
    MESH_NODE_ID=$(env XAUTHORITY=foo DISPLAY=bar ${agentBin} -m nixmeshnodeid)
fi

if [ ! -d "${agentBinPath}" ]; then
    echo "Creating ${agentBinPath}"
    mkdir -p ${agentBinPath}
fi

if [ $# -ne 0 ] && [ $1 == '--debug' ]; then
    INSTALL_CMD="${agentBin} -m install -api ${apiURL} -client-id ${clientID} -site-id ${siteID} -agent-type ${agentType} -auth ${token} -log debug"
else
    INSTALL_CMD="${agentBin} -m install -api ${apiURL} -client-id ${clientID} -site-id ${siteID} -agent-type ${agentType} -auth ${token}"
fi

if [ "${MESH_NODE_ID}" != '' ]; then
    INSTALL_CMD+=" -meshnodeid ${MESH_NODE_ID}"
fi

if [ "${proxy}" != '' ]; then
    INSTALL_CMD+=" -proxy ${proxy}"
fi

eval ${INSTALL_CMD}

tacticalsvc="$(
    cat <<EOF
[Unit]
Description=Tactical RMM Linux Agent

[Service]
Type=simple
ExecStart=${agentBin} -m svc
User=root
Group=root
Restart=always
RestartSec=5s
LimitNOFILE=1000000
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
)"
echo "${tacticalsvc}" | tee ${agentSysD} >/dev/null

systemctl daemon-reload
systemctl enable ${agentSvcName}
systemctl start ${agentSvcName}