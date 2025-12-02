use std::env;
use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");

    // Link FFmpeg libraries
    println!("cargo:rustc-link-search=/opt/homebrew/lib");
    println!("cargo:rustc-link-lib=avcodec");
    println!("cargo:rustc-link-lib=avformat");
    println!("cargo:rustc-link-lib=avutil");
    println!("cargo:rustc-link-lib=swresample");

    // Generate bindings
    let bindings = bindgen::Builder::default()
        .header("wrapper.h")
        .clang_arg("-I/opt/homebrew/include")
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
        .derive_default(true)
        .generate()
        .expect("Unable to generate bindings");

    let out_path = PathBuf::from(env::var("OUT_DIR").unwrap());
    bindings
        .write_to_file(out_path.join("bindings.rs"))
        .expect("Couldn't write bindings!");
}
