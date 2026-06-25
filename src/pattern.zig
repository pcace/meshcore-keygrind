const std = @import("std");

pub const Pattern = struct {
    raw: []const u8,
    pattern_bytes: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, hp: []const u8) !Pattern {
        if (hp.len > 64) return error.PatternTooLong;
        for (hp) |c| { _ = try parseNibble(c); }
        const bl = hp.len / 2;
        var pb = try allocator.alloc(u8, bl);
        var i: usize = 0;
        while (i + 1 < hp.len) : (i += 2) {
            pb[i/2] = (try parseNibble(hp[i]) << 4) | try parseNibble(hp[i+1]);
        }
        return .{ .raw = try allocator.dupe(u8, hp), .pattern_bytes = pb, .allocator = allocator };
    }
    pub fn deinit(self: *Pattern) void { self.allocator.free(self.raw); self.allocator.free(self.pattern_bytes); }
    pub fn matches(self: Pattern, pk: []const u8) bool {
        if (pk.len < self.pattern_bytes.len) return false;
        return std.mem.eql(u8, pk[0..self.pattern_bytes.len], self.pattern_bytes);
    }
};
fn parseNibble(c: u8) !u8 {
    return switch (c) { '0'...'9' => c-'0', 'a'...'f' => c-'a'+10, 'A'...'F' => c-'A'+10, else => error.InvalidHexChar };
}
