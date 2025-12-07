#!/bin/bash

# =================================================================
# OpenStack Monitoring - Auto-detect Interface from Gnocchi
# =================================================================

DEFAULT_RESOURCE_ID="ff90a550-aedc-46b6-985f-41b704a4c2d5"
RESOURCE_ID="${1:-$DEFAULT_RESOURCE_ID}"
SERVER_NAME="${2:-$RESOURCE_ID}"

# Load credentials
if [ -z "$OS_AUTH_URL" ]; then
    if [ -f /opt/stack/devstack/openrc ]; then
        source /opt/stack/devstack/openrc admin admin
    elif [ -f ~/devstack/openrc ]; then
        source ~/devstack/openrc admin admin
    fi
fi

echo "=== Monitoring Configuration ==="
echo "Instance ID: $RESOURCE_ID"
echo ""

# Auto-detect interface ID from Gnocchi (not Neutron!)
echo "Detecting interface from Gnocchi..."
INTERFACE_ID=$(openstack metric resource list --type instance_network_interface -f json | \
    jq -r ".[] | select(.instance_id == \"$RESOURCE_ID\") | .id")

if [ -z "$INTERFACE_ID" ] || [ "$INTERFACE_ID" = "null" ]; then
    echo "⚠ WARNING: Could not find interface in Gnocchi for this instance!"
    echo "This means Ceilometer is not collecting network metrics for this instance."
    echo ""
    echo "Possible solutions:"
    echo "1. Wait 2-3 minutes for Ceilometer to discover the instance"
    echo "2. Restart Ceilometer: sudo systemctl restart devstack@ceilometer-acompute.service"
    echo "3. Use libvirt-based monitoring instead"
    exit 1
fi

echo "✓ Interface ID: $INTERFACE_ID"
echo "  Server Name: $SERVER_NAME"
echo ""

# Verify interface has metrics
echo "Verifying interface has network metrics..."
if ! openstack metric measures show --resource-id "$INTERFACE_ID" network.incoming.packets &>/dev/null; then
    echo "⚠ WARNING: Interface exists but has no network metrics yet!"
    echo "Wait a few minutes for data collection..."
fi

# Create directory structure
CURRENT_DATE="$(date +%Y-%m-%d)"
LOG_BASE="./$SERVER_NAME/$CURRENT_DATE"
mkdir -p "$LOG_BASE"

# Log files
CPU_UTIL_PERCENT="$LOG_BASE/cpu_utilization_percent"
CPU_UTIL_RAW="$LOG_BASE/cpu_utilization_nanoseconds"
MEMORY_USAGE="$LOG_BASE/memory_usage"
MEMORY_RESIDENT="$LOG_BASE/memory_resident"

# Network metrics - using Gnocchi interface ID
NET_RX_PACKETS="$LOG_BASE/network_incoming_packets"
NET_RX_BYTES="$LOG_BASE/network_incoming_bytes"
NET_RX_RATE_PACKETS="$LOG_BASE/network_incoming_packets_rate"
NET_RX_RATE_BYTES="$LOG_BASE/network_incoming_bytes_rate"
NET_RX_DROPS="$LOG_BASE/network_incoming_packets_drop"
NET_RX_ERRORS="$LOG_BASE/network_incoming_packets_error"

NET_TX_PACKETS="$LOG_BASE/network_outgoing_packets"
NET_TX_BYTES="$LOG_BASE/network_outgoing_bytes"
NET_TX_RATE_PACKETS="$LOG_BASE/network_outgoing_packets_rate"
NET_TX_RATE_BYTES="$LOG_BASE/network_outgoing_bytes_rate"
NET_TX_DROPS="$LOG_BASE/network_outgoing_packets_drop"
NET_TX_ERRORS="$LOG_BASE/network_outgoing_packets_error"

VCPUS="$LOG_BASE/vcpus"

GRANULARITY=60
SLEEP_INTERVAL=60

# Helper functions
log_metric() {
    local log_file="$1"
    local metric_name="$2"
    local resource_id="$3"
    
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') ===" > "${log_file}.log"
    
    openstack metric measures show --granularity "$GRANULARITY" \
        --utc --resource-id "$resource_id" "$metric_name" \
        > "${log_file}.log" 2>/dev/null
    
    openstack metric measures show --granularity "$GRANULARITY" \
        -f csv --utc --resource-id "$resource_id" "$metric_name" \
        > "${log_file}.csv" 2>/dev/null
}

