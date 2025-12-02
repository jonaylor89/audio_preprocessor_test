#!/bin/bash

# Audio Dataset Preprocessor - Bash/FFmpeg version
# Usage: ./shell_test.sh <input_dir> <output_dir> [--sample-rate rate] [--min-duration sec] [--max-duration sec] [--threads num]

set -e

# Default values
SAMPLE_RATE=16000
MIN_DURATION=3.0
MAX_DURATION=5.0
NUM_THREADS=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)

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
    echo ""
    echo "Options:"
    echo "  --sample-rate <rate>   Target sample rate (default: 16000)"
    echo "  --min-duration <sec>   Minimum duration in seconds (default: 3.0)"
    echo "  --max-duration <sec>   Maximum duration in seconds (default: 5.0)"
    echo "  --threads <num>        Number of parallel jobs (default: auto)"
    echo ""
    echo "Example:"
    echo "  $0 ./input ./output --sample-rate 48000 --min-duration 1.0 --max-duration 10.0"
    exit 1
fi

echo "Audio Dataset Preprocessor (Bash/FFmpeg)"
echo "Input:  $INPUT_DIR"
echo "Output: $OUTPUT_DIR"
echo "Target sample rate: $SAMPLE_RATE Hz"
echo "Duration range: ${MIN_DURATION}s - ${MAX_DURATION}s"
echo "Threads: $NUM_THREADS"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Function to process a single file
process_file() {
    local input_file="$1"
    local output_dir="$2"
    local sample_rate="$3"
    local min_dur="$4"
    local max_dur="$5"
    
    local basename=$(basename "$input_file")
    local name="${basename%.*}"
    local output_file="$output_dir/${name}.wav"
    
    # Get input duration
    local duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null)
    
    if [[ -z "$duration" ]]; then
        echo "Failed to get duration: $input_file" >&2
        return 1
    fi
    
    # Build ffmpeg filter
    local filter="aresample=${sample_rate}:filter_size=64:cutoff=0.97"
    
    # Determine if we need to trim or pad
    local needs_trim=$(echo "$duration > $max_dur" | bc -l)
    local needs_pad=$(echo "$duration < $min_dur" | bc -l)
    
    if [[ "$needs_trim" == "1" ]]; then
        # Trim to max duration
        ffmpeg -y -v error -i "$input_file" \
            -t "$max_dur" \
            -af "$filter" \
            -ar "$sample_rate" \
            -c:a pcm_f32le \
            "$output_file"
    elif [[ "$needs_pad" == "1" ]]; then
        # Pad with silence to min duration
        local pad_duration=$(echo "$min_dur - $duration" | bc -l)
        ffmpeg -y -v error -i "$input_file" \
            -af "${filter},apad=whole_dur=${min_dur}" \
            -ar "$sample_rate" \
            -c:a pcm_f32le \
            "$output_file"
    else
        # Just resample
        ffmpeg -y -v error -i "$input_file" \
            -af "$filter" \
            -ar "$sample_rate" \
            -c:a pcm_f32le \
            "$output_file"
    fi
    
    echo "Processed: $input_file"
}

export -f process_file

# Find all audio files
AUDIO_FILES=$(find "$INPUT_DIR" -type f \( -iname "*.mp3" -o -iname "*.wav" -o -iname "*.flac" -o -iname "*.m4a" -o -iname "*.ogg" -o -iname "*.aac" -o -iname "*.wma" -o -iname "*.opus" \))

FILE_COUNT=$(echo "$AUDIO_FILES" | grep -c . || echo 0)
echo "Found $FILE_COUNT audio files"

if [[ "$FILE_COUNT" -eq 0 ]]; then
    echo "No audio files found in input directory."
    exit 0
fi

echo "Processing with $NUM_THREADS threads..."

# Process files in parallel using xargs
echo "$AUDIO_FILES" | xargs -P "$NUM_THREADS" -I {} bash -c "process_file '{}' '$OUTPUT_DIR' '$SAMPLE_RATE' '$MIN_DURATION' '$MAX_DURATION'"

echo "Processing complete!"
