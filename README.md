# Inferno AoIP - Dante to SRT Bridge for Raspberry Pi

A complete solution for receiving audio from Dante devices and streaming it via SRT (Secure Reliable Transport) protocol, running on Raspberry Pi 3/4/5 with 64-bit ARM architecture.

## Overview

This project combines several open-source components to create a professional audio-over-IP bridge:

- **Receive audio** from Dante devices on your network (AoIP)
- **Stream audio** to remote destinations via SRT protocol
- **Low latency** operation suitable for live production
- **Headless operation** on Raspberry Pi (no display required)
- **Automatic startup** on boot with systemd services

---

## Hardware Compatibility

### Tested and Confirmed Working:
- **Raspberry Pi 3 Model B/B+** (64-bit OS)
- **Raspberry Pi 4 Model B** (64-bit OS)
- **Raspberry Pi 5** (64-bit OS)

### Should Work (Untested):
- **NanoPi R5C** and similar ARM64 SBCs running Debian-based 64-bit OS
- Any **aarch64** (ARM64) device with:
  - Ethernet port
  - Linux kernel 5.x or newer
  - Debian 12+ or Ubuntu 22.04+ based OS

### Requirements:
- **Architecture:** 64-bit ARM only (aarch64)
- **OS:** Raspberry Pi OS Lite 64-bit (Debian 13 "Trixie") or compatible
- **Network:** Ethernet connection (WiFi for internet optional)
- **Storage:** 8GB+ microSD card (16GB recommended)

**Important:** This installer is **NOT compatible** with 32-bit ARM systems (armv7l).

---

## Software Components & Attribution

This project stands on the shoulders of giants. We gratefully acknowledge the following open-source projects:

### Core Audio Components

#### [Inferno AoIP](https://gitlab.com/lumifaza/inferno)
- **Author:** LUMIFAZA
- **License:** GNU GPL v3+ / GNU AGPL v3+ (dual-licensed)
- **Purpose:** Unofficial implementation of Audinate's Dante protocol for Linux
- **Description:** Enables Linux systems to send and receive audio from Dante devices without proprietary software

