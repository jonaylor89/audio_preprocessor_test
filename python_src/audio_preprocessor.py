#!/usr/bin/env python3
"""Audio dataset preprocessor for ML training using librosa and numpy."""

import argparse
import os
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

import librosa
import numpy as np
import soundfile as sf

AUDIO_EXTENSIONS = {".mp3", ".wav", ".flac", ".m4a", ".ogg", ".aac", ".wma", ".opus"}


def process_file(
    input_path: Path,
    output_path: Path,
    target_sample_rate: int,
    min_duration: float,
    max_duration: float,
) -> tuple[str, bool, str]:
    """Process a single audio file. Returns (path, success, error_msg)."""
    try:
        # Load and resample in one step (librosa handles resampling)
        audio, sr = librosa.load(str(input_path), sr=target_sample_rate, mono=False)
        
        # Handle mono vs stereo
        if audio.ndim == 1:
            audio = audio.reshape(1, -1)
        
        num_channels, num_samples = audio.shape
        
        # Calculate sample counts
        max_samples = int(max_duration * target_sample_rate)
        min_samples = int(min_duration * target_sample_rate)
        
        # Trim if too long
        if num_samples > max_samples:
            audio = audio[:, :max_samples]
            num_samples = max_samples
        
        # Pad if too short
        if num_samples < min_samples:
            padding = min_samples - num_samples
            audio = np.pad(audio, ((0, 0), (0, padding)), mode='constant', constant_values=0)
        
        # Ensure output directory exists
        output_path.parent.mkdir(parents=True, exist_ok=True)
        
        # Write output (soundfile expects shape: samples x channels)
        sf.write(str(output_path), audio.T, target_sample_rate, subtype='FLOAT')
        
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
    parser = argparse.ArgumentParser(description="Audio dataset preprocessor for ML training")
    parser.add_argument("input_dir", help="Input directory")
    parser.add_argument("output_dir", help="Output directory")
    parser.add_argument("--sample-rate", type=int, default=16000, help="Target sample rate (default: 16000)")
    parser.add_argument("--min-duration", type=float, default=3.0, help="Minimum duration in seconds (default: 3.0)")
    parser.add_argument("--max-duration", type=float, default=5.0, help="Maximum duration in seconds (default: 5.0)")
    parser.add_argument("--threads", type=int, default=0, help="Number of threads (default: auto)")
    
    args = parser.parse_args()
    
    input_dir = Path(args.input_dir)
    output_dir = Path(args.output_dir)
    
    print("Audio Dataset Preprocessor (Python/librosa)")
    print(f"Input:  {input_dir}")
    print(f"Output: {output_dir}")
    print(f"Target sample rate: {args.sample_rate} Hz")
    print(f"Duration range: {args.min_duration:.1f}s - {args.max_duration:.1f}s")
    
    # Collect files
    audio_files = collect_audio_files(input_dir)
    print(f"Found {len(audio_files)} audio files")
    
    if not audio_files:
        print("No audio files found.")
        return
    
    # Build task list
    tasks = []
    for input_path in audio_files:
        rel_path = input_path.relative_to(input_dir)
        output_path = output_dir / rel_path.with_suffix(".wav")
        tasks.append((input_path, output_path))
    
    # Determine thread count
    num_threads = args.threads if args.threads > 0 else os.cpu_count() or 4
    print(f"Processing with {num_threads} workers...")
    
    processed = 0
    failed = 0
    
    with ProcessPoolExecutor(max_workers=num_threads) as executor:
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
