#!/bin/bash

# Comprehensive benchmark script for audio preprocessor implementations
# Runs all implementations, times them, and validates output consistency

set -e

INPUT_DIR="${1:-/input}"
SAMPLE_RATE="${2:-16000}"
MAX_DURATION="${3:-10.0}"
NUM_SAMPLES="${4:-5}"  # Number of files to check for consistency

echo "=============================================="
echo "Audio Preprocessor Benchmark"
echo "=============================================="
echo "Input:       $INPUT_DIR"
echo "Sample Rate: $SAMPLE_RATE Hz"
echo "Max Duration: $MAX_DURATION s"
echo "Validation samples: $NUM_SAMPLES"
echo "=============================================="
echo ""

# Count input files
FILE_COUNT=$(find "$INPUT_DIR" -type f \( -iname "*.mp3" -o -iname "*.wav" -o -iname "*.flac" -o -iname "*.m4a" -o -iname "*.ogg" \) | wc -l)
echo "Found $FILE_COUNT audio files"
echo ""

# Create output directories for each implementation
OUTPUT_BASE="/tmp/benchmark_output"
rm -rf "$OUTPUT_BASE"
mkdir -p "$OUTPUT_BASE"/{zig,cffi,zig_perfile,bash,python}

# Array to store results
declare -A TIMES
declare -A SUCCESS

run_benchmark() {
    local name="$1"
    local cmd="$2"
    local output_dir="$3"

    echo "----------------------------------------"
    echo "Running: $name"
    echo "----------------------------------------"

    local start_time=$(date +%s.%N)

    if eval "$cmd" > /dev/null 2>&1; then
        local end_time=$(date +%s.%N)
        local elapsed=$(echo "$end_time - $start_time" | bc)
        TIMES[$name]=$elapsed
        SUCCESS[$name]="OK"

        local output_count=$(find "$output_dir" -name "*.wav" | wc -l)
        echo "  Status: SUCCESS"
        echo "  Time: ${elapsed}s"
        echo "  Output files: $output_count"
    else
        local end_time=$(date +%s.%N)
        local elapsed=$(echo "$end_time - $start_time" | bc)
        TIMES[$name]=$elapsed
        SUCCESS[$name]="FAIL"
        echo "  Status: FAILED"
        echo "  Time: ${elapsed}s"
    fi
    echo ""
}

# Run benchmarks
echo ""
echo "=============================================="
echo "RUNNING BENCHMARKS"
echo "=============================================="
echo ""

run_benchmark "zig" \
    "audio_preprocessor_zig '$INPUT_DIR' '$OUTPUT_BASE/zig' --sample-rate $SAMPLE_RATE --max-duration $MAX_DURATION" \
    "$OUTPUT_BASE/zig"

run_benchmark "cffi" \
    "audio_preprocessor_cffi '$INPUT_DIR' '$OUTPUT_BASE/cffi' --sample-rate $SAMPLE_RATE --max-duration $MAX_DURATION" \
    "$OUTPUT_BASE/cffi"

run_benchmark "zig_perfile" \
    "audio_preprocessor_zig_perfile '$INPUT_DIR' '$OUTPUT_BASE/zig_perfile' --sample-rate $SAMPLE_RATE --max-duration $MAX_DURATION" \
    "$OUTPUT_BASE/zig_perfile"

run_benchmark "bash" \
    "audio_preprocessor_bash '$INPUT_DIR' '$OUTPUT_BASE/bash' --sample-rate $SAMPLE_RATE --max-duration $MAX_DURATION" \
    "$OUTPUT_BASE/bash"

run_benchmark "python" \
    "audio_preprocessor_python '$INPUT_DIR' '$OUTPUT_BASE/python' --sample-rate $SAMPLE_RATE --max-duration $MAX_DURATION" \
    "$OUTPUT_BASE/python"

# Validation: Compare MD5 checksums
echo ""
echo "=============================================="
echo "VALIDATING OUTPUT CONSISTENCY"
echo "=============================================="
echo ""

