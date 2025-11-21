#!/usr/bin/env python3
"""
Inferno AoIP Monitoring API
FastAPI-based REST API with Prometheus metrics for monitoring Dante to SRT bridge
"""

import os
import re
import json
import time
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Optional, Dict, List

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from prometheus_client import Counter, Gauge, Histogram, Info, generate_latest, CONTENT_TYPE_LATEST
from fastapi.responses import Response
from pydantic import BaseModel
import psutil

# ============================================================================
# Configuration
# ============================================================================

CONFIG_FILE = Path("/opt/inferno/config/installation.conf")
LOG_DIR = Path("/var/log/inferno")
STATE_FILE = Path("/var/run/inferno/state.json")
AUDIO_OUT_CONFIG = Path("/opt/inferno/config/audio-output.conf")

# ============================================================================
# FastAPI Application
# ============================================================================

app = FastAPI(
    title="Inferno AoIP Monitor",
    description="Monitoring API for Dante to SRT audio bridge",
    version="1.0.0",
    docs_url="/docs",
    redoc_url="/redoc"
)

# ============================================================================
# Prometheus Metrics
# ============================================================================

# Service metrics
service_up = Gauge('inferno_service_up', 'Service is running (1=up, 0=down)', ['service'])
service_restarts = Counter('inferno_service_restarts_total', 'Total service restarts', ['service'])

# Audio metrics
audio_level = Gauge('inferno_audio_level_dbfs', 'Audio level in dBFS', ['channel'])
audio_peak = Gauge('inferno_audio_peak_dbfs', 'Audio peak level in dBFS', ['channel'])
silence_detected = Gauge('inferno_silence_detected', 'Silence detected on channel (1=silent, 0=active)', ['channel'])
silence_events = Counter('inferno_silence_events_total', 'Total silence detection events')

# PTP Clock metrics
ptp_clock_offset = Gauge('inferno_ptp_clock_offset_ns', 'PTP clock offset in nanoseconds')
ptp_synchronized = Gauge('inferno_ptp_synchronized', 'PTP is synchronized (1=synced, 0=not synced)')
ptp_master_changes = Counter('inferno_ptp_master_changes_total', 'Total PTP master changes')

# Network metrics
packets_received = Counter('inferno_packets_received_total', 'Total packets received')
packets_lost = Counter('inferno_packets_lost_total', 'Total packets lost')
packet_loss_rate = Gauge('inferno_packet_loss_rate', 'Current packet loss rate (0.0-1.0)')

# SRT metrics
srt_connected = Gauge('inferno_srt_connected', 'SRT connection status (1=connected, 0=disconnected)')
srt_bitrate = Gauge('inferno_srt_bitrate_kbps', 'SRT streaming bitrate in kbps')
srt_rtt = Gauge('inferno_srt_rtt_ms', 'SRT round-trip time in milliseconds')
srt_packet_loss = Gauge('inferno_srt_packet_loss_pct', 'SRT packet loss percentage')

# System metrics
system_uptime = Gauge('inferno_system_uptime_seconds', 'System uptime in seconds')
api_uptime = Gauge('inferno_api_uptime_seconds', 'API uptime in seconds')

# API metrics
http_requests = Counter('inferno_http_requests_total', 'Total HTTP requests', ['method', 'endpoint', 'status'])
http_request_duration = Histogram('inferno_http_request_duration_seconds', 'HTTP request duration', ['method', 'endpoint'])

# API start time
API_START_TIME = time.time()

# ============================================================================
# Pydantic Models for Request/Response
# ============================================================================

class AudioOutputConfig(BaseModel):
    enabled: bool
    device: str  # hdmi, headphones, auto
    stereo_pair: int  # 1-based pair number (1 = channels 0-1, 2 = channels 2-3, etc.)

class AudioOutputStatus(BaseModel):
    enabled: bool
    device: str
    stereo_pair: int
    channel_l: int
    channel_r: int
    service_running: bool

