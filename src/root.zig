//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Level = std.log.Level;
const Allocating = std.Io.Writer.Allocating;

pub const Options = @import("Options.zig");

pub const Message = union(enum) {
    allocating: Allocating,
    flush,

    pub const Queue = Io.Queue(@This());
};

pub const InitError = Allocator.Error || Io.ConcurrentError || Io.File.OpenError || Io.File.LengthError || Io.Dir.CreateDirPathError;

// 队列容量：留一些余量，突发日志避免阻塞
var buffer: [256]Message = undefined;

var global_io: Io = undefined;
var global_gpa: Allocator = undefined;
var queue: Message.Queue = .init(&buffer);
var file: Io.File = undefined;
var write_future: Io.Future(void) = undefined;
var flush_future: Io.Future(void) = undefined;
var initialized: Io.Event = .unset;

var base_dir: ?[]u8 = null;
var file_name: []u8 = undefined;

pub fn init(io: Io, gpa: Allocator, options: Options) InitError!void {
    std.debug.assert(!initialized.isSet());
    global_io = io;
    global_gpa = gpa;
    file_name = try gpa.dupe(u8, options.log_file_name);
    errdefer gpa.free(file_name);
    base_dir = if (options.log_base_dir) |dir| try gpa.dupe(u8, dir) else null;
    errdefer if (base_dir) |dir| gpa.free(dir);
    if (base_dir) |dir| {
        try Io.Dir.cwd().createDirPath(io, dir);
        const path = try std.fs.path.join(gpa, &.{ dir, file_name });
        defer gpa.free(path);
        file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    } else {
        file = try Io.Dir.cwd().createFile(io, file_name, .{ .truncate = false });
    }
    errdefer file.close(io);
    write_future = try io.concurrent(write, .{try file.length(io)});
    errdefer write_future.cancel(io);
    flush_future = try io.concurrent(flush, .{});
    errdefer flush_future.cancel(io);
    try initialized.wait(io); // 等待子系统准备好
}

pub fn deinit() void {
    std.debug.assert(initialized.isSet());
    queue.close(global_io); // 先关闭队列：write 线程会把队列里剩余的记录处理完后再从 getOne 收到错误退出
    _ = flush_future.cancel(global_io);
    _ = write_future.await(global_io);
    file.close(global_io);
    if (base_dir) |dir| global_gpa.free(dir);
    base_dir = null;
    global_gpa.free(file_name);
    initialized.reset();
}

pub fn push(allocating: Allocating) void {
    std.debug.assert(initialized.isSet());
    queue.putOne(global_io, .{ .allocating = allocating }) catch |err| {
        errLog("Failed to push allocating writer to queue: {s}", err);
    };
}

fn write(init_seek: u64) void {
    var buf: [16 * 1024]u8 = undefined; // 写线程独占的输出缓冲：多条日志合并成一次系统调用
    var fw = file.writer(global_io, &buf);
    defer fw.flush() catch |err| errLog("Failed to flush log: {s}", err); // 退出时兜底刷新
    fw.seekTo(init_seek) catch |err| {
        errLog("Failed to seek to end of log file: {s}", err);
        // 注意：在进入循环前的任意提前返回分支，都需要显式关闭队列，避免没有消费而阻塞。
        queue.close(global_io);
        initialized.set(global_io); // 避免让初始化无意义等待
        return;
    };
    const w = &fw.interface;
    initialized.set(global_io); // 通知初始化完成
    while (true) {
        const message = queue.getOne(global_io) catch break;
        switch (message) {
            .allocating => |allocating| {
                var tmp = allocating;
                defer tmp.deinit();
                w.writeAll(tmp.written()) catch |err| errLog("Failed to write log: {s}", err);
            },
            .flush => {
                fw.flush() catch |err| errLog("Failed to flush log: {s}", err);
            },
        }
    }
    std.log.defaultLog(.debug, .logfile, "Log file writer has exited", .{});
}

fn flush() void {
    while (true) {
        global_io.sleep(.fromSeconds(5), .awake) catch break;
        queue.putOne(global_io, .{ .flush = {} }) catch break;
    }
}

inline fn errLog(comptime format: []const u8, err: anyerror) void {
    std.log.defaultLog(.err, .logfile, format, .{@errorName(err)});
}
