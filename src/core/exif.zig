//! The original's EXIF block, carried into an export byte for byte. libvips rewrites EXIF through
//! libexif, which cuts Olympus maker notes from 17 KB to 144 bytes; patching in place keeps the
//! block's size, so every offset (the maker note's own included) stays valid.
//! Patched: orientation (the pixels are upright), pixel size, colour space, the embedded
//! thumbnail dropped (it shows the unedited photo), and GPS when asked.
const std = @import("std");

pub const header = "Exif\x00\x00";

pub const Patch = struct {
    width: u32,
    height: u32,
    // EXIF ColorSpace: 1 sRGB, 0xFFFF uncalibrated (P3).
    colour_space: u16,
    keep_gps: bool = true,
};

const Tag = enum(u16) {
    orientation = 0x0112,
    exif_ifd = 0x8769,
    gps_ifd = 0x8825,
    colour_space = 0xA001,
    pixel_x = 0xA002,
    pixel_y = 0xA003,
    thumbnail_offset = 0x0201,
    thumbnail_length = 0x0202,
    _,
};

const short = 3;
const long = 4;
const type_sizes = [_]u8{ 0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8 };

const Tiff = struct {
    bytes: []u8,
    endian: std.builtin.Endian,

    fn u16At(t: Tiff, at: usize) !u16 {
        if (at + 2 > t.bytes.len) return error.BadExif;
        return std.mem.readInt(u16, t.bytes[at..][0..2], t.endian);
    }

    fn u32At(t: Tiff, at: usize) !u32 {
        if (at + 4 > t.bytes.len) return error.BadExif;
        return std.mem.readInt(u32, t.bytes[at..][0..4], t.endian);
    }

    fn put16(t: Tiff, at: usize, v: u16) void {
        std.mem.writeInt(u16, t.bytes[at..][0..2], v, t.endian);
    }

    fn put32(t: Tiff, at: usize, v: u32) void {
        std.mem.writeInt(u32, t.bytes[at..][0..4], v, t.endian);
    }

    fn count(t: Tiff, ifd: usize) !u16 {
        const n = try t.u16At(ifd);
        if (ifd + 2 + @as(usize, n) * 12 + 4 > t.bytes.len) return error.BadExif;
        return n;
    }

    fn entry(t: Tiff, ifd: usize, tag: Tag) !?usize {
        const n = try t.count(ifd);
        for (0..n) |i| {
            const at = ifd + 2 + i * 12;
            if (try t.u16At(at) == @intFromEnum(tag)) return at;
        }
        return null;
    }

    fn nextIfd(t: Tiff, ifd: usize) !usize {
        return ifd + 2 + @as(usize, try t.count(ifd)) * 12;
    }

    // Where an entry's value lives: inside the entry when it fits in 4 bytes, else at its offset.
    fn valueSpan(t: Tiff, at: usize) !struct { usize, usize } {
        const ty = try t.u16At(at + 2);
        const n = try t.u32At(at + 4);
        const size = @as(usize, if (ty < type_sizes.len) type_sizes[ty] else 1) * n;
        if (size <= 4) return .{ at + 8, size };
        const off = try t.u32At(at + 8);
        if (off + size > t.bytes.len) return error.BadExif;
        return .{ off, size };
    }

    fn setNumber(t: Tiff, at: usize, v: u32) void {
        if (v <= 0xFFFF and (t.u16At(at + 2) catch 0) == short) {
            t.put16(at + 8, @intCast(v));
            return;
        }
        // A LONG fits the entry's own value field too.
        t.put16(at + 2, long);
        t.put32(at + 4, 1);
        t.put32(at + 8, v);
    }

    fn zero(t: Tiff, at: usize, len: usize) void {
        @memset(t.bytes[at..][0..len], 0);
    }

    // Blanks an IFD and every value it points to.
    fn wipeIfd(t: Tiff, ifd: usize) !void {
        const n = try t.count(ifd);
        for (0..n) |i| {
            const at = ifd + 2 + i * 12;
            const start, const len = try t.valueSpan(at);
            if (start != at + 8) t.zero(start, len);
        }
        t.zero(ifd, 2 + @as(usize, n) * 12 + 4);
    }

    // Takes an entry out of an IFD: the rest move up, the next-IFD offset with them.
    fn remove(t: Tiff, ifd: usize, at: usize) !void {
        const n = try t.count(ifd);
        const end = ifd + 2 + @as(usize, n) * 12 + 4;
        std.mem.copyForwards(u8, t.bytes[at .. end - 12], t.bytes[at + 12 .. end]);
        t.zero(end - 12, 12);
        t.put16(ifd, n - 1);
    }
};

