value: i64 = 0,
out_shndx: u32 = 0,
symbols: std.AutoArrayHashMapUnmanaged(Elf.Ref, void) = .{},
output_symtab_ctx: Elf.SymtabCtx = .{},

pub fn deinit(thunk: *Thunk, allocator: Allocator) void {
    thunk.symbols.deinit(allocator);
}

pub fn size(thunk: Thunk, elf_file: *Elf) usize {
    const cpu_arch = elf_file.options.cpu_arch.?;
    return thunk.symbols.keys().len * trampolineSize(cpu_arch);
}

pub fn getAddress(thunk: Thunk, elf_file: *Elf) i64 {
    const shdr = elf_file.sections.items(.shdr)[thunk.out_shndx];
    return @as(i64, @intCast(shdr.sh_addr)) + thunk.value;
}

pub fn getTargetAddress(thunk: Thunk, ref: Elf.Ref, elf_file: *Elf) i64 {
    const cpu_arch = elf_file.options.cpu_arch.?;
    return thunk.getAddress(elf_file) + @as(i64, @intCast(thunk.symbols.getIndex(ref).? * trampolineSize(cpu_arch)));
}

pub fn isReachable(atom: *const Atom, rel: elf.Elf64_Rela, elf_file: *Elf) bool {
    return switch (elf_file.options.cpu_arch.?) {
        .aarch64 => Thunk.aarch64.isReachable(atom, rel, elf_file),
        .x86_64, .riscv64 => unreachable,
        else => @panic("unsupported arch"),
    };
}

/// A branch will need an extender if its target is larger than
/// `2^(jump_bits - 1) - margin` where margin is some arbitrary number.
pub fn maxAllowedDistance(cpu_arch: std.Target.Cpu.Arch) u32 {
    return switch (cpu_arch) {
        .aarch64 => 0x500_000,
        .x86_64, .riscv64 => unreachable,
        else => @panic("unhandled arch"),
    };
}

pub fn write(thunk: Thunk, elf_file: *Elf, writer: anytype) !void {
    switch (elf_file.options.cpu_arch.?) {
        .aarch64 => try aarch64.write(thunk, elf_file, writer),
        .x86_64, .riscv64 => unreachable,
        else => @panic("unhandled arch"),
    }
}

pub fn calcSymtabSize(thunk: *Thunk, elf_file: *Elf) void {
    if (elf_file.options.strip_all) return;

    thunk.output_symtab_ctx.nlocals = @as(u32, @intCast(thunk.symbols.keys().len));
    for (thunk.symbols.keys()) |ref| {
        const sym = elf_file.getSymbol(ref).?;
        thunk.output_symtab_ctx.strsize += @as(u32, @intCast(sym.getName(elf_file).len + "$thunk".len + 1));
    }
}

pub fn writeSymtab(thunk: Thunk, elf_file: *Elf) void {
    if (elf_file.options.strip_all) return;
    const cpu_arch = elf_file.options.cpu_arch.?;

    for (thunk.symbols.keys(), thunk.output_symtab_ctx.ilocal..) |ref, ilocal| {
        const sym = elf_file.getSymbol(ref).?;
        const st_name = @as(u32, @intCast(elf_file.strtab.items.len));
        elf_file.strtab.appendSliceAssumeCapacity(sym.getName(elf_file));
        elf_file.strtab.appendSliceAssumeCapacity("$thunk");
        elf_file.strtab.appendAssumeCapacity(0);
        elf_file.symtab.items[ilocal] = .{
            .st_name = st_name,
            .st_info = elf.STT_FUNC,
            .st_other = 0,
            .st_shndx = @intCast(thunk.out_shndx),
            .st_value = @intCast(thunk.getTargetAddress(ref, elf_file)),
            .st_size = trampolineSize(cpu_arch),
        };
    }
}

fn trampolineSize(cpu_arch: std.Target.Cpu.Arch) usize {
    return switch (cpu_arch) {
        .aarch64 => aarch64.trampoline_size,
        .x86_64, .riscv64 => unreachable,
        else => @panic("unhandled arch"),
    };
}

pub fn format(
    thunk: Thunk,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = thunk;
    _ = unused_fmt_string;
    _ = options;
    _ = writer;
    @compileError("do not format Thunk directly");
}

pub fn fmt(thunk: Thunk, elf_file: *Elf) std.fmt.Formatter(format2) {
    return .{ .data = .{
        .thunk = thunk,
        .elf_file = elf_file,
    } };
}

const FormatContext = struct {
    thunk: Thunk,
    elf_file: *Elf,
};

fn format2(
    ctx: FormatContext,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    _ = unused_fmt_string;
    const thunk = ctx.thunk;
    const elf_file = ctx.elf_file;
    try writer.print("@{x} : size({x})\n", .{ thunk.value, thunk.size(elf_file) });
    for (thunk.symbols.keys()) |ref| {
        const sym = elf_file.getSymbol(ref).?;
        try writer.print("  {} : {s} : @{x}\n", .{ ref, sym.getName(elf_file), sym.value });
    }
}

pub const Index = u32;

const aarch64 = struct {
    fn isReachable(atom: *const Atom, rel: elf.Elf64_Rela, elf_file: *Elf) bool {
        const r_type: elf.R_AARCH64 = @enumFromInt(rel.r_type());
        if (r_type != .CALL26 and r_type != .JUMP26) return true;
        const object = atom.getObject(elf_file);
        const target_ref = object.resolveSymbol(rel.r_sym(), elf_file);
        const target = elf_file.getSymbol(target_ref).?;
        if (target.flags.plt) return false;
        if (atom.out_shndx != target.shndx) return false;
        const target_atom = target.getAtom(elf_file).?;
        if (target_atom.value == -1) return false;
        const saddr = atom.getAddress(elf_file) + @as(i64, @intCast(rel.r_offset));
        const taddr = target.getAddress(.{}, elf_file);
        _ = math.cast(i28, taddr + rel.r_addend - saddr) orelse return false;
        return true;
    }

    fn write(thunk: Thunk, elf_file: *Elf, writer: anytype) !void {
        for (thunk.symbols.keys(), 0..) |ref, i| {
            const sym = elf_file.getSymbol(ref).?;
            const saddr = thunk.getAddress(elf_file) + @as(i64, @intCast(i * trampoline_size));
            const taddr = sym.getAddress(.{}, elf_file);
            const pages = try util.calcNumberOfPages(saddr, taddr);
            try writer.writeInt(u32, Instruction.adrp(.x16, pages).toU32(), .little);
            const off: u12 = @truncate(@as(u64, @bitCast(taddr)));
            try writer.writeInt(u32, Instruction.add(.x16, .x16, off, false).toU32(), .little);
            try writer.writeInt(u32, Instruction.br(.x16).toU32(), .little);
        }
    }

    const trampoline_size = 3 * @sizeOf(u32);

    const util = @import("../aarch64.zig");
    const Instruction = util.Instruction;
};

const assert = std.debug.assert;
const elf = std.elf;
const log = std.log.scoped(.elf);
const math = std.math;
const mem = std.mem;
const std = @import("std");

const Allocator = mem.Allocator;
const Atom = @import("Atom.zig");
const Elf = @import("../Elf.zig");
const Symbol = @import("Symbol.zig");
const Thunk = @This();
