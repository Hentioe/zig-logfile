const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Level = std.log.Level;
const Time = @import("zig_time").Time;
const Self = @This();

time: Io.Timestamp,
level: std.log.Level,
message: []const u8,

pub fn init(io: Io, allocator: Allocator, level: Level, comptime format: []const u8, args: anytype) Allocator.Error!Self {
    const message = try std.fmt.allocPrint(allocator, format, args);
    errdefer allocator.free(message);

    return .{
        .time = Io.Timestamp.now(io, .real),
        .level = level,
        .message = message,
    };
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    allocator.free(self.message);
    self.* = undefined;
}

/// 以 `<time> <LEVEL> <message>\n` 格式写入一条记录，时间使用 UTC。
pub fn writeTo(self: Self, allocator: Allocator, w: *Io.Writer, time_fmt: []const u8) !void {
    const time = Time.fromNanoTimestamp(self.time.nanoseconds).setLoc(.utc());
    const time_s = try time.formatAlloc(allocator, time_fmt);
    defer allocator.free(time_s);

    const level_s = switch (self.level) {
        .debug => "DEBUG",
        .info => "INFO",
        .warn => "WARN",
        .err => "ERROR",
    };

    try w.print("{s} {s:<5} {s}\n", .{ time_s, level_s, self.message });
}

test "init formats message" {
    var record = try init(std.testing.io, std.testing.allocator, .info, "hello {s} {d}", .{ "world", 42 });
    defer record.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("hello world 42", record.message);
    try std.testing.expectEqual(Level.info, record.level);
}

test "format pads level and uses utc time" {
    const allocator = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const infos: Self = .{ .time = .{ .nanoseconds = 0 }, .level = .info, .message = "a" };
    const errs: Self = .{ .time = .{ .nanoseconds = 0 }, .level = .err, .message = "b" };
    try infos.writeTo(allocator, &out.writer, "YYYY-MM-DDTHH:mm:ss");
    try errs.writeTo(allocator, &out.writer, "YYYY-MM-DDTHH:mm:ss");

    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00 INFO  a\n1970-01-01T00:00:00 ERROR b\n",
        out.written(),
    );
}

test "format honors custom time format" {
    const allocator = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const record: Self = .{ .time = .{ .nanoseconds = 0 }, .level = .warn, .message = "m" };
    try record.writeTo(allocator, &out.writer, "YYYY-MM-DD");

    try std.testing.expectEqualStrings("1970-01-01 WARN  m\n", out.written());
}
