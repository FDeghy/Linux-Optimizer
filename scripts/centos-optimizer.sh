#!/bin/bash
# https://github.com/hawshemi/Linux-Optimizer


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


# Declare Paths & Settings.
SYS_PATH="/etc/sysctl.conf"
PROF_PATH="/etc/profile"
SSH_PORT=""
SSH_PATH="/etc/ssh/sshd_config"
SWAP_PATH="/swapfile"
SWAP_SIZE=2G


# Detect CPU core count & RAM size
detect_system_resources() {
    CPU_CORES=$(nproc 2>/dev/null || echo 1)
    MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    MEM_MB=$(( MEM_KB / 1024 ))
    PAGE_SIZE=$(getconf PAGESIZE 2>/dev/null || echo 4096)
}


# Clamp a value between a min and a max
clamp() {
    local val=$1 min=$2 max=$3
    if   [ "$val" -lt "$min" ]; then echo "$min"
    elif [ "$val" -gt "$max" ]; then echo "$max"
    else echo "$val"
    fi
}


# Compute network & VM tunables scaled to this machine's CPU/RAM
calculate_network_values() {
    ## Core socket buffer ceiling: ~1/16 of RAM, clamped 4MiB - 128MiB
    RMEM_WMEM_MAX=$(clamp $(( MEM_KB * 1024 / 16 )) 4194304 134217728)
    OPTMEM_MAX=$(clamp $(( RMEM_WMEM_MAX / 256 )) 65536 262144)

    ## Default socket buffers
    RMEM_DEFAULT=$(clamp $(( RMEM_WMEM_MAX / 128 )) 65536 1048576)
    WMEM_DEFAULT=$(clamp $(( RMEM_DEFAULT / 2 )) 32768 524288)
    TCP_RMEM_DEFAULT=$RMEM_DEFAULT
    TCP_WMEM_DEFAULT=$WMEM_DEFAULT

    ## TCP/UDP memory pressure thresholds, expressed in PAGES (kernel's native unit)
    MEM_PAGES=$(( MEM_KB * 1024 / PAGE_SIZE ))
    TCP_MEM_MIN=$(clamp $(( MEM_PAGES / 32 )) 8192 1048576)
    TCP_MEM_PRESSURE=$(clamp $(( MEM_PAGES / 16 )) 16384 2097152)
    TCP_MEM_MAX=$(clamp $(( MEM_PAGES / 8 )) 32768 4194304)

    ## Connection queues scale with CPU core count
    SOMAXCONN=$(clamp $(( CPU_CORES * 4096 )) 4096 65536)
    NETDEV_BACKLOG=$(clamp $(( CPU_CORES * 8192 )) 16384 131072)
    TCP_MAX_SYN_BACKLOG=$(clamp $(( CPU_CORES * 4096 )) 8192 65536)
    TCP_MAX_TW_BUCKETS=$(clamp $(( CPU_CORES * 65536 )) 131072 2000000)
    TCP_MAX_ORPHANS=$(clamp $(( CPU_CORES * 16384 )) 16384 524288)

    ## Neighbor (ARP) table sizing scales with CPU core count
    GC_THRESH1=$(clamp $(( CPU_CORES * 512 )) 1024 8192)
    GC_THRESH2=$(clamp $(( CPU_CORES * 2048 )) 4096 32768)
    GC_THRESH3=$(clamp $(( CPU_CORES * 4096 )) 8192 65536)

    ## Open file descriptor ceiling: ~1 per 16KB of RAM
    FS_FILE_MAX=$(clamp $(( MEM_KB / 16 )) 2097152 67108864)

    ## Minimum free memory kept for reclaim pressure: ~1.5% of RAM
    VM_MIN_FREE_KBYTES=$(clamp $(( MEM_KB * 3 / 200 )) 65536 1048576)

    ## Dirty page writeback thresholds: tighter % on large-RAM boxes, avoids multi-GB flush stalls
    if   [ "$MEM_MB" -le 4096 ];  then DIRTY_RATIO=15; DIRTY_BG_RATIO=5
    elif [ "$MEM_MB" -le 16384 ]; then DIRTY_RATIO=10; DIRTY_BG_RATIO=5
    elif [ "$MEM_MB" -le 65536 ]; then DIRTY_RATIO=5;  DIRTY_BG_RATIO=2
    else                               DIRTY_RATIO=3;  DIRTY_BG_RATIO=1
    fi

    ## Minimize swap usage: near-zero swappiness on RAM-rich boxes,
    ## small floor on tiny boxes so they can still swap under real pressure
    if [ "$MEM_MB" -le 2048 ]; then SWAPPINESS=10; else SWAPPINESS=1; fi
}


