use std::env;
use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");

    // Use pkg-config to find FFmpeg libraries
    let avcodec = pkg_config::probe_library("libavcodec").expect("libavcodec not found");
    let avformat = pkg_config::probe_library("libavformat").expect("libavformat not found");
    let avutil = pkg_config::probe_library("libavutil").expect("libavutil not found");
    let swresample = pkg_config::probe_library("libswresample").expect("libswresample not found");

    // Collect include paths for bindgen
    let mut clang_args: Vec<String> = Vec::new();
    for path in avcodec
        .include_paths
        .iter()
        .chain(avformat.include_paths.iter())
        .chain(avutil.include_paths.iter())
        .chain(swresample.include_paths.iter())
    {
        clang_args.push(format!("-I{}", path.display()));
    }

    // Generate bindings
    let mut builder = bindgen::Builder::default()
        .header("wrapper.h")
        .allowlist_function("avformat_.*")
        .allowlist_function("avcodec_.*")
        .allowlist_function("av_.*")
        .allowlist_function("swr_.*")
        .allowlist_function("avio_.*")
        .allowlist_type("AVFormatContext")
        .allowlist_type("AVCodecContext")
        .allowlist_type("AVCodec")
        .allowlist_type("AVStream")
        .allowlist_type("AVFrame")
        .allowlist_type("AVPacket")
        .allowlist_type("AVCodecParameters")
        .allowlist_type("SwrContext")
        .allowlist_type("AVIOContext")
        .allowlist_type("AVOutputFormat")
        .allowlist_type("AVChannelLayout")
        .allowlist_type("AVRational")
        .allowlist_type("AVMediaType")
        .allowlist_type("AVSampleFormat")
        .allowlist_type("AVCodecID")
        .allowlist_type("AVRounding")
        .allowlist_var("AVMEDIA_TYPE_.*")
        .allowlist_var("AV_SAMPLE_FMT_.*")
        .allowlist_var("AV_CODEC_ID_.*")
        .allowlist_var("AV_CODEC_FLAG_.*")
        .allowlist_var("AVFMT_.*")
        .allowlist_var("AVIO_FLAG_.*")
        .allowlist_var("AV_ROUND_.*")
        .allowlist_var("AVERROR.*")
        .allowlist_var("EAGAIN")
        .derive_default(true);

    for arg in &clang_args {
        builder = builder.clang_arg(arg);
    }

    let bindings = builder.generate().expect("Unable to generate bindings");

    let out_path = PathBuf::from(env::var("OUT_DIR").unwrap());
    bindings
        .write_to_file(out_path.join("bindings.rs"))
        .expect("Couldn't write bindings!");
}
