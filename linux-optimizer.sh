#!/bin/bash


clear


# Green, Yellow & Red Messages.
green_msg() {
    tput setaf 2
    echo "[*] ----- $1"
    tput sgr0
}

yellow_msg() {
    tput setaf 3
    echo "[*] ----- $1"
    tput sgr0
}

red_msg() {
    tput setaf 1
    echo "[*] ----- $1"
    tput sgr0
}


# Paths
HOST_PATH="/etc/hosts"
DNS_PATH="/etc/resolv.conf"


# Intro
echo 
green_msg '================================================================='
green_msg 'This script will automatically Optimize your Linux Server.'
green_msg 'Tested on: Ubuntu 20+, Debian 11+, CentOS stream 8+, AlmaLinux 8+, Fedora 37+'
green_msg 'Root access is required.' 
green_msg 'Source is @ https://github.com/hawshemi/linux-optimizer' 
green_msg '================================================================='
echo 


# Check Root Function
check_if_running_as_root() {
    # If you want to run as another user, please modify $EUID to be owned by this user
    if [[ "$EUID" -ne '0' ]]; then
      echo 
      red_msg 'Error: You must run this script as root!'
      echo 
      sleep 0.5
      exit 1
    fi
}


# Run Check Root
check_if_running_as_root
sleep 0.5


# Install dependencies
install_dependencies_debian_based() {
  echo
  yellow_msg 'Installing Dependencies...'
  echo
  sleep 0.5

  apt update -q
  apt install -yq wget curl sudo jq

  echo
  green_msg 'Dependencies Installed.'
  echo
  sleep 0.5
}


# Install dependencies
install_dependencies_rhel_based() {
  echo 
  yellow_msg 'Installing Dependencies...'
  echo 
  sleep 0.5

  # dnf up -y
  dnf install -y wget curl sudo jq
  
  echo
  green_msg 'Dependencies Installed.'
  echo 
  sleep 0.5
}


# Fix Hosts file
fix_etc_hosts(){ 
  echo 
  yellow_msg "Fixing Hosts file."
  sleep 0.5

  cp $HOST_PATH /etc/hosts.bak
  yellow_msg "Default hosts file saved. Directory: /etc/hosts.bak"
  sleep 0.5

  if ! grep -q $(hostname) $HOST_PATH; then
    echo "127.0.1.1 $(hostname)" | sudo tee -a $HOST_PATH > /dev/null
    green_msg "Hosts Fixed."
    echo 
    sleep 0.5
  else
    green_msg "Hosts OK. No changes made."
    echo 
    sleep 0.5
  fi
}


# Set DNS permanently (locked so systemd-resolved/NetworkManager/netplan/DHCP can't revert it on reboot)
fix_dns(){
    echo
    yellow_msg "Setting permanent DNS..."
    sleep 0.5

    ## Unlock a previous run's immutable file before touching it
    chattr -i "$DNS_PATH" 2>/dev/null

    if [ -e "$DNS_PATH" ]; then
        cp "$DNS_PATH" /etc/resolv.conf.bak 2>/dev/null
        yellow_msg "Default resolv.conf file saved. Directory: /etc/resolv.conf.bak"
        sleep 0.5
    fi

    ## Replace whatever resolv.conf is (real file or a symlink to the resolved stub)
    ## with a plain file, then lock it so nothing can overwrite it after reboot.
    rm -f "$DNS_PATH"
    cat > "$DNS_PATH" <<-EOF
	nameserver 1.1.1.2
	nameserver 1.0.0.2
	EOF

    if chattr +i "$DNS_PATH" 2>/dev/null; then
        green_msg "DNS set permanently (locked with chattr +i)."
    else
        yellow_msg "DNS set. (chattr unavailable, file left unlocked, may be overwritten by DHCP/NetworkManager.)"
    fi
    echo
    sleep 0.5
}


# Detect country + timezone from the VPS's public IP, once, with hard timeouts so it can never hang.
DETECTED_TIMEZONE="UTC"
DETECTED_COUNTRY=""

pick_majority() {
    local a="$1" b="$2" c="$3"
    if [ -n "$a" ] && { [ "$a" == "$b" ] || [ "$a" == "$c" ]; }; then
        echo "$a"
    elif [ -n "$b" ] && [ "$b" == "$c" ]; then
        echo "$b"
    elif [ -n "$a" ]; then
        echo "$a"
    elif [ -n "$b" ]; then
        echo "$b"
    else
        echo "$c"
    fi
}