# Pick the best available TCP congestion control + matching qdisc
select_congestion_control() {
    modprobe tcp_bbr >/dev/null 2>&1
    if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
        CONGESTION_CONTROL="bbr"
        QDISC="fq"
    else
        CONGESTION_CONTROL="cubic"
        QDISC="fq_codel"
        yellow_msg 'BBR unavailable on this kernel. Falling back to cubic + fq_codel.'
    fi
}


# Determine SWAP size: RAM-based, but never above 10% of the disk that holds it
calculate_swap_size() {
    ## RAM-based candidate size (kept small since swap is emergency-only here)
    if   [ "$MEM_MB" -le 2048 ];  then SWAP_SIZE_MB=$(( MEM_MB * 2 ))
    elif [ "$MEM_MB" -le 8192 ];  then SWAP_SIZE_MB=$MEM_MB
    elif [ "$MEM_MB" -le 32768 ]; then SWAP_SIZE_MB=$(( MEM_MB / 2 ))
    else                               SWAP_SIZE_MB=4096
    fi

    ## Hard cap: swap must never exceed 10% of total disk capacity
    local swap_dir disk_total_mb disk_cap_mb
    swap_dir=$(dirname "$SWAP_PATH")
    disk_total_mb=$(df -Pm "$swap_dir" 2>/dev/null | awk 'NR==2 {print $2}')
    if [ -n "$disk_total_mb" ] && [ "$disk_total_mb" -gt 0 ]; then
        disk_cap_mb=$(( disk_total_mb / 10 ))
        if [ "$SWAP_SIZE_MB" -gt "$disk_cap_mb" ]; then
            SWAP_SIZE_MB=$disk_cap_mb
            yellow_msg "SWAP capped at 10% of disk (${disk_total_mb}MB total): ${SWAP_SIZE_MB}MB."
        fi
    fi

    ## Guard against a zero-size swapfile on very small disks
    if [ "$SWAP_SIZE_MB" -lt 64 ]; then
        SWAP_SIZE_MB=64
    fi

    SWAP_SIZE="${SWAP_SIZE_MB}M"
}


detect_system_resources


# Root
check_if_running_as_root() {
    ## If you want to run as another user, please modify $EUID to be owned by this user
    if [[ "$EUID" -ne '0' ]]; then
      echo 
      red_msg 'Error: You must run this script as root!'
      echo 
      sleep 0.5
      exit 1
    fi
}


# Check Root
check_if_running_as_root
sleep 0.5


# Ask Reboot
ask_reboot() {
    yellow_msg 'Reboot now? (RECOMMENDED) (y/n)'
    echo 
    while true; do
        read choice
        echo 
        if [[ "$choice" == 'y' || "$choice" == 'Y' ]]; then
            sleep 0.5
            reboot
            exit 0
        fi
        if [[ "$choice" == 'n' || "$choice" == 'N' ]]; then
            break
        fi
    done
}


# Update & Upgrade & Remove & Clean
complete_update() {
    echo 
    yellow_msg 'Updating the System... (This can take a while.)'
    echo 
    sleep 0.5

    sudo dnf -y up
    sudo dnf -y autoremove
    sudo dnf -y clean all
    sleep 0.5
    
    ## Again :D
    sudo dnf -y up
    sudo dnf -y autoremove
    
    echo 
    green_msg 'System Updated & Cleaned Successfully.'
    echo 
    sleep 0.5
}


