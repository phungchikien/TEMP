#!/bin/bash

# =================================================================
#     SIEGE HTTP GET FLOOD SIMULATOR WITH TC QDISC CONTROL
#     + AUTO-RESTART ON TARGET REBOOT
#     + SAFE TC QDISC DETECTION (NO INTERFERENCE)
# =================================================================

# Default parameters
TARGET_URL="${1:-http://172.24.4.32}"
INTERFACE="${2:-br-ex}"
DURATION="${3:-21600}"
TIME_COMPRESSION="${4:-4}"
LOG_FILE="siege_http_get_flood_$(date +%Y%m%d_%H%M%S).log"
VERBOSE=true

# Config TC QDISC
BURST_SIZE="500"
LATENCY="5ms"
MIN_RATE="1kbit"
MAX_RATE="2mbit"

# Config Siege
MAX_CONCURRENT=20
SIEGE_RC_FILE="/tmp/siege_custom_$(date +%s).rc"

# PID và flags
SIEGE_PID=""
MONITOR_PID=""
TC_ACTIVE=false
TC_MANAGED_BY_US=false  # NEW: Track if we created the qdisc
PYTHON_AVAILABLE=false

SCRIPT_PID=$$
PYTHON_CALCULATOR="/tmp/traffic_calculator_${SCRIPT_PID}.py"

# Logging function
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" | tee -a "$LOG_FILE"
}

# Clean up function
cleanup() {
    log "=== CLEANUP STARTED ==="
    
    # Kill Monitor first
    if [ -n "$MONITOR_PID" ] && kill -0 "$MONITOR_PID" 2>/dev/null; then
        log "Killing monitor process (PID: $MONITOR_PID)"
        kill -9 "$MONITOR_PID" 2>/dev/null
    fi
    
    # Kill Siege
    if [ -n "$SIEGE_PID" ] && kill -0 "$SIEGE_PID" 2>/dev/null; then
        log "Killing siege process (PID: $SIEGE_PID)"
        kill -TERM "$SIEGE_PID" 2>/dev/null
        sleep 2
        if kill -0 "$SIEGE_PID" 2>/dev/null; then
            kill -KILL "$SIEGE_PID" 2>/dev/null
        fi
        wait "$SIEGE_PID" 2>/dev/null
    fi
    
    # Failsafe: kill all siege
    pkill -9 siege 2>/dev/null
    
    # Only remove TC qdisc if WE created it
    if [ "$TC_MANAGED_BY_US" = true ]; then
        log "Removing TC qdisc (created by this script)"
        tc qdisc del dev "$INTERFACE" root 2>/dev/null || true
    else
        log "Leaving existing TC qdisc untouched"
    fi
    
    # Cleanup files
    rm -f "$SIEGE_RC_FILE"
    if [ -f "$PYTHON_CALCULATOR" ]; then
        rm -f "$PYTHON_CALCULATOR"
    fi
    
    log "=== CLEANUP COMPLETED ==="
    exit 0
}

trap cleanup EXIT INT TERM

# NEW: Check if TC qdisc already exists
check_existing_qdisc() {
    local qdisc_info=$(tc qdisc show dev "$INTERFACE" 2>/dev/null | grep "qdisc" | head -n1)
    
    if [ -z "$qdisc_info" ]; then
        log "ℹ No TC qdisc found on $INTERFACE"
        return 1  # No qdisc exists
    fi
    
    # Check if it's just the default qdisc (pfifo_fast, fq_codel, etc.)
    if echo "$qdisc_info" | grep -qE "qdisc (pfifo_fast|fq_codel|noqueue|mq)"; then
        log "ℹ Only default qdisc found on $INTERFACE: $qdisc_info"
        return 1  # Default qdisc, we can replace it
    fi
    
    # There's a configured qdisc (tbf, htb, etc.)
    log "⚠ EXISTING QDISC DETECTED on $INTERFACE:"
    log "   $qdisc_info"
    log "   → Script will run WITHOUT TC control (passive mode)"
    log "   → Siege traffic generation only, no bandwidth shaping"
    return 0  # Qdisc exists, don't touch it
}

