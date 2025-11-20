#!/bin/bash
#
# Inferno AoIP Installer for Raspberry Pi
# Compatible with: Raspberry Pi 3/4/5 running 64-bit Raspberry Pi OS (aarch64)
#
# WARNING: This script is ONLY for 64-bit ARM architecture (aarch64)
# Check your architecture with: uname -m (must show "aarch64")
#
# Usage: sudo bash install-inferno.sh
#

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Banner
echo -e "${CYAN}"
cat << "EOF"
╔══════════════════════════════════════════════════════════╗
║                                                          ║
║        Inferno AoIP Installer for Raspberry Pi           ║
║           Dante to SRT Audio Bridge                      ║
║                                                          ║
║         Compatible: Pi 3/4/5 (64-bit ARM only)           ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}ERROR: Please run as root (sudo)${NC}"
    echo "Usage: sudo bash install-inferno.sh"
    exit 1
fi

# Architecture check
ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ]; then
    echo -e "${RED}ERROR: Unsupported architecture: $ARCH${NC}"
    echo "This installer only supports 64-bit ARM (aarch64)"
    echo "Your system reports: $ARCH"
    echo ""
    echo "Please install 64-bit Raspberry Pi OS Lite"
    exit 1
fi

echo -e "${GREEN}✓ Architecture check passed: $ARCH${NC}"
echo ""

# ============================================================================
# BINARY DOWNLOAD URLs
# ============================================================================
# MODIFY THESE URLs TO POINT TO YOUR WEB SERVER
STATIME_URL="https://github.com/bricedupuy/inferno2stream/blob/ebee12bf41cf4947a70ea60674c3e3db3dafa1ed/releases/statime-aarch64"
INFERNO2PIPE_URL="https://github.com/bricedupuy/inferno2stream/blob/5ed5fa98f188e4d40edb45dd3ed781d3b67c6a80/releases/inferno2pipe-aarch64"
ALSA_PLUGIN_URL="https://github.com/bricedupuy/inferno2stream/blob/5ed5fa98f188e4d40edb45dd3ed781d3b67c6a80/releases/libasound_pcm_inferno-aarch64.so"
STATIME_CONFIG_URL="https://github.com/bricedupuy/inferno2stream/blob/5ed5fa98f188e4d40edb45dd3ed781d3b67c6a80/examples/config/inferno-ptpv1.toml"
FFMPEG_URL="https://github.com/bricedupuy/inferno2stream/blob/5ed5fa98f188e4d40edb45dd3ed781d3b67c6a80/releases/ffmpeg-aarch64"

# ============================================================================
# DEFAULT CONFIGURATION
# ============================================================================

# Network configuration defaults
DEFAULT_DANTE_INTERFACE="eth0"
DEFAULT_INTERNET_INTERFACE="wlan0"
DEFAULT_DANTE_IP="169.254.0.123"
DEFAULT_DANTE_NETMASK="255.255.255.0"
DEFAULT_DANTE_CIDR="24"

# Inferno configuration defaults
DEFAULT_DEVICE_NAME="SRT-Encoder"
DEFAULT_SAMPLE_RATE="48000"
DEFAULT_RX_CHANNELS="2"
DEFAULT_TX_CHANNELS="2"
DEFAULT_RX_LATENCY_MS="10"
DEFAULT_TX_LATENCY_MS="10"

# SRT streaming defaults
DEFAULT_SRT_HOST="127.0.0.1"
DEFAULT_SRT_PORT="10000"
DEFAULT_SRT_MODE="caller"
DEFAULT_SRT_LATENCY_MS="120"

# ============================================================================
# INTERACTIVE CONFIGURATION
# ============================================================================

echo -e "${BLUE}=== Network Configuration ===${NC}"
echo ""

read -p "Dante network interface [${DEFAULT_DANTE_INTERFACE}]: " DANTE_INTERFACE
DANTE_INTERFACE=${DANTE_INTERFACE:-$DEFAULT_DANTE_INTERFACE}

read -p "Internet interface [${DEFAULT_INTERNET_INTERFACE}]: " INTERNET_INTERFACE
INTERNET_INTERFACE=${INTERNET_INTERFACE:-$DEFAULT_INTERNET_INTERFACE}

