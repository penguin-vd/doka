//! Work off the main loop: decoding, thumbnails, encoding. A task's `run` goes on a worker thread,
//! then its `done` on the main loop (a GLib idle), where the app's state lives. Urgent tasks (the
//! photo on screen, an export) go before the rest (thumbnails, neighbours).
const std = @import("std");
const Io = std.Io;
const c = @import("c.zig");

const Pool = @This();

pub const Task = struct {
    run: *const fn (*Task) void,
    done: *const fn (*Task) void,
    next: ?*Task = null,
};

pub const Priority = enum { urgent, background };

pub const workers = 4;

io: Io,
mutex: Io.Mutex = .init,
ready: Io.Condition = .init,
queues: [2]Queue = .{ .{}, .{} },
stopping: bool = false,
threads: [workers]std.Thread = undefined,

const Queue = struct {
    head: ?*Task = null,
    tail: ?*Task = null,

    fn push(q: *Queue, t: *Task) void {
        t.next = null;
        if (q.tail) |tail| tail.next = t else q.head = t;
        q.tail = t;
    }

    fn pop(q: *Queue) ?*Task {
        const t = q.head orelse return null;
        q.head = t.next;
        if (q.head == null) q.tail = null;
        return t;
    }
};

pub fn start(pool: *Pool) !void {
    for (&pool.threads) |*t| t.* = try std.Thread.spawn(.{}, work, .{pool});
}

/// Waits for the running tasks; queued ones are dropped without their `done`.
pub fn stop(pool: *Pool) void {
    pool.mutex.lockUncancelable(pool.io);
    pool.stopping = true;
    pool.ready.broadcast(pool.io);
    pool.mutex.unlock(pool.io);
    for (pool.threads) |t| t.join();
}

pub fn submit(pool: *Pool, task: *Task, priority: Priority) void {
    pool.mutex.lockUncancelable(pool.io);
    defer pool.mutex.unlock(pool.io);
    pool.queues[@intFromEnum(priority)].push(task);
    pool.ready.signal(pool.io);
}

fn work(pool: *Pool) void {
    while (true) {
        pool.mutex.lockUncancelable(pool.io);
        const task = while (true) {
            if (pool.stopping) {
                pool.mutex.unlock(pool.io);
                return;
            }
            if (pool.queues[0].pop() orelse pool.queues[1].pop()) |t| break t;
            pool.ready.waitUncancelable(pool.io, &pool.mutex);
        };
        pool.mutex.unlock(pool.io);
        task.run(task);
        _ = c.g_idle_add(finish, task);
    }
}

fn finish(ctx: ?*anyopaque) callconv(.c) c_int {
    const task: *Task = @ptrCast(@alignCast(ctx));
    task.done(task);
    return c.g_source_remove_value;
}