# Install useful packages
installations() {
    echo 
    yellow_msg 'Installing Useful Packages... (This can take a while.)'
    echo 
    sleep 0.5

    ## Install EPEL repository
    sudo dnf -y install epel-release

    ## Update for the EPEL
    sudo dnf -y up

    ## System utilities
    sudo dnf -y install bash-completion ca-certificates crontabs curl dnf-plugins-core dnf-utils gnupg2 nano screen ufw unzip vim wget zip

    ## Programming and development tools
    sudo dnf -y install autoconf automake bash-completion git libtool make pkg-config python3 python3-pip

    ## Additional libraries and dependencies
    sudo dnf -y install bc binutils haveged jq libsodium libsodium-devel PackageKit qrencode socat

    ## Miscellaneous
    sudo dnf -y install dialog htop net-tools

    echo 
    green_msg 'Useful Packages Installed Succesfully.'
    echo 
    sleep 0.5
}


# Enable packages at server boot
enable_packages() {
    sudo systemctl enable crond.service haveged
    echo 
    green_msg 'Packages Enabled Succesfully.'
    echo
    sleep 0.5
}


## Swap Maker
swap_maker() {
    echo
    yellow_msg 'Making SWAP Space...'
    echo
    sleep 0.5

    ## Skip if swap is already active
    if [ -n "$(swapon --show 2>/dev/null)" ]; then
        green_msg 'SWAP already active. Skipping.'
        echo
        sleep 0.5
        return
    fi

    ## Size SWAP to installed RAM instead of a fixed 2G
    calculate_swap_size
    yellow_msg "Sizing SWAP to ${SWAP_SIZE} for ${MEM_MB}MB RAM."
    echo

    ## Make Swap
    sudo fallocate -l $SWAP_SIZE $SWAP_PATH || sudo dd if=/dev/zero of=$SWAP_PATH bs=1M count=$SWAP_SIZE_MB status=none  ## Allocate size (fallocate can fail on some filesystems)
    sudo chmod 600 $SWAP_PATH                ## Set proper permission
    sudo mkswap $SWAP_PATH                   ## Setup swap
    sudo swapon $SWAP_PATH                   ## Enable swap
    echo "$SWAP_PATH   none    swap    sw    0   0" >> /etc/fstab ## Add to fstab

    echo
    green_msg 'SWAP Created Successfully.'
    echo
    sleep 0.5
}