log_aggregate() {
    local log_file="$1"
    local formula="$2"
    local resource_type="$3"
    local resource_filter="$4"
    
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') ===" > "${log_file}.log"
    
    openstack metric aggregates --granularity "$GRANULARITY" \
        --resource-type "$resource_type" \
        "$formula" "$resource_filter" \
        > "${log_file}.log" 2>/dev/null
    
    openstack metric aggregates --granularity "$GRANULARITY" \
        -f csv --resource-type "$resource_type" \
        "$formula" "$resource_filter" \
        > "${log_file}.csv" 2>/dev/null
}

collect_cpu_metrics() {
    echo "Collecting CPU metrics..."
    
    log_aggregate "$CPU_UTIL_PERCENT" \
        "(* (/ (/ (aggregate rate:mean (metric cpu mean)) 1000000000) 60) 100)" \
        "instance" \
        "id=$RESOURCE_ID"
    
    log_metric "$CPU_UTIL_RAW" "cpu" "$RESOURCE_ID"
}

collect_memory_metrics() {
    echo "Collecting Memory metrics..."
    
    log_metric "$MEMORY_USAGE" "memory.usage" "$RESOURCE_ID"
    log_metric "$MEMORY_RESIDENT" "memory.resident" "$RESOURCE_ID"
}

collect_network_rx_metrics() {
    echo "Collecting Network RX (Incoming) metrics..."
    
    log_metric "$NET_RX_PACKETS" "network.incoming.packets" "$INTERFACE_ID"
    log_metric "$NET_RX_BYTES" "network.incoming.bytes" "$INTERFACE_ID"
    
    log_aggregate "$NET_RX_RATE_PACKETS" \
        "(/ (aggregate rate:mean (metric network.incoming.packets mean)) 60)" \
        "instance_network_interface" \
        "id=$INTERFACE_ID"
    
    log_aggregate "$NET_RX_RATE_BYTES" \
        "(* (* (/ (aggregate rate:mean (metric network.incoming.bytes mean)) 60) 8) 0.000001)" \
        "instance_network_interface" \
        "id=$INTERFACE_ID"
    
    log_metric "$NET_RX_DROPS" "network.incoming.packets.drop" "$INTERFACE_ID"
    log_metric "$NET_RX_ERRORS" "network.incoming.packets.error" "$INTERFACE_ID"
}

collect_network_tx_metrics() {
    echo "Collecting Network TX (Outgoing) metrics..."
    
    log_metric "$NET_TX_PACKETS" "network.outgoing.packets" "$INTERFACE_ID"
    log_metric "$NET_TX_BYTES" "network.outgoing.bytes" "$INTERFACE_ID"
    
    log_aggregate "$NET_TX_RATE_PACKETS" \
        "(/ (aggregate rate:mean (metric network.outgoing.packets mean)) 60)" \
        "instance_network_interface" \
        "id=$INTERFACE_ID"
    
    log_aggregate "$NET_TX_RATE_BYTES" \
        "(* (* (/ (aggregate rate:mean (metric network.outgoing.bytes mean)) 60) 8) 0.000001)" \
        "instance_network_interface" \
        "id=$INTERFACE_ID"
    
    log_metric "$NET_TX_DROPS" "network.outgoing.packets.drop" "$INTERFACE_ID"
    log_metric "$NET_TX_ERRORS" "network.outgoing.packets.error" "$INTERFACE_ID"
}

collect_system_metrics() {
    echo "Collecting System metrics..."
    log_metric "$VCPUS" "vcpus" "$RESOURCE_ID"
}

