const std = @import("std");
const processor = @import("processor.zig");

const Config = struct {
    input_dir: []const u8,
    output_dir: []const u8,
    target_sample_rate: u32 = 16000,
    min_duration: f32 = 3.0,
    max_duration: f32 = 5.0,
    num_threads: u32 = 0,
};

const ProcessTask = struct {
    input_path: []const u8,
    output_path: []const u8,
    config: processor.ProcessorConfig,
    allocator: std.mem.Allocator,
};

fn processFile(task: ProcessTask) void {
    const input_z = task.allocator.dupeZ(u8, task.input_path) catch return;
    defer task.allocator.free(input_z);

    const output_z = task.allocator.dupeZ(u8, task.output_path) catch return;
    defer task.allocator.free(output_z);

    processor.processFile(input_z, output_z, task.config) catch |err| {
        std.debug.print("Failed: {s}: {any}\n", .{ task.input_path, err });
        return;
    };

    std.debug.print("Processed: {s}\n", .{task.input_path});
}

fn isAudioFile(path: []const u8) bool {
    const extensions = [_][]const u8{ ".mp3", ".wav", ".flac", ".m4a", ".ogg", ".aac", ".wma", ".opus" };
    for (extensions) |ext| {
        if (std.ascii.endsWithIgnoreCase(path, ext)) return true;
    }
    return false;
}

fn collectAudioFiles(
    allocator: std.mem.Allocator,
    input_dir: []const u8,
    output_dir: []const u8,
    config: processor.ProcessorConfig,
) !std.ArrayListUnmanaged(ProcessTask) {
    var tasks: std.ArrayListUnmanaged(ProcessTask) = .{};
    errdefer tasks.deinit(allocator);

    const dir = std.fs.openDirAbsolute(input_dir, .{ .iterate = true }) catch
        std.fs.cwd().openDir(input_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("Failed to open input directory: {s} ({any})\n", .{ input_dir, err });
        return err;
    };
    defer @constCast(&dir).close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!isAudioFile(entry.basename)) continue;

        const input_path = try std.fs.path.join(allocator, &.{ input_dir, entry.path });
        const stem = std.fs.path.stem(entry.path);
        const dir_path = std.fs.path.dirname(entry.path) orelse "";
        const output_filename = try std.fmt.allocPrint(allocator, "{s}.wav", .{stem});
        defer allocator.free(output_filename);

        const output_subdir = try std.fs.path.join(allocator, &.{ output_dir, dir_path });
        const output_path = try std.fs.path.join(allocator, &.{ output_subdir, output_filename });
        allocator.free(output_subdir);

        try tasks.append(allocator, .{
            .input_path = input_path,
            .output_path = output_path,
            .config = config,
            .allocator = allocator,
        });
    }

    return tasks;
}

fn ensureOutputDirs(allocator: std.mem.Allocator, tasks: []const ProcessTask) !void {
    var seen_dirs: std.StringHashMapUnmanaged(void) = .{};
    defer seen_dirs.deinit(allocator);

    for (tasks) |task| {
        const dir_path = std.fs.path.dirname(task.output_path) orelse continue;
        if (seen_dirs.contains(dir_path)) continue;

        std.fs.cwd().makePath(dir_path) catch |e| {
            std.debug.print("Failed to create directory: {s} ({any})\n", .{ dir_path, e });
            return e;
        };
        try seen_dirs.put(allocator, dir_path, {});
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print(
            \\Usage: {s} <input_dir> <output_dir> [options]
            \\
            \\Options:
            \\  --sample-rate <rate>   Target sample rate (default: 16000)
            \\  --min-duration <sec>   Minimum duration in seconds (default: 3.0)
            \\  --max-duration <sec>   Maximum duration in seconds (default: 5.0)
            \\  --threads <num>        Number of threads (default: auto)
            \\
        , .{args[0]});
        return;
    }

    var config = Config{
        .input_dir = args[1],
        .output_dir = args[2],
    };

    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--sample-rate") and i + 1 < args.len) {
            config.target_sample_rate = try std.fmt.parseInt(u32, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--min-duration") and i + 1 < args.len) {
            config.min_duration = try std.fmt.parseFloat(f32, args[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--max-duration") and i + 1 < args.len) {
            config.max_duration = try std.fmt.parseFloat(f32, args[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--threads") and i + 1 < args.len) {
            config.num_threads = try std.fmt.parseInt(u32, args[i + 1], 10);
            i += 1;
        }
    }

    std.debug.print("Audio Dataset Preprocessor (Optimized)\n", .{});
    std.debug.print("Input:  {s}\n", .{config.input_dir});
    std.debug.print("Output: {s}\n", .{config.output_dir});
    std.debug.print("Target sample rate: {} Hz\n", .{config.target_sample_rate});
    std.debug.print("Duration range: {d:.1}s - {d:.1}s\n", .{ config.min_duration, config.max_duration });

    const proc_config = processor.ProcessorConfig{
        .target_sample_rate = config.target_sample_rate,
        .min_duration_sec = config.min_duration,
        .max_duration_sec = config.max_duration,
    };

    var tasks = try collectAudioFiles(allocator, config.input_dir, config.output_dir, proc_config);
    defer {
        for (tasks.items) |task| {
            allocator.free(task.input_path);
            allocator.free(task.output_path);
        }
        tasks.deinit(allocator);
    }

    std.debug.print("Found {} audio files\n", .{tasks.items.len});

    if (tasks.items.len == 0) {
        std.debug.print("No audio files found.\n", .{});
        return;
    }

    try ensureOutputDirs(allocator, tasks.items);

    const num_cpus = std.Thread.getCpuCount() catch 4;
    const thread_count: usize = if (config.num_threads > 0) config.num_threads else @min(num_cpus, tasks.items.len);

    std.debug.print("Processing with {} threads...\n", .{thread_count});

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator, .n_jobs = @intCast(thread_count) });
    defer pool.deinit();

    for (tasks.items) |task| {
        try pool.spawn(processFile, .{task});
    }

    std.debug.print("Processing complete!\n", .{});
}
