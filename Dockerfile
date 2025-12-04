# Build stage for Zig
FROM debian:bookworm AS zig-builder

RUN apt-get update && apt-get install -y \
    libavcodec-dev \
    libavformat-dev \
    libavutil-dev \
    libswresample-dev \
    wget \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN wget -q https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz \
    && tar -xf zig-linux-x86_64-0.13.0.tar.xz \
    && mv zig-linux-x86_64-0.13.0 /opt/zig \
    && rm zig-linux-x86_64-0.13.0.tar.xz

ENV PATH="/opt/zig:${PATH}"

WORKDIR /app
COPY build.zig ./
COPY src/ ./src/
RUN zig build -Doptimize=ReleaseFast

# Build stage for Python cffi extension
FROM debian:bookworm AS python-builder

RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    python3-dev \
    libavcodec-dev \
    libavformat-dev \
    libavutil-dev \
    libswresample-dev \
    pkg-config \
    gcc \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY python_src/ ./python_src/

# Build the cffi extension
RUN pip3 install --break-system-packages cffi \
    && cd python_src/ffmpeg_bindings \
    && python3 build_ffmpeg.py

# Runtime stage
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    libavcodec59 \
    libavformat59 \
    libavutil57 \
    libswresample4 \
    ffmpeg \
    bc \
    python3 \
    python3-cffi \
    && rm -rf /var/lib/apt/lists/*

# Copy Zig binary
COPY --from=zig-builder /app/zig-out/bin/audio_preprocessor /usr/local/bin/audio_preprocessor_zig

# Copy Bash scripts
COPY shell_test.sh /usr/local/bin/audio_preprocessor_bash
COPY shell_zig_per_file.sh /usr/local/bin/audio_preprocessor_zig_perfile
COPY benchmark.sh /usr/local/bin/benchmark
RUN chmod +x /usr/local/bin/audio_preprocessor_bash /usr/local/bin/audio_preprocessor_zig_perfile /usr/local/bin/benchmark

# Copy Python source and compiled cffi extension
COPY python_src/ /opt/python_src/
COPY --from=python-builder /app/python_src/ffmpeg_bindings/*.so /opt/python_src/ffmpeg_bindings/

# Create wrapper scripts
RUN echo '#!/bin/bash\nPYTHONPATH=/opt/python_src/ffmpeg_bindings python3 /opt/python_src/audio_preprocessor_cffi.py "$@"' > /usr/local/bin/audio_preprocessor_cffi \
    && chmod +x /usr/local/bin/audio_preprocessor_cffi \
    && echo '#!/bin/bash\npython3 /opt/python_src/audio_preprocessor_subprocess.py "$@"' > /usr/local/bin/audio_preprocessor_python \
    && chmod +x /usr/local/bin/audio_preprocessor_python

# Create mount points
RUN mkdir -p /input /output

CMD ["bash"]