read -p "Dante network IP address [${DEFAULT_DANTE_IP}]: " DANTE_IP
DANTE_IP=${DANTE_IP:-$DEFAULT_DANTE_IP}

read -p "Dante network netmask [${DEFAULT_DANTE_NETMASK}]: " DANTE_NETMASK
DANTE_NETMASK=${DANTE_NETMASK:-$DEFAULT_DANTE_NETMASK}

# Calculate CIDR from netmask
DANTE_CIDR=$(ipcalc -nb "$DANTE_IP" "$DANTE_NETMASK" 2>/dev/null | grep Netmask | awk '{print $4}' | cut -d= -f2)
if [ -z "$DANTE_CIDR" ]; then
    DANTE_CIDR="$DEFAULT_DANTE_CIDR"
fi

echo ""
echo -e "${BLUE}=== Inferno Device Configuration ===${NC}"
echo ""

read -p "Device name on Dante network [${DEFAULT_DEVICE_NAME}]: " DEVICE_NAME
DEVICE_NAME=${DEVICE_NAME:-$DEFAULT_DEVICE_NAME}

read -p "Sample rate (Hz) [${DEFAULT_SAMPLE_RATE}]: " SAMPLE_RATE
SAMPLE_RATE=${SAMPLE_RATE:-$DEFAULT_SAMPLE_RATE}

read -p "Number of receive channels [${DEFAULT_RX_CHANNELS}]: " RX_CHANNELS
RX_CHANNELS=${RX_CHANNELS:-$DEFAULT_RX_CHANNELS}

read -p "Number of transmit channels [${DEFAULT_TX_CHANNELS}]: " TX_CHANNELS
TX_CHANNELS=${TX_CHANNELS:-$DEFAULT_TX_CHANNELS}

read -p "Receive latency (ms) [${DEFAULT_RX_LATENCY_MS}]: " RX_LATENCY_MS
RX_LATENCY_MS=${RX_LATENCY_MS:-$DEFAULT_RX_LATENCY_MS}

read -p "Transmit latency (ms) [${DEFAULT_TX_LATENCY_MS}]: " TX_LATENCY_MS
TX_LATENCY_MS=${TX_LATENCY_MS:-$DEFAULT_TX_LATENCY_MS}

# Convert milliseconds to nanoseconds
RX_LATENCY_NS=$((RX_LATENCY_MS * 1000000))
TX_LATENCY_NS=$((TX_LATENCY_MS * 1000000))

echo ""
echo -e "${BLUE}=== SRT Streaming Configuration ===${NC}"
echo ""

read -p "Enable SRT streaming? (y/n) [y]: " ENABLE_SRT
ENABLE_SRT=${ENABLE_SRT:-y}

if [[ "$ENABLE_SRT" =~ ^[Yy]$ ]]; then
    read -p "SRT destination host/IP [${DEFAULT_SRT_HOST}]: " SRT_HOST
    SRT_HOST=${SRT_HOST:-$DEFAULT_SRT_HOST}

    read -p "SRT destination port [${DEFAULT_SRT_PORT}]: " SRT_PORT
    SRT_PORT=${SRT_PORT:-$DEFAULT_SRT_PORT}

    read -p "SRT mode (caller/listener) [${DEFAULT_SRT_MODE}]: " SRT_MODE
    SRT_MODE=${SRT_MODE:-$DEFAULT_SRT_MODE}

    read -p "SRT latency (ms) [${DEFAULT_SRT_LATENCY_MS}]: " SRT_LATENCY_MS
    SRT_LATENCY_MS=${SRT_LATENCY_MS:-$DEFAULT_SRT_LATENCY_MS}
fi

