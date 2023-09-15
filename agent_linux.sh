#!/usr/bin/env bash

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

#############################################################
# Variables
#############################################################

siteURL='changeMe' # ex:// example.com

# MeshCentral Info
# Login to meshcentral > My Devices > TacticalRMM > Add Agent > Linux / BSD > Copy long string
meshID='changeMe'
meshURL="https://mesh.${siteURL}"

# TacticalRMM Info
# Login to tacticalrmm > menu > Agents > Install Agent > Select Client/Site > Windows > Manual > Show Manual Installation Instructions
# auth > token
# client-id > clientID
# site-id > siteID
# agent-type > agentType

apiURL="https://api.${siteURL}"
token='changeMe'
clientID='changeMe'
siteID='changeMe'
agentType='changeMe'
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
meshProxy=''

deb=(ubuntu debian raspbian kali linuxmint)
rhe=(fedora rocky centos rhel amzn arch opensuse)

DEBUG=0
INSECURE=0
NOMESH=0

MESH_NODE_ID=""

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

#############################################################
# Functions
#############################################################

checkVariables() {
  if [[ "$siteURL" == "changeMe" ]] || \
     [[ "$meshID" == "changeMe" ]] || \
     [[ "$token" == "changeMe" ]] || \
     [[ "$clientID" == "changeMe" ]] || \
     [[ "$siteID" == "changeMe" ]] || \
     [[ "$agentType" == "changeMe" ]]; then
    echo "One or more variables are set to 'changeMe'. Exiting the script."
    exit 1
  fi
}

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

UpdateMshFile() {
  # Remove all lines that start with "StartupType="
  meshTmpDir='/root/meshtemp'
  sed '/^StartupType=/ d' < "${meshTmpDir}/meshagent.msh" >> "${meshTmpDir}/meshagent2.msh"
  # Add the startup type to the file
  echo "StartupType=$starttype" >> "${meshTmpDir}/meshagent2.msh"
  mv "${meshTmpDir}/meshagent2.msh" "${meshTmpDir}/meshagent.msh"
}

CheckStartupType() {
  # 1 = Systemd
  # 2 = Upstart
  # 3 = init.d
  # 5 = BSD

  # echo "Checking if Linux or BSD Platform"
  plattype=`uname | awk '{ tst=tolower($0);a=split(tst, res, "bsd"); if(a==1) { print "LINUX"; } else { print "BSD"; }}'`
  if [[ $plattype == 'BSD' ]]
   then return 5;
  fi

  # echo "Checking process autostart system..."
  starttype1=`cat /proc/1/status | grep 'Name:' | awk '{ print $2; }'`
  starttype2=`ps -p 1 -o command= | awk '{a=split($0,res," "); b=split(res[a],tp,"/"); print tp[b]; }'`

  # Systemd
  if [[ $starttype1 == 'systemd' ]]
    then return 1;
  elif [[ $starttype1 == 'init'  ||  $starttype2 == 'init' ]]
    then
        if [ -d "/etc/init" ]
            then
                return 2;
            else
                return 3;
        fi
  fi
  return 0;
}

