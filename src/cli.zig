const std = @import("std");
const pattern_mod = @import("pattern.zig");
const Pattern = pattern_mod.Pattern;
const grinders = @import("grinders/mod.zig");
const FoundKey = grinders.FoundKey;
const VulkanGrinder = grinders.VulkanGrinder;
const BATCH_SIZE = grinders.BATCH_SIZE;

pub fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) { printUsage(); return; }
    }
    var raw_pattern: []const u8 = undefined;
    var po: ?[]u8 = null;
    defer if (po) |p| allocator.free(p);
    if (args.len >= 2 and !std.mem.startsWith(u8, args[1], "--")) { raw_pattern = args[1]; }
    else { po = std.process.getEnvVarOwned(allocator, "MESHCORE_PATTERN") catch { printUsage(); return; }; raw_pattern = po.?; }
    const parsed = parsePatternWithCount(raw_pattern);
    const ps = parsed.pattern;
    const mc = parsed.count;
    validatePattern(ps) catch { return; };
    var tpg: ?usize = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--threads") or std.mem.eql(u8, args[i], "-t")) {
            if (i + 1 < args.len) { i += 1; tpg = std.fmt.parseInt(usize, args[i], 10) catch { std.debug.print("Error: Invalid --threads: {s}\n", .{args[i]}); return; }; }
            else { std.debug.print("Error: --threads requires a value\n", .{}); return; }
        }
    }
    try searchVanity(allocator, ps, mc, tpg);
}

fn searchVanity(allocator: std.mem.Allocator, ps: []const u8, mc: u32, tpg: ?usize) !void {
    std.debug.print("\n=== MeshCore Hex Prefix Search ===\nPattern: {s}\n", .{ps});
    if (mc > 1) std.debug.print("Finding: {d} matches\n", .{mc});
    std.debug.print("Using: Vulkan GPU\n", .{});
    const bc = ps.len / 2;
    const bits = @as(u64, bc) * 8;
    const exp: f64 = @floatFromInt(@as(u64, 1) << @intCast(bits));
    const p50: f64 = exp * 0.693;
    std.debug.print("\nDifficulty: {d} prefix bytes ({d} bits)\n  Expected: {d:.0}  P50: {d:.0}\n\n", .{ bc, bits, exp, p50 });
    var pattern = try Pattern.init(allocator, ps);
    defer pattern.deinit();
    var fc: u32 = 0;
    var grinder = try VulkanGrinder.init(allocator, pattern, tpg);
    defer grinder.deinit();
    grinder.setP50(p50);
    std.debug.print("Searching...\n", .{});
    while (fc < mc) {
        if (try grinder.searchBatch(BATCH_SIZE * 100)) |found| {
            fc += 1;
            std.debug.print("\n\n*** FOUND MATCH {d}/{d}! ***\n", .{ fc, mc });
            printFoundKey(found, ps);
            if (fc < mc) std.debug.print("\nContinuing...\n", .{});
        }
    }
    std.debug.print("\nDone! Found {d} key(s).\n", .{fc});
}

fn printFoundKey(found: FoundKey, ps: []const u8) void {
    std.debug.print("Public Key (hex):  ", .{});
    for (found.public_key) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\nPrivate Key (hex): ", .{});
    for (found.private_key) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\nAttempts: {d}\nPattern '{s}' matches prefix\n", .{ found.attempts, ps });
    saveKeyAsHex(found, ps);
}

fn saveKeyAsHex(found: FoundKey, ps: []const u8) void {
    const al = std.heap.page_allocator;
    var sh: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&sh, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ found.public_key[0],found.public_key[1],found.public_key[2],found.public_key[3],found.public_key[4],found.public_key[5],found.public_key[6],found.public_key[7] }) catch return;
    const fnm = std.fmt.allocPrint(al, "meshcore_{s}_{s}.key", .{ ps, &sh }) catch { std.debug.print("Warning: filename error\n", .{}); return; };
    defer al.free(fnm);
    const file = std.fs.cwd().createFile(fnm, .{}) catch { std.debug.print("Warning: save error\n", .{}); return; };
    defer file.close();
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    for (found.public_key) |b| { w.print("{x:0>2}", .{b}) catch return; }
    w.writeByte('\n') catch return;
    for (found.private_key) |b| { w.print("{x:0>2}", .{b}) catch return; }
    w.writeByte('\n') catch return;
    _ = file.writeAll(fbs.getWritten()) catch return;
    std.debug.print("Saved: {s}\n", .{fnm});
}

const PVE = error{ InvalidCharacter, PatternTooLong };
fn validatePattern(ps: []const u8) PVE!void {
    if (ps.len > 64) { std.debug.print("Error: Pattern too long (max 64 hex chars)\n", .{}); return error.PatternTooLong; }
    if (ps.len % 2 != 0) { std.debug.print("Error: Even number of hex chars required\n", .{}); return error.InvalidCharacter; }
    for (ps, 0..) |c, i| { if (!std.ascii.isHex(c)) { std.debug.print("Error: Invalid hex char '{c}' at {d}\n", .{ c, i }); return error.InvalidCharacter; } }
}
fn parsePatternWithCount(input: []const u8) struct { pattern: []const u8, count: u32 } {
    var i: usize = input.len;
    while (i > 0) { i -= 1; if (input[i] == ':') { const cs = input[i+1..]; if (cs.len > 0) { const c = std.fmt.parseInt(u32, cs, 10) catch { return .{ .pattern = input, .count = 1 }; }; if (c > 0) return .{ .pattern = input[0..i], .count = c }; } break; } }
    return .{ .pattern = input, .count = 1 };
}
fn printUsage() void {
    std.debug.print(
        \\grincel — MeshCore Hex Prefix ID Generator (Vulkan GPU)
        \\
        \\Usage: grincel <hex-pattern>[:<count>] [options]
        \\   or: MESHCORE_PATTERN=<pattern> grincel
        \\
        \\Options:
        \\  -h, --help       Show this help
        \\  -t, --threads N  Workgroup threads (default: 64)
        \\
        \\Pattern: hex chars (0-9,a-f,A-F), even length
        \\  Example: 1337cafe matches public keys starting with 0x1337cafe...
        \\
        \\Output: meshcore_<pattern>_<id>.key (hex format)
        \\
        \\Examples:
        \\  grincel 1337cafe       # Find key with 1337cafe prefix
        \\  grincel deadbeef:5     # Find 5 keys
        \\  grincel aabb -t 128    # Custom workgroup size
        \\
    , .{});
}