#### [Statime](https://github.com/pendulum-project/statime)
- **Organization:** Pendulum Project / Trifecta Tech Foundation
- **Modified Fork:** [teodly/statime (inferno-dev branch)](https://github.com/teodly/statime/tree/inferno-dev)
- **License:** Apache-2.0 / MIT
- **Purpose:** PTP (Precision Time Protocol) daemon with PTPv1 support
- **Description:** Provides clock synchronization required for audio-over-IP timing

### Streaming & Encoding

#### [FFmpeg](https://ffmpeg.org/)
- **License:** GNU LGPL v2.1+ (with some components under GPL)
- **Purpose:** Audio encoding and streaming
- **Description:** Industry-standard multimedia framework for encoding and streaming

#### [libsrt](https://github.com/Haivision/srt)
- **Author:** Haivision
- **License:** MPL-2.0
- **Purpose:** Secure Reliable Transport protocol
- **Description:** Low-latency video and audio streaming over unpredictable networks

### System Components

- **Linux Kernel:** The foundation of the entire system
- **Debian Project:** Base operating system (Debian 13 "Trixie")
- **Raspberry Pi Foundation:** Hardware and OS distribution
- **ALSA (Advanced Linux Sound Architecture):** Audio subsystem

---

## Installation

### Quick Install

1. Download the installer script to your Raspberry Pi:
```bash
wget https://your-server.com/install-inferno.sh
```

2. Make it executable:
```bash
chmod +x install-inferno.sh
```

3. Run as root:
```bash
sudo bash install-inferno.sh
```

4. Follow the interactive prompts to configure:
   - Network interfaces (Dante and Internet)
   - Dante IP address and device name
   - Audio channels and latency
   - SRT streaming destination

5. Reboot:
```bash
sudo reboot
```

### Manual Configuration

If you need to modify settings after installation, edit:
```bash
sudo nano /opt/inferno/config/installation.conf
```

Then restart services:
```bash
sudo inferno-control restart
```

---

## Usage

### Control Commands

The installer creates a convenient control script:

```bash
# Start all services
inferno-control start

# Stop all services
inferno-control stop

# Restart all services
inferno-control restart

# Check service status
inferno-control status

# View recent logs
inferno-control logs

# Test configuration
inferno-control test
```

### Viewing Logs

```bash
# All logs
tail -f /var/log/inferno/*.log

# Specific services
tail -f /var/log/inferno/inferno.log
tail -f /var/log/inferno/statime.log
tail -f /var/log/inferno/srt.log
```

### Testing Network Configuration

```bash
# Verify multicast route (must show your Dante interface)
ip route show | grep 224.0.0.0

# Monitor Dante traffic
sudo tcpdump -i eth0 'dst net 224.0.0.0/4'

# Check if device appears in Dante Controller
# Open Dante Controller on another computer - your Pi should be visible
```

---

## Configuration Files

### Installation Configuration
`/opt/inferno/config/installation.conf` - Your installation settings

### Statime PTP Configuration
`/opt/inferno/config/inferno-ptpv1.toml` - PTP daemon settings

### Systemd Services
- `/etc/systemd/system/dante-routes.service` - Multicast routing
- `/etc/systemd/system/statime.service` - PTP clock sync
- `/etc/systemd/system/inferno.service` - Dante audio receiver
- `/etc/systemd/system/inferno-srt.service` - SRT streaming (if enabled)

---

## Network Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Raspberry Pi                              │
│                                                              │
│  ┌────────────┐         ┌──────────────┐                    │
│  │   wlan0    │◄────────┤   Internet   │                    │
│  │  (WiFi)    │         │   (Updates)  │                    │
│  └────────────┘         └──────────────┘                    │
│                                                              │
│  ┌────────────┐         ┌──────────────┐                    │
│  │   eth0     │◄────────┤ Dante Network│                    │
│  │ 10.77.70.x │         │  (Multicast) │                    │
│  └──────┬─────┘         └──────────────┘                    │
│         │                                                    │
│    ┌────▼─────────┐                                          │
│    │   Statime    │ PTP Clock Synchronization               │
│    │  (PTPv1/v2)  │                                          │
│    └────┬─────────┘                                          │
│         │                                                    │
│    ┌────▼─────────┐                                          │
│    │   Inferno    │ Receive Dante Audio                     │
│    │   (AoIP)     │                                          │
│    └────┬─────────┘                                          │
│         │                                                    │
│    ┌────▼─────────┐                                          │
│    │   FFmpeg     │ Encode & Stream                         │
│    │   (libsrt)   │                                          │
│    └────┬─────────┘                                          │
│         │                                                    │
│         ▼                                                    │
│   srt://destination:port                                    │
└─────────────────────────────────────────────────────────────┘
```

### Key Points:
- **eth0:** Connected to Dante network (10.77.70.x) - multicast traffic stays here
- **wlan0:** Connected to internet for updates and remote management
- **Multicast routing:** All 224.0.0.0/4 traffic forced through eth0
- **No gateway on eth0:** Prevents routing conflicts with wlan0

---

## Troubleshooting

### Services Not Starting

```bash
# Check service status
sudo systemctl status statime.service
sudo systemctl status inferno.service

# View detailed logs
sudo journalctl -u statime.service -n 50
sudo journalctl -u inferno.service -n 50
```

### No Dante Devices Visible

1. Verify multicast route:
```bash
ip route show | grep 224.0.0.0
# Must show: 224.0.0.0/4 dev eth0
```

2. Check if Statime is synchronizing:
```bash
tail -f /var/log/inferno/statime.log
# Should show clock offset messages
```

3. Monitor Dante multicast traffic:
```bash
sudo tcpdump -i eth0 'dst net 224.0.0.0/4'
# Should show packets from Dante devices
```

### Audio Dropouts or Glitches

1. Increase latency values in `/opt/inferno/config/installation.conf`
2. Run latency test:
```bash
sudo apt install rt-tests
cyclictest --mlockall --smp --priority=80 --interval=5000 --distance=0
```
3. Disable WiFi power management:
```bash
sudo iwconfig wlan0 power off
```

### SRT Stream Not Connecting

1. Check FFmpeg logs:
```bash
tail -f /var/log/inferno/srt.log
```

2. Test SRT destination manually:
```bash
/opt/inferno/bin/ffmpeg -re -f lavfi -i sine=frequency=1000:duration=5 \
  -c:a aac -f mpegts "srt://your-host:port?mode=caller"
```

3. Verify network connectivity:
```bash
ping your-srt-destination
telnet your-srt-destination your-port
```

---

## Performance Tuning

### Latency Optimization

For lower latencies, tune your system:

1. Test your system's real-time capabilities:
```bash
sudo apt install rt-tests
cyclictest --mlockall --smp --priority=80 --interval=5000 --distance=0
```

2. Based on max latency result, set minimum safe latency:
   - Max latency × 1000 = minimum latency in nanoseconds
   - Add 5-10ms margin for network transmission

3. Edit service configuration:
```bash
sudo systemctl edit inferno.service
```

Add:
```ini
[Service]
Environment="INFERNO_RX_LATENCY_NS=5000000"
Environment="INFERNO_TX_LATENCY_NS=5000000"
```

### CPU Governor

For consistent performance:
```bash
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```

Make it persistent:
```bash
sudo apt install cpufrequtils
echo 'GOVERNOR="performance"' | sudo tee /etc/default/cpufrequtils
```

---

## Compatibility Notes

### Raspberry Pi Models

| Model | Architecture | Status | Notes |
|-------|-------------|--------|-------|
| Pi 3B/3B+ | aarch64 | ✅ Supported | No hardware PTP, software timestamps only |
| Pi 4B | aarch64 | ✅ Supported | No hardware PTP, but faster CPU |
| Pi 5 | aarch64 | ✅ Supported | Best performance, hardware PTP support |
| Pi Zero 2 W | aarch64 | ⚠️ Limited | Works but very slow, build times 2-3 hours |
| Pi 3B (32-bit) | armv7l | ❌ Not Supported | This installer is 64-bit only |

### Other ARM64 SBCs

The binaries **should** work on other ARM64 single-board computers running:
- **Debian 12+** or **Ubuntu 22.04+** 64-bit
- **Linux kernel 5.x** or newer
- **systemd** for service management

Examples:
- **NanoPi R5C/R6S** - Should work (Rockchip RK3568/RK3588)
- **Orange Pi 5** - Should work (Rockchip RK3588S)
- **Odroid N2+** - Should work (Amlogic S922X)
- **Rock 5B** - Should work (Rockchip RK3588)

**Not tested on these devices** - feedback welcome!

### Known Limitations

1. **Raspberry Pi 3:** No hardware PTP support, requires higher latency settings (10ms+)
2. **WiFi:** Not recommended for Dante network - use Ethernet
3. **32-bit OS:** Not compatible with these pre-built binaries
4. **Windows/macOS:** Not compatible - Linux only

---

## Building from Source

If you want to build for a different architecture or customize the build:

See the [Cross-Compilation Guide](cross-compilation.md) for instructions on:
- Building for 32-bit ARM (armv7l)
- Building for x86_64
- Custom build options
- Development setup

---

## Roadmap

### Short-term Goals (Q1-Q2 2025)

#### Enhanced Installation Script
- [ ] **Multi-architecture support**
  - Build for armv7l (32-bit ARM)
  - Build for x86_64 (desktop Linux)
- [ ] **Advanced audio configuration**
  - Configurable number of inputs/outputs during installation
  - Support for up to 64 channels
  - Per-channel naming and routing
- [ ] **Hardware audio output routing**
  - Route Dante inputs to HDMI audio output
  - Route Dante inputs to 3.5mm analog output
  - Mix multiple Dante sources to hardware outputs
- [ ] **Multiple streaming destinations**
  - Support multiple SRT outputs simultaneously
  - RTMP streaming support
  - Icecast/Shoutcast streaming
- [ ] **Web-based configuration**
  - Interactive installer accessible via browser
  - Live configuration changes without service restart

#### Monitoring & Management
- [ ] **HTTP REST API**
  - Real-time status monitoring
  - Audio level metering
  - Blank/silence detection
  - Clock synchronization status
  - Network statistics (packet loss, jitter)
  - Service health checks
- [ ] **Web Dashboard**
  - Visual audio level meters
  - Status indicators for all services
  - Configuration management
  - Log viewer
  - Start/stop/restart controls
- [ ] **Alerting System**
  - Email/webhook notifications
  - Silence detection alerts
  - Clock sync loss warnings
  - Service failure notifications

#### Performance Improvements
- [ ] **Hardware acceleration**
  - Use Raspberry Pi GPU for audio encoding
  - Optimize for Pi 5's improved hardware
- [ ] **Lower latency support**
  - PREEMPT_RT kernel patches
  - Sub-5ms latency for Pi 4/5
- [ ] **Better multicast handling**
  - Automatic multicast group discovery
  - IGMP snooping optimization

### Long-term Goals (Q3 2025+)

#### Advanced Features
- [ ] **Dante Controller functionality**
  - Route audio between Dante devices from Pi
  - Device discovery and management
  - Web-based Dante routing interface
- [ ] **Recording capabilities**
  - Multi-track recording to disk
  - Time-stamped audio files
  - Automatic file splitting and naming
- [ ] **Audio processing**
  - Built-in EQ and dynamics
  - Sample rate conversion
  - Channel mixing and routing
- [ ] **High-availability mode**
  - Automatic failover between multiple Pi devices
  - Redundant network paths
  - Health check and automatic recovery

#### Enterprise Features
- [ ] **SNMP support** for network monitoring
- [ ] **Ansible/Puppet deployment** for fleet management
- [ ] **Docker container** deployment option
- [ ] **Cloud integration** for remote monitoring
- [ ] **Multi-tenant support** for service providers

---

## Contributing

This is an integration project combining several open-source components. Contributions are welcome!

### How to Contribute

1. **Bug Reports:** Open an issue with:
   - Your hardware model and OS version
   - Steps to reproduce
   - Relevant logs from `/var/log/inferno/`

2. **Hardware Testing:** Test on new ARM64 SBCs and report compatibility

3. **Feature Requests:** Describe your use case and desired functionality

4. **Code Contributions:**
   - Fork the individual component projects (Inferno, Statime, etc.)
   - Submit pull requests to upstream projects
   - Share integration improvements

### Upstream Projects

Please contribute directly to the component projects:
- **Inferno AoIP:** https://gitlab.com/lumifaza/inferno
- **Statime:** https://github.com/pendulum-project/statime
- **FFmpeg:** https://ffmpeg.org/developer.html
- **libsrt:** https://github.com/Haivision/srt

---

## Legal & Licensing

### This Integration Project
The installation scripts and documentation in this repository are provided as-is for integration purposes.

### Component Licenses

- **Inferno AoIP:** GNU GPL v3+ / GNU AGPL v3+ (dual-licensed)
- **Statime:** Apache-2.0 / MIT
- **FFmpeg:** GNU LGPL v2.1+ (some components GPL)
- **libsrt:** MPL-2.0

### Dante Protocol Notice

**Important:** The Dante protocol is proprietary and patented by Audinate. This project uses an unofficial reverse-engineered implementation (Inferno AoIP).

From the Inferno AoIP disclaimer:
> Dante uses technology patented by Audinate. This source code may use these patents too. Consult a lawyer if you want to:
> - make money of it
> - distribute binaries in (or from) a region where software patents apply

**This project makes no claim to be authorized or approved by Audinate.**

For commercial use, please consult with a legal professional regarding patent implications in your jurisdiction.

### Recommended Approach
This project is best suited for:
- Personal/home use
- Education and research
- Non-commercial production
- Evaluation and testing

For commercial deployments, consider official Audinate products:
- Dante Virtual Soundcard
- Dante AVIO adapters
- Dante-enabled hardware

---

## Support & Community

### Documentation
- This README
- Component README files in `/opt/inferno/`
- Upstream project documentation (see links above)

### Getting Help
1. Check the [Troubleshooting](#troubleshooting) section
2. Review logs: `inferno-control logs`
3. Search existing issues in upstream projects
4. Join discussions on the Inferno AoIP GitLab

### Reporting Issues
When reporting issues, please include:
- Hardware model (Pi 3/4/5, etc.)
- OS version: `cat /etc/os-release`
- Architecture: `uname -m`
- Relevant logs from `/var/log/inferno/`
- Network configuration: `ip addr` and `ip route show`

---

## Acknowledgments

Special thanks to:
- **LUMIFAZA** for creating and maintaining Inferno AoIP
- **Pendulum Project / Trifecta Tech Foundation** for Statime
- **Haivision** for the SRT protocol and library
- **FFmpeg developers** for the multimedia framework
- **Raspberry Pi Foundation** for accessible hardware
- **Debian Project** for the stable OS foundation
- The entire **open-source community** for making this possible

---

## Version History

### Version 1.0 (Initial Release)
- Automated installation script
- Dual-interface configuration (Dante + Internet)
- SRT streaming support
- Systemd service integration
- Basic monitoring and control

---

**Project Status:** Active Development  
**Last Updated:** 2025-11-19  
**Minimum Requirements:** Raspberry Pi 3, 64-bit OS, Ethernet connection

For the latest updates and downloads, visit: [Your project website/repository]
