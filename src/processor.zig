const std = @import("std");
const ffmpeg = @import("ffmpeg.zig");
const c = ffmpeg.c;

pub const ProcessorConfig = struct {
    target_sample_rate: u32 = 16000,
    min_duration_sec: f32 = 3.0,
    max_duration_sec: f32 = 5.0,
};

pub fn processFile(input_path: [:0]const u8, output_path: [:0]const u8, config: ProcessorConfig) !void {
    // === DECODER SETUP ===
    var format_ctx: ?*c.AVFormatContext = null;
    var ret = c.avformat_open_input(&format_ctx, input_path.ptr, null, null);
    if (ret < 0) return error.OpenInputFailed;
    defer c.avformat_close_input(&format_ctx);

    ret = c.avformat_find_stream_info(format_ctx, null);
    if (ret < 0) return error.FindStreamInfoFailed;

    const stream_index = c.av_find_best_stream(format_ctx, c.AVMEDIA_TYPE_AUDIO, -1, -1, null, 0);
    if (stream_index < 0) return error.NoAudioStream;

    const in_stream = format_ctx.?.streams[@intCast(stream_index)];
    const codecpar = in_stream.*.codecpar;

    const decoder = c.avcodec_find_decoder(codecpar.*.codec_id);
    if (decoder == null) return error.NoDecoder;

    var dec_ctx = c.avcodec_alloc_context3(decoder);
    if (dec_ctx == null) return error.AllocFailed;
    defer c.avcodec_free_context(&dec_ctx);

    ret = c.avcodec_parameters_to_context(dec_ctx, codecpar);
    if (ret < 0) return error.CopyParamsFailed;

    ret = c.avcodec_open2(dec_ctx, decoder, null);
    if (ret < 0) return error.OpenCodecFailed;

    const in_sample_rate: u32 = @intCast(dec_ctx.*.sample_rate);
    const in_channels: u32 = @intCast(dec_ctx.*.ch_layout.nb_channels);
    const channels: u32 = if (in_channels == 0) 2 else in_channels;

    // === ENCODER SETUP ===
    var out_format_ctx: ?*c.AVFormatContext = null;
    ret = c.avformat_alloc_output_context2(&out_format_ctx, null, "wav", output_path.ptr);
    if (ret < 0 or out_format_ctx == null) return error.AllocOutputFailed;
    defer c.avformat_free_context(out_format_ctx);

    const enc_codec = c.avcodec_find_encoder(c.AV_CODEC_ID_PCM_F32LE);
    if (enc_codec == null) return error.NoEncoder;

    const out_stream = c.avformat_new_stream(out_format_ctx, enc_codec);
    if (out_stream == null) return error.NewStreamFailed;

    var enc_ctx = c.avcodec_alloc_context3(enc_codec);
    if (enc_ctx == null) return error.AllocFailed;
    defer c.avcodec_free_context(&enc_ctx);

    enc_ctx.*.sample_fmt = c.AV_SAMPLE_FMT_FLT;
    enc_ctx.*.sample_rate = @intCast(config.target_sample_rate);
    c.av_channel_layout_default(&enc_ctx.*.ch_layout, @intCast(channels));
    enc_ctx.*.bit_rate = @intCast(config.target_sample_rate * channels * 32);

    if ((out_format_ctx.?.oformat.*.flags & c.AVFMT_GLOBALHEADER) != 0) {
        enc_ctx.*.flags |= c.AV_CODEC_FLAG_GLOBAL_HEADER;
    }

    ret = c.avcodec_open2(enc_ctx, enc_codec, null);
    if (ret < 0) return error.OpenCodecFailed;

    ret = c.avcodec_parameters_from_context(out_stream.*.codecpar, enc_ctx);
    if (ret < 0) return error.CopyParamsFailed;

    out_stream.*.time_base = c.AVRational{ .num = 1, .den = @intCast(config.target_sample_rate) };

    if ((out_format_ctx.?.oformat.*.flags & c.AVFMT_NOFILE) == 0) {
        ret = c.avio_open(&out_format_ctx.?.pb, output_path.ptr, c.AVIO_FLAG_WRITE);
        if (ret < 0) return error.OpenOutputFailed;
    }

    ret = c.avformat_write_header(out_format_ctx, null);
    if (ret < 0) return error.WriteHeaderFailed;

    // === RESAMPLER SETUP ===
    var swr_ctx: ?*c.SwrContext = null;
    var dst_ch_layout: c.AVChannelLayout = .{};
    c.av_channel_layout_default(&dst_ch_layout, @intCast(channels));

    ret = c.swr_alloc_set_opts2(
        &swr_ctx,
        &dst_ch_layout,
        c.AV_SAMPLE_FMT_FLT,
        @intCast(config.target_sample_rate),
        &dec_ctx.*.ch_layout,
        dec_ctx.*.sample_fmt,
        dec_ctx.*.sample_rate,
        0,
        null,
    );
    if (ret < 0 or swr_ctx == null) return error.SwrAllocFailed;
    defer c.swr_free(&swr_ctx);

    _ = c.av_opt_set_int(swr_ctx, "filter_size", 64, 0);
    _ = c.av_opt_set_double(swr_ctx, "cutoff", 0.97, 0);

    ret = c.swr_init(swr_ctx);
    if (ret < 0) return error.SwrInitFailed;

    // === PROCESSING ===
    var dec_frame = c.av_frame_alloc();
    var enc_frame = c.av_frame_alloc();
    var pkt = c.av_packet_alloc();
    var out_pkt = c.av_packet_alloc();
    if (dec_frame == null or enc_frame == null or pkt == null or out_pkt == null) return error.AllocFailed;
    defer c.av_frame_free(&dec_frame);
    defer c.av_frame_free(&enc_frame);
    defer c.av_packet_free(&pkt);
    defer c.av_packet_free(&out_pkt);

    const max_samples: usize = @intFromFloat(config.max_duration_sec * @as(f32, @floatFromInt(config.target_sample_rate)));
    const min_samples: usize = @intFromFloat(config.min_duration_sec * @as(f32, @floatFromInt(config.target_sample_rate)));

    var total_output_samples: usize = 0;
    var pts: i64 = 0;

    const frame_size: usize = 1024;
    var resample_buf: [8192]f32 = undefined;

    while (c.av_read_frame(format_ctx, pkt) >= 0) {
        defer c.av_packet_unref(pkt);
        if (pkt.*.stream_index != stream_index) continue;

        ret = c.avcodec_send_packet(dec_ctx, pkt);
        if (ret < 0) continue;

        while (c.avcodec_receive_frame(dec_ctx, dec_frame) >= 0) {
            defer c.av_frame_unref(dec_frame);

            if (total_output_samples >= max_samples) break;

            const out_samples_est = c.av_rescale_rnd(
                dec_frame.*.nb_samples,
                @intCast(config.target_sample_rate),
                @intCast(in_sample_rate),
                c.AV_ROUND_UP,
            );

            var out_ptr: [*]u8 = @ptrCast(&resample_buf);
            const in_ptr: [*c]const [*c]const u8 = @ptrCast(&dec_frame.*.extended_data[0]);

            const converted = c.swr_convert(
                swr_ctx,
                @ptrCast(&out_ptr),
                @intCast(@min(out_samples_est, resample_buf.len / channels)),
                in_ptr,
                dec_frame.*.nb_samples,
            );

            if (converted <= 0) continue;

            var samples_to_write: usize = @intCast(converted);
            const remaining = max_samples - total_output_samples;
            if (samples_to_write > remaining) samples_to_write = remaining;

            var offset: usize = 0;
            while (offset < samples_to_write) {
                const chunk = @min(frame_size, samples_to_write - offset);

                c.av_frame_unref(enc_frame);
                enc_frame.*.format = c.AV_SAMPLE_FMT_FLT;
                enc_frame.*.sample_rate = @intCast(config.target_sample_rate);
                c.av_channel_layout_default(&enc_frame.*.ch_layout, @intCast(channels));
                enc_frame.*.nb_samples = @intCast(chunk);

                ret = c.av_frame_get_buffer(enc_frame, 0);
                if (ret < 0) return error.GetBufferFailed;

                const src_bytes = std.mem.sliceAsBytes(resample_buf[offset * channels .. (offset + chunk) * channels]);
                const dst: [*]u8 = @ptrCast(enc_frame.*.extended_data[0]);
                @memcpy(dst[0..src_bytes.len], src_bytes);

                enc_frame.*.pts = pts;
                pts += @intCast(chunk);

                ret = c.avcodec_send_frame(enc_ctx, enc_frame);
                if (ret < 0) continue;

                while (c.avcodec_receive_packet(enc_ctx, out_pkt) >= 0) {
                    c.av_packet_rescale_ts(out_pkt, enc_ctx.*.time_base, out_stream.*.time_base);
                    out_pkt.*.stream_index = out_stream.*.index;
                    _ = c.av_interleaved_write_frame(out_format_ctx, out_pkt);
                    c.av_packet_unref(out_pkt);
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
        var out_ptr: [*]u8 = @ptrCast(&resample_buf);
        const flushed = c.swr_convert(swr_ctx, @ptrCast(&out_ptr), @intCast(resample_buf.len / channels), null, 0);
        if (flushed <= 0) break;

        var samples_to_write: usize = @intCast(flushed);
        const remaining = max_samples - total_output_samples;
        if (samples_to_write > remaining) samples_to_write = remaining;

        var offset: usize = 0;
        while (offset < samples_to_write) {
            const chunk = @min(frame_size, samples_to_write - offset);

            c.av_frame_unref(enc_frame);
            enc_frame.*.format = c.AV_SAMPLE_FMT_FLT;
            enc_frame.*.sample_rate = @intCast(config.target_sample_rate);
            c.av_channel_layout_default(&enc_frame.*.ch_layout, @intCast(channels));
            enc_frame.*.nb_samples = @intCast(chunk);

            ret = c.av_frame_get_buffer(enc_frame, 0);
            if (ret < 0) break;

            const src_bytes = std.mem.sliceAsBytes(resample_buf[offset * channels .. (offset + chunk) * channels]);
            const dst: [*]u8 = @ptrCast(enc_frame.*.extended_data[0]);
            @memcpy(dst[0..src_bytes.len], src_bytes);

            enc_frame.*.pts = pts;
            pts += @intCast(chunk);

            ret = c.avcodec_send_frame(enc_ctx, enc_frame);
            if (ret < 0) break;

            while (c.avcodec_receive_packet(enc_ctx, out_pkt) >= 0) {
                c.av_packet_rescale_ts(out_pkt, enc_ctx.*.time_base, out_stream.*.time_base);
                out_pkt.*.stream_index = out_stream.*.index;
                _ = c.av_interleaved_write_frame(out_format_ctx, out_pkt);
                c.av_packet_unref(out_pkt);
            }

            offset += chunk;
        }

        total_output_samples += samples_to_write;
    }

    // Pad with silence if needed
    if (total_output_samples < min_samples) {
        const silence_samples = min_samples - total_output_samples;
        @memset(&resample_buf, 0.0);

        var remaining = silence_samples;
        while (remaining > 0) {
            const chunk = @min(frame_size, remaining);

            c.av_frame_unref(enc_frame);
            enc_frame.*.format = c.AV_SAMPLE_FMT_FLT;
            enc_frame.*.sample_rate = @intCast(config.target_sample_rate);
            c.av_channel_layout_default(&enc_frame.*.ch_layout, @intCast(channels));
            enc_frame.*.nb_samples = @intCast(chunk);

            ret = c.av_frame_get_buffer(enc_frame, 0);
            if (ret < 0) break;

            const size = chunk * channels * @sizeOf(f32);
            const dst: [*]u8 = @ptrCast(enc_frame.*.extended_data[0]);
            @memset(dst[0..size], 0);

            enc_frame.*.pts = pts;
            pts += @intCast(chunk);

            ret = c.avcodec_send_frame(enc_ctx, enc_frame);
            if (ret < 0) break;

            while (c.avcodec_receive_packet(enc_ctx, out_pkt) >= 0) {
                c.av_packet_rescale_ts(out_pkt, enc_ctx.*.time_base, out_stream.*.time_base);
                out_pkt.*.stream_index = out_stream.*.index;
                _ = c.av_interleaved_write_frame(out_format_ctx, out_pkt);
                c.av_packet_unref(out_pkt);
            }

            remaining -= chunk;
        }
    }

    // Flush encoder
    _ = c.avcodec_send_frame(enc_ctx, null);
    while (c.avcodec_receive_packet(enc_ctx, out_pkt) >= 0) {
        c.av_packet_rescale_ts(out_pkt, enc_ctx.*.time_base, out_stream.*.time_base);
        out_pkt.*.stream_index = out_stream.*.index;
        _ = c.av_interleaved_write_frame(out_format_ctx, out_pkt);
        c.av_packet_unref(out_pkt);
    }

    _ = c.av_write_trailer(out_format_ctx);

    if ((out_format_ctx.?.oformat.*.flags & c.AVFMT_NOFILE) == 0) {
        _ = c.avio_closep(&out_format_ctx.?.pb);
    }
}