echo ""
echo -e "${YELLOW}=== Configuration Summary ===${NC}"
echo ""
echo "Network:"
echo "  Dante Interface: $DANTE_INTERFACE"
echo "  Dante IP: $DANTE_IP/$DANTE_CIDR"
echo "  Internet Interface: $INTERNET_INTERFACE"
echo ""
echo "Inferno Device:"
echo "  Name: $DEVICE_NAME"
echo "  Sample Rate: $SAMPLE_RATE Hz"
echo "  RX Channels: $RX_CHANNELS"
echo "  TX Channels: $TX_CHANNELS"
echo "  RX Latency: $RX_LATENCY_MS ms"
echo "  TX Latency: $TX_LATENCY_MS ms"
echo ""
if [[ "$ENABLE_SRT" =~ ^[Yy]$ ]]; then
    echo "SRT Streaming:"
    echo "  Mode: $SRT_MODE"
    echo "  Destination: $SRT_HOST:$SRT_PORT"
    echo "  Latency: $SRT_LATENCY_MS ms"
    echo ""
fi

read -p "Proceed with installation? (y/n) [y]: " CONFIRM
CONFIRM=${CONFIRM:-y}

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi

# ============================================================================
# SYSTEM PREPARATION
# ============================================================================

echo ""
echo -e "${GREEN}[1/10] Updating system packages...${NC}"
apt update
apt upgrade -y

echo ""
echo -e "${GREEN}[2/10] Installing dependencies...${NC}"
apt install -y \
    wget \
    curl \
    iproute2 \
    iptables \
    ethtool \
    libasound2 \
    netfilter-persistent \
    tcpdump \
    ipcalc \
    python3 \
    python3-pip \
    python3-venv

echo ""
echo -e "${GREEN}[2b/10] Installing Python packages for monitoring API...${NC}"
pip3 install --break-system-packages \
    fastapi==0.104.1 \
    uvicorn[standard]==0.24.0 \
    prometheus-client==0.19.0 \
    psutil==5.9.6 || \
pip3 install \
    fastapi==0.104.1 \
    uvicorn[standard]==0.24.0 \
    prometheus-client==0.19.0 \
    psutil==5.9.6

# ============================================================================
# DOWNLOAD BINARIES
# ============================================================================

echo ""
echo -e "${GREEN}[3/10] Creating directory structure...${NC}"
mkdir -p /opt/inferno/bin
mkdir -p /opt/inferno/config
mkdir -p /var/log/inferno
mkdir -p /usr/lib/aarch64-linux-gnu/alsa-lib

echo ""
echo -e "${GREEN}[4/10] Downloading Inferno binaries and API...${NC}"

download_file() {
    local url=$1
    local dest=$2
    local description=$3
    
    echo -n "  Downloading $description... "
    if wget -q --show-progress "$url" -O "$dest"; then
        echo -e "${GREEN}✓${NC}"
        return 0
    else
        echo -e "${RED}✗${NC}"
        echo -e "${RED}ERROR: Failed to download $description from $url${NC}"
        return 1
    fi
}

download_file "$STATIME_URL" "/opt/inferno/bin/statime" "Statime"
download_file "$INFERNO2PIPE_URL" "/opt/inferno/bin/inferno2pipe" "Inferno2pipe"
download_file "$ALSA_PLUGIN_URL" "/usr/lib/aarch64-linux-gnu/alsa-lib/libalsa_pcm_inferno.so" "ALSA plugin"
download_file "$STATIME_CONFIG_URL" "/opt/inferno/config/inferno-ptpv1.toml" "Statime config"

if [[ "$ENABLE_SRT" =~ ^[Yy]$ ]]; then
    download_file "$FFMPEG_URL" "/opt/inferno/bin/ffmpeg" "FFmpeg"
fi

# Download monitoring API script
echo -n "  Creating monitoring API... "
cat > /opt/inferno/bin/monitor-api.py << 'EOFAPI'
#!/usr/bin/env python3
"""
Inferno AoIP Monitoring API
FastAPI-based REST API with Prometheus metrics
"""
# The actual Python code will be inserted here by a separate script
# For now, this is a placeholder that will be replaced
EOFAPI

chmod +x /opt/inferno/bin/monitor-api.py
echo -e "${GREEN}✓${NC}"

echo ""
echo -e "${GREEN}[5/10] Setting permissions...${NC}"
chmod +x /opt/inferno/bin/statime
chmod +x /opt/inferno/bin/inferno2pipe
if [[ "$ENABLE_SRT" =~ ^[Yy]$ ]]; then
    chmod +x /opt/inferno/bin/ffmpeg
