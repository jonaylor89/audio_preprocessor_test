"""Build script for FFmpeg cffi bindings."""

from cffi import FFI

ffibuilder = FFI()

# Declare the C functions we'll use
ffibuilder.cdef("""
    int process_audio_file(
        const char *input_path,
        const char *output_path,
        int target_sample_rate,
        float min_duration_sec,
        float max_duration_sec
    );
""")

# The C source code that wraps FFmpeg
ffibuilder.set_source(
    "_ffmpeg_processor",
    """
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/opt.h>
#include <libavutil/channel_layout.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>

int process_audio_file(
    const char *input_path,
    const char *output_path,
    int target_sample_rate,
    float min_duration_sec,
    float max_duration_sec
) {
    AVFormatContext *in_fmt_ctx = NULL;
    AVFormatContext *out_fmt_ctx = NULL;
    AVCodecContext *dec_ctx = NULL;
    AVCodecContext *enc_ctx = NULL;
    SwrContext *swr_ctx = NULL;
    AVFrame *dec_frame = NULL;
    AVFrame *enc_frame = NULL;
    AVPacket *pkt = NULL;
    AVPacket *out_pkt = NULL;
    const AVCodec *decoder = NULL;
    const AVCodec *encoder = NULL;
    AVStream *out_stream = NULL;
    int ret = 0;
    int stream_index = -1;

    // Open input
    ret = avformat_open_input(&in_fmt_ctx, input_path, NULL, NULL);
    if (ret < 0) return -1;

    ret = avformat_find_stream_info(in_fmt_ctx, NULL);
    if (ret < 0) goto cleanup;

    // Find audio stream
    stream_index = av_find_best_stream(in_fmt_ctx, AVMEDIA_TYPE_AUDIO, -1, -1, &decoder, 0);
    if (stream_index < 0) { ret = -1; goto cleanup; }

    // Set up decoder
    dec_ctx = avcodec_alloc_context3(decoder);
    if (!dec_ctx) { ret = -1; goto cleanup; }

    ret = avcodec_parameters_to_context(dec_ctx, in_fmt_ctx->streams[stream_index]->codecpar);
    if (ret < 0) goto cleanup;

    ret = avcodec_open2(dec_ctx, decoder, NULL);
    if (ret < 0) goto cleanup;

    int in_sample_rate = dec_ctx->sample_rate;
    AVChannelLayout in_ch_layout = dec_ctx->ch_layout;
    int channels = in_ch_layout.nb_channels > 0 ? in_ch_layout.nb_channels : 2;
    enum AVSampleFormat in_sample_fmt = dec_ctx->sample_fmt;

    // Set up output
    ret = avformat_alloc_output_context2(&out_fmt_ctx, NULL, "wav", output_path);
    if (ret < 0 || !out_fmt_ctx) goto cleanup;

    encoder = avcodec_find_encoder(AV_CODEC_ID_PCM_F32LE);
    if (!encoder) { ret = -1; goto cleanup; }

    out_stream = avformat_new_stream(out_fmt_ctx, encoder);
    if (!out_stream) { ret = -1; goto cleanup; }

    enc_ctx = avcodec_alloc_context3(encoder);
    if (!enc_ctx) { ret = -1; goto cleanup; }

    enc_ctx->sample_fmt = AV_SAMPLE_FMT_FLT;
    enc_ctx->sample_rate = target_sample_rate;
    av_channel_layout_default(&enc_ctx->ch_layout, channels);
    enc_ctx->bit_rate = target_sample_rate * channels * 32;
    enc_ctx->time_base = (AVRational){1, target_sample_rate};

    if (out_fmt_ctx->oformat->flags & AVFMT_GLOBALHEADER)
        enc_ctx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;

    ret = avcodec_open2(enc_ctx, encoder, NULL);
    if (ret < 0) goto cleanup;

    ret = avcodec_parameters_from_context(out_stream->codecpar, enc_ctx);
    if (ret < 0) goto cleanup;

    out_stream->time_base = (AVRational){1, target_sample_rate};

    if (!(out_fmt_ctx->oformat->flags & AVFMT_NOFILE)) {
        ret = avio_open(&out_fmt_ctx->pb, output_path, AVIO_FLAG_WRITE);
        if (ret < 0) goto cleanup;
    }

    ret = avformat_write_header(out_fmt_ctx, NULL);
    if (ret < 0) goto cleanup;

    // Set up resampler
    AVChannelLayout dst_ch_layout;
    av_channel_layout_default(&dst_ch_layout, channels);

    ret = swr_alloc_set_opts2(&swr_ctx,
        &dst_ch_layout, AV_SAMPLE_FMT_FLT, target_sample_rate,
        &in_ch_layout, in_sample_fmt, in_sample_rate,
        0, NULL);
    if (ret < 0 || !swr_ctx) goto cleanup;

    av_opt_set_int(swr_ctx, "filter_size", 64, 0);
    av_opt_set_double(swr_ctx, "cutoff", 0.97, 0);

    ret = swr_init(swr_ctx);
    if (ret < 0) goto cleanup;

    // Allocate frames and packets
    dec_frame = av_frame_alloc();
    enc_frame = av_frame_alloc();
    pkt = av_packet_alloc();
    out_pkt = av_packet_alloc();
    if (!dec_frame || !enc_frame || !pkt || !out_pkt) { ret = -1; goto cleanup; }

    size_t max_samples = (size_t)(max_duration_sec * target_sample_rate);
    size_t min_samples = (size_t)(min_duration_sec * target_sample_rate);
    size_t total_output_samples = 0;
    int64_t pts = 0;

    // Resample buffer
    float *resample_buf = (float *)malloc(8192 * channels * sizeof(float));
    if (!resample_buf) { ret = -1; goto cleanup; }

    // Read and process
    while (av_read_frame(in_fmt_ctx, pkt) >= 0) {
        if (pkt->stream_index != stream_index) {
            av_packet_unref(pkt);
            continue;
        }

        ret = avcodec_send_packet(dec_ctx, pkt);
        av_packet_unref(pkt);
        if (ret < 0) continue;

        while (avcodec_receive_frame(dec_ctx, dec_frame) >= 0) {
            if (total_output_samples >= max_samples) {
                av_frame_unref(dec_frame);
                break;
            }

            uint8_t *out_ptr = (uint8_t *)resample_buf;
            const uint8_t **in_ptr = (const uint8_t **)dec_frame->extended_data;
            int max_out = 8192;

            int converted = swr_convert(swr_ctx, &out_ptr, max_out, in_ptr, dec_frame->nb_samples);
            av_frame_unref(dec_frame);
            if (converted <= 0) continue;

            size_t samples_to_write = (size_t)converted;
            size_t remaining = max_samples - total_output_samples;
            if (samples_to_write > remaining) samples_to_write = remaining;

            // Write in chunks
            size_t offset = 0;
            while (offset < samples_to_write) {
                size_t chunk = 1024;
                if (chunk > samples_to_write - offset) chunk = samples_to_write - offset;

                av_frame_unref(enc_frame);
                enc_frame->format = AV_SAMPLE_FMT_FLT;
                enc_frame->sample_rate = target_sample_rate;
                av_channel_layout_default(&enc_frame->ch_layout, channels);
                enc_frame->nb_samples = (int)chunk;

                ret = av_frame_get_buffer(enc_frame, 0);
                if (ret < 0) break;

                memcpy(enc_frame->extended_data[0],
                       resample_buf + offset * channels,
                       chunk * channels * sizeof(float));

                enc_frame->pts = pts;
                pts += chunk;

                ret = avcodec_send_frame(enc_ctx, enc_frame);
                if (ret < 0) continue;

                while (avcodec_receive_packet(enc_ctx, out_pkt) >= 0) {
                    av_packet_rescale_ts(out_pkt, enc_ctx->time_base, out_stream->time_base);
                    out_pkt->stream_index = out_stream->index;
                    av_interleaved_write_frame(out_fmt_ctx, out_pkt);
                    av_packet_unref(out_pkt);
                }

                offset += chunk;
            }

            total_output_samples += samples_to_write;
            if (total_output_samples >= max_samples) break;
        }

        if (total_output_samples >= max_samples) break;
    }

    // Flush resampler
    while (total_output_samples < max_samples) {
        uint8_t *out_ptr = (uint8_t *)resample_buf;
        int flushed = swr_convert(swr_ctx, &out_ptr, 8192, NULL, 0);
        if (flushed <= 0) break;

        size_t samples_to_write = (size_t)flushed;
        size_t remaining = max_samples - total_output_samples;
        if (samples_to_write > remaining) samples_to_write = remaining;

        size_t offset = 0;
        while (offset < samples_to_write) {
            size_t chunk = 1024;
            if (chunk > samples_to_write - offset) chunk = samples_to_write - offset;

            av_frame_unref(enc_frame);
            enc_frame->format = AV_SAMPLE_FMT_FLT;
            enc_frame->sample_rate = target_sample_rate;
            av_channel_layout_default(&enc_frame->ch_layout, channels);
            enc_frame->nb_samples = (int)chunk;

            av_frame_get_buffer(enc_frame, 0);
            memcpy(enc_frame->extended_data[0],
                   resample_buf + offset * channels,
                   chunk * channels * sizeof(float));

            enc_frame->pts = pts;
            pts += chunk;

            avcodec_send_frame(enc_ctx, enc_frame);
            while (avcodec_receive_packet(enc_ctx, out_pkt) >= 0) {
                av_packet_rescale_ts(out_pkt, enc_ctx->time_base, out_stream->time_base);
                out_pkt->stream_index = out_stream->index;
                av_interleaved_write_frame(out_fmt_ctx, out_pkt);
                av_packet_unref(out_pkt);
            }

            offset += chunk;
        }

        total_output_samples += samples_to_write;
    }

    // Pad with silence if needed
    if (total_output_samples < min_samples) {
        memset(resample_buf, 0, 1024 * channels * sizeof(float));
        size_t silence_remaining = min_samples - total_output_samples;

        while (silence_remaining > 0) {
            size_t chunk = 1024;
            if (chunk > silence_remaining) chunk = silence_remaining;

            av_frame_unref(enc_frame);
            enc_frame->format = AV_SAMPLE_FMT_FLT;
            enc_frame->sample_rate = target_sample_rate;
            av_channel_layout_default(&enc_frame->ch_layout, channels);
            enc_frame->nb_samples = (int)chunk;

            av_frame_get_buffer(enc_frame, 0);
            memset(enc_frame->extended_data[0], 0, chunk * channels * sizeof(float));

            enc_frame->pts = pts;
            pts += chunk;

            avcodec_send_frame(enc_ctx, enc_frame);
            while (avcodec_receive_packet(enc_ctx, out_pkt) >= 0) {
                av_packet_rescale_ts(out_pkt, enc_ctx->time_base, out_stream->time_base);
                out_pkt->stream_index = out_stream->index;
                av_interleaved_write_frame(out_fmt_ctx, out_pkt);
                av_packet_unref(out_pkt);
            }

            silence_remaining -= chunk;
        }
    }

    // Flush encoder
    avcodec_send_frame(enc_ctx, NULL);
    while (avcodec_receive_packet(enc_ctx, out_pkt) >= 0) {
        av_packet_rescale_ts(out_pkt, enc_ctx->time_base, out_stream->time_base);
        out_pkt->stream_index = out_stream->index;
        av_interleaved_write_frame(out_fmt_ctx, out_pkt);
        av_packet_unref(out_pkt);
    }

    av_write_trailer(out_fmt_ctx);
    free(resample_buf);
    ret = 0;

cleanup:
    av_frame_free(&dec_frame);
    av_frame_free(&enc_frame);
    av_packet_free(&pkt);
    av_packet_free(&out_pkt);
    swr_free(&swr_ctx);
    avcodec_free_context(&dec_ctx);
    avcodec_free_context(&enc_ctx);
    if (out_fmt_ctx && !(out_fmt_ctx->oformat->flags & AVFMT_NOFILE))
        avio_closep(&out_fmt_ctx->pb);
    avformat_free_context(out_fmt_ctx);
    avformat_close_input(&in_fmt_ctx);

    return ret;
}
    """,
    libraries=["avcodec", "avformat", "avutil", "swresample"],
)

if __name__ == "__main__":
    ffibuilder.compile(verbose=True)
