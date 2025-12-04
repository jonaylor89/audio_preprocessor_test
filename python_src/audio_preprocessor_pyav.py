#!/usr/bin/env python3
"""Audio dataset preprocessor using PyAV (FFmpeg libraries, no subprocess).

Optimized version: streams frames directly without numpy round-trips.
"""

import argparse
import os
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import av

AUDIO_EXTENSIONS = {".mp3", ".wav", ".flac", ".m4a", ".ogg", ".aac", ".wma", ".opus"}


def process_file(
    input_path: Path,
    output_path: Path,
    target_sample_rate: int,
    min_duration: float,
    max_duration: float,
) -> tuple[str, bool, str]:
    """Process a single audio file using PyAV with direct frame streaming."""
    try:
        # Open input
        input_container = av.open(str(input_path))
        input_stream = input_container.streams.audio[0]

        # Calculate sample limits
        max_samples = int(max_duration * target_sample_rate)
        min_samples = int(min_duration * target_sample_rate)

        # Ensure output directory exists
        output_path.parent.mkdir(parents=True, exist_ok=True)

        # Open output
        output_container = av.open(str(output_path), mode='w')
        output_stream = output_container.add_stream('pcm_f32le', rate=target_sample_rate)
        output_stream.layout = 'stereo'

        # Set up resampler
        resampler = av.AudioResampler(
            format='flt',
            layout='stereo',
            rate=target_sample_rate,
        )

        total_samples = 0

        # Stream and transcode directly
        for frame in input_container.decode(audio=0):
            if total_samples >= max_samples:
                break

            # Resample frame
            resampled_frames = resampler.resample(frame)

            for resampled in resampled_frames:
                if total_samples >= max_samples:
                    break

                frame_samples = resampled.samples
                remaining = max_samples - total_samples

                # Trim frame if needed
                if frame_samples > remaining:
                    # Create a trimmed frame by slicing the planes
                    import numpy as np
                    arr = resampled.to_ndarray()[:, :remaining]
                    resampled = av.AudioFrame.from_ndarray(arr, format='flt', layout='stereo')
                    resampled.rate = target_sample_rate
                    frame_samples = remaining

                # Encode and write
                for packet in output_stream.encode(resampled):
                    output_container.mux(packet)

                total_samples += frame_samples

        # Pad with silence if too short
        if total_samples < min_samples:
            import numpy as np
            silence_samples = min_samples - total_samples
            # Create silence frame(s)
            chunk_size = 1024
            while silence_samples > 0:
                chunk = min(chunk_size, silence_samples)
                silence = np.zeros((2, chunk), dtype=np.float32)
                silence_frame = av.AudioFrame.from_ndarray(silence, format='flt', layout='stereo')
                silence_frame.rate = target_sample_rate

                for packet in output_stream.encode(silence_frame):
                    output_container.mux(packet)

                silence_samples -= chunk

        # Flush encoder
        for packet in output_stream.encode():
            output_container.mux(packet)

        output_container.close()
        input_container.close()

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
    parser = argparse.ArgumentParser(description="Audio dataset preprocessor using PyAV")
    parser.add_argument("input_dir", help="Input directory")
    parser.add_argument("output_dir", help="Output directory")
    parser.add_argument("--sample-rate", type=int, default=16000, help="Target sample rate (default: 16000)")
    parser.add_argument("--min-duration", type=float, default=3.0, help="Minimum duration in seconds (default: 3.0)")
    parser.add_argument("--max-duration", type=float, default=5.0, help="Maximum duration in seconds (default: 5.0)")
    parser.add_argument("--threads", type=int, default=0, help="Number of threads (default: auto)")

    args = parser.parse_args()

    input_dir = Path(args.input_dir)
    output_dir = Path(args.output_dir)

    print("Audio Dataset Preprocessor (Python/PyAV)")
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
    print(f"Processing with {num_threads} threads...")

    processed = 0
    failed = 0

    # Use ThreadPoolExecutor since PyAV releases the GIL
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