# Check Python
check_python() {
    if command -v python3 &> /dev/null; then
        if python3 -c "import math; print('Python math OK')" &>/dev/null; then
            PYTHON_AVAILABLE=true
            log "Python3 with math module: Available"
            return 0
        fi
    fi
    
    if command -v python &> /dev/null; then
        if python -c "import math; print('Python math OK')" &>/dev/null; then
            PYTHON_AVAILABLE=true
            log "Python with math module: Available"
            return 0
        fi
    fi
    
    log "WARNING: Python not available, falling back to simplified math"
    PYTHON_AVAILABLE=false
    return 1
}

# Python calculator
create_python_calculator() {
    log "Creating Python calculator: $PYTHON_CALCULATOR"
    
    cat << 'PYTHON_SCRIPT' > "$PYTHON_CALCULATOR"
#!/usr/bin/env python3
import math
import sys
import os

SCALE_FACTOR = int(os.environ.get('TRAFFIC_SCALE_FACTOR', '1'))

def calculate_hourly_rate(hour, scale_factor=SCALE_FACTOR):
    morning_peak = 36 * math.exp(-((hour - 9) ** 2) / 6.8)
    evening_peak = 55 * math.exp(-((hour - 20) ** 2) / 7.84)
    night_drop = -15 * math.exp(-((hour - 2.5) ** 2) / 3.24)
    daily_cycle = 5 * math.sin(math.pi * hour / 12 - math.pi/2)
    base_level = 20
    
    traffic_factor = base_level + morning_peak + evening_peak + night_drop + daily_cycle
    rps = max(1, traffic_factor * scale_factor)
    
    return int(rps)

def calculate_weekly_multiplier(day_of_week):
    base = 87
    sine_component = 8 * math.sin(2 * math.pi * day_of_week / 7 + math.pi/7)
    weekend_spike = 5 * math.exp(-((day_of_week - 6) ** 2) / 2.25)
    weekly_factor = (base + sine_component + weekend_spike) / base
    return weekly_factor

def calculate_minute_factor(minute_in_hour):
    return 1 + 0.3 * math.sin(2 * math.pi * minute_in_hour / 60)

def get_compressed_time(elapsed_seconds, compression_factor):
    virtual_hours = elapsed_seconds * compression_factor / 3600
    current_hour = int(virtual_hours % 24)
    virtual_days = virtual_hours / 24
    day_of_week = int(virtual_days % 7) + 1
    seconds_in_hour = (elapsed_seconds * compression_factor) % 3600
    minute_in_hour = int(seconds_in_hour / 60)
    return current_hour, day_of_week, minute_in_hour

def calculate_traffic_rate(elapsed_seconds, compression_factor, noise_factor=0.15):
    try:
        hour, day, minute = get_compressed_time(elapsed_seconds, compression_factor)
        hourly_rate = calculate_hourly_rate(hour)
        weekly_multiplier = calculate_weekly_multiplier(day)
        minute_factor = calculate_minute_factor(minute)
        base_rate = hourly_rate * weekly_multiplier * minute_factor
        
        import random
        noise = random.uniform(-noise_factor, noise_factor)
        final_rate = base_rate * (1 + noise)
        
        return max(1, int(final_rate)), hour, day, minute
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)

def calculate_yoyo_rate(elapsed_seconds, cycle_duration=1800, yoyo_type="square"):
    cycle_position = (elapsed_seconds % cycle_duration) / cycle_duration
    
    if yoyo_type == "square":
        return 300 if cycle_position < 0.5 else 3
    elif yoyo_type == "sawtooth":
        if cycle_position < 0.7:
            return int(2 + 50 * cycle_position / 0.7)
        else:
            return 2
    elif yoyo_type == "burst":
        if cycle_position < 0.2:
            return 200
        elif cycle_position < 0.4:
            return 50
        else:
            return 3
    else:
        return 30

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python3 traffic_calculator.py <mode> <elapsed_seconds> [compression_factor] [yoyo_type]", file=sys.stderr)
        sys.exit(1)
    
    try:
        mode = sys.argv[1]
        elapsed_seconds = float(sys.argv[2])
        
        if mode == "compressed":
            compression_factor = float(sys.argv[3]) if len(sys.argv) > 3 else 72
            rate, hour, day, minute = calculate_traffic_rate(elapsed_seconds, compression_factor)
            print(f"{rate} {hour} {day} {minute}")
        
        elif mode == "yoyo":
            yoyo_type = sys.argv[3] if len(sys.argv) > 3 else "square"
            rate = calculate_yoyo_rate(elapsed_seconds, yoyo_type=yoyo_type)
            cycle_pos = (elapsed_seconds % 20) / 20
            print(f"{rate} {cycle_pos:.2f}")
        
        else:
            print(f"ERROR: Unknown mode: {mode}", file=sys.stderr)
            sys.exit(1)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
