const std = @import("std");
const pattern_mod = @import("../pattern.zig");
pub const Pattern = pattern_mod.Pattern;
pub const VulkanGrinder = @import("vulkan.zig").VulkanGrinder;

pub const BATCH_SIZE: usize = 65536;
pub const NUM_BUFFERS: usize = 3;
pub const PROGRESS_INTERVAL: u64 = 100000;

pub const FoundKey = struct {
    public_key: [32]u8,
    private_key: [64]u8,
    attempts: u64,
};

pub fn formatTimeToP50(ca: u64, p50: f64, rate: f64) void {
    if (rate <= 0) { std.debug.print("P50: --:--", .{}); return; }
    const af = @as(f64, @floatFromInt(ca));
    const rem = p50 - af;
    const secs = if (rem > 0) rem / rate else -rem / rate;
    const pfx: []const u8 = if (rem > 0) "P50: " else "P50: +";
    if (secs < 60) { std.debug.print("{s}{d:.0}s", .{ pfx, secs }); }
    else if (secs < 3600) { std.debug.print("{s}{d:.0}m", .{ pfx, secs / 60 }); }
    else if (secs < 86400) { std.debug.print("{s}{d:.0}h", .{ pfx, secs / 3600 }); }
    else { std.debug.print("{s}{d:.1}d", .{ pfx, secs / 86400 }); }
}

pub const GpuPatternConfig = extern struct {
    pattern_len: u32,
    pattern_bytes: [32]u8,
    pub fn fromPattern(pattern: Pattern) GpuPatternConfig {
        var c = GpuPatternConfig{ .pattern_len = @intCast(pattern.raw.len), .pattern_bytes = undefined };
        @memset(&c.pattern_bytes, 0);
        const cl = @min(pattern.pattern_bytes.len, 32);
        @memcpy(c.pattern_bytes[0..cl], pattern.pattern_bytes[0..cl]);
        return c;
    }
};

pub const GpuResultBuffer = extern struct {
    found: u32,
    thread_id: u32,
    public_key: [32]u8,
    private_key: [64]u8,
};