# SYSCTL Optimization
sysctl_optimizations() {
    ## Make a backup of the original sysctl.conf file
    cp $SYS_PATH /etc/sysctl.conf.bak

    echo 
    yellow_msg 'Default sysctl.conf file Saved. Directory: /etc/sysctl.conf.bak'
    echo 
    sleep 1

    echo
    yellow_msg 'Optimizing the Network...'
    echo
    sleep 0.5

    ## Compute values scaled to this machine's CPU/RAM, and pick BBR vs cubic
    calculate_network_values
    select_congestion_control

    sed -i -e '/fs.file-max/d' \
        -e '/net.core.default_qdisc/d' \
        -e '/net.core.netdev_max_backlog/d' \
        -e '/net.core.optmem_max/d' \
        -e '/net.core.somaxconn/d' \
        -e '/net.core.rmem_max/d' \
        -e '/net.core.wmem_max/d' \
        -e '/net.core.rmem_default/d' \
        -e '/net.core.wmem_default/d' \
        -e '/net.ipv4.tcp_rmem/d' \
        -e '/net.ipv4.tcp_wmem/d' \
        -e '/net.ipv4.tcp_congestion_control/d' \
        -e '/net.ipv4.tcp_fastopen/d' \
        -e '/net.ipv4.tcp_fin_timeout/d' \
        -e '/net.ipv4.tcp_keepalive_time/d' \
        -e '/net.ipv4.tcp_keepalive_probes/d' \
        -e '/net.ipv4.tcp_keepalive_intvl/d' \
        -e '/net.ipv4.tcp_max_orphans/d' \
        -e '/net.ipv4.tcp_max_syn_backlog/d' \
        -e '/net.ipv4.tcp_max_tw_buckets/d' \
        -e '/net.ipv4.tcp_mem/d' \
        -e '/net.ipv4.tcp_mtu_probing/d' \
        -e '/net.ipv4.tcp_notsent_lowat/d' \
        -e '/net.ipv4.tcp_retries2/d' \
        -e '/net.ipv4.tcp_sack/d' \
        -e '/net.ipv4.tcp_dsack/d' \
        -e '/net.ipv4.tcp_slow_start_after_idle/d' \
        -e '/net.ipv4.tcp_window_scaling/d' \
        -e '/net.ipv4.tcp_adv_win_scale/d' \
        -e '/net.ipv4.tcp_ecn/d' \
        -e '/net.ipv4.tcp_ecn_fallback/d' \
        -e '/net.ipv4.tcp_syncookies/d' \
        -e '/net.ipv4.udp_mem/d' \
        -e '/net.ipv6.conf.all.disable_ipv6/d' \
        -e '/net.ipv6.conf.default.disable_ipv6/d' \
        -e '/net.ipv6.conf.lo.disable_ipv6/d' \
        -e '/net.unix.max_dgram_qlen/d' \
        -e '/vm.min_free_kbytes/d' \
        -e '/vm.swappiness/d' \
        -e '/vm.vfs_cache_pressure/d' \
        -e '/net.ipv4.conf.default.rp_filter/d' \
        -e '/net.ipv4.conf.all.rp_filter/d' \
        -e '/net.ipv4.conf.all.accept_source_route/d' \
        -e '/net.ipv4.conf.default.accept_source_route/d' \
        -e '/net.ipv4.neigh.default.gc_thresh1/d' \
        -e '/net.ipv4.neigh.default.gc_thresh2/d' \
        -e '/net.ipv4.neigh.default.gc_thresh3/d' \
        -e '/net.ipv4.neigh.default.gc_stale_time/d' \
        -e '/net.ipv4.conf.default.arp_announce/d' \
        -e '/net.ipv4.conf.lo.arp_announce/d' \
        -e '/net.ipv4.conf.all.arp_announce/d' \
        -e '/kernel.panic/d' \
        -e '/vm.dirty_ratio/d' \
        -e '/vm.overcommit_memory/d' \
        -e '/vm.overcommit_ratio/d' \
        -e '/vm.dirty_background_ratio/d' \
        -e '/net.ipv4.ip_local_port_range/d' \
        -e '/net.ipv4.tcp_tw_reuse/d' \
        -e '/net.ipv4.tcp_orphan_retries/d' \
        -e '/net.ipv4.tcp_synack_retries/d' \
        -e '/net.ipv4.tcp_timestamps/d' \
        -e '/net.ipv4.tcp_rfc1337/d' \
        -e '/net.core.netdev_budget/d' \
        -e '/fs.inotify.max_user_watches/d' \
        -e '/fs.nr_open/d' \
        -e '/kernel.pid_max/d' \
        -e '/net.ipv4.icmp_echo_ignore_broadcasts/d' \
        -e '/net.ipv4.icmp_ignore_bogus_error_responses/d' \
        -e '/net.ipv4.conf.all.accept_redirects/d' \
        -e '/net.ipv4.conf.default.accept_redirects/d' \
        -e '/net.ipv4.conf.all.secure_redirects/d' \
        -e '/net.ipv4.conf.all.send_redirects/d' \
        -e '/net.ipv4.conf.default.send_redirects/d' \
        -e '/net.ipv6.conf.all.accept_redirects/d' \
        -e '/net.ipv6.conf.default.accept_redirects/d' \
        -e '/net.ipv4.conf.all.log_martians/d' \
        -e '/^#/d' \
        -e '/^$/d' \
        "$SYS_PATH"


    ## Add new parameteres. Read More: https://github.com/hawshemi/Linux-Optimizer/blob/main/files/sysctl.conf

cat <<EOF >> "$SYS_PATH"


################################################################
################################################################


# /etc/sysctl.conf
# These parameters in this file will be added/updated to the sysctl.conf file.
# Read More: https://github.com/hawshemi/Linux-Optimizer/blob/main/files/sysctl.conf


## File system settings
## ----------------------------------------------------------------

# Set the maximum number of open file descriptors (scaled to RAM)
fs.file-max = $FS_FILE_MAX


## Network core settings
## ----------------------------------------------------------------

# Specify default queuing discipline for network devices
net.core.default_qdisc = $QDISC

# Configure maximum network device backlog (scaled to CPU cores)
net.core.netdev_max_backlog = $NETDEV_BACKLOG

# Set maximum socket receive buffer
net.core.optmem_max = $OPTMEM_MAX

# Define maximum backlog of pending connections (scaled to CPU cores)
net.core.somaxconn = $SOMAXCONN

# Configure maximum TCP receive buffer size (scaled to RAM)
net.core.rmem_max = $RMEM_WMEM_MAX

# Set default TCP receive buffer size
net.core.rmem_default = $RMEM_DEFAULT

# Configure maximum TCP send buffer size (scaled to RAM)
net.core.wmem_max = $RMEM_WMEM_MAX

# Set default TCP send buffer size
net.core.wmem_default = $WMEM_DEFAULT


## TCP settings
## ----------------------------------------------------------------

# Define socket receive buffer sizes
net.ipv4.tcp_rmem = 4096 $TCP_RMEM_DEFAULT $RMEM_WMEM_MAX

# Specify socket send buffer sizes
net.ipv4.tcp_wmem = 4096 $TCP_WMEM_DEFAULT $RMEM_WMEM_MAX

# Set TCP congestion control algorithm (BBR if kernel supports it, else cubic)
net.ipv4.tcp_congestion_control = $CONGESTION_CONTROL

# Configure TCP FIN timeout period
net.ipv4.tcp_fin_timeout = 25

# Set keepalive time (seconds)
net.ipv4.tcp_keepalive_time = 1200

# Configure keepalive probes count and interval
net.ipv4.tcp_keepalive_probes = 7
net.ipv4.tcp_keepalive_intvl = 30

# Define maximum orphaned TCP sockets (scaled to CPU cores)
net.ipv4.tcp_max_orphans = $TCP_MAX_ORPHANS

# Set maximum TCP SYN backlog (scaled to CPU cores)
net.ipv4.tcp_max_syn_backlog = $TCP_MAX_SYN_BACKLOG

# Configure maximum TCP Time Wait buckets (scaled to CPU cores)
net.ipv4.tcp_max_tw_buckets = $TCP_MAX_TW_BUCKETS

# Define TCP memory limits, in pages (scaled to RAM)
net.ipv4.tcp_mem = $TCP_MEM_MIN $TCP_MEM_PRESSURE $TCP_MEM_MAX

# Enable TCP MTU probing
net.ipv4.tcp_mtu_probing = 1

# Define the minimum amount of data in the send buffer before TCP starts sending
net.ipv4.tcp_notsent_lowat = 32768

# Specify retries for TCP socket to establish connection
net.ipv4.tcp_retries2 = 8

# Enable TCP SACK and DSACK
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1

# Disable TCP slow start after idle
net.ipv4.tcp_slow_start_after_idle = 0

# Enable TCP window scaling
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = -2

# Enable TCP ECN
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1

# Enable the use of TCP SYN cookies to help protect against SYN flood attacks
net.ipv4.tcp_syncookies = 1


## UDP settings
## ----------------------------------------------------------------

# Define UDP memory limits, in pages (scaled to RAM)
net.ipv4.udp_mem = $TCP_MEM_MIN $TCP_MEM_PRESSURE $TCP_MEM_MAX


## IPv6 settings
## ----------------------------------------------------------------

# Enable IPv6
#net.ipv6.conf.all.disable_ipv6 = 0

# Enable IPv6 by default
#net.ipv6.conf.default.disable_ipv6 = 0

# Enable IPv6 on the loopback interface (lo)
#net.ipv6.conf.lo.disable_ipv6 = 0


## UNIX domain sockets
## ----------------------------------------------------------------

# Set maximum queue length of UNIX domain sockets
net.unix.max_dgram_qlen = 256


## Virtual memory (VM) settings
## ----------------------------------------------------------------

# Specify minimum free Kbytes at which VM pressure happens (scaled to RAM)
vm.min_free_kbytes = $VM_MIN_FREE_KBYTES

# Define how aggressively swap memory pages are used (minimized: scaled to RAM)
vm.swappiness = $SWAPPINESS

# Set the tendency of the kernel to reclaim memory used for caching of directory and inode objects
vm.vfs_cache_pressure = 100


## Network Configuration
## ----------------------------------------------------------------

# Configure reverse path filtering (loose mode: keeps anti-spoof protection, tolerates asymmetric routing)
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.rp_filter = 2

# Disable source route acceptance
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Neighbor table settings (scaled to CPU cores)
net.ipv4.neigh.default.gc_thresh1 = $GC_THRESH1
net.ipv4.neigh.default.gc_thresh2 = $GC_THRESH2
net.ipv4.neigh.default.gc_thresh3 = $GC_THRESH3
net.ipv4.neigh.default.gc_stale_time = 60

# ARP settings
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.lo.arp_announce = 2
net.ipv4.conf.all.arp_announce = 2

# Kernel panic timeout
kernel.panic = 1

# Dirty page writeback thresholds (scaled to RAM, avoids multi-GB flush stalls on large-RAM boxes)
vm.dirty_ratio = $DIRTY_RATIO
vm.dirty_background_ratio = $DIRTY_BG_RATIO

# Heuristic overcommit (kernel default): allows normal fork()/COW behavior without an artificial cap
vm.overcommit_memory = 0

# Only used if overcommit_memory is switched to 2 (strict) later
vm.overcommit_ratio = 100


## Additional TCP tuning
## ----------------------------------------------------------------

# Widen ephemeral port range for high outbound connection counts
net.ipv4.ip_local_port_range = 1024 65535

# Reuse TIME_WAIT sockets for new outbound connections
net.ipv4.tcp_tw_reuse = 1

# Drop dead orphaned / half-open connections faster
net.ipv4.tcp_orphan_retries = 2
net.ipv4.tcp_synack_retries = 2

# Keep TCP timestamps on (needed for PAWS and high performance)
net.ipv4.tcp_timestamps = 1

# Enable TCP Fast Open for both client and server
net.ipv4.tcp_fastopen = 3

# Protect against TIME_WAIT assassination
net.ipv4.tcp_rfc1337 = 1

# Raise packet processing budget per NAPI poll
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 4000


## File & process limits
## ----------------------------------------------------------------

# Raise inotify watch ceiling (file watchers, build tools, containers)
fs.inotify.max_user_watches = 524288

# Raise system-wide max open file descriptor ceiling
fs.nr_open = 2097152

# Allow a large PID space on high-density servers
kernel.pid_max = 4194304


## Network hardening
## ----------------------------------------------------------------

# Ignore ICMP broadcast and bogus error responses
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Do not accept or send ICMP redirects (host is not a router)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Log packets with impossible (martian) source addresses
net.ipv4.conf.all.log_martians = 1

################################################################
################################################################


EOF

    sudo sysctl -p
    
    echo 
    green_msg 'Network is Optimized.'
    echo 
    sleep 0.5
}


