const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const shared = @import("shared.zig");
const Message = shared.Message;
const pubsub = @import("zig_pubsub");
const Self = @This();

pub const InitError = Allocator.Error || Io.ConcurrentError || Io.File.OpenError ||
    Io.File.LengthError || Io.Dir.CreateDirPathError || pubsub.SubscribeError;

const log = shared.log;
const errLog = shared.errLog;

pub const Options = struct {
    log_file_name: []const u8,
    log_base_dir: ?[]const u8 = null,
};

io: Io,
gpa: Allocator,
base_dir: ?[]u8,
file_name: []u8,
file: Io.File,
bus: *Message.Bus,
subscription: Message.Bus.Subscription,
listener: Io.Future(void),

pub fn init(io: Io, gpa: Allocator, bus: *Message.Bus, options: Options) InitError!Self {
    const file_name = try gpa.dupe(u8, options.log_file_name);
    errdefer gpa.free(file_name);
    const base_dir = if (options.log_base_dir) |dir| try gpa.dupe(u8, dir) else null;
    errdefer if (base_dir) |dir| gpa.free(dir);
    var file: Io.File = undefined;
    if (base_dir) |dir| {
        try Io.Dir.cwd().createDirPath(io, dir);
        const path = try std.fs.path.join(gpa, &.{ dir, file_name });
        defer gpa.free(path);
        file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    } else {
        file = try Io.Dir.cwd().createFile(io, file_name, .{ .truncate = false });
    }
    errdefer file.close(io);
    const subscription = try bus.subscribe(io, .data, 256);
    var initialized: Io.Event = .unset;
    var listener = try io.concurrent(listen, .{
        io,
        gpa,
        bus,
        subscription,
        file,
        try file.length(io),
        &initialized,
    });
    errdefer listener.cancel(io);
    try initialized.wait(io); // 等待子系统准备好
    return Self{
        .io = io,
        .gpa = gpa,
        .bus = bus,
        .base_dir = base_dir,
        .file = file,
        .file_name = file_name,
        .subscription = subscription,
        .listener = listener,
    };
}

pub fn deinit(self: *Self) void {
    self.subscription.close(self.io);
    self.listener.await(self.io);
    self.bus.unsubscribe(self.io, self.subscription); // 兜底的取消订阅
    self.file.close(self.io);
    if (self.base_dir) |dir| self.gpa.free(dir);
    self.gpa.free(self.file_name);
}

pub fn listen(
    io: Io,
    gpa: Allocator,
    bus: *Message.Bus,
    subscription: Message.Bus.Subscription,
    file: Io.File,
    init_seek: u64,
    initialized: *Io.Event,
) void {
    var write_buf: [16 * 1024]u8 = undefined; // 写线程独占的输出缓冲：多条日志合并成一次系统调用
    var fw = file.writer(io, &write_buf);
    defer fw.flush() catch |err| errLog("Failed to flush log: {s}", err); // 退出时兜底刷新
    fw.seekTo(init_seek) catch |err| {
        errLog("Failed to seek to end of log file: {s}", err);
        initialized.set(io); // 初始化失败，避免 init 阻塞
        subscription.close(io); // 关闭订阅，避免继续接收消息
        bus.unsubscribe(io, subscription); // 取消订阅，避免无意义发送
        return;
    };
    const writer = &fw.interface;
    var msg_buf: [256]Message = undefined;
    initialized.set(io); // 通知初始化完成
    while (true) {
        const n = subscription.recv(io, &msg_buf, 1) catch break;
        for (msg_buf[0..n]) |message| {
            defer message.data.release(gpa);
            const log_written = message.data.getMut().allocating.written();
            writer.writeAll(log_written) catch |err| errLog("Failed to write log: {s}", err);
        }
        // todo：优化刷新间隔
        fw.flush() catch |err| errLog("Failed to flush log: {s}", err);
    }
    log.debug("Sink listener exited", .{});
}
