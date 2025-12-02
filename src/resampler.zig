const std = @import("std");
const ffmpeg = @import("ffmpeg.zig");
const c = ffmpeg.c;
const decoder = @import("decoder.zig");
const AudioData = decoder.AudioData;

pub const Resampler = struct {
    target_sample_rate: u32,

    pub fn init(target_sample_rate: u32) Resampler {
        return .{ .target_sample_rate = target_sample_rate };
    }

    pub fn resample(self: *const Resampler, audio: *AudioData, allocator: std.mem.Allocator) !AudioData {
        if (audio.sample_rate == self.target_sample_rate) {
            // No resampling needed, just copy
            const new_samples = try allocator.dupe(f32, audio.samples);
            return AudioData{
                .samples = new_samples,
                .sample_rate = audio.sample_rate,
                .channels = audio.channels,
                .allocator = allocator,
            };
        }

        // Setup channel layout
        var src_ch_layout: c.AVChannelLayout = .{};
        var dst_ch_layout: c.AVChannelLayout = .{};
        c.av_channel_layout_default(&src_ch_layout, @intCast(audio.channels));
        c.av_channel_layout_default(&dst_ch_layout, @intCast(audio.channels));

        // Create resampler context with high-quality anti-aliasing
        var swr_ctx: ?*c.SwrContext = null;

        var ret = c.swr_alloc_set_opts2(
            &swr_ctx,
            &dst_ch_layout,
            c.AV_SAMPLE_FMT_FLT,
            @intCast(self.target_sample_rate),
            &src_ch_layout,
            c.AV_SAMPLE_FMT_FLT,
            @intCast(audio.sample_rate),
            0,
            null,
        );
        if (ret < 0 or swr_ctx == null) return error.SwrAllocFailed;
        defer c.swr_free(&swr_ctx);

        // Configure high-quality resampling with anti-aliasing (soxr-like)
        _ = c.av_opt_set_int(swr_ctx, "filter_size", 64, 0);
        _ = c.av_opt_set_int(swr_ctx, "phase_shift", 10, 0);
        _ = c.av_opt_set_double(swr_ctx, "cutoff", 0.97, 0);

        ret = c.swr_init(swr_ctx);
        if (ret < 0) return error.SwrInitFailed;

        // Calculate output sample count
        const in_samples = audio.samples.len / audio.channels;
        const out_samples_est: usize = @intCast(c.av_rescale_rnd(
            @intCast(in_samples),
            @intCast(self.target_sample_rate),
            @intCast(audio.sample_rate),
            c.AV_ROUND_UP,
        ));

        // Add some extra space for resampler delay
        const out_buf_size = (out_samples_est + 256) * audio.channels;
        var out_samples = try allocator.alloc(f32, out_buf_size);
        errdefer allocator.free(out_samples);

        var out_ptr: [*]u8 = @ptrCast(out_samples.ptr);
        const in_ptr: [*]const u8 = @ptrCast(audio.samples.ptr);

        // Perform resampling
        const converted = c.swr_convert(
            swr_ctx,
            @ptrCast(&out_ptr),
            @intCast(out_samples_est + 256),
            @ptrCast(&in_ptr),
            @intCast(in_samples),
        );

        if (converted < 0) return error.ResampleFailed;

        // Flush remaining samples
        var total_converted: usize = @intCast(converted);
        while (true) {
            var flush_ptr: [*]u8 = @ptrCast(out_samples.ptr + total_converted * audio.channels);
            const remaining: c_int = @intCast(out_buf_size / audio.channels - total_converted);
            const flushed = c.swr_convert(swr_ctx, @ptrCast(&flush_ptr), remaining, null, 0);
            if (flushed <= 0) break;
            total_converted += @intCast(flushed);
        }

        // Shrink to actual size
        const final_size = total_converted * audio.channels;
        out_samples = allocator.realloc(out_samples, final_size) catch out_samples;

        return AudioData{
            .samples = out_samples[0..final_size],
            .sample_rate = self.target_sample_rate,
            .channels = audio.channels,
            .allocator = allocator,
        };
    }
};
