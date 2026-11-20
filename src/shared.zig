const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Allocating = std.Io.Writer.Allocating;
const pubsub = @import("zig_pubsub");

pub const Message = union(enum) {
    data: pubsub.AtomicShared(LogData),

    pub const Bus = pubsub.Bus(@This());
};

pub const LogData = struct {
    const Self = @This();

    allocating: Allocating,

    pub fn create(allocator: Allocator) Allocator.Error!*LogData {
        const ptr = try allocator.create(Self);
        ptr.* = Self{
            .allocating = Allocating.init(allocator),
        };

        return ptr;
    }

    pub fn destroy(self: *@This(), allocator: Allocator) void {
        self.allocating.deinit();
        allocator.destroy(self);
    }

    pub fn writer(self: *@This()) *Io.Writer {
        return &self.allocating.writer;
    }

    pub fn clone(_: *const @This(), _: Allocator) Allocator.Error!LogData {
        @panic("clone not implemented");
    }

    // rc.AtomicShared 回调此方法释放内存
    pub fn release(self: *@This(), allocator: Allocator) void {
        self.destroy(allocator);
    }

    pub const Shared = pubsub.AtomicShared(LogData);
};

// 警告：外部必须避免 `ignored_scope` 的 scope 的日志被丢向队列（否则出现错误日志时会死循环）
pub const ignored_scope = .logfile;
pub const log = std.log.scoped(ignored_scope);
pub inline fn errLog(comptime format: []const u8, err: anyerror) void {
    log.err(format, .{@errorName(err)});
}