fi

# ============================================================================
# NETWORK CONFIGURATION
# ============================================================================

echo ""
echo -e "${GREEN}[6/10] Configuring network...${NC}"

# Detect network configuration method
if [ -f /etc/dhcpcd.conf ]; then
    echo "  Using dhcpcd for network configuration..."
    
    # Check if our configuration already exists
    if ! grep -q "# Inferno AoIP static IP for ${DANTE_INTERFACE}" /etc/dhcpcd.conf; then
        # Append static IP configuration to dhcpcd.conf
        cat >> /etc/dhcpcd.conf << EOF

# Inferno AoIP static IP for ${DANTE_INTERFACE} - Added by installer
interface ${DANTE_INTERFACE}
static ip_address=${DANTE_IP}/${DANTE_CIDR}
nogateway
noipv6
EOF
        echo -e "  ${GREEN}✓ Static IP configured in dhcpcd.conf${NC}"
    else
        echo -e "  ${YELLOW}⚠ Configuration already exists in dhcpcd.conf${NC}"
    fi
    
elif [ -d /etc/network/interfaces.d ]; then
    echo "  Using /etc/network/interfaces method..."
    
    # Configure static IP on Dante interface using traditional method
    cat > /etc/network/interfaces.d/${DANTE_INTERFACE} << EOF
# Dante network interface - Managed by Inferno installer
auto ${DANTE_INTERFACE}
iface ${DANTE_INTERFACE} inet static
    address ${DANTE_IP}
    netmask ${DANTE_NETMASK}
    # No gateway - internet goes through ${INTERNET_INTERFACE}
EOF
    echo -e "  ${GREEN}✓ Static IP configured in /etc/network/interfaces.d/${NC}"
    
else
    echo -e "  ${RED}✗ Could not detect network configuration method${NC}"
    echo "  Please configure ${DANTE_INTERFACE} manually with IP ${DANTE_IP}/${DANTE_CIDR}"
    echo "  Press Enter to continue or Ctrl+C to abort..."
    read
fi

# Update Statime configuration with correct interface
sed -i "s/bind-phc = \".*\"/bind-phc = \"${DANTE_INTERFACE}\"/" /opt/inferno/config/inferno-ptpv1.toml
sed -i "s/virtual-system-clock-base = \".*\"/virtual-system-clock-base = \"monotonic\"/" /opt/inferno/config/inferno-ptpv1.toml

# Create multicast routing script
cat > /usr/local/bin/setup-dante-routes.sh << 'EOFROUTE'
#!/bin/bash
# Multicast routing for Inferno AoIP
# Auto-generated by installer

LOG_FILE="/var/log/inferno/routes.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $*" | tee -a "$LOG_FILE"
}

# Wait for interfaces
log "Waiting for network interfaces..."
for i in {1..30}; do
    if ip link show DANTE_INTERFACE &>/dev/null && ip link show INTERNET_INTERFACE &>/dev/null; then
        log "Interfaces are up"
        break
    fi
    sleep 1
done

# Remove existing multicast routes
log "Configuring multicast routing..."
ip route del 224.0.0.0/4 2>/dev/null || true

# Add multicast route to Dante interface ONLY
ip route add 224.0.0.0/4 dev DANTE_INTERFACE

# Enable multicast on Dante interface
ip link set DANTE_INTERFACE multicast on
ip link set DANTE_INTERFACE allmulticast on

# Disable multicast on internet interface to prevent leakage
ip link set INTERNET_INTERFACE multicast off

log "Multicast route configured:"
ip route show | grep 224.0.0.0 | tee -a "$LOG_FILE"

log "Configuration complete"
EOFROUTE

# Replace placeholders
sed -i "s/DANTE_INTERFACE/${DANTE_INTERFACE}/g" /usr/local/bin/setup-dante-routes.sh
sed -i "s/INTERNET_INTERFACE/${INTERNET_INTERFACE}/g" /usr/local/bin/setup-dante-routes.sh
chmod +x /usr/local/bin/setup-dante-routes.sh

