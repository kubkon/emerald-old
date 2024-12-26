pub fn flush(elf_file: *Elf) !void {
    const tracy = trace(@src());
    defer tracy.end();

    claimUnresolved(elf_file);
    try elf_file.addCommentString();
    try elf_file.finalizeMergeSections();
    try initSections(elf_file);
    try elf_file.sortSections();
    try elf_file.calcMergeSectionSizes();
    try calcSectionSizes(elf_file);

    allocateSections(elf_file, @sizeOf(elf.Elf64_Ehdr));

    elf_file.shoff = blk: {
        const shdr = elf_file.sections.items(.shdr)[elf_file.sections.len - 1];
        const offset = shdr.sh_offset + shdr.sh_size;
        break :blk mem.alignForward(u64, offset, @alignOf(elf.Elf64_Shdr));
    };

    state_log.debug("{}", .{elf_file.dumpState()});

    try writeAtoms(elf_file);
    try elf_file.writeMergeSections();
    try writeSyntheticSections(elf_file);
    try elf_file.writeShdrs();
    try writeHeader(elf_file);
}

fn claimUnresolved(elf_file: *Elf) void {
    const tracy = trace(@src());
    defer tracy.end();

    for (elf_file.objects.items) |index| {
        elf_file.getFile(index).?.object.claimUnresolvedRelocatable(elf_file);
    }
}

fn initSections(elf_file: *Elf) !void {
    const tracy = trace(@src());
    defer tracy.end();

    for (elf_file.objects.items) |index| {
        const object = elf_file.getFile(index).?.object;
        try object.initOutputSections(elf_file);
        try object.initRelaSections(elf_file);
    }

    for (elf_file.merge_sections.items) |*msec| {
        if (msec.finalized_subsections.items.len == 0) continue;
        try msec.initOutputSection(elf_file);
    }

    const needs_eh_frame = for (elf_file.objects.items) |index| {
        if (elf_file.getFile(index).?.object.cies.items.len > 0) break true;
    } else false;
    if (needs_eh_frame) {
        elf_file.eh_frame_sect_index = try elf_file.addSection(.{
            .name = try elf_file.insertShString(".eh_frame"),
            .flags = elf.SHF_ALLOC,
            .type = elf.SHT_PROGBITS,
            .addralign = @alignOf(u64),
        });
        const rela_shndx = try elf_file.addSection(.{
            .name = try elf_file.insertShString(".rela.eh_frame"),
            .type = elf.SHT_RELA,
            .flags = elf.SHF_INFO_LINK,
            .entsize = @sizeOf(elf.Elf64_Rela),
            .addralign = @alignOf(elf.Elf64_Rela),
        });
        elf_file.sections.items(.rela_shndx)[elf_file.eh_frame_sect_index.?] = rela_shndx;
    }

    try initComdatGroups(elf_file);
    try elf_file.initSymtab();
    try elf_file.initShStrtab();
}

fn initComdatGroups(elf_file: *Elf) !void {
    const gpa = elf_file.base.allocator;

    for (elf_file.objects.items) |index| {
        const object = elf_file.getFile(index).?.object;
        for (object.comdat_groups.items, 0..) |cg, cg_index| {
            if (!cg.alive) continue;
            const cg_sec = try elf_file.comdat_group_sections.addOne(gpa);
            cg_sec.* = .{
                .shndx = try elf_file.addSection(.{
                    .name = try elf_file.insertShString(".group"),
                    .type = elf.SHT_GROUP,
                    .entsize = @sizeOf(u32),
                    .addralign = @alignOf(u32),
                }),
                .cg_ref = .{ .index = @intCast(cg_index), .file = index },
            };
        }
    }
}

fn calcSectionSizes(elf_file: *Elf) !void {
    const tracy = trace(@src());
    defer tracy.end();

    for (
        elf_file.sections.items(.shdr),
        elf_file.sections.items(.atoms),
        elf_file.sections.items(.rela_shndx),
    ) |*shdr, atoms, rela_shndx| {
        if (atoms.items.len == 0) continue;

        const rela_shdr = if (rela_shndx != 0) &elf_file.sections.items(.shdr)[rela_shndx] else null;

        for (atoms.items) |ref| {
            const atom = elf_file.getAtom(ref).?;
            const alignment = try math.powi(u64, 2, atom.alignment);
            const offset = mem.alignForward(u64, shdr.sh_size, alignment);
            const padding = offset - shdr.sh_size;
            atom.value = @intCast(offset);
            shdr.sh_size += padding + atom.size;
            shdr.sh_addralign = @max(shdr.sh_addralign, alignment);

            if (rela_shdr) |rshdr| {
                rshdr.sh_size += rshdr.sh_entsize * atom.getRelocs(elf_file).len;
            }
        }
    }

    if (elf_file.eh_frame_sect_index) |index| {
        const shdr = &elf_file.sections.items(.shdr)[index];
        shdr.sh_size = try eh_frame.calcEhFrameSize(elf_file);
        shdr.sh_addralign = @alignOf(u64);

        const rela_shndx = elf_file.sections.items(.rela_shndx)[index];
        const rela_shdr = &elf_file.sections.items(.shdr)[rela_shndx];
        rela_shdr.sh_size = eh_frame.calcEhFrameRelocs(elf_file) * rela_shdr.sh_entsize;
    }

    try elf_file.calcSymtabSize();
    calcComdatGroupsSizes(elf_file);

    if (elf_file.shstrtab_sect_index) |index| {
        const shdr = &elf_file.sections.items(.shdr)[index];
        shdr.sh_size = elf_file.shstrtab.items.len;
    }
}

