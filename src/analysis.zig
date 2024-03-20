const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.json.ArrayHashMap; // Needed to get json serialization

const bril = @import("bril.zig");

const Block = []bril.Code;
const BasicBlocks = []Block;
const BlockMap = HashMap(Block);

// TODO handle funcs. (probably need a map of fn -> fnblocks)
pub fn basicBlocks(program: bril.Program, alloc: Allocator) !BasicBlocks {
    var blocks = ArrayList(Block).init(alloc);
    for (program.functions) |function| {
        var block = ArrayList(bril.Code).init(alloc);
        for (function.instrs) |code| {
            switch (code) {
                .Label => |_| {
                    try blocks.append(try block.toOwnedSlice());
                    block = ArrayList(bril.Code).init(alloc);
                    try block.append(code);
                },
                .Instruction => |instr| {
                    try block.append(code);
                    if (instr.op.isTerminal()) {
                        try blocks.append(try block.toOwnedSlice());
                        block = ArrayList(bril.Code).init(alloc);
                    }
                },
            }
        }
        // Don't append again if the last instruction was a terminal, which already appends block
        if (block.items.len != 0) {
            try blocks.append(try block.toOwnedSlice());
        }
    }

    return try blocks.toOwnedSlice();
}

pub fn blockMap(blocks: BasicBlocks, alloc: Allocator) !BlockMap {
    var block_map = BlockMap{};
    for (blocks, 0..) |block, i| {
        const first_code = block[0]; // Block cannot be empty
        switch (first_code) {
            .Label => |l| try block_map.map.put(alloc, l.label, block[1..]), // TODO slice to OwnedSlice ok?
            else => {
                const l = try std.fmt.allocPrint(alloc, "b{d:0>3}", .{i});
                try block_map.map.put(alloc, l, block);
            },
        }
    }
    return block_map;
}

pub const ControlFlowGraph = HashMap([]const []const u8);

pub fn controlFlowGraph(block_map: BlockMap, alloc: Allocator) !ControlFlowGraph {
    var cfg = ControlFlowGraph{};
    const labels = block_map.map.keys();
    const blocks = block_map.map.values();
    for (0..block_map.map.count()) |i| {
        const label = labels[i];
        const block = blocks[i];
        const last_instr = block[block.len - 1];
        const succ = switch (last_instr) {
            .Label => unreachable,
            // Note that we can assume that instr.labels only exists on control ops w/ labels (jmp, br)
            .Instruction => |instr| if (instr.op == .ret) continue else instr.labels orelse blk: {
                var out = ArrayList([]const u8).init(alloc);
                if (i <= block.len) {
                    try out.append(try std.fmt.allocPrint(alloc, "{s}", .{labels[i + 1]}));
                }
                break :blk try out.toOwnedSlice();
            },
        };

        try cfg.map.put(alloc, label, succ);
    }
    return cfg;
}