# Function to find the SSH port and set it in the SSH_PORT variable
find_ssh_port() {
    echo 
    yellow_msg "Finding SSH port..."
    echo 

    ## Check if the SSH configuration file exists
    if [ -e "$SSH_PATH" ]; then
        ## Use grep to search for the 'Port' directive in the SSH configuration file
        SSH_PORT=$(grep -oP '^Port\s+\K\d+' "$SSH_PATH" 2>/dev/null)

        if [ -n "$SSH_PORT" ]; then
            echo 
            green_msg "SSH port found: $SSH_PORT"
            echo 
            sleep 0.5
        else
            echo 
            green_msg "SSH port is default 22."
            echo 
            SSH_PORT=22
            sleep 0.5
        fi
    else
        red_msg "SSH configuration file not found at $SSH_PATH"
    fi
}


# Remove old SSH config to prevent duplicates.
remove_old_ssh_conf() {
    ## Make a backup of the original sshd_config file
    cp $SSH_PATH /etc/ssh/sshd_config.bak

    echo 
    yellow_msg 'Default SSH Config file Saved. Directory: /etc/ssh/sshd_config.bak'
    echo 
    sleep 1

    ## Remove these lines
    sed -i -e 's/#UseDNS yes/UseDNS no/' \
        -e 's/#Compression no/Compression yes/' \
        -e 's/Ciphers .*/Ciphers aes256-ctr,chacha20-poly1305@openssh.com/' \
        -e '/MaxAuthTries/d' \
        -e '/MaxSessions/d' \
        -e '/TCPKeepAlive/d' \
        -e '/ClientAliveInterval/d' \
        -e '/ClientAliveCountMax/d' \
        -e '/AllowAgentForwarding/d' \
        -e '/AllowTcpForwarding/d' \
        -e '/GatewayPorts/d' \
        -e '/PermitTunnel/d' \
        -e '/X11Forwarding/d' "$SSH_PATH"

}