fn calcComdatGroupsSizes(elf_file: *Elf) void {
    const tracy = trace(@src());
    defer tracy.end();

    for (elf_file.comdat_group_sections.items) |cg| {
        const shdr = &elf_file.sections.items(.shdr)[cg.shndx];
        shdr.sh_size = cg.size(elf_file);
        shdr.sh_link = elf_file.symtab_sect_index.?;

        const sym = cg.getSymbol(elf_file);
        shdr.sh_info = sym.getOutputSymtabIndex(elf_file) orelse sym.getShndx(elf_file).?;
    }
}

fn allocateSections(elf_file: *Elf, base_offset: u64) void {
    const shdrs = elf_file.sections.slice().items(.shdr)[1..];
    var offset = base_offset;
    for (shdrs) |*shdr| {
        if (Elf.shdrIsZerofill(shdr.*)) continue;
        shdr.sh_offset = mem.alignForward(u64, offset, shdr.sh_addralign);
        offset = shdr.sh_offset + shdr.sh_size;
    }
}

fn writeAtoms(elf_file: *Elf) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const gpa = elf_file.base.allocator;
    const slice = elf_file.sections.slice();
    for (slice.items(.shdr), slice.items(.atoms)) |shdr, atoms| {
        if (atoms.items.len == 0) continue;
        if (shdr.sh_type == elf.SHT_NOBITS) continue;

        log.debug("writing atoms in '{s}' section", .{elf_file.getShString(shdr.sh_name)});

        var buffer = try gpa.alloc(u8, shdr.sh_size);
        defer gpa.free(buffer);

        const padding_byte: u8 = if (shdr.sh_type == elf.SHT_PROGBITS and
            shdr.sh_flags & elf.SHF_EXECINSTR != 0)
            0xcc // int3
        else
            0;
        @memset(buffer, padding_byte);

        for (atoms.items) |ref| {
            const atom = elf_file.getAtom(ref).?;
            assert(atom.flags.alive);
            const off: u64 = @intCast(atom.value);
            log.debug("writing ATOM({},'{s}') at offset 0x{x}", .{
                ref,
                atom.getName(elf_file),
                shdr.sh_offset + off,
            });

            // TODO decompress directly into provided buffer
            const out_code = buffer[off..][0..atom.size];
            const in_code = try atom.getCodeUncompressAlloc(elf_file);
            defer gpa.free(in_code);
            @memcpy(out_code, in_code);
        }

        try elf_file.base.file.pwriteAll(buffer, shdr.sh_offset);
    }
}

