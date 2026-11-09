const std = @import("std");
const Io = std.Io;
const logfile = @import("zig_logfile");

pub const std_options: std.Options = .{ .logFn = logFn };
// 自定义日志函数，将日志同时输出到标准日志和写入队列
fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    // 将日志交给默认实现
    std.log.defaultLog(level, scope, format, args);
    // 把日志丢给写入队列
    logfile.push(level, format, args);
}

pub fn main(init: std.process.Init) !void {
    try logfile.init(init, .{ .log_file_name = "hello.log" });
    defer logfile.deinit();
    std.log.debug("Hello", .{});
    std.log.info("Hello", .{});
    std.log.warn("Hello", .{});
    std.log.err("Hello", .{});

    try Io.sleep(init.io, .fromMilliseconds(100), .real);
}
