# Repository instructions

## Hardware test and example scripts

- User-facing hardware test, example, and measurement scripts must run without command-line arguments.
- Put all user-adjustable network, board, timing, waveform, channel, and test parameters in a clearly labeled constants section near the top of the script.
- Assign those constants directly (for example, `BOARD_IP = "169.254.149.60"`). Do not obtain them from `argparse`, `sys.argv`, `os.environ`, `os.getenv`, or shell variable prefixes.
- Usage documentation for these scripts must tell users to edit the constants and then run the script with no options. Do not publish invocations that pass runtime configuration through command-line flags or environment variables.
- Product command-line tools whose API is inherently a CLI may keep their arguments. Do not turn a hardware test script into a CLI unless the user explicitly requests it.