# ============================================================================
# Helper Functions
# ============================================================================

def load_config() -> Dict:
    """Load installation configuration"""
    config = {}
    if CONFIG_FILE.exists():
        current_section = None
        with open(CONFIG_FILE, 'r') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                if line.startswith('[') and line.endswith(']'):
                    current_section = line[1:-1]
                    config[current_section] = {}
                elif '=' in line and current_section:
                    key, value = line.split('=', 1)
                    config[current_section][key.strip()] = value.strip()
    return config

def check_service_status(service_name: str) -> bool:
    """Check if a systemd service is running"""
    try:
        result = subprocess.run(
            ['systemctl', 'is-active', f'{service_name}.service'],
            capture_output=True,
            text=True,
            timeout=5
        )
        is_active = result.stdout.strip() == 'active'
        
        # Update Prometheus metric
        service_up.labels(service=service_name).set(1 if is_active else 0)
        
        return is_active
    except Exception as e:
        service_up.labels(service=service_name).set(0)
        return False

def get_service_restart_count(service_name: str) -> int:
    """Get number of times a service has restarted"""
    try:
        result = subprocess.run(
            ['systemctl', 'show', f'{service_name}.service', '--property=NRestarts'],
            capture_output=True,
            text=True,
            timeout=5
        )
        match = re.search(r'NRestarts=(\d+)', result.stdout)
        if match:
            return int(match.group(1))
    except Exception:
        pass
    return 0

def parse_statime_log() -> Dict:
    """Parse Statime log for PTP status"""
    ptp_status = {
        "synchronized": False,
        "clock_offset_ns": 0,
        "master_ip": None,
        "state": "unknown"
    }
    
    log_file = LOG_DIR / "statime.log"
    if not log_file.exists():
        return ptp_status
    
    try:
        # Read last 100 lines
        with open(log_file, 'r') as f:
            lines = f.readlines()[-100:]
        
        for line in reversed(lines):
            # Look for clock offset messages
            if 'offset' in line.lower():
                match = re.search(r'offset[:\s]+(-?\d+)', line)
                if match:
                    offset = int(match.group(1))
                    ptp_status["clock_offset_ns"] = offset
                    ptp_status["synchronized"] = abs(offset) < 100000  # <100μs = synced
                    
                    # Update Prometheus metrics
                    ptp_clock_offset.set(offset)
                    ptp_synchronized.set(1 if ptp_status["synchronized"] else 0)
                    break
            
            # Look for state changes
            if 'state' in line.lower():
                if 'slave' in line.lower() or 'listening' in line.lower():
                    ptp_status["state"] = "slave"
                elif 'master' in line.lower():
                    ptp_status["state"] = "master"
    
    except Exception as e:
        print(f"Error parsing statime log: {e}")
    
    return ptp_status

def parse_inferno_log() -> Dict:
    """Parse Inferno log for audio status"""
    audio_status = {
        "rx_channels": 0,
        "tx_channels": 0,
        "sample_rate": 0,
        "packets_received": 0,
        "packets_lost": 0
    }
    
    log_file = LOG_DIR / "inferno.log"
    if not log_file.exists():
        return audio_status
    
    try:
        with open(log_file, 'r') as f:
            lines = f.readlines()[-100:]
        
        for line in reversed(lines):
            # Look for channel info
            if 'channels' in line.lower():
                match = re.search(r'(\d+)\s*channels?', line)
                if match:
                    audio_status["rx_channels"] = int(match.group(1))
            
            # Look for sample rate
            if 'sample rate' in line.lower() or 'hz' in line.lower():
                match = re.search(r'(\d+)\s*hz', line, re.IGNORECASE)
                if match:
                    audio_status["sample_rate"] = int(match.group(1))
            
            # Look for packet stats
            if 'packets' in line.lower():
                match = re.search(r'received[:\s]+(\d+)', line, re.IGNORECASE)
                if match:
                    audio_status["packets_received"] = int(match.group(1))
                
                match = re.search(r'lost[:\s]+(\d+)', line, re.IGNORECASE)
                if match:
                    audio_status["packets_lost"] = int(match.group(1))
    
    except Exception as e:
        print(f"Error parsing inferno log: {e}")
    
    return audio_status

