#!/bin/bash

# Benchmark: Run Zig binary file-by-file (like bash does with ffmpeg)
# This shows the overhead of process spawning vs thread pool

set -e

# Default values
SAMPLE_RATE=16000
MIN_DURATION=3.0
MAX_DURATION=5.0
NUM_THREADS=$(nproc 2>/dev/null || echo 4)

# Parse arguments
INPUT_DIR=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --sample-rate)
            SAMPLE_RATE="$2"
            shift 2
            ;;
        --min-duration)
            MIN_DURATION="$2"
            shift 2
            ;;
        --max-duration)
            MAX_DURATION="$2"
            shift 2
            ;;
        --threads)
            NUM_THREADS="$2"
            shift 2
            ;;
        *)
            if [[ -z "$INPUT_DIR" ]]; then
                INPUT_DIR="$1"
            elif [[ -z "$OUTPUT_DIR" ]]; then
                OUTPUT_DIR="$1"
            fi
            shift
            ;;
    esac
done

if [[ -z "$INPUT_DIR" || -z "$OUTPUT_DIR" ]]; then
    echo "Usage: $0 <input_dir> <output_dir> [options]"
    exit 1
fi

echo "Audio Dataset Preprocessor (Zig per-file, like Bash)"
echo "Input:  $INPUT_DIR"
echo "Output: $OUTPUT_DIR"
echo "Threads: $NUM_THREADS"

mkdir -p "$OUTPUT_DIR"

# Function to process a single file by calling Zig binary
process_file() {
    local input_file="$1"
    local input_dir="$2"
    local output_dir="$3"
    local sample_rate="$4"
    local min_dur="$5"
    local max_dur="$6"

    # Get relative path from input dir
    local rel_path="${input_file#$input_dir/}"
    local rel_dir=$(dirname "$rel_path")
    local basename=$(basename "$input_file")
    local name="${basename%.*}"

    # Create output subdirectory if needed
    local out_subdir="$output_dir/$rel_dir"
    mkdir -p "$out_subdir"

    # Create a temp dir for this single file, run zig, copy output
    local tmp_in=$(mktemp -d)
    local tmp_out=$(mktemp -d)

    cp "$input_file" "$tmp_in/"

    audio_preprocessor_zig "$tmp_in" "$tmp_out" \
        --sample-rate "$sample_rate" \
        --min-duration "$min_dur" \
        --max-duration "$max_dur" \
        --threads 1 2>/dev/null

    # Copy output to destination (preserving directory structure)
    if [[ -f "$tmp_out/${name}.wav" ]]; then
        cp "$tmp_out/${name}.wav" "$out_subdir/"
        echo "Processed: $input_file"
    fi

    rm -rf "$tmp_in" "$tmp_out"
}

export -f process_file

# Find all audio files
AUDIO_FILES=$(find "$INPUT_DIR" -type f \( -iname "*.mp3" -o -iname "*.wav" -o -iname "*.flac" -o -iname "*.m4a" -o -iname "*.ogg" -o -iname "*.aac" -o -iname "*.wma" -o -iname "*.opus" \))

FILE_COUNT=$(echo "$AUDIO_FILES" | grep -c . || echo 0)
echo "Found $FILE_COUNT audio files"

if [[ "$FILE_COUNT" -eq 0 ]]; then
    echo "No audio files found."
    exit 0
fi

echo "Processing with $NUM_THREADS parallel processes..."

# Process files in parallel using xargs (spawns zig binary per file)
echo "$AUDIO_FILES" | xargs -P "$NUM_THREADS" -I {} bash -c "process_file '{}' '$INPUT_DIR' '$OUTPUT_DIR' '$SAMPLE_RATE' '$MIN_DURATION' '$MAX_DURATION'"

echo "Processing complete!"