CheckMeshInstallAgent() {
  # echo "Checking mesh identifier..."
  if [ $# -ge 2 ]
  then
    uninstall=$1
    url=$2
    meshid=$3

    if [[ $4 =~ ^--WebProxy= ]];
    then
       webproxy=$4
    fi
    meshidlen=${#meshid}
    if [ $meshidlen -gt 63 ]
    then
      machineid=0
      machinetype=$( uname -m )

      # If we have 3 arguments...
      if [ $# -ge 4 ] &&  [ -z "$webproxy" ]
      then
        # echo "Computer type is specified..."
        machineid=$4
      else
        # echo "Detecting computer type..."
        if [ $machinetype == 'x86_64' ] || [ $machinetype == 'amd64' ]
        then
          if [ $starttype -eq 5 ]
          then
            # FreeBSD x86, 64 bit
            machineid=30
          else
            # Linux x86, 64 bit
            bitlen=$( getconf LONG_BIT )
            if [ $bitlen == '32' ]
            then
                # 32 bit OS
                machineid=5
            else
                # 64 bit OS
                machineid=6
            fi
          fi
        fi
        if [ $machinetype == 'x86' ] || [ $machinetype == 'i686' ] || [ $machinetype == 'i586' ]
        then
          if [ $starttype -eq 5 ]
          then
            # FreeBSD x86, 32 bit
            machineid=31
          else
            # Linux x86, 32 bit
            machineid=5
          fi
        fi
        if [ $machinetype == 'armv6l' ] || [ $machinetype == 'armv7l' ]
        then
          # RaspberryPi 1 (armv6l) or RaspberryPi 2/3 (armv7l)
          machineid=25
        fi
        if [ $machinetype == 'aarch64' ]
        then
          # RaspberryPi 3B+ running Ubuntu 64 (aarch64)
          machineid=26
        fi
        # Add more machine types, detect KVM support... here.
      fi

      if [ $machineid -eq 0 ]
      then
        echo "Unsupported machine type: $machinetype."
      else
        DownloadMeshAgent $uninstall $url $meshid $machineid
      fi

    else
      echo "Device group identifier is not correct, must be at least 64 characters long."
      exit 1
    fi
  else
    echo "URI and/or device group identifier have not been specified, must be passed in as arguments."
    return 0;
  fi
}

DownloadMeshAgent() {
  uninstall=$1
  url=$2
  meshid=$3
  machineid=$4

  meshTmpDir='/root/meshtemp'
  mkdir -p $meshTmpDir

  echo "Downloading agent #$machineid..."
  meshTmpBin="${meshTmpDir}/meshagent"
  wget $url/meshagents?id=$machineid -O ${meshTmpBin} || curl -L --output ${meshTmpBin} $url/meshagents?id=$machineid

  # If it did not work, try again using http
  if [ $? != 0 ]
  then
    url=${url/"https://"/"http://"}
    wget $url/meshagents?id=$machineid -O ${meshTmpBin} || curl -L --output ${meshTmpBin} $url/meshagents?id=$machineid
  fi

  if [ $? -eq 0 ]
  then
    echo "Agent downloaded."

    chmod +x ${meshTmpBin}
    mkdir -p ${meshDir}

    # TODO: We could check the meshagent sha256 hash, but best to authenticate the server.
    chmod 755 ${meshTmpBin}
    meshTmpMsh="${meshTmpDir}/meshagent.msh"
    wget $url/meshsettings?id=$meshid -O ${meshTmpMsh} || curl -L --output ${meshTmpMsh} $url/meshsettings?id=$meshid

    # If it did not work, try again using http
    if [ $? -ne 0 ]
    then
      wget $url/meshsettings?id=$meshid -O ${meshTmpMsh} || curl -L --output ${meshTmpMsh} $url/meshsettings?id=$meshid
    fi

    if [ $? -eq 0 ]
    then
      # Update the .msh file and run the agent installer
      UpdateMshFile
      env LC_ALL=en_US.UTF-8 LANGUAGE=en_US XAUTHORITY=foo DISPLAY=bar ${meshTmpBin} -install --copy-msh=1 --installPath=${meshDir} $webproxy
    sleep 1
    rm -rf ${meshTmpDir}
    else
      echo "Unable to download device group settings at: $url/meshsettings?id=$meshid."
      exit 1
    fi

  else
    echo "Unable to download agent at: $url/meshagents?id=$machineid."
    exit 1
  fi
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

Uninstall() {
    RemoveMesh
    RemoveOldAgent
}

#############################################################
# Script Execution
#############################################################

# Check if any variables are set to 'changeMe'
checkVariables

# Script dependencies install
install_dependencies

CheckStartupType
starttype=$?

# Uncomment to check for and modify host file -- Mainly for devices on same LAN
# hostCheckandAdd "192.168.10.252" "mesh.${siteURL}"
# hostCheckandAdd "192.168.10.252" "api.${siteURL}"
# hostCheckandAdd "192.168.10.252" "rmm.${siteURL}"

# Check architecture and set agentDL download URL
AGENTVER=$(curl -s "https://api.github.com/repos/Unitil/rmmagent/releases/latest" | jq -r ".tag_name")
baseURL="https://github.com/Unitil/rmmagent/releases/download/${AGENTVER}"

ARCH=$(uname -m)
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

while [[ "$#" -gt 0 ]]; do
    case $1 in
    --debug) DEBUG=1 ;;
    --insecure) INSECURE=1 ;;
    --nomesh) NOMESH=1 ;;
    *)
        echo "ERROR: Unknown parameter: $1"
        exit 1
        ;;
    esac
    shift
done

RemoveOldAgent

# Set locale
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

echo "Downloading tactical agent..."
wget -q -O ${agentBin} "${agentDL}"
if [ $? -ne 0 ]; then
    echo "ERROR: Unable to download tactical agent"
    exit 1
fi
chmod +x ${agentBin}

if [[ $NOMESH -eq 1 ]]; then
    echo "Skipping mesh install"
else
    if [ -f "${meshSystemBin}" ]; then
        RemoveMesh
    fi
    echo "Downloading and installing mesh agent..."
    if [[ -n "${meshProxy}" ]]; then
      CheckMeshInstallAgent 'install' ${meshURL} ${meshID} ${meshProxy}
    else
      CheckMeshInstallAgent 'install' ${meshURL} ${meshID}
    fi
    sleep 2
    echo "Getting mesh node id..."
    MESH_NODE_ID=$(env XAUTHORITY=foo DISPLAY=bar ${agentBin} -m nixmeshnodeid)
fi

if [ ! -d "${agentBinPath}" ]; then
    echo "Creating ${agentBinPath}"
    mkdir -p ${agentBinPath}
fi

INSTALL_CMD="${agentBin} -m install -api ${apiURL} -client-id ${clientID} -site-id ${siteID} -agent-type ${agentType} -auth ${token}"

if [ "${MESH_NODE_ID}" != '' ]; then
    INSTALL_CMD+=" --meshnodeid ${MESH_NODE_ID}"
fi

if [[ $DEBUG -eq 1 ]]; then
    INSTALL_CMD+=" --log debug"
fi

if [[ $INSECURE -eq 1 ]]; then
    INSTALL_CMD+=" --insecure"
fi

if [ "${proxy}" != '' ]; then
    INSTALL_CMD+=" --proxy ${proxy}"
fi

eval ${INSTALL_CMD}

# Create and run systemd service
echo "${tacticalsvc}" | tee ${agentSysD} >/dev/null

systemctl daemon-reload
systemctl enable ${agentSvcName}
systemctl start ${agentSvcName}