# Update SSH config
update_sshd_conf() {
    echo 
    yellow_msg 'Optimizing SSH...'
    echo 
    sleep 0.5

    ## Enable TCP keep-alive messages
    echo "TCPKeepAlive yes" | tee -a "$SSH_PATH"

    ## Configure client keep-alive messages
    echo "ClientAliveInterval 3000" | tee -a "$SSH_PATH"
    echo "ClientAliveCountMax 100" | tee -a "$SSH_PATH"

    ## Allow TCP forwarding
    echo "AllowTcpForwarding yes" | tee -a "$SSH_PATH"

    ## Enable gateway ports
    echo "GatewayPorts yes" | tee -a "$SSH_PATH"

    ## Enable tunneling
    echo "PermitTunnel yes" | tee -a "$SSH_PATH"

    ## Enable X11 graphical interface forwarding
    echo "X11Forwarding yes" | tee -a "$SSH_PATH"

    ## Restart the SSH service to apply the changes
    sudo systemctl restart sshd

    echo 
    green_msg 'SSH is Optimized.'
    echo 
    sleep 0.5
}


# System Limits Optimizations
limits_optimizations() {
    echo
    yellow_msg 'Optimizing System Limits...'
    echo 
    sleep 0.5

    ## Clear old ulimits
    sed -i '/ulimit -c/d' $PROF_PATH
    sed -i '/ulimit -d/d' $PROF_PATH
    sed -i '/ulimit -f/d' $PROF_PATH
    sed -i '/ulimit -i/d' $PROF_PATH
    sed -i '/ulimit -l/d' $PROF_PATH
    sed -i '/ulimit -m/d' $PROF_PATH
    sed -i '/ulimit -n/d' $PROF_PATH
    sed -i '/ulimit -q/d' $PROF_PATH
    sed -i '/ulimit -s/d' $PROF_PATH
    sed -i '/ulimit -t/d' $PROF_PATH
    sed -i '/ulimit -u/d' $PROF_PATH
    sed -i '/ulimit -v/d' $PROF_PATH
    sed -i '/ulimit -x/d' $PROF_PATH
    sed -i '/ulimit -s/d' $PROF_PATH


    ## Add new ulimits
    ## The maximum size of core files created.
    echo "ulimit -c unlimited" | tee -a $PROF_PATH

    ## The maximum size of a process's data segment
    echo "ulimit -d unlimited" | tee -a $PROF_PATH

    ## The maximum size of files created by the shell (default option)
    echo "ulimit -f unlimited" | tee -a $PROF_PATH

    ## The maximum number of pending signals
    echo "ulimit -i unlimited" | tee -a $PROF_PATH

    ## The maximum size that may be locked into memory
    echo "ulimit -l unlimited" | tee -a $PROF_PATH

    ## The maximum memory size
    echo "ulimit -m unlimited" | tee -a $PROF_PATH

    ## The maximum number of open file descriptors
    echo "ulimit -n 1048576" | tee -a $PROF_PATH

    ## The maximum POSIX message queue size
    echo "ulimit -q unlimited" | tee -a $PROF_PATH

    ## The maximum stack size
    echo "ulimit -s -H 65536" | tee -a $PROF_PATH
    echo "ulimit -s 32768" | tee -a $PROF_PATH

    ## The maximum number of seconds to be used by each process.
    echo "ulimit -t unlimited" | tee -a $PROF_PATH

    ## The maximum number of processes available to a single user
    echo "ulimit -u unlimited" | tee -a $PROF_PATH

    ## The maximum amount of virtual memory available to the process
    echo "ulimit -v unlimited" | tee -a $PROF_PATH

    ## The maximum number of file locks
    echo "ulimit -x unlimited" | tee -a $PROF_PATH


    echo 
    green_msg 'System Limits are Optimized.'
    echo 
    sleep 0.5
}


