#!/bin/sh -e
MY_COMMAND="$0 $*"
exit_trap() {
  # shellcheck disable=SC2181
  if [ $? -eq 0 ]; then
    return 0
  fi
  echo ""
  echo "An error occurred."
  echo "Try running in debug mode with 'sh -x ${MY_COMMAND}'"
  echo ""
}
trap exit_trap EXIT

# BEGINNING of templates/header.txt ----------------------------------------------------------------------------------|

##
## This is the RPort client installer script.
## It helps you to quickly install the rport client on a variety of Linux distributions.
## The scripts creates a initial configuration and connects the client to your server.
##
##
## Copyright RealVNC Limited, Cambridge, UK, 2023
##
# END of templates/header.txt ----------------------------------------------------------------------------------------|

## BEGINNING of rendered template templates/linux/installer_vars.sh
#
# Dynamically inserted variables
#
FINGERPRINT="84:00:ba:78:6a:a5:c1:f9:51:30:ed:ff:7e:c3:6f:b0"
CONNECT_URL="http://gz5xxhkfepsa.users.rport.io:80"
CLIENT_ID="BIJELJINA-1A"
PASSWORD="cssCmA01md.BUBh"

#
# Global static installer vars
#
TMP_FOLDER=/tmp/rport-install
FORCE=1
USE_ALTERNATIVE_MACHINEID=0
LOG_DIR=/var/log/rport
LOG_FILE=${LOG_DIR}/rport.log
## END of rendered template templates/linux/installer_vars.sh


# BEGINNING of templates/linux/vars.sh -------------------------------------------------------------------------------|

#
# Global Variables for installation and update
#
CONF_DIR=/etc/rport
CONFIG_FILE=${CONF_DIR}/rport.conf
USER=rport
ARCH=$(uname -m | sed s/"armv\(6\|7\)l"/'armv\1'/ | sed s/aarch64/arm64/)
# END of templates/linux/vars.sh -------------------------------------------------------------------------------------|


# BEGINNING of templates/linux/functions.sh --------------------------------------------------------------------------|

set -e
if which tput >/dev/null 2>&1; then
    true
else
    alias tput=true
fi

throw_fatal() {
    echo 2>&1 "[!] $1"
    echo "[=] Fatal Exit. Don't give up. Good luck with the next try."
    false
}

throw_hint() {
    echo "[>] $1"
}

throw_info() {
    echo "$(tput setab 2 2>/dev/null)$(tput setaf 7 2>/dev/null)[*]$(tput sgr 0 2>/dev/null) $1"
}

throw_warning() {
    echo "[:] $1"
}

throw_debug() {
    echo "$(tput setab 4 2>/dev/null)$(tput setaf 7 2>/dev/null)[-]$(tput sgr 0 2>/dev/null) $1"
}

wait_for_rport() {
    i=0
    while [ "$i" -lt 40 ]; do
        pidof rport >/dev/null 2>&1 && return 0
        echo "$i waiting for rport process to come up ..."
        sleep 0.2
        i=$((i + 1))
    done
    return 1
}

