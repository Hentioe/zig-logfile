//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Level = std.log.Level;

pub const Record = @import("Record.zig");
pub const Options = @import("Options.zig");

pub const Message = union(enum) {
    log: Record,
    flush,

    pub const Queue = Io.Queue(@This());
};

pub const InitError = Allocator.Error || Io.ConcurrentError || Io.File.OpenError || Io.File.LengthError || Io.Dir.CreateDirPathError;
pub const DEFAULT_LOG_TIME_FMT: []const u8 = "YYYY-MM-DDTHH:mm:ssZ";
pub const DEFAULT_LOG_TZ_OFFSET: i32 = 0;

// 队列容量：留一些余量，突发日志避免阻塞
var buffer: [256]Message = undefined;

var io: Io = undefined;
var gpa: Allocator = undefined;
var queue: Message.Queue = .init(&buffer);
var file: Io.File = undefined;
var write_future: Io.Future(void) = undefined;
var flush_future: Io.Future(void) = undefined;
var initialized: Io.Event = .unset;

var base_dir: ?[]u8 = null;
var file_name: []u8 = undefined;
var time_fmt: []u8 = undefined;
var timezone_offset: i32 = DEFAULT_LOG_TZ_OFFSET;

pub fn init(app_init: std.process.Init, options: Options) InitError!void {
    std.debug.assert(!initialized.isSet());
    io = app_init.io;
    gpa = app_init.gpa;
    file_name = try gpa.dupe(u8, options.log_file_name);
    errdefer gpa.free(file_name);
    time_fmt = if (options.time_fmt) |fmt|
        try gpa.dupe(u8, fmt)
    else
        try gpa.dupe(u8, DEFAULT_LOG_TIME_FMT);
    errdefer gpa.free(time_fmt);
    if (options.timezone_offset) |offset| timezone_offset = offset;
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
    queue.close(io); // 先关闭队列：write 线程会把队列里剩余的记录处理完后再从 getOne 收到错误退出
    _ = flush_future.cancel(io);
    _ = write_future.await(io);
    file.close(io);
    if (base_dir) |dir| gpa.free(dir);
    base_dir = null;
    gpa.free(file_name);
    gpa.free(time_fmt);
    initialized.reset();
}

pub fn push(level: Level, comptime format: []const u8, args: anytype) void {
    std.debug.assert(initialized.isSet());
    var record = Record.init(io, gpa, level, format, args) catch |err| {
        errLog("Failed to create log record: {s}", err);
        return;
    };
    queue.putOne(io, .{ .log = record }) catch |err| {
        errLog("Failed to push log to queue: {s}", err);
        record.deinit(gpa); // 推送失败，释放 record
    };
}

pub fn updateTz(new_offset: i32) void {
    timezone_offset = new_offset;
}

fn write(init_seek: u64) void {
    var buf: [16 * 1024]u8 = undefined; // 写线程独占的输出缓冲：多条日志合并成一次系统调用
    var fw = file.writer(io, &buf);
    defer fw.flush() catch |err| errLog("Failed to flush log: {s}", err); // 退出时兜底刷新
    fw.seekTo(init_seek) catch |err| {
        errLog("Failed to seek to end of log file: {s}", err);
        // 注意：在进入循环前的任意提前返回分支，都需要显式关闭队列，避免没有消费而阻塞。
        queue.close(io);
        initialized.set(io); // 避免让初始化无意义等待
        return;
    };
    const w = &fw.interface;
    initialized.set(io); // 通知初始化完成
    while (true) {
        const message = queue.getOne(io) catch break;
        switch (message) {
            .log => |record| {
                defer gpa.free(record.message);
                record.writeTo(gpa, w, .{
                    .time_fmt = time_fmt,
                    .timezone = .create(timezone_offset, ""),
                }) catch |err| errLog("Failed to write log: {s}", err);
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
        io.sleep(.fromSeconds(5), .awake) catch break;
        queue.putOne(io, .{ .flush = {} }) catch break;
    }
}

inline fn errLog(comptime format: []const u8, err: anyerror) void {
    std.log.defaultLog(.err, .logfile, format, .{@errorName(err)});
}

test {
    _ = Record;
}