detect_location() {
    echo
    yellow_msg 'Detecting VPS location (country + timezone)...'
    sleep 0.5

    local tmp_dir; tmp_dir=$(mktemp -d)

    ## Three independent geolocation providers, auto-detecting our public IP server-side
    ## (no separate "what's my IP" call needed). Run in parallel, each with its own timeout.
    ( curl -4 -s --connect-timeout 3 --max-time 6 'http://ip-api.com/json/' > "$tmp_dir/1.json" 2>/dev/null ) &
    ( curl -4 -s --connect-timeout 3 --max-time 6 'https://ipapi.co/json/' > "$tmp_dir/2.json" 2>/dev/null ) &
    ( curl -4 -s --connect-timeout 3 --max-time 6 'https://ipwho.is/' > "$tmp_dir/3.json" 2>/dev/null ) &

    ## Hard overall ceiling: never wait more than 8s total, even if a job ignores its own timeout
    local waited=0
    while [ "$waited" -lt 8 ] && [ -n "$(jobs -rp)" ]; do
        sleep 1
        waited=$(( waited + 1 ))
    done
    kill $(jobs -rp) 2>/dev/null

    local tz1 tz2 tz3 cc1 cc2 cc3
    tz1=$(jq -r '.timezone // empty' "$tmp_dir/1.json" 2>/dev/null)
    cc1=$(jq -r '.countryCode // empty' "$tmp_dir/1.json" 2>/dev/null)
    tz2=$(jq -r '.timezone // empty' "$tmp_dir/2.json" 2>/dev/null)
    cc2=$(jq -r '.country_code // empty' "$tmp_dir/2.json" 2>/dev/null)
    tz3=$(jq -r '.timezone // empty' "$tmp_dir/3.json" 2>/dev/null)
    cc3=$(jq -r '.country_code // empty' "$tmp_dir/3.json" 2>/dev/null)

    rm -rf "$tmp_dir"

    DETECTED_TIMEZONE=$(pick_majority "$tz1" "$tz2" "$tz3")
    DETECTED_COUNTRY=$(pick_majority "$cc1" "$cc2" "$cc3")
    [ -z "$DETECTED_TIMEZONE" ] && DETECTED_TIMEZONE="UTC"

    if [ -n "$DETECTED_COUNTRY" ]; then
        green_msg "Detected country: $DETECTED_COUNTRY, timezone: $DETECTED_TIMEZONE"
    else
        red_msg "Could not detect VPS location. Defaulting timezone to UTC, keeping default APT mirror."
    fi
    echo
    sleep 0.5
}


# Set the server TimeZone based on the detected VPS location.
set_timezone() {
    echo
    yellow_msg 'Setting TimeZone...'
    sleep 0.5

    if timedatectl set-timezone "$DETECTED_TIMEZONE" 2>/dev/null; then
        green_msg "Timezone set to $DETECTED_TIMEZONE"
    else
        red_msg "Unrecognized timezone '$DETECTED_TIMEZONE'. Falling back to UTC."
        timedatectl set-timezone "UTC"
    fi

    echo
    sleep 0.5
}


# Point APT at a mirror in the VPS's own country (instead of a hardcoded default), falling back
# to the current mirror if no country-specific one exists or responds.
set_apt_mirror() {
    if [[ "$OS" != "ubuntu" && "$OS" != "debian" ]]; then
        return
    fi

    if [ -z "$DETECTED_COUNTRY" ]; then
        return
    fi

    echo
    yellow_msg 'Selecting APT mirror for detected country...'
    sleep 0.5

    local cc mirror_host
    cc=$(echo "$DETECTED_COUNTRY" | tr '[:upper:]' '[:lower:]')

    if [ "$OS" == "ubuntu" ]; then
        mirror_host="${cc}.archive.ubuntu.com"
    else
        mirror_host="ftp.${cc}.debian.org"
    fi

    if ! curl -4 -s --connect-timeout 3 --max-time 6 -o /dev/null "http://${mirror_host}/"; then
        yellow_msg "No reachable APT mirror for '${cc}'. Keeping default mirror."
        echo
        sleep 0.5
        return
    fi

    for f in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/debian.sources; do
        [ -f "$f" ] || continue
        cp "$f" "${f}.bak"
        if [ "$OS" == "ubuntu" ]; then
            sed -i -E "s#https?://([a-z]{2}\.)?archive\.ubuntu\.com#http://${mirror_host}#g" "$f"
        else
            sed -i -E "s#https?://(ftp\.[a-z]{2}\.debian\.org|deb\.debian\.org)#http://${mirror_host}#g" "$f"
        fi
    done

    apt update -q
    green_msg "APT mirror set to ${mirror_host}."
    echo
    sleep 0.5
}


