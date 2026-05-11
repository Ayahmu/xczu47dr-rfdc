# Software - Host Control

This directory contains the host-side Python software for controlling the ZCU216 RFDC system.

## Directory Structure

```
software/
├── host.py             # Main control script
├── requirements.txt    # Python dependencies
└── README.md           # This file
```

## Prerequisites

- Python 3.7 or later
- Network connection to ZCU216 board

## Installation

```bash
# Create virtual environment (recommended)
python3 -m venv venv
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt
```

## Usage

### Basic Usage

```bash
python host.py
```

### Configuration

Edit the following parameters in `host.py`:

```python
# Hardware parameters
DAC_XY_FS = 4.608e9          # DAC sampling frequency
FIXED_DATA_BYTES = 4096      # Fixed data size (2048 samples)
DDR_BASE = 0x500000000       # DDR base address

# Network configuration
BOARD_IP = "10.87.5.241"     # ZCU216 IP address
BOARD_PORT = 7               # TCP port
```

### Waveform Generation

The script generates RF bursts with Gaussian envelopes:

```python
# Generate X channel waveform
x_wave = generate_rf_burst(
    freq=0.250e9,           # RF frequency (250 MHz)
    duration_s=100e-9,      # Pulse duration (100 ns)
    delay_s=0,              # Delay (0 ns)
    fs=DAC_XY_FS,           # Sampling frequency
    interpolation=4,        # Interpolation factor
    amp=0.8                 # Amplitude (0.8 = 80%)
)
```

## Features

### RFSocController Class

Main interface for controlling the RFDC system:

```python
ctrl = RFSocController("10.87.5.241", port=7)

# Upload waveform to DDR
ctrl.upload_waveform(waveform_data, ddr_addr=0x500000000, 
                     dump_path="waveform.txt")

# Send instruction sequence
ctrl.send_instructions([
    [1, 1, 0, 0],                    # CH1 idle
    [2, 1, 4096, 0x500000000],       # CH1 play from DDR
    [3, 0, 0, 0]                     # END
])

# Trigger execution
ctrl.trigger()

ctrl.close()
```

### Packet Protocol

Communication uses a simple packet protocol:

```
[Type (u32)] [Length (u32)] [Data]
```

**Packet Types:**
- Type 0: Upload waveform (8-byte DDR address + waveform data)
- Type 1: Send instructions (16 bytes per instruction)
- Type 2: Trigger execution

### Instruction Format

Each instruction is 16 bytes (4 x 32-bit words):

```
Word 0: [Channel (4 bits)] [Opcode (4 bits)]
Word 1: Length or Delay (32 bits)
Word 2: Address Low (32 bits)
Word 3: Address High (32 bits)
```

**Opcodes:**
- 1: Idle/Delay
- 2: Play waveform from DDR
- 3: End sequence

## Output Files

The script generates:
- `x_waveform_hex.txt`: X channel waveform in hex format
- `y_waveform_hex.txt`: Y channel waveform in hex format
- `wave_preview_firstN.png`: Preview of first N samples
- `wave_preview_full.png`: Full waveform plot

## Example Workflow

1. **Generate waveforms** with desired parameters
2. **Upload to DDR** via TCP connection
3. **Send instruction sequence** defining playback
4. **Trigger execution** to start RF output
5. **Verify output** using oscilloscope or spectrum analyzer

## Troubleshooting

### Connection Issues

```bash
# Check network connectivity
ping 10.87.5.241

# Check if port is open
nc -zv 10.87.5.241 7
```

### Timeout Errors

Increase timeout in RFSocController:

```python
ctrl = RFSocController("10.87.5.241", port=7, timeout_s=10.0)
```

## Notes

- Waveforms are quantized to 16-bit signed integers
- Data is always padded/truncated to 2048 samples (4096 bytes)
- All multi-byte values use little-endian byte order
- DDR addresses must be 4096-byte aligned