# UFW Optimizations
ufw_optimizations() {
    echo
    yellow_msg 'Installing & Optimizing UFW...'
    echo 
    sleep 0.5

    ## Purge firewalld to install UFW.
    sudo dnf -y remove firewalld

    ## Install UFW if not installed.
    dnf -y install epel-release
    dnf -y up
    dnf -y install ufw
    
    ## Disable UFW
    sudo ufw disable

    ## Open default ports.
    sudo ufw allow $SSH_PORT
    sudo ufw allow 80/tcp
    sudo ufw allow 80/udp
    sudo ufw allow 443/tcp
    sudo ufw allow 443/udp
    sleep 0.5

    ## Change the UFW config to use System config.
    sed -i 's+/etc/ufw/sysctl.conf+/etc/sysctl.conf+gI' /etc/default/ufw

    ## Enable & Reload
    echo "y" | sudo ufw enable
    sudo ufw reload
    echo 
    green_msg 'UFW is Installed & Optimized. (Open your custom ports manually.)'
    echo 
    sleep 0.5
}


# Show the Menu
show_menu() {
    echo 
    yellow_msg 'Choose One Option: '
    echo 
    green_msg '1  - Apply Everything. (RECOMMENDED)'
    echo 
    green_msg '2  - Complete Update + Make SWAP + Optimize Network, SSH & System Limits + UFW'
    green_msg '3  - Complete Update + Make SWAP + Optimize Network, SSH & System Limits'
    echo 
    green_msg '4  - Complete Update & Clean the OS.'
    green_msg '5  - Install Useful Packages.'
    green_msg '6  - Make SWAP (2Gb).'
    green_msg '7  - Optimize the Network, SSH & System Limits.'
    echo 
    green_msg '8  - Optimize the Network settings.'
    green_msg '9  - Optimize the SSH settings.'
    green_msg '10 - Optimize the System Limits.'
    echo 
    green_msg '11 - Install & Optimize UFW.'
    echo 
    red_msg 'q - Exit.'
    echo 
}