def parse_srt_log() -> Dict:
    """Parse FFmpeg SRT log for streaming status"""
    srt_status = {
        "connected": False,
        "destination": None,
        "bitrate_kbps": 0,
        "rtt_ms": 0,
        "packet_loss_pct": 0.0
    }
    
    log_file = LOG_DIR / "srt.log"
    if not log_file.exists():
        return srt_status
    
    try:
        with open(log_file, 'r') as f:
            lines = f.readlines()[-100:]
        
        for line in reversed(lines):
            # Check for SRT connection
            if 'srt://' in line.lower():
                match = re.search(r'(srt://[^\s\'"]+)', line)
                if match:
                    srt_status["destination"] = match.group(1)
                    srt_status["connected"] = 'error' not in line.lower() and 'failed' not in line.lower()
            
            # Look for bitrate
            if 'bitrate' in line.lower() or 'kbits/s' in line.lower():
                match = re.search(r'(\d+\.?\d*)\s*kbits?/s', line, re.IGNORECASE)
                if match:
                    srt_status["bitrate_kbps"] = float(match.group(1))
            
            # Look for packet loss
            if 'loss' in line.lower():
                match = re.search(r'(\d+\.?\d*)%', line)
                if match:
                    srt_status["packet_loss_pct"] = float(match.group(1))
        
        # Update Prometheus metrics
        srt_connected.set(1 if srt_status["connected"] else 0)
        srt_bitrate.set(srt_status["bitrate_kbps"])
        srt_rtt.set(srt_status["rtt_ms"])
        srt_packet_loss.set(srt_status["packet_loss_pct"])
    
    except Exception as e:
        print(f"Error parsing SRT log: {e}")
    
    return srt_status

def get_system_info() -> Dict:
    """Get system information"""
    return {
        "hostname": os.uname().nodename,
        "architecture": os.uname().machine,
        "kernel": os.uname().release,
        "uptime_seconds": int(time.time() - psutil.boot_time()),
        "cpu_percent": psutil.cpu_percent(interval=1),
        "memory_percent": psutil.virtual_memory().percent,
        "disk_percent": psutil.disk_usage('/').percent
    }

def read_audio_output_config() -> Dict:
    """Read hardware audio output configuration"""
    config = {
        "enabled": False,
        "device": "auto",
        "stereo_pair": 1,
        "channel_l": 0,
        "channel_r": 1,
        "rx_channels": 2
    }
    
    if not AUDIO_OUT_CONFIG.exists():
        return config
    
    try:
        with open(AUDIO_OUT_CONFIG, 'r') as f:
            for line in f:
                line = line.strip()
                if line.startswith('ENABLED='):
                    config["enabled"] = line.split('=')[1].strip('"').lower() == "true"
                elif line.startswith('DEVICE='):
                    config["device"] = line.split('=')[1].strip('"')
                elif line.startswith('STEREO_PAIR='):
                    config["stereo_pair"] = int(line.split('=')[1].strip('"'))
                elif line.startswith('CHANNEL_L='):
                    config["channel_l"] = int(line.split('=')[1].strip('"'))
                elif line.startswith('CHANNEL_R='):
                    config["channel_r"] = int(line.split('=')[1].strip('"'))
                elif line.startswith('RX_CHANNELS='):
                    config["rx_channels"] = int(line.split('=')[1].strip('"'))
    except Exception as e:
        print(f"Error reading audio output config: {e}")
    
    return config

