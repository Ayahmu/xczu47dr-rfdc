#!/bin/bash
# Monitor the Vivado build progress

LOG_FILE="build_slave.log"

if [ ! -f "$LOG_FILE" ]; then
    echo "ERROR: $LOG_FILE not found"
    exit 1
fi

echo "=== Build Monitor for custom_xczu47dr_slave ==="
echo "Started: $(head -1 $LOG_FILE)"
echo ""

# Check if build is still running
if pgrep -f "make.*bitstream-slave" > /dev/null; then
    echo "Status: RUNNING"
else
    echo "Status: COMPLETED or FAILED"
fi

echo ""
echo "=== Latest Progress ==="
tail -30 "$LOG_FILE"

echo ""
echo "=== Key Milestones ==="
grep -E "Chisel|Creating project|launch_runs synth|launch_runs impl|write_bitstream|successfully completed" "$LOG_FILE" | tail -10

echo ""
echo "=== Errors (if any) ==="
grep -i "error" "$LOG_FILE" | tail -5

echo ""
echo "=== Warnings Count ==="
grep -c "WARNING" "$LOG_FILE" || echo "0"

echo ""
echo "To follow live: tail -f $LOG_FILE"