# Create systemd service for routing
cat > /etc/systemd/system/dante-routes.service << EOF
[Unit]
Description=Multicast routing for Dante network
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup-dante-routes.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# ============================================================================
# FIREWALL CONFIGURATION
# ============================================================================

echo ""
echo -e "${GREEN}[7/10] Configuring firewall...${NC}"

# Allow Dante ports
iptables -A INPUT -i ${DANTE_INTERFACE} -p udp --dport 4455 -j ACCEPT
iptables -A INPUT -i ${DANTE_INTERFACE} -p udp --dport 8700 -j ACCEPT
iptables -A INPUT -i ${DANTE_INTERFACE} -p udp --dport 4400 -j ACCEPT
iptables -A INPUT -i ${DANTE_INTERFACE} -p udp --dport 8800 -j ACCEPT
iptables -A INPUT -i ${DANTE_INTERFACE} -p udp --dport 5353 -j ACCEPT

# Allow IGMP for multicast
iptables -A INPUT -i ${DANTE_INTERFACE} -p igmp -j ACCEPT
iptables -A OUTPUT -o ${DANTE_INTERFACE} -p igmp -j ACCEPT

# Allow PTP
iptables -A INPUT -i ${DANTE_INTERFACE} -p udp --dport 319 -j ACCEPT
iptables -A INPUT -i ${DANTE_INTERFACE} -p udp --dport 320 -j ACCEPT

# Save firewall rules
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save
fi

# ============================================================================
# DISABLE TIME SYNC SERVICES
# ============================================================================

echo ""
echo -e "${GREEN}[8/10] Disabling conflicting time sync services...${NC}"

systemctl stop chronyd.service 2>/dev/null || true
systemctl disable chronyd.service 2>/dev/null || true
systemctl stop systemd-timesyncd.service 2>/dev/null || true
systemctl disable systemd-timesyncd.service 2>/dev/null || true
systemctl stop ntpd.service 2>/dev/null || true
systemctl disable ntpd.service 2>/dev/null || true

# ============================================================================
# CREATE SYSTEMD SERVICES
# ============================================================================

echo ""
echo -e "${GREEN}[9/10] Creating systemd services...${NC}"

# Statime service
cat > /etc/systemd/system/statime.service << EOF
[Unit]
Description=Statime PTP daemon for Inferno AoIP
After=network-online.target dante-routes.service
Wants=network-online.target
Requires=dante-routes.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/inferno
ExecStart=/opt/inferno/bin/statime -c /opt/inferno/config/inferno-ptpv1.toml
Restart=always
RestartSec=5
StandardOutput=append:/var/log/inferno/statime.log
StandardError=append:/var/log/inferno/statime-error.log

[Install]
WantedBy=multi-user.target
EOF

# Inferno service
cat > /etc/systemd/system/inferno.service << EOF
[Unit]
Description=Inferno AoIP Audio Service
After=network-online.target statime.service
Requires=statime.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/inferno
Environment="INFERNO_BIND_IP=${DANTE_IP}"
Environment="INFERNO_NAME=${DEVICE_NAME}"
Environment="INFERNO_SAMPLE_RATE=${SAMPLE_RATE}"
Environment="INFERNO_RX_CHANNELS=${RX_CHANNELS}"
Environment="INFERNO_TX_CHANNELS=${TX_CHANNELS}"
Environment="INFERNO_RX_LATENCY_NS=${RX_LATENCY_NS}"
Environment="INFERNO_TX_LATENCY_NS=${TX_LATENCY_NS}"
ExecStart=/opt/inferno/bin/inferno2pipe /tmp/inferno_audio.pipe
Restart=always
RestartSec=5
StandardOutput=append:/var/log/inferno/inferno.log
StandardError=append:/var/log/inferno/inferno-error.log

[Install]
WantedBy=multi-user.target
EOF

# SRT streaming service (if enabled)
if [[ "$ENABLE_SRT" =~ ^[Yy]$ ]]; then
    cat > /etc/systemd/system/inferno-srt.service << EOF