def write_audio_output_config(config: Dict) -> bool:
    """Write hardware audio output configuration"""
    try:
        AUDIO_OUT_CONFIG.parent.mkdir(parents=True, exist_ok=True)
        
        # Calculate channel numbers from stereo pair
        channel_l = (config["stereo_pair"] - 1) * 2
        channel_r = (config["stereo_pair"] - 1) * 2 + 1
        
        with open(AUDIO_OUT_CONFIG, 'w') as f:
            f.write("# Hardware audio output configuration\n")
            f.write("# This file can be modified via API or manually\n")
            f.write(f'ENABLED="{str(config["enabled"]).lower()}"\n')
            f.write(f'DEVICE="{config["device"]}"\n')
            f.write(f'STEREO_PAIR="{config["stereo_pair"]}"\n')
            f.write(f'CHANNEL_L="{channel_l}"\n')
            f.write(f'CHANNEL_R="{channel_r}"\n')
            f.write(f'RX_CHANNELS="{config.get("rx_channels", 2)}"\n')
        
        return True
    except Exception as e:
        print(f"Error writing audio output config: {e}")
        return False

# ============================================================================
# API Endpoints
# ============================================================================

@app.get("/")
async def root():
    """Root endpoint with API information"""
    return {
        "name": "Inferno AoIP Monitor",
        "version": "1.0.0",
        "status": "running",
        "documentation": "/docs",
        "metrics": "/metrics",
        "endpoints": {
            "status": "/status",
            "services": "/status/services",
            "audio": "/audio/status",
            "audio_output": "/audio/output",
            "ptp": "/ptp/status",
            "srt": "/srt/status",
            "network": "/network/status",
            "system": "/system/info",
            "health": "/health"
        }
    }

@app.get("/health")
async def health_check():
    """Health check endpoint"""
    services = {
        "statime": check_service_status("statime"),
        "inferno": check_service_status("inferno"),
        "srt": check_service_status("inferno-srt")
    }
    
    healthy = all(services.values())
    
    return {
        "healthy": healthy,
        "services": services,
        "timestamp": datetime.utcnow().isoformat() + "Z"
    }

@app.get("/status")
async def get_status():
    """Get overall system status"""
    config = load_config()
    
    services = {
        "statime": check_service_status("statime"),
        "inferno": check_service_status("inferno"),
        "srt": check_service_status("inferno-srt")
    }
    
    audio_info = parse_inferno_log()
    ptp_info = parse_statime_log()
    srt_info = parse_srt_log()
    
    # Update uptime metrics
    system_uptime.set(int(time.time() - psutil.boot_time()))
    api_uptime.set(int(time.time() - API_START_TIME))
    
    return {
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "uptime_seconds": int(time.time() - psutil.boot_time()),
        "api_uptime_seconds": int(time.time() - API_START_TIME),
        "services": services,
        "audio": {
            "rx_channels": audio_info.get("rx_channels", 0),
            "tx_channels": audio_info.get("tx_channels", 0),
            "sample_rate": audio_info.get("sample_rate", 0)
        },
        "ptp": {
            "synchronized": ptp_info.get("synchronized", False),
            "clock_offset_ns": ptp_info.get("clock_offset_ns", 0)
        },
        "srt": {
            "connected": srt_info.get("connected", False),
            "destination": srt_info.get("destination")
        },
        "device": {
            "name": config.get("inferno", {}).get("device_name", "Unknown"),
            "dante_ip": config.get("network", {}).get("dante_ip", "Unknown")
        }
    }

@app.get("/status/services")
async def get_services_status():
    """Get detailed service status"""
    services = {}
    
    for service in ["statime", "inferno", "inferno-srt"]:
        is_running = check_service_status(service)
        restart_count = get_service_restart_count(service)
        
        services[service] = {
            "running": is_running,
            "restart_count": restart_count,
            "status": "active" if is_running else "inactive"
        }
        
        # Update restart counter metric
        service_restarts.labels(service=service).inc(0)  # Initialize if needed
    
    return {
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "services": services
    }

