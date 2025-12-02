const std = @import("std");
const decoder = @import("decoder.zig");
const AudioData = decoder.AudioData;

pub const Normalizer = struct {
    min_duration_sec: f32,
    max_duration_sec: f32,

    pub fn init(min_duration_sec: f32, max_duration_sec: f32) Normalizer {
        return .{
            .min_duration_sec = min_duration_sec,
            .max_duration_sec = max_duration_sec,
        };
    }

    pub fn normalize(self: *const Normalizer, audio: *AudioData, allocator: std.mem.Allocator) !AudioData {
        const samples_per_channel = audio.samples.len / audio.channels;
        const duration_sec: f32 = @as(f32, @floatFromInt(samples_per_channel)) / @as(f32, @floatFromInt(audio.sample_rate));

        const min_samples = @as(usize, @intFromFloat(self.min_duration_sec * @as(f32, @floatFromInt(audio.sample_rate))));
        const max_samples = @as(usize, @intFromFloat(self.max_duration_sec * @as(f32, @floatFromInt(audio.sample_rate))));

        var new_samples: []f32 = undefined;

        if (duration_sec > self.max_duration_sec) {
            // Trim: clip to max duration
            const target_len = max_samples * audio.channels;
            new_samples = try allocator.alloc(f32, target_len);
            @memcpy(new_samples, audio.samples[0..target_len]);
        } else if (duration_sec < self.min_duration_sec) {
            // Pad: add silence to reach min duration
            const target_len = min_samples * audio.channels;
            new_samples = try allocator.alloc(f32, target_len);
            @memcpy(new_samples[0..audio.samples.len], audio.samples);
            // Zero-fill the rest (silence)
            @memset(new_samples[audio.samples.len..], 0.0);
        } else {
            // Duration is within range, just copy
            new_samples = try allocator.dupe(f32, audio.samples);
        }

        return AudioData{
            .samples = new_samples,
            .sample_rate = audio.sample_rate,
            .channels = audio.channels,
            .allocator = allocator,
        };
    }
};
