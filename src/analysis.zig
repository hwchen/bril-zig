const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringMap = std.json.ArrayHashMap; // Needed to get json serialization

const bril = @import("bril.zig");

// To make sure that block index labels are always formatted the same.
const BLOCK_INDEX_LABEL_FORMAT = "{d}";

const Block = []bril.Instruction;
const BasicBlocks = struct {
    blocks: []Block,
    // if there's no label, then the implied label is the index in blocks
    blk_to_lbl: IntStringMap,
    lbl_to_blk: StringMap(usize),

    // thin wrapper, to make it serializable to json
    const IntStringMap = struct {
        map: std.AutoHashMapUnmanaged(usize, []const u8) = std.AutoHashMapUnmanaged(usize, []const u8){},

        pub fn jsonStringify(self: @This(), jws: anytype) !void {
            var buf: [32]u8 = undefined; //32 chars should be plenty for numeric label?
            try jws.beginObject();
            var it = self.map.iterator();
            while (it.next()) |kv| {
                const k = try fmt.bufPrint(&buf, BLOCK_INDEX_LABEL_FORMAT, .{kv.key_ptr.*});
                try jws.objectField(k);
                try jws.write(kv.value_ptr.*);
            }
            try jws.endObject();
        }
    };
};
const ProgramBasicBlocks = struct {
    functions: StringMap(BasicBlocks),
};

pub fn genBasicBlocks(program: bril.Program, alloc: Allocator) !ProgramBasicBlocks {
    var fbb = StringMap(BasicBlocks){};
    for (program.functions) |func| {
        var blocks = ArrayList(Block).init(alloc);
        var blk_to_lbl = BasicBlocks.IntStringMap{};
        var lbl_to_blk = StringMap(usize){};
        var block = ArrayList(bril.Instruction).init(alloc);
        for (func.instrs, 0..) |code, code_idx| {
            switch (code) {
                .Label => |lbl| {
                    // if label comes after the first instruction, and if previous block ended in non-terminal
                    // append the block before starting a new one.
                    // If it's the first instruction, or block before label ended in a terminal, the previous
                    // block will be empty.
                    if (code_idx != 0 and block.items.len != 0) {
                        try blocks.append(try block.toOwnedSlice());
                        block = ArrayList(bril.Instruction).init(alloc);
                    }
                    try blk_to_lbl.map.put(alloc, blocks.items.len, lbl.label);
                    try lbl_to_blk.map.put(alloc, lbl.label, blocks.items.len);
                },
                .Instruction => |instr| {
                    // Don't need to generate label for block, it's just the index in blocks
                    try block.append(instr);
                    if (instr.op.isTerminal()) {
                        try blocks.append(try block.toOwnedSlice());
                        block = ArrayList(bril.Instruction).init(alloc);
                    }
                },
            }
        }
        // Don't append again if the last instruction was a terminal, which already appends block
        if (block.items.len != 0) try blocks.append(try block.toOwnedSlice());
        try fbb.map.put(alloc, func.name, BasicBlocks{ .blocks = try blocks.toOwnedSlice(), .blk_to_lbl = blk_to_lbl, .lbl_to_blk = lbl_to_blk });
    }
    return ProgramBasicBlocks{ .functions = fbb };
}

pub const ControlFlowGraph = StringMap([]const []const u8);
pub const ProgramControlFlowGraph = StringMap(ControlFlowGraph);

pub fn controlFlowGraph(pbb: ProgramBasicBlocks, alloc: Allocator) !ProgramControlFlowGraph {
    var pcfg = ProgramControlFlowGraph{};
    const fnbb = pbb.functions.map;
    for (fnbb.keys(), fnbb.values()) |fn_name, bb| {
        var cfg = ControlFlowGraph{};
        const blks = bb.blocks;
        for (blks, 0..) |blk, blk_idx| {
            const blk_lbl = bb.blk_to_lbl.map.get(blk_idx) orelse
                try fmt.allocPrint(alloc, BLOCK_INDEX_LABEL_FORMAT, .{blk_idx});
            const last_instr = blk[blk.len - 1];
            const succs = switch (last_instr.op) {
                .jmp, .br => last_instr.labels.?,
                .ret => @as([]const []const u8, &.{}),
                else => if (blk_idx < blks.len - 1) blk: {
                    // is not the last block
                    const lbl = bb.blk_to_lbl.map.get(blk_idx + 1) orelse
                        try fmt.allocPrint(alloc, BLOCK_INDEX_LABEL_FORMAT, .{blk_idx + 1});
                    const out = try alloc.alloc([]const u8, 1);
                    out[0] = lbl;
                    break :blk out;
                } else @as([]const []const u8, &.{}),
            };
            try cfg.map.put(alloc, blk_lbl, succs);
        }
        try pcfg.map.put(alloc, fn_name, cfg);
    }
    return pcfg;
}
