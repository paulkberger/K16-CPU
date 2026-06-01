#!/bin/bash
# K16 Emulator Test Runner
# Usage: ./run_tests.sh [bin_dir] [options]
#
# Runs all .bin files in bin_dir through K16EmuCLI.
# Expects each test to HALT with exit code 0 for pass.
# Non-zero exit = test failure; exit code printed.
#
# Options:
#   --bigendian    pass --bigendian to emulator (old assembler .bin format)
#   --trace        pass --trace to emulator (verbose, slow)
#   --maxcycles N  cap cycles per test (default 10000000)
#   --timeout N    wall-clock timeout per test in seconds (default 10)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMU="${SCRIPT_DIR}/K16EmuCLI"

if [ ! -x "$EMU" ]; then
    echo "ERROR: K16EmuCLI not found at $EMU"
    echo "Build with: cd $SCRIPT_DIR && fpc -Mdelphi -Fu../core K16EmuCLI.lpr"
    exit 1
fi

BIN_DIR="${1:-.}"
shift 2>/dev/null

EMU_OPTS=""
MAXCYCLES=10000000
TIMEOUT=10

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bigendian)  EMU_OPTS="$EMU_OPTS --bigendian" ;;
        --trace)      EMU_OPTS="$EMU_OPTS --trace" ;;
        --maxcycles)  MAXCYCLES="$2"; shift ;;
        --timeout)    TIMEOUT="$2"; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

EMU_OPTS="$EMU_OPTS --maxcycles $MAXCYCLES"

if [ ! -d "$BIN_DIR" ]; then
    echo "ERROR: Directory not found: $BIN_DIR"
    exit 1
fi

BINS=( "$BIN_DIR"/*.bin )
if [ ${#BINS[@]} -eq 0 ] || [ ! -f "${BINS[0]}" ]; then
    echo "No .bin files found in $BIN_DIR"
    exit 1
fi

PASS=0
FAIL=0
SKIP=0
TOTAL=${#BINS[@]}

echo "K16 Emulator Test Run"
echo "Emulator: $EMU"
echo "Test dir: $BIN_DIR"
echo "Tests:    $TOTAL"
echo "Options:  $EMU_OPTS"
echo "Timeout:  ${TIMEOUT}s"
echo "---"

for BIN in "${BINS[@]}"; do
    NAME=$(basename "$BIN" .bin)
    
    # Run with timeout
    OUTPUT=$(timeout "${TIMEOUT}s" "$EMU" "$BIN" $EMU_OPTS 2>&1)
    EXIT=$?
    
    if [ $EXIT -eq 124 ]; then
        echo "TIMEOUT $NAME"
        ((FAIL++))
    elif [ $EXIT -eq 0 ]; then
        echo "PASS    $NAME"
        ((PASS++))
    else
        echo "FAIL    $NAME  (exit $EXIT)"
        if [ -n "$OUTPUT" ]; then
            echo "        $OUTPUT" | head -3
        fi
        ((FAIL++))
    fi
done

echo "---"
echo "Results: $PASS/$TOTAL passed, $FAIL failed"

if [ $FAIL -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "FAILURES: $FAIL"
    exit 1
fi
