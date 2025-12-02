const std = @import("std");
const ffmpeg = @import("ffmpeg.zig");
const c = ffmpeg.c;
const decoder = @import("decoder.zig");
const AudioData = decoder.AudioData;

pub const Encoder = struct {
    pub fn encodeWav(audio: *const AudioData, path: [:0]const u8) !void {
        // Open output format context
        var format_ctx: ?*c.AVFormatContext = null;
        var ret = c.avformat_alloc_output_context2(&format_ctx, null, "wav", path.ptr);
        if (ret < 0 or format_ctx == null) return error.AllocOutputFailed;
        defer c.avformat_free_context(format_ctx);

        // Find encoder
        const codec = c.avcodec_find_encoder(c.AV_CODEC_ID_PCM_F32LE);
        if (codec == null) return error.NoEncoder;

        // Create new stream
        const stream = c.avformat_new_stream(format_ctx, codec);
        if (stream == null) return error.NewStreamFailed;

        // Allocate codec context
        var codec_ctx = c.avcodec_alloc_context3(codec);
        if (codec_ctx == null) return error.AllocCodecFailed;
        defer c.avcodec_free_context(&codec_ctx);

        // Configure codec
        codec_ctx.*.sample_fmt = c.AV_SAMPLE_FMT_FLT;
        codec_ctx.*.sample_rate = @intCast(audio.sample_rate);
        c.av_channel_layout_default(&codec_ctx.*.ch_layout, @intCast(audio.channels));
        codec_ctx.*.bit_rate = @intCast(audio.sample_rate * audio.channels * 32);

        // Some formats want stream headers separate
        if ((format_ctx.?.oformat.*.flags & c.AVFMT_GLOBALHEADER) != 0) {
            codec_ctx.*.flags |= c.AV_CODEC_FLAG_GLOBAL_HEADER;
        }

        // Open codec
        ret = c.avcodec_open2(codec_ctx, codec, null);
        if (ret < 0) return error.OpenCodecFailed;

        // Copy parameters to stream
        ret = c.avcodec_parameters_from_context(stream.*.codecpar, codec_ctx);
        if (ret < 0) return error.CopyParamsFailed;

        stream.*.time_base = c.AVRational{ .num = 1, .den = @intCast(audio.sample_rate) };

        // Open output file
        if ((format_ctx.?.oformat.*.flags & c.AVFMT_NOFILE) == 0) {
            ret = c.avio_open(&format_ctx.?.pb, path.ptr, c.AVIO_FLAG_WRITE);
            if (ret < 0) return error.OpenOutputFailed;
        }

        // Write header
        ret = c.avformat_write_header(format_ctx, null);
        if (ret < 0) return error.WriteHeaderFailed;

        // Allocate frame and packet
        var frame = c.av_frame_alloc();
        if (frame == null) return error.AllocFailed;
        defer c.av_frame_free(&frame);

        var pkt = c.av_packet_alloc();
        if (pkt == null) return error.AllocFailed;
        defer c.av_packet_free(&pkt);

        // Configure frame
        frame.*.format = c.AV_SAMPLE_FMT_FLT;
        frame.*.sample_rate = @intCast(audio.sample_rate);
        c.av_channel_layout_default(&frame.*.ch_layout, @intCast(audio.channels));

        const total_samples = audio.samples.len / audio.channels;
        const frame_size: usize = if (codec_ctx.*.frame_size > 0) @intCast(codec_ctx.*.frame_size) else 1024;

        var pts: i64 = 0;
        var offset: usize = 0;

        while (offset < total_samples) {
            const remaining = total_samples - offset;
            const samples_this_frame = @min(frame_size, remaining);

            frame.*.nb_samples = @intCast(samples_this_frame);

            // Unref previous frame data before getting new buffer
            c.av_frame_unref(frame);

            // Reconfigure frame for this iteration
            frame.*.format = c.AV_SAMPLE_FMT_FLT;
            frame.*.sample_rate = @intCast(audio.sample_rate);
            c.av_channel_layout_default(&frame.*.ch_layout, @intCast(audio.channels));
            frame.*.nb_samples = @intCast(samples_this_frame);

            ret = c.av_frame_get_buffer(frame, 0);
            if (ret < 0) return error.GetBufferFailed;

            // Copy sample data
            const src_start = offset * audio.channels;
            const src_end = src_start + samples_this_frame * audio.channels;
            const src_bytes = std.mem.sliceAsBytes(audio.samples[src_start..src_end]);
            const dst_bytes: [*]u8 = @ptrCast(frame.*.extended_data[0]);
            @memcpy(dst_bytes[0..src_bytes.len], src_bytes);

            frame.*.pts = pts;
            pts += @intCast(samples_this_frame);

            // Send frame to encoder
            ret = c.avcodec_send_frame(codec_ctx, frame);
            if (ret < 0) return error.SendFrameFailed;

            // Receive and write packets
            while (true) {
                ret = c.avcodec_receive_packet(codec_ctx, pkt);
                if (ret == -@as(c_int, @intCast(c.EAGAIN)) or ffmpeg.isEof(ret)) break;
                if (ret < 0) return error.ReceivePacketFailed;

                c.av_packet_rescale_ts(pkt, codec_ctx.*.time_base, stream.*.time_base);
                pkt.*.stream_index = stream.*.index;

                ret = c.av_interleaved_write_frame(format_ctx, pkt);
                if (ret < 0) return error.WriteFrameFailed;

                c.av_packet_unref(pkt);
            }

            offset += samples_this_frame;
        }

        // Flush encoder
        ret = c.avcodec_send_frame(codec_ctx, null);
        while (true) {
            ret = c.avcodec_receive_packet(codec_ctx, pkt);
            if (ret < 0) break;

            c.av_packet_rescale_ts(pkt, codec_ctx.*.time_base, stream.*.time_base);
            pkt.*.stream_index = stream.*.index;
            _ = c.av_interleaved_write_frame(format_ctx, pkt);
            c.av_packet_unref(pkt);
        }

        // Write trailer
        ret = c.av_write_trailer(format_ctx);
        if (ret < 0) return error.WriteTrailerFailed;

        // Close output
        if ((format_ctx.?.oformat.*.flags & c.AVFMT_NOFILE) == 0) {
            _ = c.avio_closep(&format_ctx.?.pb);
        }
    }
};