[Unit]
Description=Inferno to SRT streaming service
After=inferno.service
Requires=inferno.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/inferno
ExecStartPre=/bin/bash -c 'mkfifo /tmp/inferno_audio.pipe 2>/dev/null || true'
ExecStart=/opt/inferno/bin/ffmpeg \\
    -f s32le -ar ${SAMPLE_RATE} -ac ${RX_CHANNELS} -i /tmp/inferno_audio.pipe \\
    -c:a aac -b:a 192k \\
    -f mpegts "srt://${SRT_HOST}:${SRT_PORT}?mode=${SRT_MODE}&latency=${SRT_LATENCY_MS}000"
Restart=always
RestartSec=5
StandardOutput=append:/var/log/inferno/srt.log
StandardError=append:/var/log/inferno/srt-error.log

[Install]
WantedBy=multi-user.target
EOF
fi

# Monitoring API service
cat > /etc/systemd/system/inferno-api.service << EOF
[Unit]
Description=Inferno AoIP Monitoring API
After=network-online.target inferno.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/inferno
ExecStart=/usr/bin/python3 /opt/inferno/bin/monitor-api.py
Restart=always
RestartSec=5
StandardOutput=append:/var/log/inferno/api.log
StandardError=append:/var/log/inferno/api-error.log

[Install]
WantedBy=multi-user.target
EOF

# ============================================================================
# ENABLE AND START SERVICES
# ============================================================================

echo ""
echo -e "${GREEN}[10/10] Enabling and starting services...${NC}"

systemctl daemon-reload
systemctl enable dante-routes.service
systemctl enable statime.service
systemctl enable inferno.service
systemctl enable inferno-api.service

if [[ "$ENABLE_SRT" =~ ^[Yy]$ ]]; then
    systemctl enable inferno-srt.service
fi

# Start route configuration now
systemctl start dante-routes.service

echo ""
echo -e "${GREEN}Services configured. They will start automatically on next boot.${NC}"

# ============================================================================
# CREATE CONFIGURATION FILE
# ============================================================================

cat > /opt/inferno/config/installation.conf << EOF
# Inferno AoIP Installation Configuration
# Generated: $(date)

[network]
dante_interface=${DANTE_INTERFACE}
internet_interface=${INTERNET_INTERFACE}
dante_ip=${DANTE_IP}
dante_netmask=${DANTE_NETMASK}
dante_cidr=${DANTE_CIDR}

[inferno]
device_name=${DEVICE_NAME}
sample_rate=${SAMPLE_RATE}
rx_channels=${RX_CHANNELS}
tx_channels=${TX_CHANNELS}
rx_latency_ms=${RX_LATENCY_MS}
tx_latency_ms=${TX_LATENCY_MS}

[srt]
enabled=${ENABLE_SRT}
host=${SRT_HOST}
port=${SRT_PORT}
mode=${SRT_MODE}
latency_ms=${SRT_LATENCY_MS}
EOF

# ============================================================================
# CREATE MANAGEMENT SCRIPT
# ============================================================================

cat > /usr/local/bin/inferno-control << 'EOFCONTROL'
#!/bin/bash
# Inferno AoIP control script