# Get sample files to check - use bash output as reference since it's flat
SAMPLE_FILES=$(find "$OUTPUT_BASE/bash" -name "*.wav" 2>/dev/null | head -n "$NUM_SAMPLES")

# Fallback to zig_perfile if bash has no output
if [[ -z "$SAMPLE_FILES" ]]; then
    SAMPLE_FILES=$(find "$OUTPUT_BASE/zig_perfile" -name "*.wav" 2>/dev/null | head -n "$NUM_SAMPLES")
fi

if [[ -z "$SAMPLE_FILES" ]]; then
    echo "No output files to validate!"
else
    echo "Checking MD5 checksums of $NUM_SAMPLES sample files..."
    echo ""

    CONSISTENT=true

    for file in $SAMPLE_FILES; do
        basename=$(basename "$file")
        echo "File: $basename"

        # Get MD5 for each implementation
        declare -A CHECKSUMS

        for impl in zig cffi zig_perfile bash python; do
            # Search recursively for the file (handles different directory structures)
            impl_file=$(find "$OUTPUT_BASE/$impl" -name "$basename" 2>/dev/null | head -1)
            if [[ -f "$impl_file" ]]; then
                CHECKSUMS[$impl]=$(md5sum "$impl_file" | awk '{print $1}')
                echo "  $impl: ${CHECKSUMS[$impl]}"
            else
                CHECKSUMS[$impl]="MISSING"
                echo "  $impl: MISSING"
            fi
        done

        # Check if all checksums match (excluding missing)
        unique_checksums=$(echo "${CHECKSUMS[@]}" | tr ' ' '\n' | grep -v MISSING | sort -u | wc -l)
        if [[ "$unique_checksums" -gt 1 ]]; then
            echo "  ⚠️  MISMATCH DETECTED!"
            CONSISTENT=false
        else
            echo "  ✓ All match"
        fi
        echo ""

        unset CHECKSUMS
        declare -A CHECKSUMS
    done

    if $CONSISTENT; then
        echo "✓ All sampled outputs are consistent across implementations"
    else
        echo "⚠️  Some outputs differ between implementations"
    fi
fi

# Summary
echo ""
echo "=============================================="
echo "BENCHMARK RESULTS SUMMARY"
echo "=============================================="
echo ""
printf "%-15s %10s %10s %10s\n" "Implementation" "Time (s)" "Status" "Speedup"
printf "%-15s %10s %10s %10s\n" "---------------" "----------" "----------" "----------"

# Find baseline (bash time)
BASELINE=${TIMES[bash]:-1}

for impl in zig cffi zig_perfile bash python; do
    time=${TIMES[$impl]:-0}
    status=${SUCCESS[$impl]:-N/A}
    if [[ "$time" != "0" && "$BASELINE" != "0" ]]; then
        speedup=$(echo "scale=2; $BASELINE / $time" | bc)
        printf "%-15s %10.2f %10s %10sx\n" "$impl" "$time" "$status" "$speedup"
    else
        printf "%-15s %10.2f %10s %10s\n" "$impl" "$time" "$status" "N/A"
    fi
done

echo ""
echo "=============================================="
echo "ANALYSIS"
echo "=============================================="
echo ""

# Calculate and show key comparisons
if [[ "${TIMES[zig]}" && "${TIMES[zig_perfile]}" ]]; then
    overhead=$(echo "scale=2; ${TIMES[zig_perfile]} / ${TIMES[zig]}" | bc)
    echo "Process spawn overhead (zig_perfile / zig): ${overhead}x slower"
fi

if [[ "${TIMES[zig]}" && "${TIMES[cffi]}" ]]; then
    overhead=$(echo "scale=2; ${TIMES[cffi]} / ${TIMES[zig]}" | bc)
    echo "Python/cffi overhead (cffi / zig): ${overhead}x slower"
fi

if [[ "${TIMES[zig_perfile]}" && "${TIMES[bash]}" ]]; then
    ratio=$(echo "scale=2; ${TIMES[bash]} / ${TIMES[zig_perfile]}" | bc)
    echo "Zig vs ffmpeg binary startup (bash / zig_perfile): ${ratio}x"
fi

echo ""
echo "Benchmark complete!"