PYTHON_SCRIPT
    
    chmod +x "$PYTHON_CALCULATOR"
}

# Fallback math
calculate_simple_rate() {
    local hour=$1
    local day=$2
    local minute=$3
    
    local base_rate=5000
    
    if [ $hour -ge 8 ] && [ $hour -le 10 ]; then
        base_rate=8000
    elif [ $hour -ge 19 ] && [ $hour -le 21 ]; then
        base_rate=12000
    elif [ $hour -ge 1 ] && [ $hour -le 5 ]; then
        base_rate=2000
    fi
    
    if [ $day -eq 6 ] || [ $day -eq 7 ]; then
        base_rate=$(echo "scale=0; $base_rate * 1.3 / 1" | bc -l)
    fi
    
    local minute_var=$(echo "scale=0; $minute % 10" | bc -l)
    local variation=$(echo "scale=0; $base_rate * $minute_var / 100" | bc -l)
    local final_rate=$(echo "scale=0; $base_rate + $variation" | bc -l)
    echo "$final_rate"
}

# RPS to bandwidth 
rps_to_bandwidth() {
    local rps=$1
    local avg_request_bytes=500
    local avg_response_bytes=1500
    local bytes_per_transaction=$((avg_request_bytes + avg_response_bytes))
    local bps=$(echo "scale=0; $rps * $bytes_per_transaction * 8" | bc -l)
    
    local min_bps=1000
    if [ $(echo "$bps < $min_bps" | bc -l) -eq 1 ]; then
        bps=$min_bps
    fi
    
    if [ $(echo "$bps >= 1000000000" | bc -l) -eq 1 ]; then
        local gbps=$(echo "scale=2; $bps / 1000000000" | bc -l)
        echo "${gbps}gbit"
    elif [ $(echo "$bps >= 1000000" | bc -l) -eq 1 ]; then
        local mbps=$(echo "scale=2; $bps / 1000000" | bc -l)
        echo "${mbps}mbit"
    elif [ $(echo "$bps >= 1000" | bc -l) -eq 1 ]; then
        local kbps=$(echo "scale=0; $bps / 1000" | bc -l)
        echo "${kbps}kbit"
    else
        echo "1kbit"
    fi
}

# TC qdisc init - Only if no qdisc exists
init_tc_qdisc() {
    # Check if qdisc already exists
    if check_existing_qdisc; then
        TC_ACTIVE=false
        TC_MANAGED_BY_US=false
        log "✓ Running in PASSIVE mode (no TC control)"
        log "✓ Siege will generate traffic at maximum capacity"
        return 0  # Success, but we won't manage TC
    fi
    
    log "Initializing TC qdisc on interface $INTERFACE"
    tc qdisc del dev "$INTERFACE" root 2>/dev/null || true
    
    if tc qdisc add dev "$INTERFACE" root tbf rate "$MIN_RATE" burst "$BURST_SIZE" latency "$LATENCY"; then
        TC_ACTIVE=true
        TC_MANAGED_BY_US=true
        log "✓ TC qdisc initialized successfully (managed by this script)"
        return 0
    else
        log "ERROR: Failed to initialize TC qdisc"
        return 1
    fi
}

# TC qdisc update - Only if we manage the qdisc
update_tc_rate() {
    local new_rate="$1"
    
    # Don't update if we're not managing TC
    if [ "$TC_MANAGED_BY_US" != true ]; then
        return 0
    fi
    
    if [ "$TC_ACTIVE" = true ]; then
        if tc qdisc change dev "$INTERFACE" root tbf rate "$new_rate" burst "$BURST_SIZE" latency "$LATENCY" 2>/dev/null; then
            return 0
        else
            log "WARNING: Failed to update TC rate to $new_rate, reinitializing..."
            tc qdisc del dev "$INTERFACE" root 2>/dev/null || true
            if tc qdisc add dev "$INTERFACE" root tbf rate "$new_rate" burst "$BURST_SIZE" latency "$LATENCY"; then
                return 0
            else
                log "ERROR: Failed to reinitialize TC qdisc"
                TC_ACTIVE=false
                TC_MANAGED_BY_US=false
                return 1
            fi
        fi
    else
        return 1
    fi
}

