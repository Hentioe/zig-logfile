const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const logfile = @import("zig_logfile");
const LogData = logfile.LogData;

pub const std_options: std.Options = .{ .logFn = logFn };
// 自定义日志函数，将日志同时输出到标准日志和写入队列
fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    // 将日志交给默认实现
    std.log.defaultLog(level, scope, format, args);
    // 跳过忽略的 logfile 内部的日志 scope
    if (scope == logfile.ignored_scope) return;
    // 创建日志数据，丢给写入队列
    const log_data = buildShared(level, format, args) catch return;
    defer log_data.release(global_gpa);
    _ = global_bus.publish(global_io, .{ .data = log_data }) catch return;
}

fn buildShared(
    comptime level: std.log.Level,
    comptime format: []const u8,
    args: anytype,
) !logfile.LogData.Shared {
    var data = try LogData.create(global_gpa);
    errdefer data.destroy(global_gpa);

    var lw = data.writer();
    try lw.writeAll(level.asText());
    try lw.writeAll(": ");
    try lw.print(format ++ "\n", args);

    return try logfile.LogData.Shared.fromOwned(global_gpa, data);
}

var global_io: Io = undefined;
var global_gpa: Allocator = undefined;
var global_bus: logfile.Message.Bus = undefined;

pub fn main(init: std.process.Init) !void {
    global_io = init.io;
    global_gpa = init.gpa;
    global_bus = logfile.Message.Bus.init(init.gpa);

    defer global_bus.deinit(global_io);

    var sink = try logfile.Sink.init(
        global_io,
        global_gpa,
        &global_bus,
        .{ .log_file_name = "hello.log" },
    );
    defer sink.deinit();

    std.log.debug("Hello", .{});
    std.log.info("Hello", .{});
    std.log.warn("Hello", .{});
    std.log.err("Hello", .{});

    try Io.sleep(init.io, .fromMilliseconds(100), .real);
}