/// The export's EXIF block: the original's (`exif-data`, with or without the "Exif\0\0" header),
/// patched. Returns the TIFF part, without the header.
pub fn prepare(gpa: std.mem.Allocator, original: []const u8, patch: Patch) ![]u8 {
    const tiff_bytes = if (std.mem.startsWith(u8, original, header)) original[header.len..] else original;
    if (tiff_bytes.len < 8) return error.BadExif;
    const endian: std.builtin.Endian = if (std.mem.eql(u8, tiff_bytes[0..2], "II")) .little else if (std.mem.eql(u8, tiff_bytes[0..2], "MM")) .big else return error.BadExif;
    const t: Tiff = .{ .bytes = try gpa.dupe(u8, tiff_bytes), .endian = endian };
    errdefer gpa.free(t.bytes);
    if (try t.u16At(2) != 42) return error.BadExif;
    const ifd0 = try t.u32At(4);

    if (try t.entry(ifd0, .orientation)) |at| t.setNumber(at, 1);
    if (try t.entry(ifd0, .exif_ifd)) |at| {
        const sub = try t.u32At(at + 8);
        if (try t.entry(sub, .pixel_x)) |e| t.setNumber(e, patch.width);
        if (try t.entry(sub, .pixel_y)) |e| t.setNumber(e, patch.height);
        if (try t.entry(sub, .colour_space)) |e| t.setNumber(e, patch.colour_space);
    }

    const next_at = try t.nextIfd(ifd0);
    const ifd1 = try t.u32At(next_at);
    if (ifd1 != 0) {
        const off = if (try t.entry(ifd1, .thumbnail_offset)) |e| try t.u32At(e + 8) else 0;
        const len = if (try t.entry(ifd1, .thumbnail_length)) |e| try t.u32At(e + 8) else 0;
        if (off != 0 and off + len <= t.bytes.len) t.zero(off, len);
        try t.wipeIfd(ifd1);
        t.put32(next_at, 0);
    }

    if (!patch.keep_gps) if (try t.entry(ifd0, .gps_ifd)) |at| {
        try t.wipeIfd(try t.u32At(at + 8));
        try t.remove(ifd0, at);
    };
    return t.bytes;
}

/// A JPEG with the EXIF block as its first segment. `jpeg` must carry no EXIF of its own.
pub fn intoJpeg(gpa: std.mem.Allocator, jpeg: []const u8, tiff: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, jpeg, "\xff\xd8")) return error.NotJpeg;
    const len = 2 + header.len + tiff.len;
    if (len > 0xFFFF) return error.ExifTooLarge;
    var out: std.ArrayList(u8) = try .initCapacity(gpa, jpeg.len + len + 2);
    out.appendSliceAssumeCapacity("\xff\xd8\xff\xe1");
    out.appendSliceAssumeCapacity(&std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(len))));
    out.appendSliceAssumeCapacity(header);
    out.appendSliceAssumeCapacity(tiff);
    out.appendSliceAssumeCapacity(jpeg[2..]);
    return out.toOwnedSlice(gpa);
}

/// A PNG with the EXIF block as an eXIf chunk, right after IHDR (it must come before IDAT).
pub fn intoPng(gpa: std.mem.Allocator, png: []const u8, tiff: []const u8) ![]u8 {
    const signature = "\x89PNG\r\n\x1a\n";
    if (!std.mem.startsWith(u8, png, signature) or png.len < 33) return error.NotPng;
    const ihdr_end = signature.len + 8 + 13 + 4;
    var out: std.ArrayList(u8) = try .initCapacity(gpa, png.len + tiff.len + 12);
    out.appendSliceAssumeCapacity(png[0..ihdr_end]);
    out.appendSliceAssumeCapacity(&std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(tiff.len))));
    var crc: std.hash.Crc32 = .init();
    crc.update("eXIf");
    crc.update(tiff);
    out.appendSliceAssumeCapacity("eXIf");
    out.appendSliceAssumeCapacity(tiff);
    out.appendSliceAssumeCapacity(&std.mem.toBytes(std.mem.nativeToBig(u32, crc.final())));
    out.appendSliceAssumeCapacity(png[ihdr_end..]);
    return out.toOwnedSlice(gpa);
}