# Create Siege RC
create_siege_rc() {
    cat > "$SIEGE_RC_FILE" << EOF
verbose = false
color = off
quiet = true
show-logfile = false
logging = false
protocol = HTTP/1.1
chunked = true
cache = false
connection = close
concurrent = $MAX_CONCURRENT
delay = 0.5
timeout = 3
failures = 0
benchmark = true
user-agent = Mozilla/5.0 (compatible; SiegeLoadTester/1.0)
accept-encoding = gzip, deflate
EOF

    log "Custom Siege RC created: $SIEGE_RC_FILE"
    log "Config: timeout=3s, failures=unlimited, connection=close"
}

# Start Siege - Run in MAX CAPACITY 
start_siege_flood() {
    log "Starting Siege HTTP flood to $TARGET_URL"
    log "Max concurrent users: $MAX_CONCURRENT"
    
    if [ "$TC_MANAGED_BY_US" = true ]; then
        log "Mode: Benchmark (max speed) - TC qdisc will control rate"
    else
        log "Mode: Benchmark (max speed) - PASSIVE (no TC control)"
    fi
    
    siege \
        -R "$SIEGE_RC_FILE" \
        -c "$MAX_CONCURRENT" \
        -t "${DURATION}s" \
        "$TARGET_URL" \
        >> "$LOG_FILE" 2>&1 &
    
    SIEGE_PID=$!
    
    if [ -n "$SIEGE_PID" ] && kill -0 "$SIEGE_PID" 2>/dev/null; then
        log "✓ Siege started successfully (PID: $SIEGE_PID)"
        return 0
    else
        log "ERROR: Failed to start Siege"
        return 1
    fi
}

# Wait for target to be ready
wait_for_target_ready() {
    local target_host=$(echo $TARGET_URL | sed -e 's|^http://||' -e 's|^https://||' -e 's|:.*||' -e 's|/.*||')
    local max_wait=300
    local waited=0
    
    log "Waiting for target $target_host to be ready..."
    
    while [ $waited -lt $max_wait ]; do
        if timeout 5 curl -sf -o /dev/null "$TARGET_URL" 2>/dev/null; then
            log "✓ Target is ready after ${waited}s"
            return 0
        fi
        
        sleep 5
        waited=$((waited + 5))
        
        if [ $((waited % 30)) -eq 0 ]; then
            log "  Still waiting for target... (${waited}s elapsed)"
        fi
    done
    
    log "✗ Target not responding after ${max_wait}s"
    return 1
}

# Restart Siege
restart_siege() {
    log "=== RESTARTING SIEGE ==="
    
    # Kill old Siege
    if [ -n "$SIEGE_PID" ] && kill -0 "$SIEGE_PID" 2>/dev/null; then
        log "Killing old Siege process (PID: $SIEGE_PID)"
        kill -TERM "$SIEGE_PID" 2>/dev/null
        sleep 2
        kill -KILL "$SIEGE_PID" 2>/dev/null 2>&1
    fi
    
    pkill -9 siege 2>/dev/null
    sleep 2
    
    # Flush ARP cache
    local target_ip=$(echo $TARGET_URL | sed -e 's|^http://||' -e 's|^https://||' -e 's|:.*||' -e 's|/.*||')
    log "Flushing ARP cache for $target_ip..."
    arp -d "$target_ip" 2>/dev/null || true
    ip neigh flush dev "$INTERFACE" 2>/dev/null || true
    
    # Wait for target ready
    if ! wait_for_target_ready; then
        log "ERROR: Target not ready, cannot restart Siege"
        return 1
    fi
    
    # Extra stabilization time
    log "Waiting 5s for target stabilization..."
    sleep 5
    
    # Start new Siege
    if start_siege_flood; then
        log "✓ Siege restarted successfully (New PID: $SIEGE_PID)"
        return 0
    else
        log "✗ Failed to restart Siege"
        return 1
    fi
}