is_rport_subprocess() {
    if [ -n "$1" ]; then
        SEARCH_PID=$1
    else
        SEARCH_PID=$$
    fi
    PARENT_PID=$(ps -o ppid= -p "$SEARCH_PID" | tr -d ' ')
    PARENT_NAME=$(ps -p "$PARENT_PID" -o comm=)
    if [ "$PARENT_NAME" = "rport" ]; then
        return 0
    elif [ "$PARENT_PID" -eq 1 ]; then
        return 1
    fi
    is_rport_subprocess "$PARENT_PID"
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  is_available
#   DESCRIPTION:  Check if a command is available on the system.
#    PARAMETERS:  command name
#       RETURNS:  0 if available, 1 otherwise
#----------------------------------------------------------------------------------------------------------------------
is_available() {
    if command -v "$1" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  uninstall
#   DESCRIPTION:  Uninstall everything and remove the user
#----------------------------------------------------------------------------------------------------------------------
uninstall() {
    if pgrep rportd >/dev/null; then
        echo 1>&2 "You are running the rportd server on this machine. Uninstall manually."
        exit 0
    fi
    stop_rport >/dev/null 2>&1 || true
    rc-service rport stop >/dev/null 2>&1 || true
    pkill -9 rport >/dev/null 2>&1 || true
    rport --service uninstall >/dev/null 2>&1 || true
    FILES="/usr/local/bin/rport
    /usr/local/bin/rport
    /etc/systemd/system/rport.service
    /etc/sudoers.d/rport-update-status
    /etc/sudoers.d/rport-all-cmd
    /usr/local/bin/tacoscript
    /etc/init.d/rport
    /var/run/rport.pid
    /etc/runlevels/default/rport
    /etc/apt/sources.list.d/rport.list"
    for FILE in $FILES; do
        if [ -e "$FILE" ]; then
            rm -f "$FILE" && echo " [ DELETED ] File $FILE"
        fi
    done
    if id rport >/dev/null 2>&1; then
        if is_available deluser; then
            deluser --remove-home rport >/dev/null 2>&1 || true
            deluser --only-if-empty --group rport >/dev/null 2>&1 || true
        elif is_available userdel; then
            userdel -r -f rport >/dev/null 2>&1
        fi
        if is_available groupdel; then
            groupdel -f rport >/dev/null 2>&1 || true
        fi
        echo " [ DELETED ] User rport"
    fi
    FOLDERS="/etc/rport
    /var/log/rport
    /var/lib/rport"
    for FOLDER in $FOLDERS; do
        if [ -e "$FOLDER" ]; then
            rm -rf "$FOLDER" && echo " [ DELETED ] Folder $FOLDER"
        fi
    done
    if dpkg -l 2>&1 | grep -q "rport.*Remote access"; then
        apt-get -y remove --purge rport
    fi
    echo "RPort client successfully uninstalled."
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  print_distro
#   DESCRIPTION:  print name of the distro
#----------------------------------------------------------------------------------------------------------------------
print_distro() {
    if [ -e /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release 2>/dev/null || true
        echo "Detected Linux Distribution: ${PRETTY_NAME}"
    fi
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  has_sudo
#   DESCRIPTION:  Check if sudo is installed and sudo rules can be managed as separated files
#       RETURNS:  0 (success,  sudo os present), 1 (fail, sudo can't be used by rport)
#----------------------------------------------------------------------------------------------------------------------
has_sudo() {
    if ! which sudo >/dev/null 2>&1; then
        return 1
    fi
    if [ -e /etc/sudoers.d/ ]; then
        return 0
    fi
    return 1
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  create_sudoers_all
#   DESCRIPTION:  create a sudoers file to grant full sudo right to the rport user
#----------------------------------------------------------------------------------------------------------------------
create_sudoers_all() {
    SUDOERS_FILE=/etc/sudoers.d/rport-all-cmd
    if [ -e "$SUDOERS_FILE" ]; then
        throw_info "You already have a $SUDOERS_FILE. Not changing."
        return 0
    fi

    if has_sudo; then
        echo "#
# This file has been auto-generated during the installation of the rport client.
# Change to your needs or delete.
#
${USER} ALL=(ALL) NOPASSWD:ALL
" >$SUDOERS_FILE
        echo "A $SUDOERS_FILE has been created. Please review and change to your needs."
    else
        echo "You don't have sudo installed. No sudo rules created. RPort will not be able to get elevated right."
    fi
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  create_sudoers_updates
#   DESCRIPTION:  create a sudoers file to allow rport supervise the update status
#----------------------------------------------------------------------------------------------------------------------
create_sudoers_updates() {
    SUDOERS_FILE=/etc/sudoers.d/rport-update-status
    if [ -e "$SUDOERS_FILE" ]; then
        throw_info "You already have a $SUDOERS_FILE. Not changing."
        return 0
    fi

    if has_sudo; then
        echo '#
# This file has been auto-generated during the installation of the rport client.
# Change to your needs.
#' >$SUDOERS_FILE
        if is_available apt-get; then
            echo "${USER} ALL=NOPASSWD: SETENV: /usr/bin/apt-get update -o Debug\:\:NoLocking=true" >>$SUDOERS_FILE
        fi
        #if is_available yum;then
        #  echo 'rport ALL=NOPASSWD: SETENV: /usr/bin/yum *'>>$SUDOERS_FILE
        #fi
        #if is_available dnf;then
        #  echo 'rport ALL=NOPASSWD: SETENV: /usr/bin/dnf *'>>$SUDOERS_FILE
        #fi
        if is_available zypper; then
            echo "${USER} ALL=NOPASSWD: SETENV: /usr/bin/zypper refresh *" >>$SUDOERS_FILE
        fi
        #if is_available apk;then
        #  echo 'rport ALL=NOPASSWD: SETENV: /sbin/apk *'>>$SUDOERS_FILE
        #fi
        echo "A $SUDOERS_FILE has been created. Please review and change to your needs."
    fi
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  abort
#   DESCRIPTION:  Exit the script with an error message.
#----------------------------------------------------------------------------------------------------------------------
abort() {
    echo >&2 "$1 Exit!"
    clean_up
    exit 1
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  confirm
#   DESCRIPTION:  Print a success message.
#----------------------------------------------------------------------------------------------------------------------
confirm() {
    echo "Success: $1"
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  check_prerequisites
#   DESCRIPTION:  Check if prerequisites are fulfilled.
#----------------------------------------------------------------------------------------------------------------------

check_prerequisites() {
    if [ "$(id -u)" -ne 0 ]; then
        abort "Execute as root or use sudo."
    fi

    if command -v sed >/dev/null 2>&1; then
        true
    else
        abort "sed command missing. Make sure sed is in your path."
    fi

    if command -v tar >/dev/null 2>&1; then
        true
    else
        abort "tar command missing. Make sure tar is in your path."
    fi
}

is_terminal() {
    if echo "$TERM" | grep -q "^xterm"; then
        return 0
    else
        echo 1>&2 "You are not on a terminal. Please use command line switches to avoid interactive questions."
        return 1
    fi
}

update_tacoscript() {
    TACO_VERSION=$(/usr/local/bin/tacoscript --version | grep -o "Version:.*" | awk '{print $2}')
    cd /tmp
    test -e tacoscript.tar.gz && rm -f tacoscript.tar.gz
    curl -LSso tacoscript.tar.gz "https://download.rport.io/tacoscript/${RELEASE}/?arch=Linux_${ARCH}&gt=$TACO_VERSION"
    if tar xzf tacoscript.tar.gz 2>/dev/null; then
        echo ""
        throw_info "Updating Tacoscript from ${TACO_VERSION} to latest ${RELEASE} $(./tacoscript --version | grep -o "Version:.*")"
        mv -f /tmp/tacoscript /usr/local/bin/tacoscript
    else
        throw_info "Nothing to do. Tacoscript is on the latest version ${TACO_VERSION}."
    fi
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  install_tacoscript
#   DESCRIPTION:  install Tacoscript on Linux
#----------------------------------------------------------------------------------------------------------------------
install_tacoscript() {
    if [ -e /usr/local/bin/tacoscript ]; then
        throw_info "Tacoscript already installed. Checking for updates ..."
        update_tacoscript
        return 0
    fi
    cd /tmp
    test -e tacoscript.tar.gz && rm -f tacoscript.tar.gz
    curl -Ls "https://download.rport.io/tacoscript/${RELEASE}/?arch=Linux_${ARCH}" -o tacoscript.tar.gz
    tar xvzf tacoscript.tar.gz -C /usr/local/bin/ tacoscript
    rm -f tacoscript.tar.gz
    echo "Tacoscript installed $(/usr/local/bin/tacoscript --version)"
}

version_to_int() {
    echo "$1" |
        awk -v 'maxsections=3' -F'.' 'NF < maxsections {printf("%s",$0);for(i=NF;i<maxsections;i++)printf("%s",".0");printf("\n")} NF >= maxsections {print}' |
        awk -v 'maxdigits=3' -F'.' '{print $1*10^(maxdigits*2)+$2*10^(maxdigits)+$3}'
}

runs_with_selinux() {
    if command -v getenforce >/dev/null 2>&1 && getenforce | grep -q Enforcing; then
        return 0
    else
        return 1
    fi
}

enable_file_reception() {
    if [ "$(version_to_int "$TARGET_VERSION")" -lt 6005 ]; then
        # Version does not handle file reception yet.
        return 0
    fi
    if [ "$ENABLE_FILEREC" -eq 0 ]; then
        echo "File reception disabled."
        FILEREC_CONF="false"
    else
        echo "File reception enabled."
        FILEREC_CONF="true"
    fi
    if grep -q '\[file-reception\]' "$CONFIG_FILE"; then
        echo "File reception already configured"
    else
        cat <<EOF >>"$CONFIG_FILE"


[file-reception]
  ## Receive files pushed by the server, enabled by default
  # enabled = true
  ## The rport client will reject writing files to any of the following folders and its subfolders.
  ## https://oss.rport.io/docs/no18-file-reception.html
  ## Wildcards (glob) are supported.
  ## Linux defaults
  # protected = ['/bin', '/sbin', '/boot', '/usr/bin', '/usr/sbin', '/dev', '/lib*', '/run']
  ## Windows defaults
  # protected = ['C:\Windows\', 'C:\ProgramData']

EOF
    fi
    toml_set "$CONFIG_FILE" file-reception enabled $FILEREC_CONF
    # Clean up from pre-releases
    test -e /etc/sudoers.d/rport-filepush && rm -f /etc/sudoers.d/rport-filepush
    if [ "$ENABLE_FILEREC_SUDO" -eq 0 ]; then
        # File receptions sudo rules not desired, end this function here
        return 0
    fi
    # Create a sudoers file
    FILERCV_SUDO="/etc/sudoers.d/rport-filereception"
    if [ -e $FILERCV_SUDO ]; then
        echo "Sudo rule $FILERCV_SUDO already exists"
    else
        cat <<EOF >$FILERCV_SUDO
# The following rule allows the rport client to change the ownership of any file retrieved from the rport server
rport ALL=NOPASSWD: /usr/bin/chown * /var/lib/rport/filepush/*_rport_filepush

# The following rules allows the rport client to move copied files to any folder
rport ALL=NOPASSWD: /usr/bin/mv /var/lib/rport/filepush/*_rport_filepush *

EOF
    fi
}

enable_lan_monitoring() {
    if [ "$(version_to_int "$TARGET_VERSION")" -lt 5008 ]; then
        # Version does not handle network interfaces yet.
        return 0
    fi
    if grep "^\s*net_[wl]" "$CONFIG_FILE"; then
        # Network interfaces already configured
        return 0
    fi
    echo "Enabling Network monitoring"
    for IFACE in /sys/class/net/*; do
        IFACE=$(basename "${IFACE}")
        [ "$IFACE" = 'lo' ] && continue
        if ip addr show "$IFACE" | grep -E -q "inet (10|192\.168|172\.16)\."; then
            # Private IP
            NET_LAN="$IFACE"
        else
            # Public IP
            NET_WAN="$IFACE"
        fi
    done
    if [ -n "$NET_LAN" ]; then
        sed -i "/^\[monitoring\]/a \ \ net_lan = ['${NET_LAN}' , '1000' ]" "$CONFIG_FILE"
    fi
    if [ -n "$NET_WAN" ]; then
        sed -i "/^\[monitoring\]/a \ \ net_wan = ['${NET_WAN}' , '1000' ]" "$CONFIG_FILE"
    fi
}

detect_interpreters() {
    if [ "$(version_to_int "$TARGET_VERSION")" -lt 5008 ]; then
        # Version does not handle interpreters yet.
        return 0
    fi
    if grep -q "\[interpreter\-aliases\]" "$CONFIG_FILE"; then
        # Config already updated
        true
    else
        echo "Updating config with new interpreter-aliases ..."
        echo '[interpreter-aliases]' >>"$CONFIG_FILE"
    fi
    SEARCH="bash zsh ksh csh python3 python2 perl pwsh fish"
    for ITEM in $SEARCH; do
        FOUND=$(command -v "$ITEM" 2>/dev/null || true)
        if [ -z "$FOUND" ]; then
            continue
        fi
        echo "Interpreter '$ITEM' found in '$FOUND'"
        if grep -q -E "^\s*$ITEM =" "$CONFIG_FILE"; then
            echo "Interpreter '$ITEM' already registered."
            continue
        fi
        # Append the found interpreter to the config
        sed -i "/^\[interpreter-aliases\]/a \ \ $ITEM = \"$FOUND\"" "${CONFIG_FILE}"
    done
}

toml_set() {
    TOML_FILE="$1"
    BLOCK="$2"
    KEY="$3"
    VALUE="$4"
    if [ -w "$TOML_FILE" ]; then
        true
    else
        echo 2>&1 "$TOML_FILE does not exist or is not writable."
        return 1
    fi
    if grep -q "\[$BLOCK\]" "$TOML_FILE"; then
        true
    else
        echo 2>&1 "$TOML_FILE has no block [$BLOCK]"
        return 1
    fi
    LINE=$(grep -n -A100 "\[$BLOCK\]" "$TOML_FILE" | grep "${KEY} = ")
    if [ -z "$LINE" ]; then
        echo 2>&1 "Key $KEY not found in block $BLOCK"
        return 1
    fi
    LINE_NO=$(echo "$LINE" | cut -d'-' -f1)
    sed -i "${LINE_NO}s/.*/  ${KEY} = ${VALUE}/" "$TOML_FILE"
}

gen_uuid() {
    if [ -e /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
        return 0
    fi
    if which uuidgen >/dev/null 2>&1; then
        uuidgen
        return 0
    fi
    if which dbus-uuidgen >/dev/null 2>&1; then
        dbus-uuidgen
        return 0
    fi
    # Use a internet-based fallback
    curl -s https://www.uuidtools.com/api/generate/v4 | tr -d '"[]'
}

get_ip_from_fqdn() {
    if which getent >/dev/null; then
        getent hosts "$1" | awk '{ print $1 }'
        return 0
    fi
    ping "$1" -c 1 -q 2>&1 | grep -Po "(\d{1,3}\.){3}\d{1,3}"
}

start_rport() {
    if is_available systemctl; then
        systemctl daemon-reload
        systemctl start rport
        systemctl enable rport
    elif [ -e /etc/init/rport.conf ]; then
        # We are on an upstart system
        start rport
    elif is_available service; then
        service rport start
    fi
    if pidof rport >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

stop_rport() {
    if is_available systemctl; then
        systemctl stop rport
    elif [ -e /etc/init/rport.conf ]; then
        # We are on an upstart system
        stop rport
    elif is_available service; then
        service rport stop
    fi
}

backup_config() {
    if [ -z "$CONFIG_FILE" ]; then
        throw_fatal "backup_config() \$CONFIG_FILE undefined."
    fi
    CONFIG_BACKUP="/tmp/.rport-conf.$(date +%s)"
    cp "$CONFIG_FILE" "$CONFIG_BACKUP"
    throw_debug "Configuration file copied to $CONFIG_BACKUP"
}

clean_up_legacy_installation() {
    # If this is a migration from the old none deb-based installation, clean up
    if [ -e /etc/systemd/system/rport.service ]; then
        throw_info "Removing old systemd service /etc/systemd/system/rport.service"
        rm -f /etc/systemd/system/rport.service
        systemctl daemon-reload
    fi
    if [ -e /usr/local/bin/rport ]; then
        throw_info "Removing old version /usr/local/bin/rport"
        rm -f /usr/local/bin/rport
    fi
}

install_via_deb_repo() {
    if [ -z "$RELEASE" ]; then
        throw_fatal "install_via_deb_repo() \$RELEASE undefined"
    fi
    validate_custom_user
    if [ -e /etc/apt/trusted.gpg.d/rport.gpg ] && dpkg -l | grep -q rport; then
        throw_info "System is already using the rport deb repo."
    else
        throw_info "RPort will use Debian package ..."
        # shellcheck source=/dev/null
        . /etc/os-release
        if [ -n "$UBUNTU_CODENAME" ]; then
            CODENAME=$UBUNTU_CODENAME
        else
            CODENAME=$VERSION_CODENAME
        fi
        curl -sf http://repo.rport.io/dearmor.gpg >/etc/apt/trusted.gpg.d/rport.gpg
        echo "deb [signed-by=/etc/apt/trusted.gpg.d/rport.gpg] http://repo.rport.io/deb ${CODENAME} ${RELEASE}" >/etc/apt/sources.list.d/rport.list
    fi
    apt-get update
    if dpkg -s rport >/dev/null 2>&1 && ! [ -e /etc/rport/rport.conf ]; then
        throw_warning "Broken DEB package installation found."
        throw_debug "Will remove old package first."
        apt-get -y --purge remove rport
    fi
    DEBIAN_FRONTEND=noninteractive apt-get --yes -o Dpkg::Options::="--force-confold" install rport
    TARGET_VERSION=$(rport --version | cut -d" " -f2)
    clean_up_legacy_installation
}

install_via_rpm_repo() {
    if [ -z "$RELEASE" ]; then
        throw_fatal "install_via_rpm_repo() \$RELEASE undefined"
    fi
    validate_custom_user
    if [ -e /etc/yum.repos.d/rport.repo ] && rpm -qa | grep -q rport; then
        throw_info "System is already using the rport yum repo."
    else
        throw_info "RPort will use RPM package ..."
        rpm --import https://repo.rport.io/key.gpg
        cat <<EOF >/etc/yum.repos.d/rport.repo
[rport-stable]
name=RPort $RELEASE
baseurl=http://repo.rport.io/rpm/$RELEASE/
enabled=1
gpgcheck=1
gpgkey=https://repo.rport.io/key.gpg
EOF
    fi
    dnf -y install rport --refresh
    TARGET_VERSION=$(rport --version | cut -d" " -f2)
    clean_up_legacy_installation
}

validate_custom_user() {
    if [ "$USER" != "rport" ]; then
        throw_fatal "RPM/DEB packages cannot be used with a custom user. Try '-p'"
    fi
}

# Check if it's a supported debian system
is_debian() {
    if [ "$NO_REPO" -eq 1 ]; then
        return 1
    fi
    if which apt-get >/dev/null 2>&1 && test -e /etc/apt/sources.list.d/; then
        true
    else
        return 1
    fi
    DIST_SUPPORTED="jammy focal bionic bullseye buster bookworm"
    for DIST in $DIST_SUPPORTED; do
        if grep -qi "CODENAME.*$DIST" /etc/os-release; then
            return 0
        fi
    done
    return 1
}

is_rhel() {
    if [ "$NO_REPO" -eq 1 ]; then
        return 1
    fi
    if grep -q "VERSION=.[6-7]" /etc/os-release; then
        throw_info "RHEL/CentOS too old for RPM installation. Switching to tar.gz package."
        return 1
    fi

    if which rpm >/dev/null 2>&1 && test -e /etc/yum.repos.d; then
        return 0
    fi
    return 1
}

validate_pkg_url() {
    if echo "${PKG_URL}" | grep -q -E "https*:\/\/.*_linux_$(uname -m)\.(tar\.gz|deb|rpm)$"; then
        true
    else
        throw_fatal "Invalid PKG_URL '$PKG_URL'."
    fi
}

download_pkg_url() {
    DL_AUTH=""
    if [ -n "$RPORT_INSTALLER_DL_USERNAME" ] && [ -n "$RPORT_INSTALLER_DL_PASSWORD" ]; then
        DL_AUTH="-u ${RPORT_INSTALLER_DL_USERNAME}:${RPORT_INSTALLER_DL_PASSWORD}"
        throw_info "Download will use HTTP basic authentication"
    fi
    throw_info "Downloading from ${PKG_URL} ..."
    PKG_DOWNLOAD=$(mktemp)
    # shellcheck disable=SC2086
    curl -LSs "${PKG_URL}" ${DL_AUTH} >${PKG_DOWNLOAD}
    if [ -n "$(find "${PKG_DOWNLOAD}" -empty)" ]; then
        rm -f "${PKG_DOWNLOAD}"
        throw_fatal "Download to ${PKG_DOWNLOAD} failed"
    fi
    throw_info "Download to ${PKG_DOWNLOAD} completed"
}

install_from_deb_download() {
    validate_pkg_url
    if echo "${PKG_URL}" | grep -q "deb$"; then
        true
    else
        throw_fatal "URL not pointing to a debian package"
    fi
    download_pkg_url
    mv "${PKG_DOWNLOAD}" "${PKG_DOWNLOAD}".deb
    PKG_DOWNLOAD=${PKG_DOWNLOAD}.deb
    chmod 0644 "${PKG_DOWNLOAD}"
    throw_info "Installing debian package ${PKG_DOWNLOAD}"
    DEBIAN_FRONTEND=noninteractive apt-get --yes -o Dpkg::Options::="--force-confold" install "${PKG_DOWNLOAD}"
    rm -f "${PKG_DOWNLOAD}"
    clean_up_legacy_installation
}

install_from_rpm_download() {
    validate_pkg_url
    if echo "${PKG_URL}" | grep -q "rpm$"; then
        true
    else
        throw_fatal "URL not pointing to an rpm package"
    fi
    download_pkg_url
    throw_info "Installing rpm package"
    rpm -U "${PKG_DOWNLOAD}"
    rm -f "${PKG_DOWNLOAD}"
    clean_up_legacy_installation
}

abort_on_rport_subprocess() {
    if is_rport_subprocess; then
        throw_hint "Execute the rport update in a process decoupled from its parent, e.g."
        throw_hint '  nohup sh -c "curl -s https://pairing.rport.io/update|sh" >/tmp/rport-update.log 2>&1 &'
        throw_fatal "You cannot update rport from an rport subprocess."
    fi
}

# END of templates/linux/functions.sh --------------------------------------------------------------------------------|


# BEGINNING of templates/linux/install.sh ----------------------------------------------------------------------------|

set -e
#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  prepare
#   DESCRIPTION:  Create a temporary folder and prepare the system to execute the installation
#----------------------------------------------------------------------------------------------------------------------
prepare() {
    test -e "${TMP_FOLDER}" && rm -rf "${TMP_FOLDER}"
    mkdir "${TMP_FOLDER}"
    cd "${TMP_FOLDER}"
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  cleanup
#   DESCRIPTION:  Remove the temporary folder and cleanup any leftovers after script has ended
#----------------------------------------------------------------------------------------------------------------------
clean_up() {
    cd /tmp
    rm -rf "${TMP_FOLDER}"
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  test_connection
#   DESCRIPTION:  Check if the RPort server is reachable or abort.
#----------------------------------------------------------------------------------------------------------------------
test_connection() {
    CONN_TEST=$(curl -vIs -m5 "${CONNECT_URL}" 2>&1 || true)
    if echo "${CONN_TEST}" | grep -q "Connected to"; then
        confirm "${CONNECT_URL} is reachable. All good."
    else
        echo "$CONN_TEST"
        echo ""
        echo "Testing the connection to the RPort server on ${CONNECT_URL} failed."
        echo "* Check your internet connection and firewall rules."
        echo "* Check if a transparent HTTP proxy is sniffing and blocking connections."
        echo "* Check if a virus scanner is inspecting HTTP connections."
        abort "FATAL: No connection to the RPort server."
    fi
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  download_and_extract
#   DESCRIPTION:  Download the package from Github and unpack to the temp folder
#                 https://downloads.rport.io/ acts a redirector service
#                 returning the real download URL of GitHub in a more handy fashion
#----------------------------------------------------------------------------------------------------------------------
download_and_extract() {
    cd "${TMP_FOLDER}"
    # Download the tar.gz package
    if is_available curl; then
        curl -LSs "https://downloads.rport.io/rport/${RELEASE}/latest.php?arch=Linux_${ARCH}" -o rport.tar.gz
    elif is_available wget; then
        wget -q "https://downloads.rport.io/rport/${RELEASE}/latest.php?arch=Linux_${ARCH}" -O rport.tar.gz
    else
        abort "No download tool found. Install curl or wget."
    fi
    # Unpack
    tar xzf rport.tar.gz
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  download_and_extract_from_url
#   DESCRIPTION:  Download the package from any URL and unpack to the temp folder
#----------------------------------------------------------------------------------------------------------------------
download_and_extract_from_url() {
    cd "${TMP_FOLDER}"
    ARCH=$(uname -m)
    DL_AUTH=""
    DL="rport.tar.gz"
    # Use a specific version
    if echo "$PKG_URL" | grep -q -E "^https?:\/\/.*\_linux_${ARCH}.tar.gz"; then
        DOWNLOAD_URL="$PKG_URL"
    else
        echo "PKG_URL does not match 'http(s)://... _linux_${ARCH}.tar.gz'"
        abort "Invalid download URL."
    fi
    if [ -n "$RPORT_INSTALLER_DL_USERNAME" ] && [ -n "$RPORT_INSTALLER_DL_PASSWORD" ]; then
        DL_AUTH="-u ${RPORT_INSTALLER_DL_USERNAME}:${RPORT_INSTALLER_DL_PASSWORD}"
        confirm "Download will use HTTP basic authentication"
    fi
    echo "Downloading from ${DOWNLOAD_URL}"
    [ -e "${DL}" ] && rm -f "${DL}"
    # shellcheck disable=SC2086
    curl -LSs "${DOWNLOAD_URL}" -o "${DL}" ${DL_AUTH}
    echo "Verifying download"
    FILES_IN_TAR=$(tar tzf "${DL}")
    confirm "Package contains $(echo "$FILES_IN_TAR" | wc -w) files"
    tar xzf "${DL}" rport
    tar xzf "${DL}" rport.example.conf
    rm -f "${DL}"
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  install_bin
#   DESCRIPTION:  Install a binary located in the temp folder to /usr/local/bin
#    PARAMETERS:  binary name relative to the temp folder
#----------------------------------------------------------------------------------------------------------------------
install_bin() {
    EXEC_BIN=/usr/local/bin/${1}
    if [ -e "$EXEC_BIN" ]; then
        if [ "$FORCE" -eq 0 ]; then
            abort "${EXEC_BIN} already exists. Use -f to overwrite."
        fi
    fi
    mv "${TMP_FOLDER}/${1}" "${EXEC_BIN}"
    confirm "${1} installed to ${EXEC_BIN}"
    TARGET_VERSION=$(${EXEC_BIN} --version | awk '{print $2}')
    confirm "RPort $TARGET_VERSION installed to $EXEC_BIN"
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  install_config
#   DESCRIPTION:  Install an example config located in the temp folder to /etc/rport
#    PARAMETERS:
#----------------------------------------------------------------------------------------------------------------------
install_config() {
    test -e "$CONF_DIR" || mkdir "$CONF_DIR"
    CONFIG_FILE=${CONF_DIR}/${1}.conf
    if [ -e "${CONFIG_FILE}" ]; then
        true
    elif [ -e "${TMP_FOLDER}/rport.example.conf" ]; then
        mv "${TMP_FOLDER}/rport.example.conf" "${CONFIG_FILE}"
    else
        throw_hint "If you have used the RPort RPM or DEB package previously, remove it first using the package manager."
        throw_fatal "No rport.conf file found."
    fi
    confirm "${CONFIG_FILE} created."
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  create_user
#   DESCRIPTION:  Create a system user "rport"
#----------------------------------------------------------------------------------------------------------------------
create_user() {
    confirm "RPort will run as user ${USER}"
    if id "${USER}" >/dev/null 2>&1; then
        confirm "User ${USER} already exist."
    else
        if is_available useradd; then
            useradd -r -d /var/lib/rport -m -s /bin/false -U -c "System user for rport client" "$USER"
        elif is_available adduser; then
            addgroup rport
            adduser -h /var/lib/rport -s /bin/false -G rport -S -D "$USER"
        else
            abort "No command found to add a user"
        fi
    fi
}

set_file_and_dir_owner() {
    test -e "$LOG_DIR" || mkdir -p "$LOG_DIR"
    test -e /var/lib/rport/scripts || mkdir -p /var/lib/rport/scripts
    chown "${USER}":root "$LOG_DIR"
    chown "${USER}":root /var/lib/rport/scripts
    chmod 0700 /var/lib/rport/scripts
    chown "${USER}":root "$CONFIG_FILE"
    chmod 0640 "$CONFIG_FILE"
    if [ -e /usr/local/bin/rport ]; then
        chown root:root /usr/local/bin/rport
        chmod 0755 /usr/local/bin/rport
    fi
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  create_systemd_service
#   DESCRIPTION:  Install a systemd service file, if needed
#----------------------------------------------------------------------------------------------------------------------
create_systemd_service() {
    if [ -e /lib/systemd/system/rport.service ]; then
        echo "Systemd service already present."
    else
        echo "Installing systemd service for rport"
        test -e /etc/systemd/system/rport.service && rm -f /etc/systemd/system/rport.service
        /usr/local/bin/rport --service install --service-user "${USER}" --config /etc/rport/rport.conf
    fi
    start_rport
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  create_openrc_service
#   DESCRIPTION:  Install a oprnrc service file
#----------------------------------------------------------------------------------------------------------------------
create_openrc_service() {
    echo "Installing openrc service for rport"
    cat <<EOF >/etc/init.d/rport
#!/sbin/openrc-run
command="/usr/local/bin/rport"
command_args="-c /etc/rport/rport.conf"
command_user="${USER}"
command_background=true
pidfile=/var/run/rport.pid
EOF
    chmod 0755 /etc/init.d/rport
    rc-service rport start
    rc-update add rport default
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  prepare_server_cofnig
#   DESCRIPTION:  Make changes to the example config to give the user a better starting point
#----------------------------------------------------------------------------------------------------------------------
prepare_config() {
    echo "Preparing $CONFIG_FILE"
    sed -i "s|#*server = .*|server = \"${CONNECT_URL}\"|g" "$CONFIG_FILE"
    sed -i "s/#*auth = .*/auth = \"${CLIENT_ID}:${PASSWORD}\"/g" "$CONFIG_FILE"
    sed -i "s/#*fingerprint = .*/fingerprint = \"${FINGERPRINT}\"/g" "$CONFIG_FILE"
    sed -i "s/#*log_file = .*C.*Program Files.*/""/g" "$CONFIG_FILE"
    sed -i "s/#*log_file = /log_file = /g" "$CONFIG_FILE"
    sed -i "s|#updates_interval = '4h'|updates_interval = '4h'|g" "$CONFIG_FILE"
    if [ "$ENABLE_COMMANDS" -eq 1 ]; then
        sed -i "s/#allow = .*/allow = ['.*']/g" "$CONFIG_FILE"
        sed -i "s/#deny = .*/deny = []/g" "$CONFIG_FILE"
        sed -i '/^\[remote-scripts\]/a \ \ enabled = true' "$CONFIG_FILE"
        sed -i "s|# script_dir = '/var/lib/rport/scripts'|script_dir = '/var/lib/rport/scripts'|g" "$CONFIG_FILE"
    else
        sed -i '/^\[remote-commands\]/a \ \ enabled = false' "$CONFIG_FILE"
    fi

    # Set the hostname.
    if grep -Eq "\s+use_hostname = true" "$CONFIG_FILE"; then
        # For versions >= 0.5.9
        # Just insert an example.
        sed -i "s/#name = .*/#name = \"$(get_hostname)\"/g" "$CONFIG_FILE"
    else
        # Older versions
        # Insert a hardcoded name
        sed -i "s/#*name = .*/name = \"$(get_hostname)\"/g" "$CONFIG_FILE"
    fi

    # Set the machine_id
    if [ -n "$MACHINE_ID" ]; then
        #User wants a hard-coded client id
        sed -i "s/.*use_system_id = .*/  use_system_id = false/g" "$CONFIG_FILE"
        sed -i "s/#id = .*/id = \"$MACHINE_ID\"/g" "$CONFIG_FILE"
        echo "Using a random hard-coded client id not based on /etc/machine-id"
    else
        if grep -Eq "\s+use_system_id = true" "$CONFIG_FILE" && [ -e /etc/machine-id ]; then
            # Versions >= 0.5.9 read it dynamically, nothing to do here
            echo "Using /etc/machine-id as rport client id"
        else
            # Older versions need a hard-coded id in the rport.conf, preferably based on /etc/machine-id
            sed -i "s/#id = .*/id = \"$(machine_id)\"/g" "$CONFIG_FILE"
        fi
    fi

    # Activate client attributes
    if get_geodata; then
        LABELS="\"city\":\"${CITY}\", \"country\":\"${COUNTRY}\""
    fi
    if [ -n "$XTAG" ]; then
        XTAG="\"$XTAG\""
    fi
    CLIENT_ATTRIBUTES="/var/lib/rport/client_attributes.json"
    if [ -e /var/lib/rport ]; then
        true
    else
        mkdir /var/lib/rport
        chown "${USER}":root /var/lib/rport
    fi
    cat <<EOF >$CLIENT_ATTRIBUTES
{
  "tags": [${TAGS}],
  "labels": { ${LABELS} }
}
EOF
    sed -i "s|#attributes_file_path = \"/var/.*|attributes_file_path = \"${CLIENT_ATTRIBUTES}\"|g" "$CONFIG_FILE"
    chown "${USER}" "${CLIENT_ATTRIBUTES}"
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  get_hostname
#   DESCRIPTION:  Try to get the hostname from various sources
#----------------------------------------------------------------------------------------------------------------------
get_hostname() {
    hostname -f 2>/dev/null && return 0
    hostname 2>/dev/null && return 0
    cat /etc/hostname 2>/dev/null && return 0
    LANG=en hostnamectl | grep hostname | grep -v 'n/a' | cut -d':' -f2 | tr -d ' '
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  machine_id
#   DESCRIPTION:  Try to get a unique machine id form different locations.
#                 Generate one based on the hostname as a fallback.
#----------------------------------------------------------------------------------------------------------------------
machine_id() {
    if [ -e /etc/machine-id ]; then
        cat /etc/machine-id
        return 0
    fi

    if [ -e /var/lib/dbus/machine-id ]; then
        cat /var/lib/dbus/machine-id
        return 0
    fi

    alt_machine_id
}

alt_machine_id() {
    ip a | grep ether | md5sum | awk '{print $1}'
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  install_client
#   DESCRIPTION:  Execute all needed steps to install the rport client
#----------------------------------------------------------------------------------------------------------------------
install_client() {
    echo "Installing rport client"
    print_distro
    if runs_with_selinux && [ "$SELINUX_FORCE" -ne 1 ]; then
        echo ""
        echo "Your system has SELinux enabled. This installer will not create the needed policies."
        echo "RPort will not connect with out the right policies."
        echo "Read more https://kb.rport.io/digging-deeper/advanced-client-management/run-with-selinux"
        echo "Execute '$0 ${RAW_ARGS} -l' to skip this warning and install anyways. You must create the policies later."
        exit 1
    fi
    test_connection
    if [ -n "$PKG_URL" ]; then
        if is_debian; then
            install_from_deb_download
        elif is_rhel; then
            install_from_rpm_download
        else
            download_and_extract_from_url
            install_bin rport
        fi
    elif is_debian; then
        install_via_deb_repo
    elif is_rhel; then
        install_via_rpm_repo
    else
        download_and_extract
        install_bin rport
    fi
    create_user
    install_config rport
    prepare_config
    enable_lan_monitoring
    detect_interpreters
    set_file_and_dir_owner
    if is_available openrc; then
        # Create and start the service
        create_openrc_service
    else
        # Create and start the service
        create_systemd_service
    fi
    create_sudoers_updates
    [ "$ENABLE_SUDO" -eq 1 ] && create_sudoers_all
    [ "$INSTALL_TACO" -eq 1 ] && install_tacoscript
    verify_and_terminate
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  verify_and_terminate
#   DESCRIPTION:  Verify the installation has succeeded
#----------------------------------------------------------------------------------------------------------------------
verify_and_terminate() {
    sleep 1
    if pgrep rport >/dev/null 2>&1; then
        if check_log; then
            finish
            return 0
        elif [ $? -eq 1 ] && [ "$USE_ALTERNATIVE_MACHINEID" -ne 1 ]; then
            USE_ALTERNATIVE_MACHINEID=1
            use_alternative_machineid
            verify_and_terminate
            return 0
        fi
    fi
    fail
}

use_alternative_machineid() {
    # If the /etc/machine-id is already used, use an alternative unique id
    stop_rport
    rm -f "$LOG_FILE"
    echo "Creating a unique id based on the mac addresses of the network cards."
    sed -i "s/^id = .*/id = \"$(alt_machine_id)\"/g" "$CONFIG_FILE"
    start_rport
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  get_geodata
#   DESCRIPTION:  Retrieve the Country and the city of the currently used public IP address
#----------------------------------------------------------------------------------------------------------------------
get_geodata() {
    GEODATA=""
    GEOSERVICE_URL="http://ip-api.com/line/?fields=status,country,city"
    if is_available curl; then
        GEODATA=$(curl -m2 -Ss "${GEOSERVICE_URL}" 2>/dev/null)
    else
        GEODATA=$(wget --timeout=2 -O - -q "${GEOSERVICE_URL}" 2>/dev/null)
    fi
    if echo "$GEODATA" | grep -q "^success"; then
        CITY="$(echo "$GEODATA" | head -n3 | tail -n1)"
        COUNTRY="$(echo "$GEODATA" | head -n2 | tail -n1)"
        GEODATA="1"
        return 0
    else
        return 1
    fi
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  check_log
#   DESCRIPTION:  Check the log file for proper operation or common errors
#----------------------------------------------------------------------------------------------------------------------
check_log() {
    if [ -e "$LOG_FILE" ]; then
        true
    else
        echo 2>&1 "[!] Logfile $LOG_FILE does not exist."
        echo 2>&1 "[!] RPOrt very likely failed to start."
        return 4
    fi
    if grep -q "client id .* is already in use" "$LOG_FILE"; then
        echo ""
        echo 2>&1 "[!] Configuration error: client id is already in use."
        echo 2>&1 "[!] Likely you have systems with an duplicated machine-id in your network."
        echo ""
        return 1
    elif grep -q "Connection error: websocket: bad handshake" "$LOG_FILE"; then
        echo ""
        echo 2>&1 "[!] Connection error: websocket: bad handshake"
        echo "Check if transparent proxies are interfering outgoing http connections."
        return 2
    elif tac "$LOG_FILE" | grep error; then
        return 3
    fi

    return 0
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  help
#   DESCRIPTION:  print a help message and exit
#----------------------------------------------------------------------------------------------------------------------
help() {
    cat <<EOF
Usage $0 [OPTION(s)]

Options:
-h  Print this help message.
-f  Force  overwriting existing files and configurations.
-t  Use the latest unstable version (DANGEROUS!).
-u  Uninstall the rport client and all configurations and logs.
-x  Enable unrestricted command execution in rport.conf.
-s  Create sudo rules to grant full root access to the rport user.
-r  Enable file reception. (sending files from server to client)
-b  Create sudo rule for file reception to give full filesystem write access. Requires -r.
-a  <USER> Use a different user account than 'rport'. Will be created if not present.
-i  Install Tacoscript along with the RPort client.
-l  Install with SELinux enabled.
-g  <TAG> Add an extra tag to the client.
-d  Do not use /etc/machine-id to identify this machine. A random UUID will be used instead.
-p  Do not use the RPM/DEB repository. Forces tar.gz installation.
-z  Download the rport client tar.gz from the given URL instead of using GitHub releases. See environment variables.

Environment variables:
  If RPORT_INSTALLER_DL_USERNAME and RPORT_INSTALLER_DL_PASSWORD are set, downloads of custom packages triggered with
  '-z' are initiated with HTTP basic authentication.

Learn more https://kb.rport.io/connecting-clients#advanced-pairing-options
EOF
}

#---  FUNCTION  -------------------------------------------------------------------------------------------------------
#          NAME:  finish
#   DESCRIPTION:  print some information
#----------------------------------------------------------------------------------------------------------------------
finish() {
    echo "
#
#  Installation of rport finished.
#
#  This client is now connected to $SERVER
#
#  Look at $CONFIG_FILE and explore all options.
#  Logs are written to /var/log/rport/rport.log.
#
#  READ THE DOCS ON https://kb.rport.io/
#

Thanks for using
  _____  _____           _
 |  __ \|  __ \         | |
 | |__) | |__) |__  _ __| |_
 |  _  /|  ___/ _ \| '__| __|
 | | \ \| |  | (_) | |  | |_
 |_|  \_\_|   \___/|_|   \__|
"
}

fail() {
    echo "
#
# -------------!!   ERROR  !!-------------
#
# Installation of rport finished with errors.
#

Try the following to investigate:
1) systemctl rport status

2) tail /var/log/rport/rport.log

3) Ask for help on https://kb.rport.io/need-help/request-support
"
    if runs_with_selinux; then
        echo "
4) Check your SELinux settings and create a policy for rport."
    fi
}

#----------------------------------------------------------------------------------------------------------------------
#                                               END OF FUNCTION DECLARATION
#----------------------------------------------------------------------------------------------------------------------

#
# Check for prerequisites
#
check_prerequisites

MANDATORY="SERVER FINGERPRINT CLIENT_ID PASSWORD"
for VAR in $MANDATORY; do
    if eval "[ -z $${VAR} ]"; then
        abort "Variable \$${VAR} not set."
    fi
done

#
# Read the command line options and map to a function call
#
RAW_ARGS=$*
ACTION=install_client
ENABLE_COMMANDS=0
ENABLE_SUDO=0
RELEASE=stable
INSTALL_TACO=0
SELINUX_FORCE=0
ENABLE_FILEREC=0
ENABLE_FILEREC_SUDO=0
XTAG=""
NO_REPO=0
while getopts 'phvfcsuxstildrba:g:z:' opt; do
    case "${opt}" in

    h)
        help
        exit 0
        ;;
    f) FORCE=1 ;;
    v)
        echo "$0 -- Version $VERSION"
        exit 0
        ;;
    c) ACTION=install_client ;;
    u) ACTION=uninstall ;;
    x) ENABLE_COMMANDS=1 ;;
    s) ENABLE_SUDO=1 ;;
    t) RELEASE=unstable ;;
    i) INSTALL_TACO=1 ;;
    l) SELINUX_FORCE=1 ;;
    r) export ENABLE_FILEREC=1 ;;
    b) export ENABLE_FILEREC_SUDO=1 ;;
    a) USER=${OPTARG} ;;
    g) XTAG=${OPTARG} ;;
    z) export PKG_URL="${OPTARG}" ;;
    d) MACHINE_ID=$(gen_uuid) ;;
    p) NO_REPO=1 ;;

    \?)
        echo "Option does not exist."
        exit 1
        ;;
    esac # --- end of case ---
done
shift $((OPTIND - 1))
prepare  # Prepare the system
$ACTION  # Execute the function according to the users decision
clean_up # Clean up the system

# END of templates/linux/install.sh ----------------------------------------------------------------------------------|

