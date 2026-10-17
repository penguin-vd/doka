//! One photo's edits while the app runs: the recipe, its undo and redo, and Claude's change waiting
//! for Keep or Undo. The recipe is kept as its JSON; history is in memory only (SPEC.md).
const std = @import("std");
const core = @import("photo-core");
const Recipe = core.Recipe;

const Session = @This();

pub const max_history = 200;

gpa: std.mem.Allocator,
json: []u8,
undo_stack: std.ArrayList([]u8) = .empty,
redo_stack: std.ArrayList([]u8) = .empty,
// Edits that arrive with the same gesture (one slider drag) undo together.
gesture: u64 = 0,
// The recipe before Claude's change, and what Claude said it changed, until Keep or Undo.
claude_base: ?[]u8 = null,
claude_note: std.ArrayList(u8) = .empty,
// The undo stack's depth when Claude's change began.
claude_depth: usize = 0,

pub fn init(gpa: std.mem.Allocator, start: Recipe) !Session {
    return .{ .gpa = gpa, .json = try start.writeAlloc(gpa) };
}

pub fn deinit(s: *Session) void {
    s.gpa.free(s.json);
    for (s.undo_stack.items) |j| s.gpa.free(j);
    for (s.redo_stack.items) |j| s.gpa.free(j);
    s.undo_stack.deinit(s.gpa);
    s.redo_stack.deinit(s.gpa);
    if (s.claude_base) |b| s.gpa.free(b);
    s.claude_note.deinit(s.gpa);
}

/// The current recipe; its strings live in `arena`.
pub fn recipe(s: *const Session, arena: std.mem.Allocator) !Recipe {
    return Recipe.parse(arena, s.json);
}

pub const Change = struct {
    patch: std.json.Value,
    by: Recipe.By = .user,
    // 0: a change of its own.
    gesture: u64 = 0,
    // Seconds since the epoch, for updatedAt.
    now: u64,
    // Claude's one-line summary.
    note: []const u8 = "",
};

/// Applies a change; the new recipe's strings live in `arena`.
pub fn change(s: *Session, arena: std.mem.Allocator, ch: Change) !Recipe {
    var r = try Recipe.apply(arena, try s.recipe(arena), ch.patch);
    r.updatedBy = ch.by;
    var buf: [20]u8 = undefined;
    r.updatedAt = Recipe.timestamp(&buf, ch.now);
    const next = try r.writeAlloc(s.gpa);
    errdefer s.gpa.free(next);

    if (ch.by == .claude) {
        if (s.claude_base == null) {
            s.claude_base = try s.gpa.dupe(u8, s.json);
            s.claude_depth = s.undo_stack.items.len;
        }
        if (ch.note.len > 0) {
            if (s.claude_note.items.len > 0) try s.claude_note.appendSlice(s.gpa, "; ");
            try s.claude_note.appendSlice(s.gpa, ch.note);
        }
    }
    if (ch.gesture == 0 or ch.gesture != s.gesture) {
        try s.pushHistory(&s.undo_stack, s.json);
        for (s.redo_stack.items) |j| s.gpa.free(j);
        s.redo_stack.clearRetainingCapacity();
    } else {
        s.gpa.free(s.json);
    }
    s.gesture = ch.gesture;
    s.json = next;
    return Recipe.parse(arena, s.json);
}

fn pushHistory(s: *Session, stack: *std.ArrayList([]u8), json: []u8) !void {
    if (stack.items.len == max_history) s.gpa.free(stack.orderedRemove(0));
    try stack.append(s.gpa, json);
}

pub fn canUndo(s: *const Session) bool {
    return s.undo_stack.items.len > 0;
}

pub fn canRedo(s: *const Session) bool {
    return s.redo_stack.items.len > 0;
}

/// Steps back one change; false when there is none.
pub fn undo(s: *Session) !bool {
    const prev = s.undo_stack.pop() orelse return false;
    try s.pushHistory(&s.redo_stack, s.json);
    s.json = prev;
    s.gesture = 0;
    s.dropClaude();
    return true;
}

pub fn redo(s: *Session) !bool {
    const next = s.redo_stack.pop() orelse return false;
    try s.pushHistory(&s.undo_stack, s.json);
    s.json = next;
    s.gesture = 0;
    return true;
}

pub fn claudePending(s: *const Session) bool {
    return s.claude_base != null;
}

/// Keep: Claude's change stays, the bar goes.
pub fn keepClaude(s: *Session) void {
    s.dropClaude();
}

/// Undo on the bar: back to before Claude's change, however many steps it took, as one undo;
/// redo brings Claude's version back.
pub fn undoClaude(s: *Session) !bool {
    const base = s.claude_base orelse return false;
    s.claude_base = null;
    s.claude_note.clearRetainingCapacity();
    for (s.redo_stack.items) |j| s.gpa.free(j);
    s.redo_stack.clearRetainingCapacity();
    try s.pushHistory(&s.redo_stack, s.json);
    while (s.undo_stack.items.len > @min(s.claude_depth, s.undo_stack.items.len)) s.gpa.free(s.undo_stack.pop().?);
    s.json = base;
    s.gesture = 0;
    return true;
}

fn dropClaude(s: *Session) void {
    if (s.claude_base) |b| s.gpa.free(b);
    s.claude_base = null;
    s.claude_note.clearRetainingCapacity();
}
