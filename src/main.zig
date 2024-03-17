/// Note: for json parsing, missing fields need default values
///
const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const stdin = std.io.getStdIn();
    var in_buf_rdr = std.io.bufferedReader(stdin.reader());
    var r = in_buf_rdr.reader();
    var in_buf: [4096]u8 = undefined;
    const bytes_read = try r.readAll(&in_buf);
    const in_bytes = in_buf[0..bytes_read];
    const in_json = try std.json.parseFromSliceLeaky(Program, alloc, in_bytes, .{});

    const transformed_bril = in_json;

    const stdout = std.io.getStdOut();
    var out_buf_wtr = std.io.bufferedWriter(stdout.writer());
    const w = out_buf_wtr.writer();
    try std.json.stringify(transformed_bril, .{ .emit_null_optional_fields = false }, w);
    try out_buf_wtr.flush();
}

const Program = struct {
    functions: []Function,
};

const Function = struct {
    name: []const u8,
    args: ?[]const []const u8 = null,
    type: ?[]const u8 = null,
    instrs: []Code,
};

const Code = union(enum) {
    Instruction: Instruction,
    Label: Label,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        return try jsonParseFromValue(allocator, try std.json.innerParse(std.json.Value, allocator, source, options), options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
        switch (source) {
            .object => |object| {
                if (object.contains("label")) {
                    const label = try std.json.innerParseFromValue(Label, allocator, source, options);
                    return Code{ .Label = label };
                } else {
                    const instr = try std.json.innerParseFromValue(Instruction, allocator, source, options);
                    return Code{ .Instruction = instr };
                }
            },
            else => return error.UnexpectedToken,
        }
    }
};

const Label = struct {
    label: []const u8,
};

const Instruction = struct {
    op: []const u8,
    dest: ?[]const u8 = null,
    type: ?[]const u8 = null,
    args: ?[]const []const u8 = null,
    funcs: ?[]const []const u8 = null,
    labels: ?[]const []const u8 = null,
    value: ?Value = null, // for Constant
};

const Value = union(enum) {
    bool: bool,
    int: i64,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        return try jsonParseFromValue(allocator, try std.json.innerParse(std.json.Value, allocator, source, options), options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
        _ = allocator;
        _ = options;
        switch (source) {
            .bool => |b| return Value{ .bool = b },
            .integer => |i| return Value{ .int = i },
            else => return error.UnexpectedToken,
        }
    }
};