@app.get("/audio/status")
async def get_audio_status():
    """Get audio status and levels"""
    config = load_config()
    audio_info = parse_inferno_log()
    
    # Simulate audio levels (in production, read from shared memory or pipe)
    # For now, return placeholder values
    rx_channels = int(config.get("inferno", {}).get("rx_channels", 2))
    channels = []
    
    for i in range(rx_channels):
        # TODO: Read actual audio levels from Inferno
        level = -20.0  # Placeholder
        peak = -15.0   # Placeholder
        silent = level < -60.0
        
        channels.append({
            "id": i,
            "level_dbfs": level,
            "peak_dbfs": peak,
            "silent": silent
        })
        
        # Update Prometheus metrics
        audio_level.labels(channel=str(i)).set(level)
        audio_peak.labels(channel=str(i)).set(peak)
        silence_detected.labels(channel=str(i)).set(1 if silent else 0)
    
    return {
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "sample_rate": audio_info.get("sample_rate", 48000),
        "rx_channels": rx_channels,
        "channels": channels,
        "silence_detected": any(ch["silent"] for ch in channels)
    }

@app.get("/ptp/status")
async def get_ptp_status():
    """Get PTP clock synchronization status"""
    ptp_info = parse_statime_log()
    
    return {
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "synchronized": ptp_info.get("synchronized", False),
        "clock_offset_ns": ptp_info.get("clock_offset_ns", 0),
        "master_ip": ptp_info.get("master_ip"),
        "state": ptp_info.get("state", "unknown")
    }

@app.get("/srt/status")
async def get_srt_status():
    """Get SRT streaming status"""
    srt_info = parse_srt_log()
    config = load_config()
    
    return {
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "connected": srt_info.get("connected", False),
        "destination": srt_info.get("destination") or 
                      f"srt://{config.get('srt', {}).get('host', 'unknown')}:{config.get('srt', {}).get('port', '0')}",
        "mode": config.get('srt', {}).get('mode', 'unknown'),
        "bitrate_kbps": srt_info.get("bitrate_kbps", 0),
        "rtt_ms": srt_info.get("rtt_ms", 0),
        "packet_loss_pct": srt_info.get("packet_loss_pct", 0.0),
        "latency_ms": config.get('srt', {}).get('latency_ms', 0)
    }

@app.get("/network/status")
async def get_network_status():
    """Get network status"""
    config = load_config()
    audio_info = parse_inferno_log()
    
    # Calculate packet loss rate
    total_packets = audio_info.get("packets_received", 0) + audio_info.get("packets_lost", 0)
    loss_rate = audio_info.get("packets_lost", 0) / total_packets if total_packets > 0 else 0.0
    
    # Update Prometheus metrics
    packet_loss_rate.set(loss_rate)
    
    return {
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "dante_interface": config.get("network", {}).get("dante_interface", "eth0"),
        "dante_ip": config.get("network", {}).get("dante_ip", "Unknown"),
        "packets_received": audio_info.get("packets_received", 0),
        "packets_lost": audio_info.get("packets_lost", 0),
        "packet_loss_rate": loss_rate
    }

@app.get("/system/info")
async def get_system_info_endpoint():
    """Get system information"""
    system_info = get_system_info()
    config = load_config()
    
    return {
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "hostname": system_info["hostname"],
        "architecture": system_info["architecture"],
        "kernel": system_info["kernel"],
        "uptime_seconds": system_info["uptime_seconds"],
        "cpu_percent": system_info["cpu_percent"],
        "memory_percent": system_info["memory_percent"],
        "disk_percent": system_info["disk_percent"],
        "inferno": {
            "device_name": config.get("inferno", {}).get("device_name", "Unknown"),
            "dante_ip": config.get("network", {}).get("dante_ip", "Unknown")
        }
    }

@app.get("/metrics")
async def metrics():
    """Prometheus metrics endpoint"""
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)

# ============================================================================
# Hardware Audio Output Endpoints
# ============================================================================

@app.get("/audio/output", response_model=AudioOutputStatus)
async def get_audio_output():
    """Get hardware audio output configuration and status"""
    config = read_audio_output_config()
    service_running = check_service_status("inferno-audio-out")
    
    return AudioOutputStatus(
        enabled=config["enabled"],
        device=config["device"],
        stereo_pair=config["stereo_pair"],
        channel_l=config["channel_l"],
        channel_r=config["channel_r"],
        service_running=service_running
    )