# Monitor target health and auto-restart Siege
monitor_target_health() {
    local consecutive_failures=0
    local max_failures=3
    local check_interval=15
    
    log "=== HEALTH MONITOR STARTED ==="
    log "Check interval: ${check_interval}s"
    log "Failure threshold: ${max_failures} consecutive failures"
    
    while true; do
        sleep $check_interval
        
        # Check if Siege is still running
        if ! kill -0 "$SIEGE_PID" 2>/dev/null; then
            log "⚠ WARNING: Siege process died unexpectedly!"
            if restart_siege; then
                consecutive_failures=0
                continue
            else
                log "ERROR: Failed to restart Siege, monitor exiting"
                return 1
            fi
        fi
        
        # Check target connectivity
        if timeout 5 curl -sf -o /dev/null "$TARGET_URL" 2>/dev/null; then
            # Target OK
            if [ $consecutive_failures -gt 0 ]; then
                log "✓ Target recovered (was down for $((consecutive_failures * check_interval))s)"
                consecutive_failures=0
            fi
        else
            # Target NOT responding
            consecutive_failures=$((consecutive_failures + 1))
            log "⚠ Target check failed (${consecutive_failures}/${max_failures})"
            
            if [ $consecutive_failures -ge $max_failures ]; then
                log "⚠ Target appears to be DOWN (no response for $((consecutive_failures * check_interval))s)"
                log "   Likely instance reboot in progress..."
                
                # Restart Siege (will wait for target to be ready)
                if restart_siege; then
                    log "✓ Traffic resumed after target recovery"
                    consecutive_failures=0
                else
                    log "ERROR: Failed to restart Siege after target recovery"
                    return 1
                fi
            fi
        fi
    done
}

generate_compressed_pattern_python() {
    local duration_seconds=$1
    
    log "=== SIEGE + TC QDISC SIMULATION WITH SAFE DETECTION ==="
    log "Math Engine: Python3 with accurate mathematical functions"
    log "Compression factor: ${TIME_COMPRESSION}x"
    log "Real duration: ${duration_seconds}s"
    log "Target URL: $TARGET_URL"
    
    # Try to init TC qdisc (will detect existing)
    init_tc_qdisc
    
    if ! start_siege_flood; then
        log "ERROR: Cannot start Siege flood"
        return 1
    fi
    
    # Start health monitor in background
    monitor_target_health &
    MONITOR_PID=$!
    log "✓ Health monitor started (PID: $MONITOR_PID)"
    
    local update_interval=60
    local current_time=0
    local last_rate=""
    
    while [ $current_time -lt $duration_seconds ]; do
        local python_output
        if python_output=$(python3 "$PYTHON_CALCULATOR" compressed $current_time $TIME_COMPRESSION 2>/dev/null); then
            local final_rps=$(echo "$python_output" | awk '{print $1}')
            local virtual_hour=$(echo "$python_output" | awk '{print $2}')
            local virtual_day=$(echo "$python_output" | awk '{print $3}')
            local virtual_minute=$(echo "$python_output" | awk '{print $4}')
            
            local bandwidth=$(rps_to_bandwidth "$final_rps")
            
            if [ "$TC_MANAGED_BY_US" = true ]; then
                # We control TC, update it
                if [ "$bandwidth" != "$last_rate" ]; then
                    if update_tc_rate "$bandwidth"; then
                        log "T+${current_time}s | Day${virtual_day} ${virtual_hour}:$(printf "%02d" $virtual_minute) | RPS: ${final_rps} | BW: ${bandwidth} | Siege: ${SIEGE_PID} [TC-ACTIVE]"
                        last_rate="$bandwidth"
                    fi
                fi
            else
                # Passive mode, just log
                log "T+${current_time}s | Day${virtual_day} ${virtual_hour}:$(printf "%02d" $virtual_minute) | RPS: ${final_rps} | BW: ${bandwidth} | Siege: ${SIEGE_PID} [PASSIVE]"
            fi
        fi
        
        sleep $update_interval
        current_time=$((current_time + update_interval))
    done
    
    # Kill monitor
    if [ -n "$MONITOR_PID" ] && kill -0 "$MONITOR_PID" 2>/dev/null; then
        kill -9 "$MONITOR_PID" 2>/dev/null
    fi
}

