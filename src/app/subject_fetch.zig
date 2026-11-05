//! Click-a-subject's download into the models folder, asked for once with a dialog: ONNX Runtime
//! (MIT, Microsoft) and MobileSAM (Apache-2.0; ONNX export by Acly, MIT). Every file is checked
//! against its checksum, and only a checked one gets its real name.
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const gtk = @import("gtk.zig");
const Pool = @import("jobs.zig");
const Subject = @import("subject.zig");

const log = std.log.scoped(.subject);

const ort_version = "1.31.1";
const Runtime = struct { platform: []const u8, member: []const u8, sha256: []const u8 };

// subject.zig's hand-written API follows this version, so it isn't left to the system's.
const runtime: ?Runtime = switch (builtin.os.tag) {
    .macos => if (builtin.cpu.arch == .aarch64) .{
        .platform = "osx-arm64",
        .member = "lib/libonnxruntime." ++ ort_version ++ ".dylib",
        .sha256 = "2e1344a1926ee50eb25b38153cb6992c3567515aef0e677a1a520a1798896d6f",
    } else null,
    .linux => switch (builtin.cpu.arch) {
        .x86_64 => .{
            .platform = "linux-x64",
            .member = "lib/libonnxruntime.so." ++ ort_version,
            .sha256 = "c849e36a1ef3e22d4ff217b9d1ce4a3cf5b9467b975610913ae959ad5b16bdc9",
        },
        .aarch64 => .{
            .platform = "linux-aarch64",
            .member = "lib/libonnxruntime.so." ++ ort_version,
            .sha256 = "5317505e2da99be65f8e2775ba3c2afd6d2961fd78aba1bd8f56159f48820c78",
        },
        else => null,
    },
    else => null,
};

const model_url = "https://huggingface.co/Acly/MobileSAM/resolve/main/";
const models = [_]struct { name: []const u8, sha256: []const u8 }{
    .{ .name = Subject.encoder_name, .sha256 = "580f5fb648ea1062c0aabc26217aed56921985f03f0cbbd852bba81d760cc749" },
    .{ .name = Subject.decoder_name, .sha256 = "8976b90a87ba50a6a72217a5ff994f7d25ce16f2229fcc1ed259e1294c622ffe" },
};
const credits =
    \\ONNX Runtime: Copyright (c) Microsoft Corporation, MIT License.
    \\MobileSAM: Chaoning Zhang et al., Apache License 2.0 (https://github.com/ChaoningZhang/MobileSAM).
    \\Segment Anything's mask decoder: Meta Platforms, Apache License 2.0.
    \\ONNX export: https://huggingface.co/Acly/MobileSAM, MIT License.
    \\
;
const question_detail = "Click-a-subject needs ONNX Runtime and the MobileSAM model, " ++
    (if (builtin.os.tag == .macos) "about 80 MB" else "about 56 MB") ++
    ", downloaded once. Everything else in Doka works without them.";

/// Fetches what's missing; what's already there and correct stays.
pub fn install(gpa: std.mem.Allocator, io: Io, folder: []const u8) !void {
    const rt = runtime orelse return error.NoRuntimeForThisComputer;
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, folder);

    for (models) |model| {
        const path = try std.fs.path.join(gpa, &.{ folder, model.name });
        defer gpa.free(path);
        if (checksumIs(io, path, model.sha256) catch false) continue;
        const url = try std.fmt.allocPrint(gpa, model_url ++ "{s}", .{model.name});
        defer gpa.free(url);
        try fetchChecked(gpa, io, url, model.sha256, path);
    }

    const library = try std.fs.path.join(gpa, &.{ folder, Subject.library_name });
    defer gpa.free(library);
    if (cwd.access(io, library, .{})) |_| {} else |_| {
        const archive = try std.fs.path.join(gpa, &.{ folder, "onnxruntime.tgz" });
        defer gpa.free(archive);
        defer cwd.deleteFile(io, archive) catch {};
        const url = try std.fmt.allocPrint(gpa, "https://github.com/microsoft/onnxruntime/releases/download/v{0s}/onnxruntime-{1s}-{0s}.tgz", .{ ort_version, rt.platform });
        defer gpa.free(url);
        try fetchChecked(gpa, io, url, rt.sha256, archive);
        const member = try std.fmt.allocPrint(gpa, "onnxruntime-{s}-{s}/{s}", .{ rt.platform, ort_version, rt.member });
        defer gpa.free(member);
        try unpackMember(gpa, io, archive, member, library);
    }

    const notes = try std.fs.path.join(gpa, &.{ folder, "CREDITS.txt" });
    defer gpa.free(notes);
    try cwd.writeFile(io, .{ .sub_path = notes, .data = credits });
}

fn fetchChecked(gpa: std.mem.Allocator, io: Io, url: []const u8, sha256: []const u8, path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const partial = try std.fmt.allocPrint(gpa, "{s}.partial", .{path});
    defer gpa.free(partial);
    defer cwd.deleteFile(io, partial) catch {};
    // curl, not std.http: Zig's TLS can't reach GitHub's release servers, and every Mac has curl.
    var child = try std.process.spawn(io, .{
        .argv = &.{ "curl", "--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--output", partial, url },
        .stdin = .ignore,
    });
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) {
        log.err("{s}: curl failed", .{url});
        return error.DownloadFailed;
    }
    if (!try checksumIs(io, partial, sha256)) {
        log.err("{s}: wrong checksum, nothing installed", .{url});
        return error.WrongChecksum;
    }
    try cwd.rename(partial, cwd, path, io);
}

