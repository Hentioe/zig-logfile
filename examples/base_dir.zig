const std = @import("std");
const Io = std.Io;
const logfile = @import("zig_logfile");

pub const std_options: std.Options = .{ .logFn = logFn };

fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    std.log.defaultLog(level, scope, format, args);
    logfile.push(level, format, args);
}

pub fn main(init: std.process.Init) !void {
    try logfile.init(init, .{ .log_file_name = "base_dir.log", .log_base_dir = "logs" });
    defer logfile.deinit();
    std.log.info("Hello from base_dir", .{});

    try Io.sleep(init.io, .fromMilliseconds(100), .real);
}