@app.post("/audio/output")
async def set_audio_output(audio_config: AudioOutputConfig):
    """Configure hardware audio output
    
    Parameters:
    - enabled: true to enable audio output, false to disable
    - device: "hdmi", "headphones", or "auto"
    - stereo_pair: Stereo pair number to route (1 = channels 0-1, 2 = channels 2-3, etc.)
    """
    # Validate device
    if audio_config.device not in ["hdmi", "headphones", "auto"]:
        raise HTTPException(status_code=400, detail="Device must be 'hdmi', 'headphones', or 'auto'")
    
    # Validate stereo pair
    if audio_config.stereo_pair < 1:
        raise HTTPException(status_code=400, detail="Stereo pair must be >= 1")
    
    # Get total RX channels from config
    main_config = load_config()
    rx_channels = int(main_config.get("inferno", {}).get("rx_channels", 2))
    max_pairs = (rx_channels + 1) // 2
    
    if audio_config.stereo_pair > max_pairs:
        raise HTTPException(
            status_code=400, 
            detail=f"Stereo pair {audio_config.stereo_pair} exceeds available pairs (max: {max_pairs} for {rx_channels} channels)"
        )
    
    # Write new configuration
    config = {
        "enabled": audio_config.enabled,
        "device": audio_config.device,
        "stereo_pair": audio_config.stereo_pair,
        "rx_channels": rx_channels
    }
    
    if not write_audio_output_config(config):
        raise HTTPException(status_code=500, detail="Failed to write configuration")
    
    # Restart service to apply changes
    try:
        if audio_config.enabled:
            subprocess.run(['systemctl', 'restart', 'inferno-audio-out.service'], 
                         check=True, timeout=10)
        else:
            subprocess.run(['systemctl', 'stop', 'inferno-audio-out.service'], 
                         check=True, timeout=10)
    except subprocess.CalledProcessError as e:
        raise HTTPException(status_code=500, detail=f"Failed to control service: {e}")
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=500, detail="Service control timeout")
    
    return {
        "success": True,
        "message": "Audio output configuration updated",
        "config": {
            "enabled": audio_config.enabled,
            "device": audio_config.device,
            "stereo_pair": audio_config.stereo_pair,
            "channels": f"{(audio_config.stereo_pair-1)*2}-{(audio_config.stereo_pair-1)*2+1}"
        }
    }

@app.post("/audio/output/toggle")
async def toggle_audio_output():
    """Toggle hardware audio output on/off"""
    config = read_audio_output_config()
    config["enabled"] = not config["enabled"]
    
    if not write_audio_output_config(config):
        raise HTTPException(status_code=500, detail="Failed to write configuration")
    
    try:
        if config["enabled"]:
            subprocess.run(['systemctl', 'start', 'inferno-audio-out.service'], 
                         check=True, timeout=10)
        else:
            subprocess.run(['systemctl', 'stop', 'inferno-audio-out.service'], 
                         check=True, timeout=10)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to toggle service: {e}")
    
    return {
        "success": True,
        "enabled": config["enabled"],
        "message": f"Audio output {'enabled' if config['enabled'] else 'disabled'}"
    }

# ============================================================================
# Startup Event
# ============================================================================

@app.on_event("startup")
async def startup_event():
    """Initialize metrics on startup"""
    print("Inferno AoIP Monitor API starting...")
    
    # Initialize all service metrics
    for service in ["statime", "inferno", "inferno-srt"]:
        check_service_status(service)
    
    print("API ready at http://0.0.0.0:8080")
    print("Prometheus metrics at http://0.0.0.0:8080/metrics")
    print("API documentation at http://0.0.0.0:8080/docs")

# ============================================================================
# Main
# ============================================================================

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080, log_level="info")