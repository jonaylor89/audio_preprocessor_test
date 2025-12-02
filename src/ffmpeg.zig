// FFmpeg C bindings via @cImport
pub const c = @cImport({
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libavutil/avutil.h");
    @cInclude("libavutil/opt.h");
    @cInclude("libavutil/channel_layout.h");
    @cInclude("libavutil/samplefmt.h");
    @cInclude("libswresample/swresample.h");
});

const std = @import("std");

pub const AVERROR_EOF = -@as(c_int, @intCast(('E') | (('O') << 8) | (('F') << 16) | ((' ') << 24)));

pub fn avError(err: c_int) []const u8 {
    var buf: [256]u8 = undefined;
    _ = c.av_strerror(err, &buf, buf.len);
    const len = std.mem.indexOfScalar(u8, &buf, 0) orelse buf.len;
    return buf[0..len];
}

pub fn isEof(err: c_int) bool {
    return err == AVERROR_EOF or err == -@as(c_int, @intCast(c.EAGAIN));
}