# Choosing Program
main() {
    while true; do
        show_menu
        read -p 'Enter Your Choice: ' choice
        case $choice in
        1)
            apply_everything

            echo 
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='

            ask_reboot
            ;;
        2)
            complete_update
            sleep 0.5

            swap_maker
            sleep 0.5

            sysctl_optimizations
            sleep 0.5

            remove_old_ssh_conf
            sleep 0.5
    
            update_sshd_conf
            sleep 0.5

            limits_optimizations
            sleep 0.5

            find_ssh_port
            ufw_optimizations
            sleep 0.5

            echo 
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='

            ask_reboot
            ;;
        3)
            complete_update
            sleep 0.5

            swap_maker
            sleep 0.5

            sysctl_optimizations
            sleep 0.5

            remove_old_ssh_conf
            sleep 0.5
    
            update_sshd_conf
            sleep 0.5

            limits_optimizations
            sleep 0.5

            echo 
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='

            ask_reboot
            ;;
        4)
            complete_update
            sleep 0.5

            echo 
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='

            ask_reboot
            ;;
            
        5)
            complete_update
            installations
            enable_packages
            sleep 0.5

            echo 
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='

            ask_reboot
            ;;
        6)
            swap_maker
            sleep 0.5

            echo 
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='

            ask_reboot
            ;;
        7)
            sysctl_optimizations
            sleep 0.5

            remove_old_ssh_conf
            sleep 0.5
    
            update_sshd_conf
            sleep 0.5

            limits_optimizations
            sleep 0.5

            echo 
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='

            ask_reboot
            ;;
        8)
            sysctl_optimizations
            sleep 0.5

            echo 
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='

            ;;
        9)
            remove_old_ssh_conf
            sleep 0.5
    
            update_sshd_conf
            sleep 0.5

            echo 
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='

            ;;
        10)
            limits_optimizations
            sleep 0.5

            echo 
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='

            ask_reboot
            ;;
        11)
            find_ssh_port
            ufw_optimizations
            sleep 0.5

            echo 
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='

            ask_reboot
            ;;
        q)
            exit 0
            ;;

        *)
            red_msg 'Wrong input!'
            ;;
        esac
    done
}


# Apply Everything
apply_everything() {

    complete_update
    sleep 0.5

    installations
    sleep 0.5

    enable_packages
    sleep 0.5

    swap_maker
    sleep 0.5

    sysctl_optimizations
    sleep 0.5

    remove_old_ssh_conf
    sleep 0.5
    
    update_sshd_conf
    sleep 0.5

    limits_optimizations
    sleep 0.5

    find_ssh_port
    ufw_optimizations
    sleep 0.5
}


main