generate_summary() {
    local summary_file="$LOG_BASE/summary.txt"
    
    echo "=== Monitoring Summary ===" > "$summary_file"
    echo "Generated at: $(date '+%Y-%m-%d %H:%M:%S')" > "$summary_file"
    echo "" > "$summary_file"
    
    echo "Instance: $RESOURCE_ID" > "$summary_file"
    echo "Interface (Gnocchi): $INTERFACE_ID" > "$summary_file"
    echo "" > "$summary_file"
    
    echo "=== Latest Metrics ===" > "$summary_file"
    
    # CPU
    if [ -f "${CPU_UTIL_PERCENT}.csv" ] && [ -s "${CPU_UTIL_PERCENT}.csv" ]; then
        local cpu_latest=$(tail -1 "${CPU_UTIL_PERCENT}.csv" 2>/dev/null | cut -d',' -f3)
        [ -n "$cpu_latest" ] && echo "CPU Utilization: ${cpu_latest}%" > "$summary_file"
    fi
    
    # Memory
    if [ -f "${MEMORY_USAGE}.csv" ] && [ -s "${MEMORY_USAGE}.csv" ]; then
        local mem_latest=$(tail -1 "${MEMORY_USAGE}.csv" 2>/dev/null | cut -d',' -f3)
        [ -n "$mem_latest" ] && echo "Memory Usage: ${mem_latest} MB" > "$summary_file"
    fi
    
    # Network RX
    if [ -f "${NET_RX_RATE_PACKETS}.csv" ] && [ -s "${NET_RX_RATE_PACKETS}.csv" ]; then
        local rx_pps=$(tail -1 "${NET_RX_RATE_PACKETS}.csv" 2>/dev/null | cut -d',' -f3)
        [ -n "$rx_pps" ] && echo "Incoming Packets Rate: ${rx_pps} pps" > "$summary_file"
    fi
    
    if [ -f "${NET_RX_RATE_BYTES}.csv" ] && [ -s "${NET_RX_RATE_BYTES}.csv" ]; then
        local rx_mbps=$(tail -1 "${NET_RX_RATE_BYTES}.csv" 2>/dev/null | cut -d',' -f3)
        [ -n "$rx_mbps" ] && echo "Incoming Bandwidth: ${rx_mbps} Mbps" > "$summary_file"
    fi
    
    # Network TX
    if [ -f "${NET_TX_RATE_PACKETS}.csv" ] && [ -s "${NET_TX_RATE_PACKETS}.csv" ]; then
        local tx_pps=$(tail -1 "${NET_TX_RATE_PACKETS}.csv" 2>/dev/null | cut -d',' -f3)
        [ -n "$tx_pps" ] && echo "Outgoing Packets Rate: ${tx_pps} pps" > "$summary_file"
    fi
    
    if [ -f "${NET_TX_RATE_BYTES}.csv" ] && [ -s "${NET_TX_RATE_BYTES}.csv" ]; then
        local tx_mbps=$(tail -1 "${NET_TX_RATE_BYTES}.csv" 2>/dev/null | cut -d',' -f3)
        [ -n "$tx_mbps" ] && echo "Outgoing Bandwidth: ${tx_mbps} Mbps" > "$summary_file"
    fi
    
    # Packet Loss
    if [ -f "${NET_RX_DROPS}.csv" ] && [ -s "${NET_RX_DROPS}.csv" ]; then
        local drops=$(tail -1 "${NET_RX_DROPS}.csv" 2>/dev/null | cut -d',' -f3)
        [ -n "$drops" ] && echo "Incoming Packet Drops: ${drops}" > "$summary_file"
    fi
    
    if [ -f "${NET_RX_ERRORS}.csv" ] && [ -s "${NET_RX_ERRORS}.csv" ]; then
        local errors=$(tail -1 "${NET_RX_ERRORS}.csv" 2>/dev/null | cut -d',' -f3)
        [ -n "$errors" ] && echo "Incoming Packet Errors: ${errors}" > "$summary_file"
    fi
    
    echo "" > "$summary_file"
    echo "Full logs available in: $LOG_BASE" > "$summary_file"
    
    cat "$summary_file"
}

# Main loop
echo "=== Starting Comprehensive Monitoring ==="
echo "Logs will be saved to: $LOG_BASE"
echo "Press Ctrl+C to stop"
echo ""

iteration=0

while true; do
    ((iteration++))
    echo ""
    echo "╔════════════════════════════════════════════════════════╗"
    printf "║  Iteration #%-3d - %s\n" "$iteration" "$(date '+%Y-%m-%d %H:%M:%S')"
    echo "╚════════════════════════════════════════════════════════╝"
    
    collect_cpu_metrics
    collect_memory_metrics
    collect_network_rx_metrics
    collect_network_tx_metrics
    collect_system_metrics
    
    if [ $((iteration % 5)) -eq 0 ]; then
        echo ""
        echo "Generating summary report..."
        generate_summary
    fi
    
    echo ""
    echo "✓ Metrics collection completed. Sleeping for $SLEEP_INTERVAL seconds..."
    echo "────────────────────────────────────────────────────────"
    
    sleep "$SLEEP_INTERVAL"
done
