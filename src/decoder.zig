const std = @import("std");
const ffmpeg = @import("ffmpeg.zig");
const c = ffmpeg.c;

pub const AudioData = struct {
    samples: []f32,
    sample_rate: u32,
    channels: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *AudioData) void {
        self.allocator.free(self.samples);
    }
};

pub const Decoder = struct {
    format_ctx: ?*c.AVFormatContext,
    codec_ctx: ?*c.AVCodecContext,
    stream_index: c_int,
    frame: ?*c.AVFrame,
    packet: ?*c.AVPacket,

    pub fn init() Decoder {
        return .{
            .format_ctx = null,
            .codec_ctx = null,
            .stream_index = -1,
            .frame = null,
            .packet = null,
        };
    }

    pub fn open(self: *Decoder, path: [:0]const u8) !void {
        // Open input file
        var ret = c.avformat_open_input(&self.format_ctx, path.ptr, null, null);
        if (ret < 0) {
            std.debug.print("Failed to open input: {s}\n", .{path});
            return error.OpenInputFailed;
        }

        // Find stream info
        ret = c.avformat_find_stream_info(self.format_ctx, null);
        if (ret < 0) return error.FindStreamInfoFailed;

        // Find best audio stream
        self.stream_index = c.av_find_best_stream(self.format_ctx, c.AVMEDIA_TYPE_AUDIO, -1, -1, null, 0);
        if (self.stream_index < 0) return error.NoAudioStream;

        const stream = self.format_ctx.?.streams[@intCast(self.stream_index)];
        const codecpar = stream.*.codecpar;

        // Find decoder
        const codec = c.avcodec_find_decoder(codecpar.*.codec_id);
        if (codec == null) return error.NoDecoder;

        // Allocate codec context
        self.codec_ctx = c.avcodec_alloc_context3(codec);
        if (self.codec_ctx == null) return error.AllocFailed;

        // Copy codec parameters
        ret = c.avcodec_parameters_to_context(self.codec_ctx, codecpar);
        if (ret < 0) return error.CopyParamsFailed;

        // Open codec
        ret = c.avcodec_open2(self.codec_ctx, codec, null);
        if (ret < 0) return error.OpenCodecFailed;

        // Allocate frame and packet
        self.frame = c.av_frame_alloc();
        self.packet = c.av_packet_alloc();
        if (self.frame == null or self.packet == null) return error.AllocFailed;
    }

    pub fn decode(self: *Decoder, allocator: std.mem.Allocator) !AudioData {
        var samples: std.ArrayListUnmanaged(f32) = .{};
        errdefer samples.deinit(allocator);

        const codec_ctx = self.codec_ctx.?;
        const sample_rate: u32 = @intCast(codec_ctx.sample_rate);

        // Determine channel count
        var channels: u32 = @intCast(codec_ctx.ch_layout.nb_channels);
        if (channels == 0) channels = 2;

        // Setup resampler to convert to f32 planar
        var swr_ctx: ?*c.SwrContext = null;

        var dst_ch_layout: c.AVChannelLayout = .{};
        c.av_channel_layout_default(&dst_ch_layout, @intCast(channels));

        var ret = c.swr_alloc_set_opts2(
            &swr_ctx,
            &dst_ch_layout,
            c.AV_SAMPLE_FMT_FLT,
            @intCast(sample_rate),
            &codec_ctx.ch_layout,
            codec_ctx.sample_fmt,
            codec_ctx.sample_rate,
            0,
            null,
        );
        if (ret < 0 or swr_ctx == null) return error.SwrAllocFailed;
        defer c.swr_free(&swr_ctx);

        ret = c.swr_init(swr_ctx);
        if (ret < 0) return error.SwrInitFailed;

        // Read and decode packets
        while (c.av_read_frame(self.format_ctx, self.packet) >= 0) {
            defer c.av_packet_unref(self.packet);

            if (self.packet.?.stream_index != self.stream_index) continue;

            ret = c.avcodec_send_packet(self.codec_ctx, self.packet);
            if (ret < 0) continue;

            while (true) {
                ret = c.avcodec_receive_frame(self.codec_ctx, self.frame);
                if (ret < 0) break;

                const frame = self.frame.?;
                const nb_samples = frame.nb_samples;

                // Allocate output buffer
                const out_samples: usize = @intCast(nb_samples);
                const out_buf = try allocator.alloc(f32, out_samples * channels);
                defer allocator.free(out_buf);

                var out_ptr: [*]u8 = @ptrCast(out_buf.ptr);
                const in_ptr: [*c]const [*c]const u8 = @ptrCast(&frame.extended_data[0]);

                const converted = c.swr_convert(
                    swr_ctx,
                    @ptrCast(&out_ptr),
                    nb_samples,
                    in_ptr,
                    nb_samples,
                );

                if (converted > 0) {
                    const conv_samples: usize = @intCast(converted);
                    try samples.appendSlice(allocator, out_buf[0 .. conv_samples * channels]);
                }

                c.av_frame_unref(self.frame);
            }
        }

        // Flush decoder
        _ = c.avcodec_send_packet(self.codec_ctx, null);
        while (true) {
            ret = c.avcodec_receive_frame(self.codec_ctx, self.frame);
            if (ret < 0) break;

            const frame = self.frame.?;
            const nb_samples = frame.nb_samples;
            const out_samples: usize = @intCast(nb_samples);
            const out_buf = try allocator.alloc(f32, out_samples * channels);
            defer allocator.free(out_buf);

            var out_ptr: [*]u8 = @ptrCast(out_buf.ptr);
            const in_ptr: [*c]const [*c]const u8 = @ptrCast(&frame.extended_data[0]);

            const converted = c.swr_convert(
                swr_ctx,
                @ptrCast(&out_ptr),
                nb_samples,
                in_ptr,
                nb_samples,
            );

            if (converted > 0) {
                const conv_samples: usize = @intCast(converted);
                try samples.appendSlice(allocator, out_buf[0 .. conv_samples * channels]);
            }

            c.av_frame_unref(self.frame);
        }

        return AudioData{
            .samples = try samples.toOwnedSlice(allocator),
            .sample_rate = sample_rate,
            .channels = channels,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Decoder) void {
        if (self.packet) |pkt| c.av_packet_free(@constCast(&@as(?*c.AVPacket, pkt)));
        if (self.frame) |frm| c.av_frame_free(@constCast(&@as(?*c.AVFrame, frm)));
        if (self.codec_ctx) |ctx| c.avcodec_free_context(@constCast(&@as(?*c.AVCodecContext, ctx)));
        if (self.format_ctx) |ctx| c.avformat_close_input(@constCast(&@as(?*c.AVFormatContext, ctx)));
    }
};