case "$1" in
    start)
        systemctl start dante-routes.service
        systemctl start statime.service
        systemctl start inferno.service
        systemctl start inferno-api.service
        systemctl start inferno-srt.service 2>/dev/null
        echo "Inferno services started"
        ;;
    stop)
        systemctl stop inferno-srt.service 2>/dev/null
        systemctl stop inferno-api.service
        systemctl stop inferno.service
        systemctl stop statime.service
        echo "Inferno services stopped"
        ;;
    restart)
        $0 stop
        sleep 2
        $0 start
        ;;
    status)
        echo "=== Dante Routes ==="
        systemctl status dante-routes.service --no-pager
        echo ""
        echo "=== Statime ==="
        systemctl status statime.service --no-pager
        echo ""
        echo "=== Inferno ==="
        systemctl status inferno.service --no-pager
        echo ""
        echo "=== Monitoring API ==="
        systemctl status inferno-api.service --no-pager
        echo ""
        echo "=== SRT Streaming ==="
        systemctl status inferno-srt.service --no-pager 2>/dev/null || echo "SRT not enabled"
        ;;
    logs)
        echo "=== Recent Inferno Logs ==="
        tail -n 50 /var/log/inferno/*.log
        ;;
    api)
        echo "=== API Status ==="
        curl -s http://localhost:8080/status | python3 -m json.tool 2>/dev/null || \
        curl -s http://localhost:8080/status
        ;;
    test)
        echo "=== Network Configuration ==="
        ip addr show ${DANTE_INTERFACE}
        echo ""
        echo "=== Multicast Route ==="
        ip route show | grep 224.0.0.0
        echo ""
        echo "=== Listening Services ==="
        ss -ulnp | grep -E 'statime|inferno|ffmpeg'
        echo ""
        echo "=== API Health Check ==="
        curl -s http://localhost:8080/health | python3 -m json.tool 2>/dev/null || \
        curl -s http://localhost:8080/health
        ;;
    *)
        echo "Usage: inferno-control {start|stop|restart|status|logs|api|test}"
        exit 1
        ;;
esac
EOFCONTROL

chmod +x /usr/local/bin/inferno-control

# ============================================================================
# INSTALLATION COMPLETE
# ============================================================================

echo ""
echo -e "${CYAN}"
cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║            Installation Complete!                         ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

echo -e "${GREEN}Inferno AoIP has been successfully installed!${NC}"
echo ""
echo "Configuration saved to: /opt/inferno/config/installation.conf"
echo "Logs directory: /var/log/inferno/"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo ""
echo "1. REBOOT your Raspberry Pi to apply all changes:"
echo -e "   ${CYAN}sudo reboot${NC}"
echo ""
echo "2. After reboot, verify services are running:"
echo -e "   ${CYAN}inferno-control status${NC}"
echo ""
echo "3. Test multicast routing:"
echo -e "   ${CYAN}ip route show | grep 224.0.0.0${NC}"
echo "   Should show: 224.0.0.0/4 dev ${DANTE_INTERFACE}"
echo ""
echo "4. Monitor Dante traffic:"
echo -e "   ${CYAN}sudo tcpdump -i ${DANTE_INTERFACE} 'dst net 224.0.0.0/4'${NC}"
echo ""
echo "5. View logs:"
echo -e "   ${CYAN}inferno-control logs${NC}"
echo ""
echo "6. Access Monitoring API:"
echo -e "   ${CYAN}http://${DANTE_IP}:8080/docs${NC} (Swagger UI)"
echo -e "   ${CYAN}http://${DANTE_IP}:8080/status${NC} (Status JSON)"
echo -e "   ${CYAN}http://${DANTE_IP}:8080/metrics${NC} (Prometheus metrics)"
echo ""
echo -e "${YELLOW}Management Commands:${NC}"
echo "  inferno-control start    - Start all services"
echo "  inferno-control stop     - Stop all services"
echo "  inferno-control restart  - Restart all services"
echo "  inferno-control status   - Show service status"
echo "  inferno-control logs     - View recent logs"
echo "  inferno-control api      - Query API status"
echo "  inferno-control test     - Test configuration"
echo ""
echo -e "${YELLOW}Your Dante Device Configuration:${NC}"
echo "  Name: ${DEVICE_NAME}"
echo "  IP: ${DANTE_IP}"
echo "  Channels: ${RX_CHANNELS} in / ${TX_CHANNELS} out"
echo ""
echo -e "${YELLOW}Monitoring API:${NC}"
echo "  URL: http://${DANTE_IP}:8080"
echo "  Docs: http://${DANTE_IP}:8080/docs"
echo "  Metrics: http://${DANTE_IP}:8080/metrics"
if [[ "$ENABLE_SRT" =~ ^[Yy]$ ]]; then
    echo ""
    echo -e "${YELLOW}SRT Streaming:${NC}"
    echo "  Destination: srt://${SRT_HOST}:${SRT_PORT}"
    echo "  Mode: ${SRT_MODE}"
fi
echo ""
echo -e "${CYAN}Configure external Prometheus to scrape:${NC}"
echo "  - job_name: 'inferno'"
echo "    static_configs:"
echo "      - targets: ['${DANTE_IP}:8080']"
echo ""
echo -e "${GREEN}For support and documentation, see /opt/inferno/README.md${NC}"
echo ""