fn writeSyntheticSections(elf_file: *Elf) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const gpa = elf_file.base.allocator;

    const SortRelocs = struct {
        pub fn lessThan(ctx: void, lhs: elf.Elf64_Rela, rhs: elf.Elf64_Rela) bool {
            _ = ctx;
            return lhs.r_offset < rhs.r_offset;
        }
    };

    for (elf_file.sections.items(.rela_shndx), elf_file.sections.items(.atoms)) |rela_shndx, atoms| {
        if (atoms.items.len == 0) continue;

        const shdr = elf_file.sections.items(.shdr)[rela_shndx];
        if (shdr.sh_type == elf.SHT_NULL) continue;

        const num_relocs = @divExact(shdr.sh_size, shdr.sh_entsize);
        var relocs = try std.ArrayList(elf.Elf64_Rela).initCapacity(gpa, num_relocs);
        defer relocs.deinit();

        for (atoms.items) |ref| {
            const atom = elf_file.getAtom(ref) orelse continue;
            if (!atom.flags.alive) continue;
            try atom.writeRelocs(elf_file, &relocs);
        }
        assert(relocs.items.len == num_relocs);
        mem.sort(elf.Elf64_Rela, relocs.items, {}, SortRelocs.lessThan);

        log.debug("writing {s} from 0x{x} to 0x{x}", .{
            elf_file.getShString(shdr.sh_name),
            shdr.sh_offset,
            shdr.sh_offset + shdr.sh_size,
        });

        try elf_file.base.file.pwriteAll(mem.sliceAsBytes(relocs.items), shdr.sh_offset);
    }

    if (elf_file.eh_frame_sect_index) |shndx| {
        const shdr = elf_file.sections.items(.shdr)[shndx];
        var buffer = try std.ArrayList(u8).initCapacity(gpa, shdr.sh_size);
        defer buffer.deinit();
        try eh_frame.writeEhFrameRelocatable(elf_file, buffer.writer());

        log.debug("writing .eh_frame from 0x{x} to 0x{x}", .{
            shdr.sh_offset,
            shdr.sh_offset + shdr.sh_size,
        });

        assert(buffer.items.len == shdr.sh_size);
        try elf_file.base.file.pwriteAll(buffer.items, shdr.sh_offset);

        const rela_shndx = elf_file.sections.items(.rela_shndx)[shndx];
        const rela_shdr = elf_file.sections.items(.shdr)[rela_shndx];
        const num_relocs = @divExact(rela_shdr.sh_size, rela_shdr.sh_entsize);
        var relocs = try std.ArrayList(elf.Elf64_Rela).initCapacity(gpa, num_relocs);
        defer relocs.deinit();
        try eh_frame.writeEhFrameRelocs(elf_file, &relocs);
        assert(relocs.items.len == num_relocs);
        mem.sort(elf.Elf64_Rela, relocs.items, {}, SortRelocs.lessThan);

        log.debug("writing .rela.eh_frame from 0x{x} to 0x{x}", .{
            rela_shdr.sh_offset,
            rela_shdr.sh_offset + rela_shdr.sh_size,
        });

        try elf_file.base.file.pwriteAll(mem.sliceAsBytes(relocs.items), rela_shdr.sh_offset);
    }

    try writeComdatGroup(elf_file);
    try elf_file.writeSymtab();

    if (elf_file.shstrtab_sect_index) |shndx| {
        const shdr = elf_file.sections.items(.shdr)[shndx];
        try elf_file.base.file.pwriteAll(elf_file.shstrtab.items, shdr.sh_offset);
    }
}

fn writeComdatGroup(elf_file: *Elf) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const gpa = elf_file.base.allocator;

    for (elf_file.comdat_group_sections.items) |cgs| {
        const shdr = elf_file.sections.items(.shdr)[cgs.shndx];
        var buffer = try std.ArrayList(u8).initCapacity(gpa, shdr.sh_size);
        defer buffer.deinit();
        try cgs.write(elf_file, buffer.writer());

        log.debug("writing COMDAT group from 0x{x} to 0x{x}", .{
            shdr.sh_offset,
            shdr.sh_offset + shdr.sh_size,
        });

        assert(buffer.items.len == shdr.sh_size);
        try elf_file.base.file.pwriteAll(buffer.items, shdr.sh_offset);
    }
}

fn writeHeader(elf_file: *Elf) !void {
    var header = elf.Elf64_Ehdr{
        .e_ident = undefined,
        .e_type = .REL,
        .e_machine = switch (elf_file.options.cpu_arch.?) {
            .x86_64 => .X86_64,
            .aarch64 => .AARCH64,
            .riscv64 => .RISCV,
            else => unreachable,
        },
        .e_version = 1,
        .e_entry = 0,
        .e_phoff = 0,
        .e_shoff = elf_file.shoff,
        .e_flags = 0,
        .e_ehsize = @sizeOf(elf.Elf64_Ehdr),
        .e_phentsize = 0,
        .e_phnum = 0,
        .e_shentsize = @sizeOf(elf.Elf64_Shdr),
        .e_shnum = @as(u16, @intCast(elf_file.sections.items(.shdr).len)),
        .e_shstrndx = @intCast(elf_file.shstrtab_sect_index.?),
    };
    // Magic
    @memcpy(header.e_ident[0..4], "\x7fELF");
    // Class
    header.e_ident[4] = elf.ELFCLASS64;
    // Endianness
    header.e_ident[5] = elf.ELFDATA2LSB;
    // ELF version
    header.e_ident[6] = 1;
    // OS ABI, often set to 0 regardless of target platform
    // ABI Version, possibly used by glibc but not by static executables
    // padding
    @memset(header.e_ident[7..][0..9], 0);
    log.debug("writing ELF header {} at 0x{x}", .{ header, 0 });
    try elf_file.base.file.pwriteAll(mem.asBytes(&header), 0);
}

const assert = std.debug.assert;
const eh_frame = @import("eh_frame.zig");
const elf = std.elf;
const log = std.log.scoped(.elf);
const math = std.math;
const mem = std.mem;
const state_log = std.log.scoped(.state);
const std = @import("std");
const trace = @import("../tracy.zig").trace;

const Elf = @import("../Elf.zig");