# OS Detection
if [[ $(grep -oP '(?<=^NAME=").*(?=")' /etc/os-release) == "Ubuntu" ]]; then
    OS="ubuntu"
    echo 
    sleep 0.5
    yellow_msg "OS: Ubuntu"
    echo 
    sleep 0.5
elif [[ $(grep -oP '(?<=^NAME=").*(?=")' /etc/os-release) == "Debian GNU/Linux" ]]; then
    OS="debian"
    echo 
    sleep 0.5
    yellow_msg "OS: Debian"
    echo 
    sleep 0.5
elif [[ $(grep -oP '(?<=^NAME=").*(?=")' /etc/os-release) == "CentOS Stream" ]]; then
    OS="centos"
    echo 
    sleep 0.5
    yellow_msg "OS: Centos Stream"
    echo 
    sleep 0.5
elif [[ $(grep -oP '(?<=^NAME=").*(?=")' /etc/os-release) == "AlmaLinux" ]]; then
    OS="almalinux"
    echo 
    sleep 0.5
    yellow_msg "OS: AlmaLinux"
    echo 
    sleep 0.5
elif [[ $(grep -oP '(?<=^NAME=").*(?=")' /etc/os-release) == "Fedora Linux" ]]; then
    OS="fedora"
    echo 
    sleep 0.5
    yellow_msg "OS: Fedora"
    echo 
    sleep 0.5
else
    echo 
    sleep 0.5
    red_msg "Unknown OS, Create an issue here: https://github.com/hawshemi/Linux-Optimizer"
    OS="unknown"
    echo 
    sleep 2
fi


## Run

# Install dependencies
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    install_dependencies_debian_based
elif [[ "$OS" == "centos" || "$OS" == "fedora" || "$OS" == "almalinux" ]]; then
    install_dependencies_rhel_based
fi


# Fix Hosts file
fix_etc_hosts
sleep 0.5

# Fix DNS
fix_dns
sleep 0.5

# Detect country + timezone once, then apply both
detect_location
sleep 0.5

# Timezone
set_timezone
sleep 0.5

# APT mirror (Ubuntu/Debian only)
set_apt_mirror
sleep 0.5


# Run Script based on Distros
case $OS in
ubuntu)
    # Ubuntu
    wget "https://raw.githubusercontent.com/FDeghy/Linux-Optimizer/main/scripts/ubuntu-optimizer.sh" -q -O ubuntu-optimizer.sh && chmod +x ubuntu-optimizer.sh && bash ubuntu-optimizer.sh 
    ;;
debian)
    # Debian
    wget "https://raw.githubusercontent.com/FDeghy/Linux-Optimizer/main/scripts/debian-optimizer.sh" -q -O debian-optimizer.sh && chmod +x debian-optimizer.sh && bash debian-optimizer.sh 
    ;;
centos)
    # CentOS
    wget "https://raw.githubusercontent.com/FDeghy/Linux-Optimizer/main/scripts/centos-optimizer.sh" -q -O centos-optimizer.sh && chmod +x centos-optimizer.sh && bash centos-optimizer.sh 
    ;;
almalinux)
    # AlmaLinux
    wget "https://raw.githubusercontent.com/FDeghy/Linux-Optimizer/main/scripts/centos-optimizer.sh" -q -O almalinux-optimizer.sh && chmod +x almalinux-optimizer.sh && bash almalinux-optimizer.sh 
    ;;
fedora)
    # Fedora
    wget "https://raw.githubusercontent.com/FDeghy/Linux-Optimizer/main/scripts/fedora-optimizer.sh" -q -O fedora-optimizer.sh && chmod +x fedora-optimizer.sh && bash fedora-optimizer.sh 
    ;;
unknown)
    # Unknown
    exit 
    ;;
esac

