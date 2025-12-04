#!/usr/bin/env python3
"""Audio dataset preprocessor using ffmpeg subprocess (fast, simple)."""

import argparse
import os
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

AUDIO_EXTENSIONS = {".mp3", ".wav", ".flac", ".m4a", ".ogg", ".aac", ".wma", ".opus"}


def get_duration(input_path: Path) -> float:
    """Get audio duration using ffprobe."""
    result = subprocess.run(
        [
            "ffprobe", "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            str(input_path)
        ],
        capture_output=True,
        text=True,
    )
    try:
        return float(result.stdout.strip())
    except ValueError:
        return 0.0


def process_file(
    input_path: Path,
    output_path: Path,
    target_sample_rate: int,
    min_duration: float,
    max_duration: float,
) -> tuple[str, bool, str]:
    """Process a single audio file using ffmpeg subprocess."""
    try:
        output_path.parent.mkdir(parents=True, exist_ok=True)

        duration = get_duration(input_path)

        # Build ffmpeg command
        cmd = ["ffmpeg", "-y", "-v", "error", "-i", str(input_path)]

        # Trim if too long
        if duration > max_duration:
            cmd.extend(["-t", str(max_duration)])

        # Build filter
        audio_filter = f"aresample={target_sample_rate}:filter_size=64:cutoff=0.97"

        # Pad if too short
        if duration < min_duration:
            audio_filter += f",apad=whole_dur={min_duration}"

        cmd.extend([
            "-af", audio_filter,
            "-ar", str(target_sample_rate),
            "-c:a", "pcm_f32le",
            str(output_path)
        ])

        result = subprocess.run(cmd, capture_output=True, text=True)

        if result.returncode != 0:
            return str(input_path), False, result.stderr

        return str(input_path), True, ""
    except Exception as e:
        return str(input_path), False, str(e)


def collect_audio_files(input_dir: Path) -> list[Path]:
    """Recursively collect all audio files from input directory."""
    files = []
    for path in input_dir.rglob("*"):
        if path.is_file() and path.suffix.lower() in AUDIO_EXTENSIONS:
            files.append(path)
    return files


def main():
    parser = argparse.ArgumentParser(description="Audio dataset preprocessor using ffmpeg")
    parser.add_argument("input_dir", help="Input directory")
    parser.add_argument("output_dir", help="Output directory")
    parser.add_argument("--sample-rate", type=int, default=16000, help="Target sample rate (default: 16000)")
    parser.add_argument("--min-duration", type=float, default=3.0, help="Minimum duration in seconds (default: 3.0)")
    parser.add_argument("--max-duration", type=float, default=5.0, help="Maximum duration in seconds (default: 5.0)")
    parser.add_argument("--threads", type=int, default=0, help="Number of threads (default: auto)")

    args = parser.parse_args()

    input_dir = Path(args.input_dir)
    output_dir = Path(args.output_dir)

    print("Audio Dataset Preprocessor (Python/subprocess)")
    print(f"Input:  {input_dir}")
    print(f"Output: {output_dir}")
    print(f"Target sample rate: {args.sample_rate} Hz")
    print(f"Duration range: {args.min_duration:.1f}s - {args.max_duration:.1f}s")

    audio_files = collect_audio_files(input_dir)
    print(f"Found {len(audio_files)} audio files")

    if not audio_files:
        print("No audio files found.")
        return

    tasks = []
    for input_path in audio_files:
        rel_path = input_path.relative_to(input_dir)
        output_path = output_dir / rel_path.with_suffix(".wav")
        tasks.append((input_path, output_path))

    num_threads = args.threads if args.threads > 0 else os.cpu_count() or 4
    print(f"Processing with {num_threads} threads...")

    processed = 0
    failed = 0

    with ThreadPoolExecutor(max_workers=num_threads) as executor:
        futures = {
            executor.submit(
                process_file,
                input_path,
                output_path,
                args.sample_rate,
                args.min_duration,
                args.max_duration,
            ): input_path
            for input_path, output_path in tasks
        }

        for future in as_completed(futures):
            path, success, error = future.result()
            if success:
                processed += 1
                print(f"Processed: {path}")
            else:
                failed += 1
                print(f"Failed: {path} - {error}")

    print(f"Processing complete! {processed} succeeded, {failed} failed")


if __name__ == "__main__":
    main()
