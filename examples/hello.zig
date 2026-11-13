const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Allocating = std.Io.Writer.Allocating;
const logfile = @import("zig_logfile");

pub const std_options: std.Options = .{ .logFn = logFn };
// 自定义日志函数，将日志同时输出到标准日志和写入队列
fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    // 将日志交给默认实现
    std.log.defaultLog(level, scope, format, args);
    // 创建日志数据，丢给写入队列
    var aw = Allocating.init(global_gpa);
    var w = &aw.writer;
    w.writeAll(level.asText()) catch {};
    w.writeAll(": ") catch {};
    w.print(format ++ "\n", args) catch {};
    logfile.push(aw);
}

var global_gpa: Allocator = undefined;

pub fn main(init: std.process.Init) !void {
    global_gpa = init.gpa;

    try logfile.init(init, .{ .log_file_name = "hello.log" });
    defer logfile.deinit();
    std.log.debug("Hello", .{});
    std.log.info("Hello", .{});
    std.log.warn("Hello", .{});
    std.log.err("Hello", .{});

    try Io.sleep(init.io, .fromMilliseconds(100), .real);
}
