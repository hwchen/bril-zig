const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringMap = std.json.ArrayHashMap; // Needed to get json serialization

const bril = @import("bril.zig");
const util = @import("util.zig");
const IntStringMap = util.IntStringMap;
const LABEL_FMT = util.BLOCK_INDEX_LABEL_FORMAT;

const Block = []bril.Instruction;
const BasicBlocks = struct {
    blocks: []Block,
    // if there's no label, then the implied label is the index in blocks
    blk_to_lbl: IntStringMap,
    lbl_to_blk: StringMap(usize),

    // Carried over from bril.Function so we don't lose info when converting back.
    name: []const u8,
    args: ?[]const bril.FunctionArg = null,
    type: ?bril.Type = null,

    pub fn toBril(bb: BasicBlocks, alloc: Allocator) !bril.Function {
        var instrs = ArrayList(bril.Code).init(alloc);
        for (bb.blocks, 0..) |block, blk_idx| {
            if (bb.blk_to_lbl.map.get(blk_idx)) |label| {
                try instrs.append(.{ .label = .{ .label = label } });
            }
            for (block) |instr| {
                try instrs.append(.{ .instruction = instr });
            }
        }
        return bril.Function{ .name = bb.name, .args = bb.args, .type = bb.type, .instrs = try instrs.toOwnedSlice() };
    }
};
const ProgramBasicBlocks = struct {
    functions: StringMap(BasicBlocks),

    pub fn toBril(pbb: ProgramBasicBlocks, alloc: Allocator) !bril.Program {
        var fns = ArrayList(bril.Function).init(alloc);
        const pbb_fns = pbb.functions.map;
        for (pbb_fns.values()) |bb| {
            try fns.append(try bb.toBril(alloc));
        }
        return bril.Program{ .functions = try fns.toOwnedSlice() };
    }
};

pub fn genBasicBlocks(program: bril.Program, alloc: Allocator) !ProgramBasicBlocks {
    var fbb = StringMap(BasicBlocks){};
    for (program.functions) |func| {
        var blocks = ArrayList(Block).init(alloc);
        var blk_to_lbl = IntStringMap{};
        var lbl_to_blk = StringMap(usize){};
        var block = ArrayList(bril.Instruction).init(alloc);
        for (func.instrs, 0..) |code, code_idx| {
            switch (code) {
                .label => |lbl| {
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
                .instruction => |instr| {
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
        try fbb.map.put(
            alloc,
            func.name,
            BasicBlocks{
                .blocks = try blocks.toOwnedSlice(),
                .blk_to_lbl = blk_to_lbl,
                .lbl_to_blk = lbl_to_blk,
                .name = func.name,
                .args = func.args,
                .type = func.type,
            },
        );
    }
    return ProgramBasicBlocks{ .functions = fbb };
}

pub const ControlFlowGraph = StringMap([]const []const u8);
pub const ProgramControlFlowGraph = StringMap(ControlFlowGraph);

pub fn controlFlowGraph(pbb: ProgramBasicBlocks, alloc: Allocator) !ProgramControlFlowGraph {
    var pcfg = ProgramControlFlowGraph{};
    const fnbb = pbb.functions.map;
    for (fnbb.values()) |bb| {
        var cfg = ControlFlowGraph{};
        const blks = bb.blocks;
        for (blks, 0..) |blk, blk_idx| {
            const blk_lbl = bb.blk_to_lbl.map.get(blk_idx) orelse
                try fmt.allocPrint(alloc, LABEL_FMT, .{blk_idx});
            const last_instr = blk[blk.len - 1];
            const succs = switch (last_instr.op) {
                .jmp, .br => last_instr.labels.?,
                .ret => @as([]const []const u8, &.{}),
                else => if (blk_idx < blks.len - 1) blk: {
                    // is not the last block
                    const lbl = bb.blk_to_lbl.map.get(blk_idx + 1) orelse
                        try fmt.allocPrint(alloc, LABEL_FMT, .{blk_idx + 1});
                    const out = try alloc.alloc([]const u8, 1);
                    out[0] = lbl;
                    break :blk out;
                } else @as([]const []const u8, &.{}),
            };
            try cfg.map.put(alloc, blk_lbl, succs);
        }
        try pcfg.map.put(alloc, bb.name, cfg);
    }
    return pcfg;
}

// Currently operations on basic blocks are mutable.
// Since size of slices only decrease, shouldn't have to allocate.
pub fn deadCodeEliminationGloballyUnused(pbb: *ProgramBasicBlocks, scratch_alloc: Allocator) !void {
    for (pbb.functions.map.values()) |bb| {
        var converged = false;
        while (!converged) {
            converged = true;
            var used = std.StringHashMap(void).init(scratch_alloc);
            defer used.deinit();
            // First loop over all instrs, to collect set of used args
            for (bb.blocks) |b| {
                for (b) |instr| {
                    if (instr.args) |args| for (args) |arg| {
                        try used.put(arg, {});
                    };
                }
            }
            // Second loop over instrs, if instr destination not in `used`, delete instr
            for (bb.blocks) |*instrs| {
                var i = instrs.len;
                while (i > 0) {
                    i -= 1;
                    if (instrs.*[i].dest) |dest| {
                        if (!used.contains(dest)) {
                            util.orderedRemoveSlice(bril.Instruction, instrs, i);
                            converged = false;
                        }
                    }
                }
            }
        }
    }
}

pub fn deadCodeEliminationLocallyKilled(pbb: *ProgramBasicBlocks, scratch_alloc: Allocator) !void {
    for (pbb.functions.map.values()) |bb| {
        for (bb.blocks) |*instrs| {
            var declared = std.StringHashMap(void).init(scratch_alloc);
            defer declared.deinit();
            var i = instrs.len;
            while (i > 0) {
                i -= 1;
                const instr = instrs.*[i];
                if (instr.args) |args| {
                    for (args) |arg| {
                        _ = declared.remove(arg);
                    }
                }

                if (instr.dest) |dest| {
                    if (declared.contains(dest)) {
                        util.orderedRemoveSlice(bril.Instruction, instrs, i);
                    } else {
                        try declared.put(dest, {});
                    }
                }
            }
        }
    }
}
