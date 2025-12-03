# Audio Dataset Preprocessor

Batch audio preprocessing for ML training data. Resamples, trims/pads to uniform duration, outputs WAV.

Same tool implemented in 5 ways to compare performance and ergonomics.

## Benchmark

320 WAV files, resample to 16kHz, max 10s duration, 8 threads, Apple M1:

| Implementation | Time | Speedup |
|----------------|------|---------|
| Python (librosa) | 14.19s | 1x |
| Bash (ffmpeg CLI) | 8.45s | 1.7x |
| Zig (FFmpeg bindings) | 1.29s | 11x |
| Rust (FFmpeg bindings) | 0.93s | 15x |
| C (FFmpeg bindings) | 0.85s | 17x |

## Usage

```sh
# Zig
zig build run -- ./input ./output --sample-rate 16000 --min-duration 1.0 --max-duration 10.0

# Rust
cd rust_src && cargo build --release
./target/release/audio_preprocessor ./input ./output --min-duration 1.0 --max-duration 10.0

# C
cd c_src && make
./audio_preprocessor ./input ./output --min-duration 1.0 --max-duration 10.0

# Python
cd python_src && uv run python audio_preprocessor.py ./input ./output --min-duration 1.0 --max-duration 10.0

# Bash
./shell_test.sh ./input ./output --min-duration 1.0 --max-duration 10.0
```

## Test Data

[MusicNet Dataset on Kaggle](https://www.kaggle.com/datasets/imsparsh/musicnet-dataset)