fn unpackMember(gpa: std.mem.Allocator, io: Io, archive: []const u8, member: []const u8, path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const partial = try std.fmt.allocPrint(gpa, "{s}.partial", .{path});
    defer gpa.free(partial);
    defer cwd.deleteFile(io, partial) catch {};
    const file = try cwd.openFile(io, archive, .{});
    defer file.close(io);
    var buffer: [1 << 16]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gzip: std.compress.flate.Decompress = .init(&reader.interface, .gzip, &window);
    var file_name: [std.fs.max_path_bytes]u8 = undefined;
    var link_name: [std.fs.max_path_bytes]u8 = undefined;
    var tar: std.tar.Iterator = .init(&gzip.reader, .{ .file_name_buffer = &file_name, .link_name_buffer = &link_name });
    while (try tar.next()) |entry| {
        if (entry.kind != .file or !std.mem.eql(u8, entry.name, member)) continue;
        {
            const out = try cwd.createFile(io, partial, .{});
            defer out.close(io);
            var out_buffer: [1 << 16]u8 = undefined;
            var writer = out.writer(io, &out_buffer);
            try tar.streamRemaining(entry, &writer.interface);
            try writer.interface.flush();
        }
        try cwd.rename(partial, cwd, path, io);
        return;
    }
    return error.NotInArchive;
}

fn checksumIs(io: Io, path: []const u8, want: []const u8) !bool {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [1 << 16]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    while (true) {
        const chunk = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        hash.update(chunk);
        reader.interface.toss(chunk.len);
    }
    const got = std.fmt.bytesToHex(hash.finalResult(), .lower);
    return std.mem.eql(u8, &got, want);
}

// ---- The question and the worker ----

const Flow = struct {
    task: Pool.Task,
    subject: *Subject,
    parent: ?*anyopaque,
    ctx: *anyopaque,
    on_start: *const fn (*anyopaque) void,
    on_done: *const fn (*anyopaque) void,
    failure: ?anyerror = null,
};

/// Asks, and downloads on a worker when told to: `on_start` then, `on_done` when it has finished.
pub fn ask(subject: *Subject, parent: ?*anyopaque, ctx: *anyopaque, on_start: *const fn (*anyopaque) void, on_done: *const fn (*anyopaque) void) void {
    const flow = subject.gpa.create(Flow) catch return;
    flow.* = .{ .task = .{ .run = run, .done = done }, .subject = subject, .parent = parent, .ctx = ctx, .on_start = on_start, .on_done = on_done };
    const dialog = gtk.gtk_alert_dialog_new("Download click-a-subject?");
    defer gtk.g_object_unref(dialog);
    gtk.gtk_alert_dialog_set_detail(dialog, question_detail);
    const buttons = [_:null]?[*:0]const u8{ "Not now", "Download" };
    gtk.gtk_alert_dialog_set_buttons(dialog, &buttons);
    gtk.gtk_alert_dialog_set_cancel_button(dialog, 0);
    gtk.gtk_alert_dialog_set_default_button(dialog, 1);
    gtk.gtk_alert_dialog_choose(dialog, parent, null, onAnswer, flow);
}

fn onAnswer(source: *anyopaque, result: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const flow: *Flow = @ptrCast(@alignCast(data.?));
    if (gtk.gtk_alert_dialog_choose_finish(source, result, null) != 1) {
        flow.subject.gpa.destroy(flow);
        return;
    }
    flow.on_start(flow.ctx);
    flow.subject.pool.submit(&flow.task, .urgent);
}

fn run(task: *Pool.Task) void {
    const flow: *Flow = @fieldParentPtr("task", task);
    const s = flow.subject;
    install(s.gpa, s.io, s.models_dir) catch |err| {
        flow.failure = err;
    };
}

fn done(task: *Pool.Task) void {
    const flow: *Flow = @fieldParentPtr("task", task);
    defer flow.subject.gpa.destroy(flow);
    if (flow.failure) |err| {
        log.err("download: {t}", .{err});
        const dialog = gtk.gtk_alert_dialog_new("The download didn't finish");
        defer gtk.g_object_unref(dialog);
        gtk.gtk_alert_dialog_set_detail(dialog, "Check the connection and click + Subject to try again.");
        gtk.gtk_alert_dialog_show(dialog, flow.parent);
    }
    flow.on_done(flow.ctx);
}

test "a file's checksum is checked" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = "abc" });
    const path = try tmp.dir.realPathFileAlloc(testing.io, "f", testing.allocator);
    defer testing.allocator.free(path);
    try testing.expect(try checksumIs(testing.io, path, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
    try testing.expect(!try checksumIs(testing.io, path, "580f5fb648ea1062c0aabc26217aed56921985f03f0cbbd852bba81d760cc749"));
}