generate_yoyo_pattern_python() {
    local duration_seconds=$1
    local yoyo_type="${2:-square}"
    
    log "=== SIEGE + TC QDISC YO-YO PATTERN WITH SAFE DETECTION ==="
    log "Type: $yoyo_type | Duration: ${duration_seconds}s"
    log "Target URL: $TARGET_URL"
    
    init_tc_qdisc
    
    if ! start_siege_flood; then
        log "ERROR: Cannot start Siege flood"
        return 1
    fi
    
    # Start health monitor in background
    monitor_target_health &
    MONITOR_PID=$!
    log "✓ Health monitor started (PID: $MONITOR_PID)"
    
    local update_interval=60
    local current_time=0
    
    while [ $current_time -lt $duration_seconds ]; do
        local python_output
        if python_output=$(python3 "$PYTHON_CALCULATOR" yoyo $current_time $yoyo_type 2>/dev/null); then
            local rps=$(echo "$python_output" | awk '{print $1}')
            local cycle_pos=$(echo "$python_output" | awk '{print $2}')
            
            local bandwidth=$(rps_to_bandwidth "$rps")
            
            if [ "$TC_MANAGED_BY_US" = true ]; then
                if update_tc_rate "$bandwidth"; then
                    log "T+${current_time}s | Cycle: ${cycle_pos} | RPS: ${rps} | BW: ${bandwidth} | Siege: ${SIEGE_PID} [$yoyo_type] [TC-ACTIVE]"
                fi
            else
                log "T+${current_time}s | Cycle: ${cycle_pos} | RPS: ${rps} | BW: ${bandwidth} | Siege: ${SIEGE_PID} [$yoyo_type] [PASSIVE]"
            fi
        fi
        
        sleep $update_interval
        current_time=$((current_time + update_interval))
    done
    
    # Kill monitor
    if [ -n "$MONITOR_PID" ] && kill -0 "$MONITOR_PID" 2>/dev/null; then
        kill -9 "$MONITOR_PID" 2>/dev/null
    fi
}

check_dependencies() {
    local missing_deps=()
    
    if ! command -v siege &> /dev/null; then
        missing_deps+=("siege")
    fi
    
    if ! command -v bc &> /dev/null; then
        missing_deps+=("bc")
    fi
    
    if ! command -v tc &> /dev/null; then
        missing_deps+=("iproute2")
    fi
    
    if ! command -v curl &> /dev/null; then
        missing_deps+=("curl")
    fi
    
    if [[ $EUID -ne 0 ]]; then
        log "ERROR: Root privileges required"
        exit 1
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log "ERROR: Missing dependencies: ${missing_deps[*]}"
        exit 1
    fi
    
    if ! ip link show "$INTERFACE" &>/dev/null; then
        log "ERROR: Interface $INTERFACE does not exist"
        exit 1
    fi
}

validate_url() {
    local url=$1
    if [[ ! "$url" =~ ^https?:// ]]; then
        log "ERROR: Invalid URL. Must start with http:// or https://"
        exit 1
    fi
}

main() {
    local mode="${5:-python-compressed}"
    local yoyo_type="${6:-square}"
    
    log "=== SIEGE HTTP FLOOD SIMULATOR WITH AUTO-RESTART + SAFE TC DETECTION ==="
    log "Target URL: $TARGET_URL"
    log "Interface: $INTERFACE"
    log "Duration: ${DURATION}s"
    log "Compression: ${TIME_COMPRESSION}x"
    log "Mode: $mode"
    log "Max Concurrent: $MAX_CONCURRENT users"
    
    validate_url "$TARGET_URL"
    check_dependencies
    check_python
    
    create_siege_rc
    
    if [ "$PYTHON_AVAILABLE" = true ]; then
        create_python_calculator
        log "✓ Python math calculator created successfully"
    else
        log "ERROR: Python not available, cannot run"
        exit 1
    fi
    
    case "$mode" in
        "python-compressed")
            generate_compressed_pattern_python "$DURATION"
            ;;
        "python-yoyo")
            generate_yoyo_pattern_python "$DURATION" "$yoyo_type"
            ;;
        *)
            log "ERROR: Unknown mode: $mode"
            exit 1
            ;;
    esac
    
    log "=== SIMULATION COMPLETED ==="
    log "Log file: $LOG_FILE"
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Siege HTTP Flood Simulator with Safe TC Detection"
    echo "Usage: $0 [TARGET_URL] [INTERFACE] [DURATION] [COMPRESSION] [MODE] [YOYO_TYPE]"
    echo ""
    echo "This script will:"
    echo "  - Detect existing TC qdisc on the interface"
    echo "  - Run in PASSIVE mode if qdisc exists (no TC control)"
    echo "  - Run in ACTIVE mode if no qdisc exists (with TC control)"
    echo "  - Auto-restart Siege if target reboots"
    exit 0
fi

main "$@"
