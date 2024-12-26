base: Ld,
options: Options,

dyld_info_cmd: macho.dyld_info_command = .{},
symtab_cmd: macho.symtab_command = .{},
dysymtab_cmd: macho.dysymtab_command = .{},
function_starts_cmd: macho.linkedit_data_command = .{ .cmd = .FUNCTION_STARTS },
data_in_code_cmd: macho.linkedit_data_command = .{ .cmd = .DATA_IN_CODE },
uuid_cmd: macho.uuid_command = .{
    .uuid = [_]u8{0} ** 16,
},
codesig_cmd: macho.linkedit_data_command = .{ .cmd = .CODE_SIGNATURE },

internal_object_index: ?File.Index = null,
objects: std.ArrayListUnmanaged(File.Index) = .{},
dylibs: std.ArrayListUnmanaged(File.Index) = .{},
files: std.MultiArrayList(File.Entry) = .{},
file_handles: std.ArrayListUnmanaged(File.Handle) = .{},

segments: std.ArrayListUnmanaged(macho.segment_command_64) = .{},
sections: std.MultiArrayList(Section) = .{},

resolver: SymbolResolver = .{},

/// This table will be populated after `scanRelocs` has run.
/// Key is symbol index.
undefs: std.AutoArrayHashMapUnmanaged(SymbolResolver.Index, UndefRefs) = .{},
undefs_mutex: std.Thread.Mutex = .{},

dupes: std.AutoArrayHashMapUnmanaged(SymbolResolver.Index, std.ArrayListUnmanaged(File.Index)) = .{},
dupes_mutex: std.Thread.Mutex = .{},

pagezero_seg_index: ?u8 = null,
text_seg_index: ?u8 = null,
linkedit_seg_index: ?u8 = null,
data_sect_index: ?u8 = null,
got_sect_index: ?u8 = null,
stubs_sect_index: ?u8 = null,
stubs_helper_sect_index: ?u8 = null,
la_symbol_ptr_sect_index: ?u8 = null,
tlv_ptr_sect_index: ?u8 = null,
eh_frame_sect_index: ?u8 = null,
unwind_info_sect_index: ?u8 = null,
objc_stubs_sect_index: ?u8 = null,

symtab: std.ArrayListUnmanaged(macho.nlist_64) = .{},
strtab: std.ArrayListUnmanaged(u8) = .{},
indsymtab: Indsymtab = .{},
got: GotSection = .{},
stubs: StubsSection = .{},
stubs_helper: StubsHelperSection = .{},
objc_stubs: ObjcStubsSection = .{},
la_symbol_ptr: LaSymbolPtrSection = .{},
tlv_ptr: TlvPtrSection = .{},
rebase: Rebase = .{},
bind: Bind = .{},
weak_bind: WeakBind = .{},
lazy_bind: LazyBind = .{},
export_trie: ExportTrie = .{},
unwind_info: UnwindInfo = .{},
data_in_code: DataInCode = .{},

thunks: std.ArrayListUnmanaged(Thunk) = .{},

has_tlv: AtomicBool = AtomicBool.init(false),
binds_to_weak: AtomicBool = AtomicBool.init(false),
weak_defines: AtomicBool = AtomicBool.init(false),
has_errors: AtomicBool = AtomicBool.init(false),

/// Atomic counter used only in relocatable (-r) mode when -x flag (strip locals)
/// was specified. See Object.stripLocalsRelocatable for usage.
strip_locals_counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

pub fn openPath(allocator: Allocator, options: Options, thread_pool: *ThreadPool) !*MachO {
    const file = try options.emit.directory.createFile(options.emit.sub_path, .{
        .truncate = true,
        .read = true,
        .mode = if (builtin.os.tag == .windows) 0 else if (options.relocatable) 0o666 else 0o777,
    });
    errdefer file.close();

    const self = try createEmpty(allocator, options, thread_pool);
    errdefer self.base.destroy();

    self.base.file = file;

    return self;
}

fn createEmpty(gpa: Allocator, options: Options, thread_pool: *ThreadPool) !*MachO {
    const self = try gpa.create(MachO);
    self.* = .{
        .base = .{
            .tag = .macho,
            .allocator = gpa,
            .file = undefined,
            .thread_pool = thread_pool,
        },
        .options = options,
    };
    return self;
}

pub fn deinit(self: *MachO) void {
    const gpa = self.base.allocator;

    for (self.file_handles.items) |file| {
        file.close();
    }
    self.file_handles.deinit(gpa);

    self.resolver.deinit(gpa);
    for (self.undefs.values()) |*val| {
        val.deinit(gpa);
    }
    self.undefs.deinit(gpa);
    for (self.dupes.values()) |*val| {
        val.deinit(gpa);
    }
    self.dupes.deinit(gpa);

    self.objects.deinit(gpa);
    self.dylibs.deinit(gpa);

    for (self.files.items(.tags), self.files.items(.data)) |tag, *data| switch (tag) {
        .null => {},
        .internal => data.internal.deinit(gpa),
        .object => data.object.deinit(gpa),
        .dylib => data.dylib.deinit(gpa),
    };
    self.files.deinit(gpa);

    self.segments.deinit(gpa);
    for (
        self.sections.items(.atoms),
        self.sections.items(.thunks),
        self.sections.items(.out),
        self.sections.items(.relocs),
    ) |*atoms, *th, *out, *relocs| {
        atoms.deinit(gpa);
        th.deinit(gpa);
        out.deinit(gpa);
        relocs.deinit(gpa);
    }
    self.sections.deinit(gpa);
    self.thunks.deinit(gpa);

    self.symtab.deinit(gpa);
    self.strtab.deinit(gpa);
    self.got.deinit(gpa);
    self.stubs.deinit(gpa);
    self.objc_stubs.deinit(gpa);
    self.tlv_ptr.deinit(gpa);
    self.rebase.deinit(gpa);
    self.bind.deinit(gpa);
    self.weak_bind.deinit(gpa);
    self.lazy_bind.deinit(gpa);
    self.export_trie.deinit(gpa);
    self.unwind_info.deinit(gpa);
    self.data_in_code.deinit(gpa);
}

pub fn flush(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const gpa = self.base.allocator;

    // Append empty string to string tables
    try self.strtab.append(gpa, 0);
    // Append null file
    try self.files.append(gpa, .null);

    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const syslibroot = self.options.syslibroot;

    // Resolve paths
    log.debug("library search dirs", .{});
    var lib_dirs = std.ArrayList([]const u8).init(arena);
    for (self.options.lib_dirs) |dir| {
        if (try resolveSearchDir(arena, dir, syslibroot)) |search_dir| {
            try lib_dirs.append(search_dir);
            log.debug("  {s}", .{dir});
        } else {
            self.base.warn("{s}: library search directory not found", .{dir});
        }
    }

    log.debug("framework search dirs", .{});
    var framework_dirs = std.ArrayList([]const u8).init(arena);
    for (self.options.framework_dirs) |dir| {
        if (try resolveSearchDir(arena, dir, syslibroot)) |search_dir| {
            try framework_dirs.append(search_dir);
            log.debug("  {s}", .{dir});
        } else {
            self.base.warn("{s}: framework search directory not found", .{dir});
        }
    }

    var resolved_objects = std.ArrayList(LinkObject).init(arena);
    try self.resolvePaths(arena, lib_dirs.items, framework_dirs.items, &resolved_objects);

    if (self.options.cpu_arch == null) {
        try self.inferCpuArchAndPlatform(resolved_objects.items);
    }

    if (self.options.platform == null) {
        // Check if we have already inferred a version from env vars.
        inline for (self.options.inferred_platform_versions) |platform| {
            if (platform.version.value > 0) {
                self.options.platform = .{ .platform = platform.platform, .version = platform.version };
                break;
            }
        }
    }

    if (self.options.sdk_version == null) {
        // First, try inferring SDK version from the SDK path if we have one.
        if (self.options.syslibroot) |path| {
            self.options.sdk_version = Options.inferSdkVersionFromSdkPath(path);
        }
        // Next, if platform has been worked out to be macOS but wasn't inferred from env vars,
        // do a syscall.
        if (self.options.sdk_version == null and self.options.platform != null) blk: {
            if ((comptime builtin.target.isDarwin()) and
                self.options.platform.?.platform == .MACOS and
                self.options.inferred_platform_versions[0].version.value == 0)
            {
                var ver_str: [100]u8 = undefined;
                var size: usize = 100;
                std.posix.sysctlbynameZ("kern.osrelease", &ver_str, &size, null, 0) catch break :blk;
                const kern_ver = Options.Version.parse(ver_str[0 .. size - 1]) orelse break :blk;
                // According to Apple, kernel major version is 4 ahead of x in 10.
                const minor = @as(u8, @truncate((kern_ver.value >> 16) - 4));
                self.options.sdk_version = Options.Version.new(10, minor, 0);
            }
        }
    }

    for (resolved_objects.items) |obj| {
        self.classifyInputFile(obj) catch |err| switch (err) {
            else => |e| {
                self.base.fatal("{s}: unexpected error occurred while parsing input file: {s}", .{
                    obj.path, @errorName(e),
                });
                return e;
            },
        };
    }

    try self.parseInputFiles();
    try self.parseDependentDylibs(arena, lib_dirs.items, framework_dirs.items);

    if (!self.options.relocatable) {
        const index = @as(File.Index, @intCast(try self.files.addOne(gpa)));
        self.files.set(index, .{ .internal = .{ .index = index } });
        self.internal_object_index = index;
        const object = self.getInternalObject().?;
        try object.init(gpa);
        try object.initSymbols(self);
    }

    try self.resolveSymbols();

    if (self.options.relocatable) return relocatable.flush(self);

    try self.convertTentativeDefsAndResolveSpecialSymbols();
    try self.dedupLiterals();

    if (self.options.dead_strip) {
        try dead_strip.gcAtoms(self);
    }

    try self.checkDuplicates();

    self.markImportsAndExports();
    self.deadStripDylibs();

    for (self.dylibs.items, 1..) |index, ord| {
        const dylib = self.getFile(index).?.dylib;
        dylib.ordinal = @intCast(ord);
    }

    self.claimUnresolved();
    try self.scanRelocs();
    try self.initOutputSections();
    try self.initSyntheticSections();
    try self.sortSections();
    try self.addAtomsToSections();
    try self.calcSectionSizes();

    try self.generateUnwindInfo();

    try self.initSegments();
    try self.allocateSections();
    self.allocateSegments();
    self.allocateSyntheticSymbols();

    state_log.debug("{}", .{self.dumpState()});

    try self.resizeSections();
    try self.writeSectionsAndUpdateLinkeditSizes();

    try self.writeSectionsToFile();
    try self.allocateLinkeditSegment();
    try self.writeLinkeditSectionsToFile();

    var codesig: ?CodeSignature = if (self.requiresCodeSig()) blk: {
        // Preallocate space for the code signature.
        // We need to do this at this stage so that we have the load commands with proper values
        // written out to the file.
        // The most important here is to have the correct vm and filesize of the __LINKEDIT segment
        // where the code signature goes into.
        var codesig = CodeSignature.init(self.getPageSize());
        codesig.code_directory.ident = std.fs.path.basename(self.options.emit.sub_path);
        if (self.options.entitlements) |path| try codesig.addEntitlements(gpa, path);
        try self.writeCodeSignaturePadding(&codesig);
        break :blk codesig;
    } else null;
    defer if (codesig) |*csig| csig.deinit(gpa);

    self.getLinkeditSegment().vmsize = mem.alignForward(
        u64,
        self.getLinkeditSegment().filesize,
        self.getPageSize(),
    );

    const ncmds, const sizeofcmds, const uuid_cmd_offset = try self.writeLoadCommands();
    try self.writeHeader(ncmds, sizeofcmds);
    try self.writeUuid(uuid_cmd_offset, self.requiresCodeSig());

    if (codesig) |*csig| {
        try self.writeCodeSignature(csig); // code signing always comes last
        const emit = self.options.emit;
        try invalidateKernelCache(emit.directory, emit.sub_path);
    }
}

fn resolveSearchDir(
    arena: Allocator,
    dir: []const u8,
    syslibroot: ?[]const u8,
) !?[]const u8 {
    var candidates = std.ArrayList([]const u8).init(arena);

    if (fs.path.isAbsolute(dir)) {
        if (syslibroot) |root| {
            const common_dir = if (builtin.os.tag == .windows) blk: {
                // We need to check for disk designator and strip it out from dir path so
                // that we can concat dir with syslibroot.
                const disk_designator = fs.path.diskDesignatorWindows(dir);

                if (mem.indexOf(u8, dir, disk_designator)) |where| {
                    break :blk dir[where + disk_designator.len ..];
                }

                break :blk dir;
            } else dir;
            const full_path = try fs.path.join(arena, &[_][]const u8{ root, common_dir });
            try candidates.append(full_path);
        }
    }

    try candidates.append(dir);

    for (candidates.items) |candidate| {
        // Verify that search path actually exists
        if (try accessPath(candidate)) return candidate;
    }

    return null;
}

fn resolvePathsFirst(arena: Allocator, dirs: []const []const u8, path: []const u8) !?[]const u8 {
    for (dirs) |dir| {
        for (&[_][]const u8{ ".tbd", ".dylib", ".a" }) |ext| {
            const with_ext = try std.fmt.allocPrint(arena, "{s}{s}", .{ path, ext });
            const full_path = try std.fs.path.join(arena, &[_][]const u8{ dir, with_ext });
            if (try accessPath(full_path)) return full_path;
        }
    }
    return null;
}

fn resolveDylibsFirst(arena: Allocator, dirs: []const []const u8, path: []const u8) !?[]const u8 {
    for (dirs) |dir| {
        for (&[_][]const u8{ ".tbd", ".dylib" }) |ext| {
            const with_ext = try std.fmt.allocPrint(arena, "{s}{s}", .{ path, ext });
            const full_path = try std.fs.path.join(arena, &[_][]const u8{ dir, with_ext });
            if (try accessPath(full_path)) return full_path;
        }
    }
    for (dirs) |dir| {
        const with_ext = try std.fmt.allocPrint(arena, "{s}.a", .{path});
        const full_path = try std.fs.path.join(arena, &[_][]const u8{ dir, with_ext });
        if (try accessPath(full_path)) return full_path;
    }
    return null;
}

fn accessPath(path: []const u8) !bool {
    std.fs.cwd().access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}

fn resolveLib(
    self: *MachO,
    arena: Allocator,
    search_dirs: []const []const u8,
    name: []const u8,
) !?[]const u8 {
    const path = try std.fmt.allocPrint(arena, "lib{s}", .{name});
    const search_strategy = self.options.search_strategy orelse .paths_first;
    switch (search_strategy) {
        .paths_first => return try resolvePathsFirst(arena, search_dirs, path),
        .dylibs_first => return try resolveDylibsFirst(arena, search_dirs, path),
    }
}

fn resolveFramework(
    self: *MachO,
    arena: Allocator,
    search_dirs: []const []const u8,
    name: []const u8,
) !?[]const u8 {
    const prefix = try std.fmt.allocPrint(arena, "{s}.framework", .{name});
    const path = try std.fs.path.join(arena, &[_][]const u8{ prefix, name });
    const search_strategy = self.options.search_strategy orelse .paths_first;
    switch (search_strategy) {
        .paths_first => return try resolvePathsFirst(arena, search_dirs, path),
        .dylibs_first => return try resolveDylibsFirst(arena, search_dirs, path),
    }
}

fn resolvePaths(
    self: *MachO,
    arena: Allocator,
    lib_dirs: []const []const u8,
    framework_dirs: []const []const u8,
    resolved_objects: *std.ArrayList(LinkObject),
) !void {
    const tracy = trace(@src());
    defer tracy.end();

    var has_resolve_error = false;
    try resolved_objects.ensureTotalCapacityPrecise(self.options.positionals.len);
    for (self.options.positionals) |obj| {
        const full_path = blk: {
            switch (obj.tag) {
                .obj => {
                    var buffer: [fs.max_path_bytes]u8 = undefined;
                    const full_path = std.fs.realpath(obj.path, &buffer) catch |err| switch (err) {
                        error.FileNotFound => {
                            self.base.fatal("file not found {}", .{obj});
                            has_resolve_error = true;
                            continue;
                        },
                        else => |e| return e,
                    };
                    break :blk try arena.dupe(u8, full_path);
                },
                .lib => {
                    const full_path = (try self.resolveLib(arena, lib_dirs, obj.path)) orelse {
                        const err = try self.base.addErrorWithNotes(lib_dirs.len);
                        defer err.unlock();
                        try err.addMsg("library not found for {}", .{obj});
                        for (lib_dirs) |dir| try err.addNote("tried {s}", .{dir});
                        has_resolve_error = true;
                        continue;
                    };
                    break :blk full_path;
                },
                .framework => {
                    const full_path = (try self.resolveFramework(arena, framework_dirs, obj.path)) orelse {
                        const err = try self.base.addErrorWithNotes(framework_dirs.len);
                        defer err.unlock();
                        try err.addMsg("framework not found for {}", .{obj});
                        for (framework_dirs) |dir| try err.addNote("tried {s}", .{dir});
                        has_resolve_error = true;
                        continue;
                    };
                    break :blk full_path;
                },
            }
        };
        resolved_objects.appendAssumeCapacity(.{
            .path = full_path,
            .tag = obj.tag,
            .needed = obj.needed,
            .weak = obj.weak,
            .hidden = obj.hidden,
            .reexport = obj.reexport,
            .must_link = obj.must_link,
        });
    }

    if (has_resolve_error) return error.ResolveFailed;
}

fn inferCpuArchAndPlatform(self: *MachO, resolved_objects: []const LinkObject) !void {
    const tracy = trace(@src());
    defer tracy.end();

    var has_parse_error = false;
    var platforms = std.ArrayList(struct { std.Target.Cpu.Arch, ?Options.Platform }).init(self.base.allocator);
    defer platforms.deinit();
    try platforms.ensureUnusedCapacity(resolved_objects.len);

    for (resolved_objects) |obj| {
        self.inferCpuArchAndPlatformInObject(obj, &platforms) catch |err| {
            has_parse_error = true;
            switch (err) {
                error.UnhandledCpuArch => {}, // already reported
                else => |e| {
                    self.base.fatal("{s}: unexpected error occurred while parsing input file: {s}", .{
                        obj.path, @errorName(e),
                    });
                    return e;
                },
            }
        };
    }
    if (has_parse_error) return error.ParseFailed;
    if (platforms.items.len == 0) {
        self.base.fatal("could not infer CPU architecture", .{});
        return error.InferCpuFailed;
    }

    self.options.cpu_arch = platforms.items[0][0];
    self.options.platform = for (platforms.items) |platform| {
        if (platform[1]) |p| break p;
    } else null;
}

fn inferCpuArchAndPlatformInObject(self: *MachO, obj: LinkObject, platforms: anytype) !void {
    const gpa = self.base.allocator;

    const file = try std.fs.cwd().openFile(obj.path, .{});
    defer file.close();

    const header = file.reader().readStruct(macho.mach_header_64) catch return;
    if (header.filetype != macho.MH_OBJECT) return;

    const cpu_arch: std.Target.Cpu.Arch = switch (header.cputype) {
        macho.CPU_TYPE_ARM64 => .aarch64,
        macho.CPU_TYPE_X86_64 => .x86_64,
        else => {
            self.base.fatal("{s}: unhandled CPU architecture: {d}", .{
                obj.path,
                header.cputype,
            });
            return error.UnhandledCpuArch;
        },
    };

    const out = platforms.addOneAssumeCapacity();
    out.* = .{ cpu_arch, null };

    const cmds_buffer = try gpa.alloc(u8, header.sizeofcmds);
    defer gpa.free(cmds_buffer);
    const amt = file.reader().readAll(cmds_buffer) catch return;
    if (amt != header.sizeofcmds) return;

    var it = macho.LoadCommandIterator{
        .ncmds = header.ncmds,
        .buffer = cmds_buffer,
    };
    // An input object file may have more than one build LC but we take the first one and bail.
    out[1] = while (it.next()) |cmd| switch (cmd.cmd()) {
        .BUILD_VERSION,
        .VERSION_MIN_MACOSX,
        .VERSION_MIN_IPHONEOS,
        .VERSION_MIN_TVOS,
        .VERSION_MIN_WATCHOS,
        => break Options.Platform.fromLoadCommand(cmd),
        else => {},
    } else null;
}

fn classifyInputFile(self: *MachO, obj: LinkObject) !void {
    const tracy = trace(@src());
    defer tracy.end();

    log.debug("parsing positional {}", .{obj});

    const file = try std.fs.cwd().openFile(obj.path, .{});
    const fh = try self.addFileHandle(file);
    var buffer: [Archive.SARMAG]u8 = undefined;

    const fat_arch: ?fat.Arch = try self.parseFatFile(obj, file);
    const offset = if (fat_arch) |fa| fa.offset else 0;

    if (readMachHeader(file, offset) catch null) |h| blk: {
        if (h.magic != macho.MH_MAGIC_64) break :blk;
        switch (h.filetype) {
            macho.MH_OBJECT => try self.addObject(obj, fh, offset),
            macho.MH_DYLIB => if (self.options.cpu_arch) |_| {
                _ = try self.addDylib(obj, fh, offset, true);
            } else {
                self.base.fatal("{s}: ignoring library as no architecture specified", .{obj.path});
            },
            else => self.base.fatal("{s}: unsupported input file type: {x}", .{ obj.path, h.filetype }),
        }
        return;
    }
    if (readArMagic(file, offset, &buffer) catch null) |ar_magic| blk: {
        if (!mem.eql(u8, ar_magic, Archive.ARMAG)) break :blk;
        if (self.options.cpu_arch) |_| {
            try self.addArchive(obj, fh, fat_arch);
        } else {
            self.base.fatal("{s}: ignoring library as no architecture specified", .{obj.path});
        }
        return;
    }
    blk: {
        if (self.options.cpu_arch == null) {
            self.base.fatal("{s}: ignoring library as no architecture specified", .{obj.path});
        } else {
            const lib_stub = LibStub.loadFromFile(self.base.allocator, file) catch break :blk;
            _ = try self.addTbd(obj, lib_stub, true);
        }
        return;
    }

    self.base.fatal("unknown filetype for positional argument: '{s}'", .{obj.path});
}

fn parseFatFile(self: *MachO, obj: LinkObject, file: std.fs.File) !?fat.Arch {
    const fat_h = fat.readFatHeader(file) catch return null;
    if (fat_h.magic != macho.FAT_MAGIC and fat_h.magic != macho.FAT_MAGIC_64) return null;
    var fat_archs_buffer: [2]fat.Arch = undefined;
    const fat_archs = try fat.parseArchs(file, fat_h, &fat_archs_buffer);
    const fat_arch = if (self.options.cpu_arch) |cpu_arch| arch: {
        for (fat_archs) |arch| {
            if (arch.tag == cpu_arch) break :arch arch;
        }
        self.base.fatal("{s}: missing arch in universal file: expected {s}", .{ obj.path, @tagName(cpu_arch) });
        return error.MissingArch;
    } else {
        const err = try self.base.addErrorWithNotes(1 + fat_archs.len);
        defer err.unlock();
        try err.addMsg("{s}: ignoring universal file as no architecture specified", .{obj.path});
        for (fat_archs) |arch| {
            try err.addNote("universal file built for {s}", .{@tagName(arch.tag)});
        }
        return error.NoArchSpecified;
    };
    return fat_arch;
}

pub fn readMachHeader(file: std.fs.File, offset: usize) !macho.mach_header_64 {
    var buffer: [@sizeOf(macho.mach_header_64)]u8 = undefined;
    const nread = try file.preadAll(&buffer, offset);
    if (nread != buffer.len) return error.InputOutput;
    const hdr = @as(*align(1) const macho.mach_header_64, @ptrCast(&buffer)).*;
    return hdr;
}

pub fn readArMagic(file: std.fs.File, offset: usize, buffer: *[Archive.SARMAG]u8) ![]const u8 {
    const nread = try file.preadAll(buffer, offset);
    if (nread != buffer.len) return error.InputOutput;
    return buffer[0..Archive.SARMAG];
}

fn addObject(self: *MachO, obj: LinkObject, handle: File.HandleIndex, offset: u64) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const gpa = self.base.allocator;
    const mtime: u64 = mtime: {
        const file = self.getFileHandle(handle);
        const stat = file.stat() catch break :mtime 0;
        break :mtime @as(u64, @intCast(@divFloor(stat.mtime, 1_000_000_000)));
    };

    const index = @as(File.Index, @intCast(try self.files.addOne(gpa)));
    self.files.set(index, .{ .object = .{
        .offset = offset,
        .path = try gpa.dupe(u8, obj.path),
        .file_handle = handle,
        .index = index,
        .mtime = mtime,
    } });
    try self.objects.append(gpa, index);
}

fn parseInputFiles(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();

    var wg: WaitGroup = .{};

    {
        wg.reset();
        defer wg.wait();

        for (self.objects.items) |index| {
            self.base.thread_pool.spawnWg(&wg, parseObjectWorker, .{ self, index });
        }
        for (self.dylibs.items) |index| {
            self.base.thread_pool.spawnWg(&wg, parseDylibWorker, .{ self, index });
        }
    }

    if (self.has_errors.swap(false, .seq_cst)) return error.FlushFailed;
}

fn parseObjectWorker(self: *MachO, index: File.Index) void {
    const object = self.getFile(index).?.object;
    object.parse(self) catch |err| {
        switch (err) {
            error.ParseFailed => {}, // reported
            else => |e| self.base.fatal("{}: unxexpected error occurred while parsing input file: {s}", .{
                object.fmtPath(),
                @errorName(e),
            }),
        }
        _ = self.has_errors.swap(true, .seq_cst);
    };
}

fn addArchive(self: *MachO, obj: LinkObject, handle: File.HandleIndex, fat_arch: ?fat.Arch) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const gpa = self.base.allocator;

    var archive = Archive{};
    defer archive.deinit(gpa);
    try archive.parse(self, obj.path, handle, fat_arch);

    for (archive.objects.items) |extracted| {
        const index = @as(File.Index, @intCast(try self.files.addOne(gpa)));
        self.files.set(index, .{ .object = extracted });
        const object = &self.files.items(.data)[index].object;
        object.index = index;
        object.alive = obj.must_link or obj.needed or self.options.all_load;
        object.hidden = obj.hidden;
        try self.objects.append(gpa, index);
    }
}

const DylibOpts = struct {
    syslibroot: ?[]const u8,
    id: ?Dylib.Id = null,
    needed: bool = false,
    weak: bool = false,
    reexport: bool = false,
};

fn addDylib(self: *MachO, obj: LinkObject, handle: File.HandleIndex, offset: u64, explicit: bool) anyerror!File.Index {
    const tracy = trace(@src());
    defer tracy.end();

    const gpa = self.base.allocator;
    const index = @as(File.Index, @intCast(try self.files.addOne(gpa)));
    self.files.set(index, .{ .dylib = .{
        .offset = offset,
        .file_handle = handle,
        .path = obj.path,
        .index = index,
        .needed = obj.needed,
        .weak = obj.weak,
        .reexport = obj.reexport,
        .explicit = explicit,
        .umbrella = index,
    } });
    try self.dylibs.append(gpa, index);

    return index;
}

fn addTbd(self: *MachO, obj: LinkObject, lib_stub: LibStub, explicit: bool) anyerror!File.Index {
    const tracy = trace(@src());
    defer tracy.end();

    const gpa = self.base.allocator;

    const index = @as(File.Index, @intCast(try self.files.addOne(gpa)));
    self.files.set(index, .{ .dylib = .{
        .offset = 0,
        .lib_stub = lib_stub,
        .path = obj.path,
        .index = index,
        .needed = obj.needed,
        .weak = obj.weak,
        .reexport = obj.reexport,
        .explicit = explicit,
        .umbrella = index,
    } });
    try self.dylibs.append(gpa, index);

    return index;
}

fn parseDylibWorker(self: *MachO, index: File.Index) void {
    const dylib = self.getFile(index).?.dylib;
    dylib.parse(self) catch |err| {
        switch (err) {
            error.ParseFailed => {}, // reported already
            else => |e| self.base.fatal("{s}: unexpected error occurred while parsing input file: {s}", .{
                dylib.path,
                @errorName(e),
            }),
        }
        _ = self.has_errors.swap(true, .seq_cst);
    };
}

/// According to ld64's manual, public (i.e., system) dylibs/frameworks are hoisted into the final
/// image unless overriden by -no_implicit_dylibs.
fn isHoisted(self: *MachO, install_name: []const u8) bool {
    if (self.options.no_implicit_dylibs) return true;
    if (std.fs.path.dirname(install_name)) |dirname| {
        if (mem.startsWith(u8, dirname, "/usr/lib")) return true;
        if (eatPrefix(dirname, "/System/Library/Frameworks/")) |path| {
            const basename = std.fs.path.basename(install_name);
            if (mem.indexOfScalar(u8, path, '.')) |index| {
                if (mem.eql(u8, basename, path[0..index])) return true;
            }
        }
    }
    return false;
}

fn parseDependentDylibs(
    self: *MachO,
    arena: Allocator,
    lib_dirs: []const []const u8,
    framework_dirs: []const []const u8,
) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const gpa = self.base.allocator;

    if (self.dylibs.items.len == 0) return;

    log.debug("parsing dependent dylibs aka reexports", .{});

    // TODO handle duplicate dylibs - it is not uncommon to have the same dylib loaded multiple times
    // in which case we should track that and return File.Index immediately instead re-parsing paths.

    var index: usize = 0;
    while (index < self.dylibs.items.len) : (index += 1) {
        const dylib_index = self.dylibs.items[index];

        var dependents = std.ArrayList(File.Index).init(gpa);
        defer dependents.deinit();
        try dependents.ensureTotalCapacityPrecise(self.getFile(dylib_index).?.dylib.dependents.items.len);

        const is_weak = self.getFile(dylib_index).?.dylib.weak;
        for (self.getFile(dylib_index).?.dylib.dependents.items) |id| {
            // We will search for the dependent dylibs in the following order:
            // 1. Basename is in search lib directories or framework directories
            // 2. If name is an absolute path, search as-is optionally prepending a syslibroot
            //    if specified.
            // 3. If name is a relative path, substitute @rpath, @loader_path, @executable_path with
            //    dependees list of rpaths, and search there.
            // 4. Finally, just search the provided relative path directly in CWD.
            const full_path = full_path: {
                {
                    const stem = std.fs.path.stem(id.name);
                    if (try self.resolveFramework(arena, framework_dirs, stem)) |full_path| break :full_path full_path;

                    // Library
                    const lib_name = eatPrefix(stem, "lib") orelse stem;
                    if (try self.resolveLib(arena, lib_dirs, lib_name)) |full_path| break :full_path full_path;
                }

                if (std.fs.path.isAbsolute(id.name)) {
                    // If the path is absolute, we need to check the path as-is as well as prefixed
                    // with syslibroot if it was specified. Next, we also need to consider all possible
                    // combinations of extensions: ["", ".tbd", ".dylib", "<ext>"].
                    var paths: [2]?[]const u8 = .{
                        if (self.options.syslibroot) |root|
                            try std.fs.path.join(arena, &.{ root, id.name })
                        else
                            null,
                        id.name,
                    };
                    for (&paths) |maybe_path| {
                        const path = maybe_path orelse continue;
                        const curr_ext = std.fs.path.extension(path);
                        const without_ext = if (curr_ext.len > 0) path[0 .. path.len - curr_ext.len] else path;
                        for (&[_][]const u8{ "", ".tbd", ".dylib", curr_ext }) |ext| {
                            const full_path = try std.fmt.allocPrint(arena, "{s}{s}", .{ without_ext, ext });
                            if (try accessPath(full_path)) break :full_path full_path;
                        }
                    }
                }

                if (eatPrefix(id.name, "@rpath/")) |path| {
                    const dylib = self.getFile(dylib_index).?.dylib;
                    for (self.getFile(dylib.umbrella).?.dylib.rpaths.keys()) |rpath| {
                        const prefix = eatPrefix(rpath, "@loader_path/") orelse rpath;
                        const rel_path = try std.fs.path.join(arena, &.{ prefix, path });
                        var buffer: [std.fs.max_path_bytes]u8 = undefined;
                        const full_path = std.fs.realpath(rel_path, &buffer) catch continue;
                        break :full_path try arena.dupe(u8, full_path);
                    }
                } else if (eatPrefix(id.name, "@loader_path/")) |_| {
                    return self.base.fatal("{s}: TODO handle install_name '{s}'", .{
                        self.getFile(dylib_index).?.dylib.path, id.name,
                    });
                } else if (eatPrefix(id.name, "@executable_path/")) |_| {
                    return self.base.fatal("{s}: TODO handle install_name '{s}'", .{
                        self.getFile(dylib_index).?.dylib.path, id.name,
                    });
                }

                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                if (std.fs.realpath(id.name, &buffer)) |full_path| {
                    break :full_path try arena.dupe(u8, full_path);
                } else |_| {
                    dependents.appendAssumeCapacity(0);
                    continue;
                }
            };
            const link_obj = LinkObject{
                .path = full_path,
                .tag = .obj,
                .weak = is_weak,
            };
            const file = try std.fs.cwd().openFile(link_obj.path, .{});
            const fh = try self.addFileHandle(file);

            const fat_arch = try self.parseFatFile(link_obj, file);
            const offset = if (fat_arch) |fa| fa.offset else 0;

            const file_index = file_index: {
                if (readMachHeader(file, offset) catch null) |h| blk: {
                    if (h.magic != macho.MH_MAGIC_64) break :blk;
                    switch (h.filetype) {
                        macho.MH_DYLIB => break :file_index try self.addDylib(link_obj, fh, offset, false),
                        else => break :file_index @as(File.Index, 0),
                    }
                }
                const lib_stub = LibStub.loadFromFile(gpa, file) catch break :file_index @as(File.Index, 0);
                break :file_index try self.addTbd(link_obj, lib_stub, false);
            };
            dependents.appendAssumeCapacity(file_index);
        }

        const dylib = self.getFile(dylib_index).?.dylib;
        for (dylib.dependents.items, dependents.items) |id, file_index| {
            if (self.getFile(file_index)) |file| {
                const dep_dylib = file.dylib;
                try dep_dylib.parse(self); // TODO in parallel
                dep_dylib.hoisted = self.isHoisted(id.name);
                dep_dylib.umbrella = dylib.umbrella;
                if (!dep_dylib.hoisted) {
                    const umbrella = dep_dylib.getUmbrella(self);
                    for (dep_dylib.exports.items(.name), dep_dylib.exports.items(.flags)) |off, flags| {
                        // TODO rethink this entire algorithm
                        try umbrella.addExport(gpa, dep_dylib.getString(off), flags);
                    }
                    try umbrella.rpaths.ensureUnusedCapacity(gpa, dep_dylib.rpaths.keys().len);
                    for (dep_dylib.rpaths.keys()) |rpath| {
                        umbrella.rpaths.putAssumeCapacity(try gpa.dupe(u8, rpath), {});
                    }
                }
            } else self.base.fatal("{s}: unable to resolve dependency {s}", .{ dylib.getUmbrella(self).path, id.name });
        }
    }
}

/// When resolving symbols, we approach the problem similarly to `mold`.
/// 1. Resolve symbols across all objects (including those preemptively extracted archives).
/// 2. Resolve symbols across all shared objects.
/// 3. Mark live objects (see `MachO.markLive`)
/// 4. Reset state of all resolved globals since we will redo this bit on the pruned set.
/// 5. Remove references to dead objects/shared objects
/// 6. Re-run symbol resolution on pruned objects and shared objects sets.
pub fn resolveSymbols(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // Resolve symbols on the set of all objects and shared objects (even if some are unneeded).
    for (self.objects.items) |index| try self.getFile(index).?.resolveSymbols(self);
    for (self.dylibs.items) |index| try self.getFile(index).?.resolveSymbols(self);
    if (self.getInternalObject()) |obj| try obj.resolveSymbols(self);

    // Mark live objects.
    self.markLive();

    // Reset state of all globals after marking live objects.
    self.resolver.reset();

    // Prune dead objects.
    var i: usize = 0;
    while (i < self.objects.items.len) {
        const index = self.objects.items[i];
        if (!self.getFile(index).?.object.alive) {
            _ = self.objects.orderedRemove(i);
            self.files.items(.data)[index].object.deinit(self.base.allocator);
            self.files.set(index, .null);
        } else i += 1;
    }

    // Re-resolve the symbols.
    for (self.objects.items) |index| try self.getFile(index).?.resolveSymbols(self);
    for (self.dylibs.items) |index| try self.getFile(index).?.resolveSymbols(self);
    if (self.getInternalObject()) |obj| try obj.resolveSymbols(self);

    // Merge symbol visibility
    for (self.objects.items) |index| self.getFile(index).?.object.mergeSymbolVisibility(self);
}

fn markLive(self: *MachO) void {
    const tracy = trace(@src());
    defer tracy.end();

    for (self.objects.items) |index| {
        const object = self.getFile(index).?.object;
        if (object.alive) object.markLive(self);
    }
    if (self.getInternalObject()) |obj| obj.markLive(self);
}

fn deadStripDylibs(self: *MachO) void {
    const tracy = trace(@src());
    defer tracy.end();

    for (self.dylibs.items) |index| {
        self.getFile(index).?.dylib.markReferenced(self);
    }

    var i: usize = 0;
    while (i < self.dylibs.items.len) {
        const index = self.dylibs.items[i];
        if (!self.getFile(index).?.dylib.isAlive(self)) {
            _ = self.dylibs.orderedRemove(i);
            self.files.items(.data)[index].dylib.deinit(self.base.allocator);
            self.files.set(index, .null);
        } else i += 1;
    }
}

fn convertTentativeDefsAndResolveSpecialSymbols(self: *MachO) !void {
    var wg: WaitGroup = .{};

    {
        wg.reset();
        defer wg.wait();
        for (self.objects.items) |index| {
            self.base.thread_pool.spawnWg(&wg, convertTentativeDefinitionsWorker, .{ self, index });
        }
        if (self.getInternalObject()) |obj| {
            self.base.thread_pool.spawnWg(&wg, resolveSpecialSymbolsWorker, .{ self, obj });
        }
    }

    if (self.has_errors.swap(false, .seq_cst)) return error.FlushFailed;
}

fn convertTentativeDefinitionsWorker(self: *MachO, index: File.Index) void {
    const tracy = trace(@src());
    defer tracy.end();

    const object = self.getFile(index).?.object;
    object.convertTentativeDefinitions(self) catch |err| {
        self.base.fatal("{s}: unexpected error occurred while converting tentative symbols into defined symbols: {s}", .{
            object.fmtPath(),
            @errorName(err),
        });
        _ = self.has_errors.swap(true, .seq_cst);
    };
}

fn resolveSpecialSymbolsWorker(self: *MachO, obj: *InternalObject) void {
    const tracy = trace(@src());
    defer tracy.end();

    obj.resolveBoundarySymbols(self) catch |err| {
        self.base.fatal("unexpected error occurred while resolving boundary symbols: {s}", .{
            @errorName(err),
        });
        _ = self.has_errors.swap(true, .seq_cst);
        return;
    };
    obj.resolveObjcMsgSendSymbols(self) catch |err| {
        self.base.fatal("unexpected error occurred while resolving ObjC msgsend stubs: {s}", .{
            @errorName(err),
        });
        _ = self.has_errors.swap(true, .seq_cst);
    };
}

fn markImportsAndExports(self: *MachO) void {
    const tracy = trace(@src());
    defer tracy.end();
    for (self.objects.items) |index| {
        self.getFile(index).?.markImportsAndExports(self);
    }
    if (self.getInternalObject()) |obj| {
        obj.asFile().markImportsAndExports(self);
    }
}

fn initOutputSections(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();
    for (self.objects.items) |index| {
        try self.getFile(index).?.initOutputSections(self);
    }
    if (self.getInternalObject()) |object| {
        try object.asFile().initOutputSections(self);
    }
    self.data_sect_index = self.getSectionByName("__DATA", "__data") orelse
        try self.addSection("__DATA", "__data", .{});
}

pub fn dedupLiterals(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const gpa = self.base.allocator;
    var lp: LiteralPool = .{};
    defer lp.deinit(gpa);

    for (self.objects.items) |index| {
        try self.getFile(index).?.object.resolveLiterals(&lp, self);
    }
    if (self.getInternalObject()) |object| {
        try object.resolveLiterals(&lp, self);
    }

    var wg: WaitGroup = .{};
    {
        wg.reset();
        defer wg.wait();
        for (self.objects.items) |index| {
            self.base.thread_pool.spawnWg(&wg, File.dedupLiterals, .{ self.getFile(index).?, lp, self });
        }
        if (self.getInternalObject()) |object| {
            self.base.thread_pool.spawnWg(&wg, File.dedupLiterals, .{ object.asFile(), lp, self });
        }
    }

    if (self.has_errors.swap(false, .seq_cst)) return error.FlushFailed;
}

fn claimUnresolved(self: *MachO) void {
    for (self.objects.items) |index| {
        self.getFile(index).?.object.claimUnresolved(self);
    }
}

fn checkDuplicates(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();

    var wg: WaitGroup = .{};
    {
        wg.reset();
        defer wg.wait();
        for (self.objects.items) |index| {
            self.base.thread_pool.spawnWg(&wg, checkDuplicatesWorker, .{ self, self.getFile(index).? });
        }
        if (self.getInternalObject()) |object| {
            self.base.thread_pool.spawnWg(&wg, checkDuplicatesWorker, .{ self, object.asFile() });
        }
    }

    if (self.has_errors.swap(false, .seq_cst)) return error.FlushFailed;

    try self.reportDuplicates();
}

fn checkDuplicatesWorker(self: *MachO, file: File) void {
    const tracy = trace(@src());
    defer tracy.end();
    file.checkDuplicates(self) catch |err| {
        self.base.fatal("{}: failed to check duplicate definitions: {s}", .{
            file.fmtPath(),
            @errorName(err),
        });
        _ = self.has_errors.swap(true, .seq_cst);
    };
}

fn reportDuplicates(self: *MachO) error{ HasDuplicates, OutOfMemory }!void {
    const tracy = trace(@src());
    defer tracy.end();

    if (self.dupes.keys().len == 0) return; // Nothing to do

    const gpa = self.base.allocator;
    const max_notes = 3;

    // We will sort by name, and then by file to ensure deterministic output.
    var keys = try std.ArrayList(SymbolResolver.Index).initCapacity(gpa, self.dupes.keys().len);
    defer keys.deinit();
    keys.appendSliceAssumeCapacity(self.dupes.keys());
    self.sortGlobalSymbolsByName(keys.items);

    for (self.dupes.values()) |*refs| {
        mem.sort(File.Index, refs.items, {}, std.sort.asc(File.Index));
    }

    for (keys.items) |key| {
        const sym = self.resolver.keys.items[key - 1];
        const notes = self.dupes.get(key).?;
        const nnotes = @min(notes.items.len, max_notes) + @intFromBool(notes.items.len > max_notes);

        const err = try self.base.addErrorWithNotes(nnotes + 1);
        defer err.unlock();
        try err.addMsg("duplicate symbol definition: {s}", .{sym.getName(self)});
        try err.addNote("defined by {}", .{sym.getFile(self).?.fmtPath()});

        var inote: usize = 0;
        while (inote < @min(notes.items.len, max_notes)) : (inote += 1) {
            const file = self.getFile(notes.items[inote]).?;
            try err.addNote("defined by {}", .{file.fmtPath()});
        }

        if (notes.items.len > max_notes) {
            const remaining = notes.items.len - max_notes;
            try err.addNote("defined {d} more times", .{remaining});
        }
    }
    return error.HasDuplicates;
}

fn scanRelocs(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();

    var wg: WaitGroup = .{};

    {
        wg.reset();
        defer wg.wait();
        for (self.objects.items) |index| {
            self.base.thread_pool.spawnWg(&wg, scanRelocsWorker, .{ self, self.getFile(index).? });
        }
        if (self.getInternalObject()) |obj| {
            self.base.thread_pool.spawnWg(&wg, scanRelocsWorker, .{ self, obj.asFile() });
        }
    }

    if (self.has_errors.swap(false, .seq_cst)) return error.FlushFailed;

    if (self.getInternalObject()) |obj| {
        try obj.checkUndefs(self);
    }
    try self.reportUndefs();

    for (self.objects.items) |index| {
        try self.getFile(index).?.createSymbolIndirection(self);
    }
    for (self.dylibs.items) |index| {
        try self.getFile(index).?.createSymbolIndirection(self);
    }
    if (self.getInternalObject()) |obj| {
        try obj.asFile().createSymbolIndirection(self);
    }
}

fn scanRelocsWorker(self: *MachO, file: File) void {
    file.scanRelocs(self) catch |err| {
        self.base.fatal("{}: failed to scan relocations: {s}", .{
            file.fmtPath(),
            @errorName(err),
        });
        _ = self.has_errors.swap(true, .seq_cst);
    };
}

fn sortGlobalSymbolsByName(self: *MachO, symbols: []SymbolResolver.Index) void {
    const lessThan = struct {
        fn lessThan(ctx: *MachO, lhs: SymbolResolver.Index, rhs: SymbolResolver.Index) bool {
            const lhs_name = ctx.resolver.keys.items[lhs - 1].getName(ctx);
            const rhs_name = ctx.resolver.keys.items[rhs - 1].getName(ctx);
            return mem.order(u8, lhs_name, rhs_name) == .lt;
        }
    }.lessThan;
    mem.sort(SymbolResolver.Index, symbols, self, lessThan);
}

fn reportUndefs(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();

    if (self.options.undefined_treatment == .suppress or
        self.options.undefined_treatment == .dynamic_lookup) return;
    if (self.undefs.keys().len == 0) return; // Nothing to do

    const addFn = switch (self.options.undefined_treatment) {
        .dynamic_lookup => unreachable, // handled above
        .suppress => unreachable, // handled above
        .@"error" => &Ld.addErrorWithNotes,
        .warn => &Ld.addWarningWithNotes,
    };

    const gpa = self.base.allocator;
    const max_notes = 4;

    // We will sort by name, and then by file to ensure deterministic output.
    var keys = try std.ArrayList(SymbolResolver.Index).initCapacity(gpa, self.undefs.keys().len);
    defer keys.deinit();
    keys.appendSliceAssumeCapacity(self.undefs.keys());
    self.sortGlobalSymbolsByName(keys.items);

    const refLessThan = struct {
        fn lessThan(ctx: void, lhs: Ref, rhs: Ref) bool {
            _ = ctx;
            return lhs.lessThan(rhs);
        }
    }.lessThan;

    for (self.undefs.values()) |*undefs| switch (undefs.*) {
        .refs => |refs| mem.sort(Ref, refs.items, {}, refLessThan),
        else => {},
    };

    for (keys.items) |key| {
        const undef_sym = self.resolver.keys.items[key - 1];
        const notes = self.undefs.get(key).?;
        const nnotes = nnotes: {
            const nnotes = switch (notes) {
                .refs => |refs| refs.items.len,
                else => 1,
            };
            break :nnotes @min(nnotes, max_notes) + @intFromBool(nnotes > max_notes);
        };

        const err = try addFn(&self.base, nnotes);
        defer err.unlock();

        if (self.options.arch_multiple) {
            // When clang is invoked with two -arch flags, it will pass -arch_multiple and -final_output to the linker.
            // According to LLD implementation [1], -arch_multiple is only used to signal to the linker that it should
            // suffix undefined symbols errors/warnings with current architecture.
            // [1]: https://reviews.llvm.org/D105450
            try err.addMsg("undefined symbol for architecture {s}: {s}", .{
                @tagName(self.options.cpu_arch.?),
                undef_sym.getName(self),
            });
        } else {
            try err.addMsg("undefined symbol: {s}", .{undef_sym.getName(self)});
        }

        switch (notes) {
            .force_undefined => try err.addNote("referenced with linker flag -u", .{}),
            .entry => try err.addNote("referenced with linker flag -e", .{}),
            .dyld_stub_binder, .objc_msgsend => try err.addNote("referenced implicitly", .{}),
            .refs => |refs| {
                var inote: usize = 0;
                while (inote < @min(refs.items.len, max_notes)) : (inote += 1) {
                    const ref = refs.items[inote];
                    const file = self.getFile(ref.file).?;
                    const atom = ref.getAtom(self).?;
                    try err.addNote("referenced by {}:{s}", .{ file.fmtPath(), atom.getName(self) });
                }

                if (refs.items.len > max_notes) {
                    const remaining = refs.items.len - max_notes;
                    try err.addNote("referenced {d} more times", .{remaining});
                }
            },
        }
    }
    return error.UndefinedSymbols;
}

fn initSyntheticSections(self: *MachO) !void {
    const cpu_arch = self.options.cpu_arch.?;

    if (self.got.symbols.items.len > 0) {
        self.got_sect_index = try self.addSection("__DATA_CONST", "__got", .{
            .flags = macho.S_NON_LAZY_SYMBOL_POINTERS,
            .reserved1 = @intCast(self.stubs.symbols.items.len),
        });
    }

    if (self.stubs.symbols.items.len > 0) {
        self.stubs_sect_index = try self.addSection("__TEXT", "__stubs", .{
            .flags = macho.S_SYMBOL_STUBS |
                macho.S_ATTR_PURE_INSTRUCTIONS | macho.S_ATTR_SOME_INSTRUCTIONS,
            .reserved1 = 0,
            .reserved2 = switch (cpu_arch) {
                .x86_64 => 6,
                .aarch64 => 3 * @sizeOf(u32),
                else => 0,
            },
        });
        self.stubs_helper_sect_index = try self.addSection("__TEXT", "__stub_helper", .{
            .flags = macho.S_ATTR_PURE_INSTRUCTIONS | macho.S_ATTR_SOME_INSTRUCTIONS,
        });
        self.la_symbol_ptr_sect_index = try self.addSection("__DATA", "__la_symbol_ptr", .{
            .flags = macho.S_LAZY_SYMBOL_POINTERS,
            .reserved1 = @intCast(self.stubs.symbols.items.len + self.got.symbols.items.len),
        });
    }

    if (self.objc_stubs.symbols.items.len > 0) {
        self.objc_stubs_sect_index = try self.addSection("__TEXT", "__objc_stubs", .{
            .flags = macho.S_ATTR_PURE_INSTRUCTIONS | macho.S_ATTR_SOME_INSTRUCTIONS,
        });
    }

    if (self.tlv_ptr.symbols.items.len > 0) {
        self.tlv_ptr_sect_index = try self.addSection("__DATA", "__thread_ptrs", .{
            .flags = macho.S_THREAD_LOCAL_VARIABLE_POINTERS,
        });
    }

    const needs_unwind_info = for (self.objects.items) |index| {
        if (self.getFile(index).?.object.hasUnwindRecords()) break true;
    } else false;
    if (needs_unwind_info) {
        self.unwind_info_sect_index = try self.addSection("__TEXT", "__unwind_info", .{});
    }

    const needs_eh_frame = for (self.objects.items) |index| {
        if (self.getFile(index).?.object.hasEhFrameRecords()) break true;
    } else false;
    if (needs_eh_frame) {
        assert(needs_unwind_info);
        self.eh_frame_sect_index = try self.addSection("__TEXT", "__eh_frame", .{});
    }

    if (self.getInternalObject()) |obj| {
        const gpa = self.base.allocator;

        for (obj.boundary_symbols.items) |sym_index| {
            const ref = obj.getSymbolRef(sym_index, self);
            const sym = ref.getSymbol(self).?;
            const name = sym.getName(self);

            if (eatPrefix(name, "segment$start$")) |segname| {
                if (self.getSegmentByName(segname) == null) { // TODO check segname is valid
                    const prot = getSegmentProt(segname);
                    _ = try self.segments.append(gpa, .{
                        .cmdsize = @sizeOf(macho.segment_command_64),
                        .segname = makeStaticString(segname),
                        .initprot = prot,
                        .maxprot = prot,
                    });
                }
            } else if (eatPrefix(name, "segment$end$")) |segname| {
                if (self.getSegmentByName(segname) == null) { // TODO check segname is valid
                    const prot = getSegmentProt(segname);
                    _ = try self.segments.append(gpa, .{
                        .cmdsize = @sizeOf(macho.segment_command_64),
                        .segname = makeStaticString(segname),
                        .initprot = prot,
                        .maxprot = prot,
                    });
                }
            } else if (eatPrefix(name, "section$start$")) |actual_name| {
                const sep = mem.indexOfScalar(u8, actual_name, '$').?; // TODO error rather than a panic
                const segname = actual_name[0..sep]; // TODO check segname is valid
                const sectname = actual_name[sep + 1 ..]; // TODO check sectname is valid
                if (self.getSectionByName(segname, sectname) == null) {
                    _ = try self.addSection(segname, sectname, .{});
                }
            } else if (eatPrefix(name, "section$end$")) |actual_name| {
                const sep = mem.indexOfScalar(u8, actual_name, '$').?; // TODO error rather than a panic
                const segname = actual_name[0..sep]; // TODO check segname is valid
                const sectname = actual_name[sep + 1 ..]; // TODO check sectname is valid
                if (self.getSectionByName(segname, sectname) == null) {
                    _ = try self.addSection(segname, sectname, .{});
                }
            } else unreachable;
        }
    }
}

fn getSegmentProt(segname: []const u8) macho.vm_prot_t {
    if (mem.eql(u8, segname, "__PAGEZERO")) return macho.PROT.NONE;
    if (mem.eql(u8, segname, "__TEXT")) return macho.PROT.READ | macho.PROT.EXEC;
    if (mem.eql(u8, segname, "__LINKEDIT")) return macho.PROT.READ;
    return macho.PROT.READ | macho.PROT.WRITE;
}

fn getSegmentRank(segname: []const u8) u4 {
    if (mem.eql(u8, segname, "__PAGEZERO")) return 0x0;
    if (mem.eql(u8, segname, "__LINKEDIT")) return 0x5;
    if (mem.startsWith(u8, segname, "__TEXT")) return 0x1;
    if (mem.startsWith(u8, segname, "__DATA_CONST")) return 0x2;
    if (mem.startsWith(u8, segname, "__DATA")) return 0x3;
    return 0x4;
}

fn segmentLessThan(ctx: void, lhs: []const u8, rhs: []const u8) bool {
    _ = ctx;
    const lhs_rank = getSegmentRank(lhs);
    const rhs_rank = getSegmentRank(rhs);
    if (lhs_rank == rhs_rank) {
        return mem.order(u8, lhs, rhs) == .lt;
    }
    return lhs_rank < rhs_rank;
}

fn getSectionRank(section: macho.section_64) u8 {
    if (section.isCode()) {
        if (mem.eql(u8, "__text", section.sectName())) return 0x0;
        if (section.type() == macho.S_SYMBOL_STUBS) return 0x1;
        return 0x2;
    }
    switch (section.type()) {
        macho.S_NON_LAZY_SYMBOL_POINTERS,
        macho.S_LAZY_SYMBOL_POINTERS,
        => return 0x0,

        macho.S_MOD_INIT_FUNC_POINTERS => return 0x1,
        macho.S_MOD_TERM_FUNC_POINTERS => return 0x2,
        macho.S_ZEROFILL => return 0xf,
        macho.S_THREAD_LOCAL_REGULAR => return 0xd,
        macho.S_THREAD_LOCAL_ZEROFILL => return 0xe,

        else => {
            if (mem.eql(u8, "__unwind_info", section.sectName())) return 0xe;
            if (mem.eql(u8, "__compact_unwind", section.sectName())) return 0xe;
            if (mem.eql(u8, "__eh_frame", section.sectName())) return 0xf;
            return 0x3;
        },
    }
}

fn sectionLessThan(ctx: void, lhs: macho.section_64, rhs: macho.section_64) bool {
    if (mem.eql(u8, lhs.segName(), rhs.segName())) {
        const lhs_rank = getSectionRank(lhs);
        const rhs_rank = getSectionRank(rhs);
        if (lhs_rank == rhs_rank) {
            return mem.order(u8, lhs.sectName(), rhs.sectName()) == .lt;
        }
        return lhs_rank < rhs_rank;
    }
    return segmentLessThan(ctx, lhs.segName(), rhs.segName());
}

pub fn sortSections(self: *MachO) !void {
    const Entry = struct {
        index: u8,

        pub fn lessThan(macho_file: *MachO, lhs: @This(), rhs: @This()) bool {
            return sectionLessThan(
                {},
                macho_file.sections.items(.header)[lhs.index],
                macho_file.sections.items(.header)[rhs.index],
            );
        }
    };

    const gpa = self.base.allocator;

    var entries = try std.ArrayList(Entry).initCapacity(gpa, self.sections.slice().len);
    defer entries.deinit();
    for (0..self.sections.slice().len) |index| {
        entries.appendAssumeCapacity(.{ .index = @intCast(index) });
    }

    mem.sort(Entry, entries.items, self, Entry.lessThan);

    const backlinks = try gpa.alloc(u8, entries.items.len);
    defer gpa.free(backlinks);
    for (entries.items, 0..) |entry, i| {
        backlinks[entry.index] = @intCast(i);
    }

    var slice = self.sections.toOwnedSlice();
    defer slice.deinit(gpa);

    try self.sections.ensureTotalCapacity(gpa, slice.len);
    for (entries.items) |sorted| {
        self.sections.appendAssumeCapacity(slice.get(sorted.index));
    }

    for (self.objects.items) |index| {
        const file = self.getFile(index).?;
        for (file.getAtoms()) |atom_index| {
            const atom = file.getAtom(atom_index) orelse continue;
            if (!atom.alive.load(.seq_cst)) continue;
            atom.out_n_sect = backlinks[atom.out_n_sect];
        }
    }
    if (self.getInternalObject()) |object| {
        for (object.getAtoms()) |atom_index| {
            const atom = object.getAtom(atom_index) orelse continue;
            if (!atom.alive.load(.seq_cst)) continue;
            atom.out_n_sect = backlinks[atom.out_n_sect];
        }
    }

    for (&[_]*?u8{
        &self.data_sect_index,
        &self.got_sect_index,
        &self.stubs_sect_index,
        &self.stubs_helper_sect_index,
        &self.la_symbol_ptr_sect_index,
        &self.tlv_ptr_sect_index,
        &self.eh_frame_sect_index,
        &self.unwind_info_sect_index,
        &self.objc_stubs_sect_index,
    }) |maybe_index| {
        if (maybe_index.*) |*index| {
            index.* = backlinks[index.*];
        }
    }
}

pub fn addAtomsToSections(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();

    for (self.objects.items) |index| {
        const file = self.getFile(index).?;
        for (file.getAtoms()) |atom_index| {
            const atom = file.getAtom(atom_index) orelse continue;
            if (!atom.alive.load(.seq_cst)) continue;
            const atoms = &self.sections.items(.atoms)[atom.out_n_sect];
            try atoms.append(self.base.allocator, .{ .index = atom.atom_index, .file = index });
        }
    }
    if (self.getInternalObject()) |object| {
        for (object.getAtoms()) |atom_index| {
            const atom = object.getAtom(atom_index) orelse continue;
            if (!atom.alive.load(.seq_cst)) continue;
            const atoms = &self.sections.items(.atoms)[atom.out_n_sect];
            try atoms.append(self.base.allocator, .{ .index = atom.atom_index, .file = object.index });
        }
    }
}

fn generateUnwindInfo(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();

    if (self.eh_frame_sect_index) |index| {
        const sect = &self.sections.items(.header)[index];
        sect.size = try eh_frame.calcSize(self);
        sect.@"align" = 3;
    }
    if (self.unwind_info_sect_index) |index| {
        const sect = &self.sections.items(.header)[index];
        try self.unwind_info.generate(self);
        sect.size = self.unwind_info.calcSize();
        sect.@"align" = 2;
    }
}

fn calcSectionSizes(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const cpu_arch = self.options.cpu_arch.?;

    if (self.data_sect_index) |idx| {
        const header = &self.sections.items(.header)[idx];
        header.size += @sizeOf(u64);
        header.@"align" = 3;
    }

    var wg: WaitGroup = .{};
    {
        wg.reset();
        defer wg.wait();
        const slice = self.sections.slice();
        for (slice.items(.header), slice.items(.atoms), 0..) |header, atoms, i| {
            if (atoms.items.len == 0) continue;
            if (self.requiresThunks() and header.isCode()) continue;
            self.base.thread_pool.spawnWg(&wg, calcSectionSizeWorker, .{ self, @as(u8, @intCast(i)) });
        }

        if (self.requiresThunks()) {
            for (slice.items(.header), slice.items(.atoms), 0..) |header, atoms, i| {
                if (!header.isCode()) continue;
                if (atoms.items.len == 0) continue;
                self.base.thread_pool.spawnWg(&wg, createThunksWorker, .{ self, @as(u8, @intCast(i)) });
            }
        }

        // At this point, we can also calculate symtab and data-in-code linkedit section sizes
        for (self.objects.items) |index| {
            self.base.thread_pool.spawnWg(&wg, File.calcSymtabSize, .{ self.getFile(index).?, self });
        }
        for (self.dylibs.items) |index| {
            self.base.thread_pool.spawnWg(&wg, File.calcSymtabSize, .{ self.getFile(index).?, self });
        }
        if (self.getInternalObject()) |obj| {
            self.base.thread_pool.spawnWg(&wg, File.calcSymtabSize, .{ obj.asFile(), self });
        }
    }

    if (self.has_errors.swap(false, .seq_cst)) return error.FlushFailed;

    try self.calcSymtabSize();

    if (self.got_sect_index) |idx| {
        const header = &self.sections.items(.header)[idx];
        header.size = self.got.size();
        header.@"align" = 3;
    }

    if (self.stubs_sect_index) |idx| {
        const header = &self.sections.items(.header)[idx];
        header.size = self.stubs.size(self);
        header.@"align" = switch (cpu_arch) {
            .x86_64 => 1,
            .aarch64 => 2,
            else => 0,
        };
    }

    if (self.stubs_helper_sect_index) |idx| {
        const header = &self.sections.items(.header)[idx];
        header.size = self.stubs_helper.size(self);
        header.@"align" = 2;
    }

    if (self.la_symbol_ptr_sect_index) |idx| {
        const header = &self.sections.items(.header)[idx];
        header.size = self.la_symbol_ptr.size(self);
        header.@"align" = 3;
    }

    if (self.tlv_ptr_sect_index) |idx| {
        const header = &self.sections.items(.header)[idx];
        header.size = self.tlv_ptr.size();
        header.@"align" = 3;
    }

    if (self.objc_stubs_sect_index) |idx| {
        const header = &self.sections.items(.header)[idx];
        header.size = self.objc_stubs.size(self);
        header.@"align" = switch (cpu_arch) {
            .x86_64 => 0,
            .aarch64 => 2,
            else => 0,
        };
    }
}

fn calcSectionSizeWorker(self: *MachO, sect_id: u8) void {
    const tracy = trace(@src());
    defer tracy.end();
    const doWork = struct {
        fn doWork(
            macho_file: *MachO,
            header: *macho.section_64,
            atoms: []const Ref,
        ) !void {
            for (atoms) |ref| {
                const atom = ref.getAtom(macho_file).?;
                const p2align = atom.alignment;
                const atom_alignment = try math.powi(u32, 2, p2align);
                const offset = mem.alignForward(u64, header.size, atom_alignment);
                const padding = offset - header.size;
                atom.value = offset;
                header.size += padding + atom.size;
                header.@"align" = @max(header.@"align", p2align);
            }
        }
    }.doWork;
    const slice = self.sections.slice();
    const header = &slice.items(.header)[sect_id];
    const atoms = slice.items(.atoms)[sect_id].items;
    doWork(self, header, atoms) catch |err| {
        self.base.fatal("failed to calculate size of section '{s},{s}': {s}", .{
            header.segName(),
            header.sectName(),
            @errorName(err),
        });
        _ = self.has_errors.swap(true, .seq_cst);
    };
}

fn createThunksWorker(self: *MachO, sect_id: u8) void {
    const tracy = trace(@src());
    defer tracy.end();
    self.createThunks(sect_id) catch |err| {
        const header = self.sections.items(.header)[sect_id];
        self.base.fatal("failed to create thunks and calculate size of section '{s},{s}': {s}", .{
            header.segName(),
            header.sectName(),
            @errorName(err),
        });
        _ = self.has_errors.swap(true, .seq_cst);
    };
}

fn initSegments(self: *MachO) !void {
    const gpa = self.base.allocator;
    const slice = self.sections.slice();

    // First, create segments required by sections
    for (slice.items(.header)) |header| {
        const segname = header.segName();
        if (self.getSegmentByName(segname) == null) {
            const prot = getSegmentProt(segname);
            try self.segments.append(gpa, .{
                .cmdsize = @sizeOf(macho.segment_command_64),
                .segname = makeStaticString(segname),
                .maxprot = prot,
                .initprot = prot,
            });
        }
    }

    // Add __PAGEZERO if required
    const pagezero_vmsize = self.options.pagezero_size orelse default_pagezero_vmsize;
    const aligned_pagezero_vmsize = mem.alignBackward(u64, pagezero_vmsize, self.getPageSize());
    if (!self.options.dylib and aligned_pagezero_vmsize > 0) {
        if (aligned_pagezero_vmsize != pagezero_vmsize) {
            // TODO convert into a warning
            log.warn("requested __PAGEZERO size (0x{x}) is not page aligned", .{pagezero_vmsize});
            log.warn("  rounding down to 0x{x}", .{aligned_pagezero_vmsize});
        }
        try self.segments.append(gpa, .{
            .cmdsize = @sizeOf(macho.segment_command_64),
            .segname = makeStaticString("__PAGEZERO"),
            .vmsize = aligned_pagezero_vmsize,
        });
    }

    // Add __LINKEDIT
    {
        const protection = getSegmentProt("__LINKEDIT");
        self.linkedit_seg_index = @intCast(self.segments.items.len);
        try self.segments.append(gpa, .{
            .cmdsize = @sizeOf(macho.segment_command_64),
            .segname = makeStaticString("__LINKEDIT"),
            .maxprot = protection,
            .initprot = protection,
        });
    }

    // __TEXT segment is non-optional
    if (self.getSegmentByName("__TEXT") == null) {
        const protection = getSegmentProt("__TEXT");
        try self.segments.append(gpa, .{
            .cmdsize = @sizeOf(macho.segment_command_64),
            .segname = makeStaticString("__TEXT"),
            .maxprot = protection,
            .initprot = protection,
        });
    }

    const sortFn = struct {
        fn sortFn(ctx: void, lhs: macho.segment_command_64, rhs: macho.segment_command_64) bool {
            return segmentLessThan(ctx, lhs.segName(), rhs.segName());
        }
    }.sortFn;

    // Sort segments
    mem.sort(macho.segment_command_64, self.segments.items, {}, sortFn);

    // Attach sections to segments
    for (slice.items(.header), slice.items(.segment_id)) |header, *seg_id| {
        const segname = header.segName();
        const segment_id = self.getSegmentByName(segname) orelse blk: {
            const segment_id = @as(u8, @intCast(self.segments.items.len));
            const protection = getSegmentProt(segname);
            try self.segments.append(gpa, .{
                .cmdsize = @sizeOf(macho.segment_command_64),
                .segname = makeStaticString(segname),
                .maxprot = protection,
                .initprot = protection,
            });
            break :blk segment_id;
        };
        const segment = &self.segments.items[segment_id];
        segment.cmdsize += @sizeOf(macho.section_64);
        segment.nsects += 1;
        seg_id.* = segment_id;
    }

    self.pagezero_seg_index = self.getSegmentByName("__PAGEZERO");
    self.text_seg_index = self.getSegmentByName("__TEXT").?;
    self.linkedit_seg_index = self.getSegmentByName("__LINKEDIT").?;

    if (self.getSegmentByName("__DATA_CONST")) |seg_id| {
        const seg = &self.segments.items[seg_id];
        seg.flags |= macho.SG_READ_ONLY;
    }
}

fn allocateSections(self: *MachO) !void {
    const headerpad = load_commands.calcMinHeaderPadSize(self);
    var vmaddr: u64 = if (self.pagezero_seg_index) |index|
        self.segments.items[index].vmaddr + self.segments.items[index].vmsize
    else
        0;
    vmaddr += headerpad;
    var fileoff = headerpad;

    const page_size = self.getPageSize();
    const slice = self.sections.slice();

    var next_seg_id: u8 = if (self.pagezero_seg_index) |index| index + 1 else 0;
    for (slice.items(.header), slice.items(.segment_id)) |*header, seg_id| {
        if (seg_id != next_seg_id) {
            vmaddr = mem.alignForward(u64, vmaddr, page_size);
            fileoff = mem.alignForward(u32, fileoff, page_size);
        }

        const alignment = try math.powi(u32, 2, header.@"align");

        vmaddr = mem.alignForward(u64, vmaddr, alignment);
        header.addr = vmaddr;
        vmaddr += header.size;

        if (!header.isZerofill()) {
            fileoff = mem.alignForward(u32, fileoff, alignment);
            header.offset = fileoff;
            fileoff += @intCast(header.size);
        }

        next_seg_id = seg_id;
    }
}

fn allocateSegments(self: *MachO) void {
    const page_size = self.getPageSize();
    var vmaddr = if (self.pagezero_seg_index) |index|
        self.segments.items[index].vmaddr + self.segments.items[index].vmsize
    else
        0;
    var fileoff: u64 = 0;
    const index = if (self.pagezero_seg_index) |index| index + 1 else 0;

    const slice = self.sections.slice();
    var next_sect_id: u8 = 0;
    for (self.segments.items[index..], index..) |*seg, seg_id| {
        seg.vmaddr = vmaddr;
        seg.fileoff = fileoff;

        for (
            slice.items(.header)[next_sect_id..],
            slice.items(.segment_id)[next_sect_id..],
        ) |header, sid| {
            if (seg_id != sid) break;

            vmaddr = header.addr + header.size;
            if (!header.isZerofill()) {
                fileoff = header.offset + header.size;
            }

            next_sect_id += 1;
        }

        vmaddr = mem.alignForward(u64, vmaddr, page_size);
        fileoff = mem.alignForward(u64, fileoff, page_size);

        seg.vmsize = vmaddr - seg.vmaddr;
        seg.filesize = fileoff - seg.fileoff;
    }
}

fn allocateSyntheticSymbols(self: *MachO) void {
    if (self.getInternalObject()) |obj| {
        obj.allocateSyntheticSymbols(self);

        const text_seg = self.getTextSegment();

        for (obj.boundary_symbols.items) |sym_index| {
            const ref = obj.getSymbolRef(sym_index, self);
            const sym = ref.getSymbol(self).?;
            const name = sym.getName(self);

            sym.value = text_seg.vmaddr;

            if (mem.startsWith(u8, name, "segment$start$")) {
                const segname = name["segment$start$".len..];
                if (self.getSegmentByName(segname)) |seg_id| {
                    const seg = self.segments.items[seg_id];
                    sym.value = seg.vmaddr;
                }
            } else if (mem.startsWith(u8, name, "segment$end$")) {
                const segname = name["segment$end$".len..];
                if (self.getSegmentByName(segname)) |seg_id| {
                    const seg = self.segments.items[seg_id];
                    sym.value = seg.vmaddr + seg.vmsize;
                }
            } else if (mem.startsWith(u8, name, "section$start$")) {
                const actual_name = name["section$start$".len..];
                const sep = mem.indexOfScalar(u8, actual_name, '$').?; // TODO error rather than a panic
                const segname = actual_name[0..sep];
                const sectname = actual_name[sep + 1 ..];
                if (self.getSectionByName(segname, sectname)) |sect_id| {
                    const sect = self.sections.items(.header)[sect_id];
                    sym.value = sect.addr;
                    sym.out_n_sect = sect_id;
                }
            } else if (mem.startsWith(u8, name, "section$end$")) {
                const actual_name = name["section$end$".len..];
                const sep = mem.indexOfScalar(u8, actual_name, '$').?; // TODO error rather than a panic
                const segname = actual_name[0..sep];
                const sectname = actual_name[sep + 1 ..];
                if (self.getSectionByName(segname, sectname)) |sect_id| {
                    const sect = self.sections.items(.header)[sect_id];
                    sym.value = sect.addr + sect.size;
                    sym.out_n_sect = sect_id;
                }
            } else unreachable;
        }
    }

    if (self.objc_stubs.symbols.items.len > 0) {
        const addr = self.sections.items(.header)[self.objc_stubs_sect_index.?].addr;

        for (self.objc_stubs.symbols.items, 0..) |ref, idx| {
            const sym = ref.getSymbol(self).?;
            sym.value = addr + idx * ObjcStubsSection.entrySize(self.options.cpu_arch.?);
            sym.out_n_sect = self.objc_stubs_sect_index.?;
        }
    }
}

fn allocateLinkeditSegment(self: *MachO) error{Overflow}!void {
    const seg = self.getLinkeditSegment();
    var off = math.cast(u32, seg.fileoff) orelse return error.Overflow;
    // DYLD_INFO_ONLY
    {
        const cmd = &self.dyld_info_cmd;
        cmd.rebase_off = off;
        off += cmd.rebase_size;
        cmd.bind_off = off;
        off += cmd.bind_size;
        cmd.weak_bind_off = off;
        off += cmd.weak_bind_size;
        cmd.lazy_bind_off = off;
        off += cmd.lazy_bind_size;
        cmd.export_off = off;
        off += cmd.export_size;
        off = mem.alignForward(u32, off, @alignOf(u64));
    }

    // FUNCTION_STARTS
    {
        const cmd = &self.function_starts_cmd;
        cmd.dataoff = off;
        off += cmd.datasize;
        off = mem.alignForward(u32, off, @alignOf(u64));
    }

    // DATA_IN_CODE
    {
        const cmd = &self.data_in_code_cmd;
        cmd.dataoff = off;
        off += cmd.datasize;
        off = mem.alignForward(u32, off, @alignOf(u64));
    }

    // SYMTAB (symtab)
    {
        const cmd = &self.symtab_cmd;
        cmd.symoff = off;
        off += cmd.nsyms * @sizeOf(macho.nlist_64);
        off = mem.alignForward(u32, off, @alignOf(u32));
    }

    // DYSYMTAB
    {
        const cmd = &self.dysymtab_cmd;
        cmd.indirectsymoff = off;
        off += cmd.nindirectsyms * @sizeOf(u32);
        off = mem.alignForward(u32, off, @alignOf(u64));
    }

    // SYMTAB (strtab)
    {
        const cmd = &self.symtab_cmd;
        cmd.stroff = off;
        off += cmd.strsize;
    }

    seg.filesize = off - seg.fileoff;
}

fn updateLazyBindSizeWorker(self: *MachO) void {
    const doWork = struct {
        fn doWork(macho_file: *MachO) !void {
            const tracy = trace(@src());
            defer tracy.end();
            try macho_file.lazy_bind.updateSize(macho_file);
            const sect_id = macho_file.stubs_helper_sect_index.?;
            const out = &macho_file.sections.items(.out)[sect_id];
            var stream = std.io.fixedBufferStream(out.items);
            try macho_file.stubs_helper.write(macho_file, stream.writer());
        }
    }.doWork;
    doWork(self) catch |err| {
        self.base.fatal("could not calculate lazy_bind opcodes size: {s}", .{@errorName(err)});
        _ = self.has_errors.swap(true, .seq_cst);
    };
}

pub fn updateLinkeditSizeWorker(self: *MachO, tag: enum {
    rebase,
    bind,
    weak_bind,
    export_trie,
    data_in_code,
}) void {
    const res = switch (tag) {
        .rebase => self.rebase.updateSize(self),
        .bind => self.bind.updateSize(self),
        .weak_bind => self.weak_bind.updateSize(self),
        .export_trie => self.export_trie.updateSize(self),
        .data_in_code => self.data_in_code.updateSize(self),
    };
    res catch |err| {
        self.base.fatal("could not calculate {s} opcodes size: {s}", .{
            @tagName(tag),
            @errorName(err),
        });
        _ = self.has_errors.swap(true, .seq_cst);
    };
}

fn resizeSections(self: *MachO) !void {
    const slice = self.sections.slice();
    for (slice.items(.header), slice.items(.out)) |header, *out| {
        if (header.isZerofill()) continue;
        const cpu_arch = self.options.cpu_arch.?;
        try out.resize(self.base.allocator, header.size);
        const padding_byte: u8 = if (header.isCode() and cpu_arch == .x86_64) 0xcc else 0;
        @memset(out.items, padding_byte);
    }
}

fn writeSectionsAndUpdateLinkeditSizes(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const gpa = self.base.allocator;

    const cmd = self.symtab_cmd;
    try self.symtab.resize(gpa, cmd.nsyms);
    try self.strtab.resize(gpa, cmd.strsize);
    self.strtab.items[0] = 0;

    var wg: WaitGroup = .{};
    {
        wg.reset();
        defer wg.wait();
        for (self.objects.items) |index| {
            self.base.thread_pool.spawnWg(&wg, writeAtomsWorker, .{ self, index });
        }
        if (self.getInternalObject()) |obj| {
            self.base.thread_pool.spawnWg(&wg, writeAtomsWorker, .{ self, obj.index });
        }
        for (self.thunks.items) |thunk| {
            self.base.thread_pool.spawnWg(&wg, writeThunkWorker, .{ self, thunk });
        }

        const slice = self.sections.slice();
        for (&[_]?u8{
            self.eh_frame_sect_index,
            self.unwind_info_sect_index,
            self.got_sect_index,
            self.stubs_sect_index,
            self.la_symbol_ptr_sect_index,
            self.tlv_ptr_sect_index,
            self.objc_stubs_sect_index,
        }) |maybe_sect_id| {
            if (maybe_sect_id) |sect_id| {
                const out = &slice.items(.out)[sect_id];
                self.base.thread_pool.spawnWg(&wg, writeSyntheticSectionWorker, .{ self, sect_id, out.items });
            }
        }

        if (self.la_symbol_ptr_sect_index) |_| {
            self.base.thread_pool.spawnWg(&wg, updateLazyBindSizeWorker, .{self});
        }

        self.base.thread_pool.spawnWg(&wg, updateLinkeditSizeWorker, .{ self, .rebase });
        self.base.thread_pool.spawnWg(&wg, updateLinkeditSizeWorker, .{ self, .bind });
        self.base.thread_pool.spawnWg(&wg, updateLinkeditSizeWorker, .{ self, .weak_bind });
        self.base.thread_pool.spawnWg(&wg, updateLinkeditSizeWorker, .{ self, .export_trie });
        self.base.thread_pool.spawnWg(&wg, updateLinkeditSizeWorker, .{ self, .data_in_code });

        for (self.objects.items) |index| {
            self.base.thread_pool.spawnWg(&wg, File.writeSymtab, .{ self.getFile(index).?, self });
        }
        for (self.dylibs.items) |index| {
            self.base.thread_pool.spawnWg(&wg, File.writeSymtab, .{ self.getFile(index).?, self });
        }
        if (self.getInternalObject()) |obj| {
            self.base.thread_pool.spawnWg(&wg, File.writeSymtab, .{ obj.asFile(), self });
        }
    }

    if (self.has_errors.swap(false, .seq_cst)) return error.FlushFailed;
}

fn writeSectionsToFile(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const slice = self.sections.slice();
    for (slice.items(.header), slice.items(.out)) |header, out| {
        try self.base.file.pwriteAll(out.items, header.offset);
    }
}

fn writeAtomsWorker(self: *MachO, index: File.Index) void {
    const tracy = trace(@src());
    defer tracy.end();
    self.getFile(index).?.writeAtoms(self) catch |err| {
        self.base.fatal("{}: failed to write atoms: {s}", .{
            self.getFile(index).?.fmtPath(),
            @errorName(err),
        });
        _ = self.has_errors.swap(true, .seq_cst);
    };
}

fn writeThunkWorker(self: *MachO, thunk: Thunk) void {
    const tracy = trace(@src());
    defer tracy.end();
    const doWork = struct {
        fn doWork(th: Thunk, buffer: []u8, macho_file: *MachO) !void {
            const off = th.value;
            const size = th.size();
            var stream = std.io.fixedBufferStream(buffer[off..][0..size]);
            try th.write(macho_file, stream.writer());
        }
    }.doWork;
    const out = self.sections.items(.out)[thunk.out_n_sect].items;
    doWork(thunk, out, self) catch |err| {
        self.base.fatal("failed to write contents of thunk: {s}", .{@errorName(err)});
        _ = self.has_errors.swap(true, .seq_cst);
    };
}

fn writeSyntheticSectionWorker(self: *MachO, sect_id: u8, out: []u8) void {
    const tracy = trace(@src());
    defer tracy.end();
    const Tag = enum {
        eh_frame,
        unwind_info,
        got,
        stubs,
        la_symbol_ptr,
        tlv_ptr,
        objc_stubs,
    };
    const doWork = struct {
        fn doWork(macho_file: *MachO, tag: Tag, buffer: []u8) !void {
            var stream = std.io.fixedBufferStream(buffer);
            switch (tag) {
                .eh_frame => eh_frame.write(macho_file, buffer),
                .unwind_info => try macho_file.unwind_info.write(macho_file, buffer),
                .got => try macho_file.got.write(macho_file, stream.writer()),
                .stubs => try macho_file.stubs.write(macho_file, stream.writer()),
                .la_symbol_ptr => try macho_file.la_symbol_ptr.write(macho_file, stream.writer()),
                .tlv_ptr => try macho_file.tlv_ptr.write(macho_file, stream.writer()),
                .objc_stubs => try macho_file.objc_stubs.write(macho_file, stream.writer()),
            }
        }
    }.doWork;
    const header = self.sections.items(.header)[sect_id];
    const tag: Tag = tag: {
        if (self.eh_frame_sect_index != null and
            self.eh_frame_sect_index.? == sect_id) break :tag .eh_frame;
        if (self.unwind_info_sect_index != null and
            self.unwind_info_sect_index.? == sect_id) break :tag .unwind_info;
        if (self.got_sect_index != null and
            self.got_sect_index.? == sect_id) break :tag .got;
        if (self.stubs_sect_index != null and
            self.stubs_sect_index.? == sect_id) break :tag .stubs;
        if (self.la_symbol_ptr_sect_index != null and
            self.la_symbol_ptr_sect_index.? == sect_id) break :tag .la_symbol_ptr;
        if (self.tlv_ptr_sect_index != null and
            self.tlv_ptr_sect_index.? == sect_id) break :tag .tlv_ptr;
        if (self.objc_stubs_sect_index != null and
            self.objc_stubs_sect_index.? == sect_id) break :tag .objc_stubs;
        unreachable;
    };
    doWork(self, tag, out) catch |err| {
        self.base.fatal("could not write section '{s},{s}' to file: {s}", .{
            header.segName(),
            header.sectName(),
            @errorName(err),
        });
        _ = self.has_errors.swap(true, .seq_cst);
    };
}

fn writeLinkeditSectionsToFile(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();
    try self.writeDyldInfo();
    try self.writeDataInCode();
    try self.writeSymtabToFile();
    try self.writeIndsymtab();
}

fn writeDyldInfo(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const gpa = self.base.allocator;
    const base_off = self.getLinkeditSegment().fileoff;
    const cmd = self.dyld_info_cmd;
    var needed_size: u32 = 0;
    needed_size += cmd.rebase_size;
    needed_size += cmd.bind_size;
    needed_size += cmd.weak_bind_size;
    needed_size += cmd.lazy_bind_size;
    needed_size += cmd.export_size;

    const buffer = try gpa.alloc(u8, needed_size);
    defer gpa.free(buffer);
    @memset(buffer, 0);

    var stream = std.io.fixedBufferStream(buffer);
    const writer = stream.writer();

    try self.rebase.write(writer);
    try stream.seekTo(cmd.bind_off - base_off);
    try self.bind.write(writer);
    try stream.seekTo(cmd.weak_bind_off - base_off);
    try self.weak_bind.write(writer);
    try stream.seekTo(cmd.lazy_bind_off - base_off);
    try self.lazy_bind.write(writer);
    try stream.seekTo(cmd.export_off - base_off);
    try self.export_trie.write(writer);
    try self.base.file.pwriteAll(buffer, cmd.rebase_off);
}

pub fn writeDataInCode(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();
    const gpa = self.base.allocator;
    const cmd = self.data_in_code_cmd;
    var buffer = try std.ArrayList(u8).initCapacity(gpa, self.data_in_code.size());
    defer buffer.deinit();
    try self.data_in_code.write(self, buffer.writer());
    try self.base.file.pwriteAll(buffer.items, cmd.dataoff);
}

fn calcSymtabSize(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const gpa = self.base.allocator;

    var files = std.ArrayList(File.Index).init(gpa);
    defer files.deinit();
    try files.ensureTotalCapacityPrecise(self.objects.items.len + self.dylibs.items.len + 1);
    for (self.objects.items) |index| files.appendAssumeCapacity(index);
    for (self.dylibs.items) |index| files.appendAssumeCapacity(index);
    if (self.internal_object_index) |index| files.appendAssumeCapacity(index);

    var nlocals: u32 = 0;
    var nstabs: u32 = 0;
    var nexports: u32 = 0;
    var nimports: u32 = 0;
    var strsize: u32 = 1;

    for (files.items) |index| {
        const file = self.getFile(index).?;
        const ctx = switch (file) {
            inline else => |x| &x.output_symtab_ctx,
        };
        ctx.ilocal = nlocals;
        ctx.istab = nstabs;
        ctx.iexport = nexports;
        ctx.iimport = nimports;
        ctx.stroff = strsize;
        nlocals += ctx.nlocals;
        nstabs += ctx.nstabs;
        nexports += ctx.nexports;
        nimports += ctx.nimports;
        strsize += ctx.strsize;
    }

    for (files.items) |index| {
        const file = self.getFile(index).?;
        const ctx = switch (file) {
            inline else => |x| &x.output_symtab_ctx,
        };
        ctx.istab += nlocals;
        ctx.iexport += nlocals + nstabs;
        ctx.iimport += nlocals + nstabs + nexports;
    }

    try self.indsymtab.updateSize(self);

    {
        const cmd = &self.symtab_cmd;
        cmd.nsyms = nlocals + nstabs + nexports + nimports;
        cmd.strsize = strsize;
    }

    {
        const cmd = &self.dysymtab_cmd;
        cmd.ilocalsym = 0;
        cmd.nlocalsym = nlocals + nstabs;
        cmd.iextdefsym = nlocals + nstabs;
        cmd.nextdefsym = nexports;
        cmd.iundefsym = nlocals + nstabs + nexports;
        cmd.nundefsym = nimports;
    }
}

fn writeIndsymtab(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();
    const gpa = self.base.allocator;
    const cmd = self.dysymtab_cmd;
    const needed_size = cmd.nindirectsyms * @sizeOf(u32);
    var buffer = try std.ArrayList(u8).initCapacity(gpa, needed_size);
    defer buffer.deinit();
    try self.indsymtab.write(self, buffer.writer());
    try self.base.file.pwriteAll(buffer.items, cmd.indirectsymoff);
}

pub fn writeSymtabToFile(self: *MachO) !void {
    const tracy = trace(@src());
    defer tracy.end();
    const cmd = self.symtab_cmd;
    try self.base.file.pwriteAll(mem.sliceAsBytes(self.symtab.items), cmd.symoff);
    try self.base.file.pwriteAll(self.strtab.items, cmd.stroff);
}

fn writeLoadCommands(self: *MachO) !struct { usize, usize, usize } {
    const gpa = self.base.allocator;
    const needed_size = load_commands.calcLoadCommandsSize(self, false);
    const buffer = try gpa.alloc(u8, needed_size);
    defer gpa.free(buffer);

    var stream = std.io.fixedBufferStream(buffer);
    var cwriter = std.io.countingWriter(stream.writer());
    const writer = cwriter.writer();

    var ncmds: usize = 0;

    // Segment and section load commands
    {
        const slice = self.sections.slice();
        var sect_id: usize = 0;
        for (self.segments.items) |seg| {
            try writer.writeStruct(seg);
            for (slice.items(.header)[sect_id..][0..seg.nsects]) |header| {
                try writer.writeStruct(header);
            }
            sect_id += seg.nsects;
        }
        ncmds += self.segments.items.len;
    }

    try writer.writeStruct(self.dyld_info_cmd);
    ncmds += 1;
    try writer.writeStruct(self.function_starts_cmd);
    ncmds += 1;
    try writer.writeStruct(self.data_in_code_cmd);
    ncmds += 1;
    try writer.writeStruct(self.symtab_cmd);
    ncmds += 1;
    try writer.writeStruct(self.dysymtab_cmd);
    ncmds += 1;

    if (!self.options.dylib) {
        try load_commands.writeDylinkerLC(writer);
        ncmds += 1;
    }

    if (self.getInternalObject()) |obj| {
        if (obj.getEntryRef(self)) |ref| {
            const sym = ref.getSymbol(self).?;
            const seg = self.getTextSegment();
            const entryoff: u32 = if (sym.getFile(self) == null)
                0
            else
                @as(u32, @intCast(sym.getAddress(.{ .stubs = true }, self) - seg.vmaddr));
            try writer.writeStruct(macho.entry_point_command{
                .entryoff = entryoff,
                .stacksize = self.options.stack_size orelse 0,
            });
            ncmds += 1;
        }
    }

    if (self.options.dylib) {
        try load_commands.writeDylibIdLC(self, writer);
        ncmds += 1;
    }

    try load_commands.writeRpathLCs(self.options.rpath_list, writer);
    ncmds += self.options.rpath_list.len;

    try writer.writeStruct(macho.source_version_command{ .version = 0 });
    ncmds += 1;

    if (self.options.platform) |platform| {
        if (platform.isBuildVersionCompatible()) {
            try load_commands.writeBuildVersionLC(platform, self.options.sdk_version, writer);
            ncmds += 1;
        } else {
            try load_commands.writeVersionMinLC(platform, self.options.sdk_version, writer);
            ncmds += 1;
        }
    }

    const uuid_cmd_offset = @sizeOf(macho.mach_header_64) + cwriter.bytes_written;
    try writer.writeStruct(self.uuid_cmd);
    ncmds += 1;

    for (self.dylibs.items) |index| {
        const dylib = self.getFile(index).?.dylib;
        assert(dylib.isAlive(self));
        const dylib_id = dylib.id.?;
        try load_commands.writeDylibLC(.{
            .cmd = if (dylib.weak)
                .LOAD_WEAK_DYLIB
            else if (dylib.reexport)
                .REEXPORT_DYLIB
            else
                .LOAD_DYLIB,
            .name = dylib_id.name,
            .timestamp = dylib_id.timestamp,
            .current_version = dylib_id.current_version,
            .compatibility_version = dylib_id.compatibility_version,
        }, writer);
        ncmds += 1;
    }

    if (self.requiresCodeSig()) {
        try writer.writeStruct(self.codesig_cmd);
        ncmds += 1;
    }

    assert(cwriter.bytes_written == needed_size);

    try self.base.file.pwriteAll(buffer, @sizeOf(macho.mach_header_64));

    return .{ ncmds, buffer.len, uuid_cmd_offset };
}

fn writeHeader(self: *MachO, ncmds: usize, sizeofcmds: usize) !void {
    var header: macho.mach_header_64 = .{};
    header.flags = macho.MH_NOUNDEFS | macho.MH_DYLDLINK;

    if (self.options.namespace == .two_level) {
        header.flags |= macho.MH_TWOLEVEL;
    }

    switch (self.options.cpu_arch.?) {
        .aarch64 => {
            header.cputype = macho.CPU_TYPE_ARM64;
            header.cpusubtype = macho.CPU_SUBTYPE_ARM_ALL;
        },
        .x86_64 => {
            header.cputype = macho.CPU_TYPE_X86_64;
            header.cpusubtype = macho.CPU_SUBTYPE_X86_64_ALL;
        },
        else => {},
    }

    if (self.options.dylib) {
        header.filetype = macho.MH_DYLIB;
    } else {
        header.filetype = macho.MH_EXECUTE;
        header.flags |= macho.MH_PIE;
    }

    const has_reexports = for (self.dylibs.items) |index| {
        if (self.getFile(index).?.dylib.reexport) break true;
    } else false;
    if (!has_reexports) {
        header.flags |= macho.MH_NO_REEXPORTED_DYLIBS;
    }

    if (self.has_tlv.load(.seq_cst)) {
        header.flags |= macho.MH_HAS_TLV_DESCRIPTORS;
    }
    if (self.binds_to_weak.load(.seq_cst)) {
        header.flags |= macho.MH_BINDS_TO_WEAK;
    }
    if (self.weak_defines.load(.seq_cst)) {
        header.flags |= macho.MH_WEAK_DEFINES;
    }

    header.ncmds = @intCast(ncmds);
    header.sizeofcmds = @intCast(sizeofcmds);

    log.debug("writing Mach-O header {}", .{header});

    try self.base.file.pwriteAll(mem.asBytes(&header), 0);
}

fn writeUuid(self: *MachO, uuid_cmd_offset: usize, has_codesig: bool) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const file_size = if (!has_codesig) blk: {
        const seg = self.getLinkeditSegment();
        break :blk seg.fileoff + seg.filesize;
    } else self.codesig_cmd.dataoff;
    try calcUuid(self.base.allocator, self.base.thread_pool, self.base.file, file_size, &self.uuid_cmd.uuid);
    const offset = uuid_cmd_offset + @sizeOf(macho.load_command);
    try self.base.file.pwriteAll(&self.uuid_cmd.uuid, offset);
}

pub fn writeCodeSignaturePadding(self: *MachO, code_sig: *CodeSignature) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const seg = self.getLinkeditSegment();
    // Code signature data has to be 16-bytes aligned for Apple tools to recognize the file
    // https://github.com/opensource-apple/cctools/blob/fdb4825f303fd5c0751be524babd32958181b3ed/libstuff/checkout.c#L271
    const offset = mem.alignForward(u64, seg.fileoff + seg.filesize, 16);
    const needed_size = code_sig.estimateSize(offset);
    seg.filesize = offset + needed_size - seg.fileoff;
    seg.vmsize = mem.alignForward(u64, seg.filesize, self.getPageSize());
    log.debug("writing code signature padding from 0x{x} to 0x{x}", .{ offset, offset + needed_size });
    // Pad out the space. We need to do this to calculate valid hashes for everything in the file
    // except for code signature data.
    try self.base.file.pwriteAll(&[_]u8{0}, offset + needed_size - 1);

    self.codesig_cmd.dataoff = @as(u32, @intCast(offset));
    self.codesig_cmd.datasize = @as(u32, @intCast(needed_size));
}

pub fn writeCodeSignature(self: *MachO, code_sig: *CodeSignature) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const seg = self.getTextSegment();
    const offset = self.codesig_cmd.dataoff;

    var buffer = std.ArrayList(u8).init(self.base.allocator);
    defer buffer.deinit();
    try buffer.ensureTotalCapacityPrecise(code_sig.size());
    try code_sig.writeAdhocSignature(self, .{
        .file = self.base.file,
        .exec_seg_base = seg.fileoff,
        .exec_seg_limit = seg.filesize,
        .file_size = offset,
        .dylib = self.options.dylib,
    }, buffer.writer());
    assert(buffer.items.len == code_sig.size());

    log.debug("writing code signature from 0x{x} to 0x{x}", .{
        offset,
        offset + buffer.items.len,
    });

    try self.base.file.pwriteAll(buffer.items, offset);
}

/// XNU starting with Big Sur running on arm64 is caching inodes of running binaries.
/// Any change to the binary will effectively invalidate the kernel's cache
/// resulting in a SIGKILL on each subsequent run. Since when doing incremental
/// linking we're modifying a binary in-place, this will end up with the kernel
/// killing it on every subsequent run. To circumvent it, we will copy the file
/// into a new inode, remove the original file, and rename the copy to match
/// the original file. This is super messy, but there doesn't seem any other
/// way to please the XNU.
pub fn invalidateKernelCache(dir: std.fs.Dir, sub_path: []const u8) !void {
    const tracy = trace(@src());
    defer tracy.end();
    if (comptime builtin.target.isDarwin() and builtin.target.cpu.arch == .aarch64) {
        try dir.copyFile(sub_path, dir, sub_path, .{});
    }
}

pub inline fn getPageSize(self: MachO) u16 {
    return switch (self.options.cpu_arch.?) {
        .aarch64 => 0x4000,
        .x86_64 => 0x1000,
        else => unreachable,
    };
}

pub fn getInstallName(self: MachO) []const u8 {
    // According to [1], when clang is invoked with two -arch flags, it will:
    // 1. call the linker driver twice, once for each arch
    // 2. call `lipo` tool to merge two outputs into a single file
    // `emit.sub_path` is the name of the temporary file the linker writes to.
    // `final_output` is the name of the file lipo writes to after the link.
    // [1]: https://reviews.llvm.org/D105449
    const install_name = self.options.install_name orelse blk: {
        break :blk self.options.final_output orelse self.options.emit.sub_path;
    };
    return install_name;
}

pub fn requiresCodeSig(self: MachO) bool {
    if (self.options.entitlements) |_| return true;
    if (self.options.adhoc_codesign) |cs| return cs;
    return switch (self.options.cpu_arch.?) {
        .aarch64 => switch (self.options.platform.?.platform) {
            .MACOS,
            .IOSSIMULATOR,
            .TVOSSIMULATOR,
            .WATCHOSSIMULATOR,
            .VISIONOSSIMULATOR,
            => true,
            else => false,
        },
        .x86_64 => false,
        else => unreachable,
    };
}

inline fn requiresThunks(self: MachO) bool {
    return self.options.cpu_arch.? == .aarch64;
}

pub fn isMarkedForExport(self: MachO, name: []const u8) ?bool {
    if (self.options.exported_symbols.len == 0) return null;
    // TODO handle wildcards
    // TODO handle unexport list
    for (self.options.exported_symbols) |exp_name| {
        if (mem.eql(u8, exp_name, name)) return true;
    }
    return false;
}

const AddSectionOpts = struct {
    flags: u32 = macho.S_REGULAR,
    reserved1: u32 = 0,
    reserved2: u32 = 0,
};

pub fn addSection(
    self: *MachO,
    segname: []const u8,
    sectname: []const u8,
    opts: AddSectionOpts,
) !u8 {
    const gpa = self.base.allocator;
    const index = @as(u8, @intCast(try self.sections.addOne(gpa)));
    self.sections.set(index, .{
        .segment_id = 0, // Segments will be created automatically later down the pipeline.
        .header = .{
            .sectname = makeStaticString(sectname),
            .segname = makeStaticString(segname),
            .flags = opts.flags,
            .reserved1 = opts.reserved1,
            .reserved2 = opts.reserved2,
        },
    });
    return index;
}

pub fn makeStaticString(bytes: []const u8) [16]u8 {
    var buf = [_]u8{0} ** 16;
    assert(bytes.len <= buf.len);
    @memcpy(buf[0..bytes.len], bytes);
    return buf;
}

pub fn getSegmentByName(self: MachO, segname: []const u8) ?u8 {
    for (self.segments.items, 0..) |seg, i| {
        if (mem.eql(u8, segname, seg.segName())) return @as(u8, @intCast(i));
    } else return null;
}

pub fn getSectionByName(self: MachO, segname: []const u8, sectname: []const u8) ?u8 {
    for (self.sections.items(.header), 0..) |header, i| {
        if (mem.eql(u8, header.segName(), segname) and mem.eql(u8, header.sectName(), sectname))
            return @as(u8, @intCast(i));
    } else return null;
}

pub fn getTlsAddress(self: MachO) u64 {
    for (self.sections.items(.header)) |header| switch (header.type()) {
        macho.S_THREAD_LOCAL_REGULAR,
        macho.S_THREAD_LOCAL_ZEROFILL,
        => return header.addr,
        else => {},
    };
    return 0;
}

pub inline fn getTextSegment(self: *MachO) *macho.segment_command_64 {
    return &self.segments.items[self.text_seg_index.?];
}

pub inline fn getLinkeditSegment(self: *MachO) *macho.segment_command_64 {
    return &self.segments.items[self.linkedit_seg_index.?];
}

pub fn getFile(self: *MachO, index: File.Index) ?File {
    const tag = self.files.items(.tags)[index];
    return switch (tag) {
        .null => null,
        .internal => .{ .internal = &self.files.items(.data)[index].internal },
        .object => .{ .object = &self.files.items(.data)[index].object },
        .dylib => .{ .dylib = &self.files.items(.data)[index].dylib },
    };
}

pub fn getInternalObject(self: *MachO) ?*InternalObject {
    const index = self.internal_object_index orelse return null;
    return self.getFile(index).?.internal;
}

pub fn addFileHandle(self: *MachO, file: std.fs.File) !File.HandleIndex {
    const gpa = self.base.allocator;
    const index: File.HandleIndex = @intCast(self.file_handles.items.len);
    const fh = try self.file_handles.addOne(gpa);
    fh.* = file;
    return index;
}

pub fn getFileHandle(self: MachO, index: File.HandleIndex) File.Handle {
    assert(index < self.file_handles.items.len);
    return self.file_handles.items[index];
}

fn addThunk(self: *MachO) !Thunk.Index {
    const index = @as(Thunk.Index, @intCast(self.thunks.items.len));
    const thunk = try self.thunks.addOne(self.base.allocator);
    thunk.* = .{};
    return index;
}

pub fn getThunk(self: *MachO, index: Thunk.Index) *Thunk {
    assert(index < self.thunks.items.len);
    return &self.thunks.items[index];
}

fn createThunks(self: *MachO, sect_id: u8) !void {
    const tracy = trace(@src());
    defer tracy.end();

    const advance = struct {
        fn advance(sect: *macho.section_64, size: u64, pow2_align: u32) !u64 {
            const alignment = try math.powi(u32, 2, pow2_align);
            const offset = mem.alignForward(u64, sect.size, alignment);
            const padding = offset - sect.size;
            sect.size += padding + size;
            sect.@"align" = @max(sect.@"align", pow2_align);
            return offset;
        }
    }.advance;

    const scanRelocations = struct {
        fn scanRelocations(thunk_index: Thunk.Index, gpa: Allocator, atoms: []const MachO.Ref, mf: *MachO) !void {
            const tr = trace(@src());
            defer tr.end();

            const thunk = mf.getThunk(thunk_index);

            for (atoms) |ref| {
                const atom = ref.getAtom(mf).?;
                log.debug("atom({d}) {s}", .{ atom.atom_index, atom.getName(mf) });
                for (atom.getRelocs(mf)) |rel| {
                    if (rel.type != .branch) continue;
                    if (Thunk.isReachable(atom, rel, mf)) continue;
                    try thunk.symbols.put(gpa, rel.getTargetSymbolRef(atom.*, mf), {});
                }
                atom.addExtra(.{ .thunk = thunk_index }, mf);
            }
        }
    }.scanRelocations;

    // Branch instruction has 26 bits immediate but is 4 byte aligned.
    const jump_bits = @bitSizeOf(i28);
    const max_distance = (1 << (jump_bits - 1));

    // A branch will need an extender if its target is larger than
    // `2^(jump_bits - 1) - margin` where margin is some arbitrary number.
    // mold uses 5MiB margin, while ld64 uses 4MiB margin. We will follow mold
    // and assume margin to be 5MiB.
    const max_allowed_distance = max_distance - 0x500_000;

    const gpa = self.base.allocator;
    const slice = self.sections.slice();
    const header = &slice.items(.header)[sect_id];
    const thnks = &slice.items(.thunks)[sect_id];
    const atoms = slice.items(.atoms)[sect_id].items;
    assert(atoms.len > 0);

    for (atoms) |ref| {
        ref.getAtom(self).?.value = @bitCast(@as(i64, -1));
    }

    var i: usize = 0;
    while (i < atoms.len) {
        const start = i;
        const start_atom = atoms[start].getAtom(self).?;
        assert(start_atom.alive.load(.seq_cst));
        start_atom.value = try advance(header, start_atom.size, start_atom.alignment);
        i += 1;

        while (i < atoms.len and
            header.size - start_atom.value < max_allowed_distance) : (i += 1)
        {
            const atom = atoms[i].getAtom(self).?;
            assert(atom.alive.load(.seq_cst));
            atom.value = try advance(header, atom.size, atom.alignment);
        }

        // Insert a thunk at the group end
        const thunk_index = try self.addThunk();
        const thunk = self.getThunk(thunk_index);
        thunk.out_n_sect = sect_id;
        try thnks.append(gpa, thunk_index);

        // Scan relocs in the group and create trampolines for any unreachable callsite
        try scanRelocations(thunk_index, gpa, atoms[start..i], self);
        thunk.value = try advance(header, thunk.size(), 2);

        log.debug("thunk({d}) : {}", .{ thunk_index, thunk.fmt(self) });
    }
}

pub fn eatPrefix(path: []const u8, prefix: []const u8) ?[]const u8 {
    if (mem.startsWith(u8, path, prefix)) return path[prefix.len..];
    return null;
}

pub fn dumpState(self: *MachO) std.fmt.Formatter(fmtDumpState) {
    return .{ .data = self };
}

fn fmtDumpState(
    self: *MachO,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    _ = unused_fmt_string;
    for (self.objects.items) |index| {
        const object = self.getFile(index).?.object;
        try writer.print("object({d}) : {} : has_debug({})", .{
            index,
            object.fmtPath(),
            object.hasDebugInfo(),
        });
        if (!object.alive) try writer.writeAll(" : ([*])");
        try writer.writeByte('\n');
        try writer.print("{}{}{}{}{}\n", .{
            object.fmtAtoms(self),
            object.fmtCies(self),
            object.fmtFdes(self),
            object.fmtUnwindRecords(self),
            object.fmtSymtab(self),
        });
    }
    for (self.dylibs.items) |index| {
        const dylib = self.getFile(index).?.dylib;
        try writer.print("dylib({d}) : {s} : needed({}) : weak({})", .{
            index,
            dylib.path,
            dylib.needed,
            dylib.weak,
        });
        if (!dylib.isAlive(self)) try writer.writeAll(" : ([*])");
        try writer.writeByte('\n');
        try writer.print("{}\n", .{dylib.fmtSymtab(self)});
    }
    if (self.getInternalObject()) |internal| {
        try writer.print("internal({d}) : internal\n", .{internal.index});
        try writer.print("{}{}\n", .{ internal.fmtAtoms(self), internal.fmtSymtab(self) });
    }
    try writer.writeAll("thunks\n");
    for (self.thunks.items, 0..) |thunk, index| {
        try writer.print("thunk({d}) : {}\n", .{ index, thunk.fmt(self) });
    }
    try writer.print("stubs\n{}\n", .{self.stubs.fmt(self)});
    try writer.print("objc_stubs\n{}\n", .{self.objc_stubs.fmt(self)});
    try writer.print("got\n{}\n", .{self.got.fmt(self)});
    try writer.print("tlv_ptr\n{}\n", .{self.tlv_ptr.fmt(self)});
    try writer.writeByte('\n');
    try writer.print("sections\n{}\n", .{self.fmtSections()});
    try writer.print("segments\n{}\n", .{self.fmtSegments()});
}

fn fmtSections(self: *MachO) std.fmt.Formatter(formatSections) {
    return .{ .data = self };
}

fn formatSections(
    self: *MachO,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    _ = unused_fmt_string;
    const slice = self.sections.slice();
    for (slice.items(.header), slice.items(.segment_id), 0..) |header, seg_id, i| {
        try writer.print("sect({d}) : seg({d}) : {s},{s} : @{x} ({x}) : align({x}) : size({x})\n", .{
            i,               seg_id,      header.segName(), header.sectName(), header.offset, header.addr,
            header.@"align", header.size,
        });
    }
}

fn fmtSegments(self: *MachO) std.fmt.Formatter(formatSegments) {
    return .{ .data = self };
}

fn formatSegments(
    self: *MachO,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    _ = unused_fmt_string;
    for (self.segments.items, 0..) |seg, i| {
        try writer.print("seg({d}) : {s} : @{x}-{x} ({x}-{x})\n", .{
            i,           seg.segName(),              seg.vmaddr, seg.vmaddr + seg.vmsize,
            seg.fileoff, seg.fileoff + seg.filesize,
        });
    }
}

pub fn fmtSectType(tt: u8) std.fmt.Formatter(formatSectType) {
    return .{ .data = tt };
}

fn formatSectType(
    tt: u8,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    _ = unused_fmt_string;
    const name = switch (tt) {
        macho.S_REGULAR => "REGULAR",
        macho.S_ZEROFILL => "ZEROFILL",
        macho.S_CSTRING_LITERALS => "CSTRING_LITERALS",
        macho.S_4BYTE_LITERALS => "4BYTE_LITERALS",
        macho.S_8BYTE_LITERALS => "8BYTE_LITERALS",
        macho.S_16BYTE_LITERALS => "16BYTE_LITERALS",
        macho.S_LITERAL_POINTERS => "LITERAL_POINTERS",
        macho.S_NON_LAZY_SYMBOL_POINTERS => "NON_LAZY_SYMBOL_POINTERS",
        macho.S_LAZY_SYMBOL_POINTERS => "LAZY_SYMBOL_POINTERS",
        macho.S_SYMBOL_STUBS => "SYMBOL_STUBS",
        macho.S_MOD_INIT_FUNC_POINTERS => "MOD_INIT_FUNC_POINTERS",
        macho.S_MOD_TERM_FUNC_POINTERS => "MOD_TERM_FUNC_POINTERS",
        macho.S_COALESCED => "COALESCED",
        macho.S_GB_ZEROFILL => "GB_ZEROFILL",
        macho.S_INTERPOSING => "INTERPOSING",
        macho.S_DTRACE_DOF => "DTRACE_DOF",
        macho.S_THREAD_LOCAL_REGULAR => "THREAD_LOCAL_REGULAR",
        macho.S_THREAD_LOCAL_ZEROFILL => "THREAD_LOCAL_ZEROFILL",
        macho.S_THREAD_LOCAL_VARIABLES => "THREAD_LOCAL_VARIABLES",
        macho.S_THREAD_LOCAL_VARIABLE_POINTERS => "THREAD_LOCAL_VARIABLE_POINTERS",
        macho.S_THREAD_LOCAL_INIT_FUNCTION_POINTERS => "THREAD_LOCAL_INIT_FUNCTION_POINTERS",
        macho.S_INIT_FUNC_OFFSETS => "INIT_FUNC_OFFSETS",
        else => |x| return writer.print("UNKNOWN({x})", .{x}),
    };
    try writer.print("{s}", .{name});
}

pub const LinkObject = struct {
    path: []const u8 = "",
    tag: enum { obj, lib, framework },
    needed: bool = false,
    weak: bool = false,
    hidden: bool = false,
    reexport: bool = false,
    must_link: bool = false,

    pub fn format(
        self: LinkObject,
        comptime unused_fmt_string: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = unused_fmt_string;
        switch (self.tag) {
            .lib => if (self.needed) {
                try writer.writeAll("-needed-l");
            } else if (self.weak) {
                try writer.writeAll("-weak-l");
            } else if (self.hidden) {
                try writer.writeAll("-hidden-l");
            } else if (self.reexport) {
                try writer.writeAll("-reexport-l");
            } else try writer.writeAll("-l"),

            .framework => if (self.needed) {
                try writer.writeAll("-needed_framework ");
            } else if (self.weak) {
                try writer.writeAll("-weak_framework ");
            } else try writer.writeAll("-framework "),

            .obj => if (self.must_link) {
                try writer.writeAll("-force_load ");
            } else if (self.hidden) {
                try writer.writeAll("-load_hidden ");
            },
        }
        try writer.writeAll(self.path);
    }
};

/// Default virtual memory offset corresponds to the size of __PAGEZERO segment and
/// start of __TEXT segment.
const default_pagezero_vmsize: u64 = 0x100000000;

pub const LiteralPool = struct {
    table: std.AutoArrayHashMapUnmanaged(void, void) = .{},
    keys: std.ArrayListUnmanaged(Key) = .{},
    values: std.ArrayListUnmanaged(MachO.Ref) = .{},
    data: std.ArrayListUnmanaged(u8) = .{},

    pub fn deinit(lp: *LiteralPool, allocator: Allocator) void {
        lp.table.deinit(allocator);
        lp.keys.deinit(allocator);
        lp.values.deinit(allocator);
        lp.data.deinit(allocator);
    }

    const InsertResult = struct {
        found_existing: bool,
        index: Index,
        ref: *MachO.Ref,
    };

    pub fn getSymbolRef(lp: LiteralPool, index: Index) MachO.Ref {
        assert(index < lp.values.items.len);
        return lp.values.items[index];
    }

    pub fn getSymbol(lp: LiteralPool, index: Index, macho_file: *MachO) *Symbol {
        return lp.getSymbolRef(index).getSymbol(macho_file).?;
    }

    pub fn insert(lp: *LiteralPool, allocator: Allocator, @"type": u8, string: []const u8) !InsertResult {
        const size: u32 = @intCast(string.len);
        try lp.data.ensureUnusedCapacity(allocator, size);
        const off: u32 = @intCast(lp.data.items.len);
        lp.data.appendSliceAssumeCapacity(string);
        const adapter = Adapter{ .lp = lp };
        const key = Key{ .off = off, .size = size, .seed = @"type" };
        const gop = try lp.table.getOrPutAdapted(allocator, key, adapter);
        if (!gop.found_existing) {
            try lp.keys.append(allocator, key);
            _ = try lp.values.addOne(allocator);
        }
        return .{
            .found_existing = gop.found_existing,
            .index = @intCast(gop.index),
            .ref = &lp.values.items[gop.index],
        };
    }

    const Key = struct {
        off: u32,
        size: u32,
        seed: u8,

        fn getData(key: Key, lp: *const LiteralPool) []const u8 {
            return lp.data.items[key.off..][0..key.size];
        }

        fn eql(key: Key, other: Key, lp: *const LiteralPool) bool {
            const key_data = key.getData(lp);
            const other_data = other.getData(lp);
            return mem.eql(u8, key_data, other_data);
        }

        fn hash(key: Key, lp: *const LiteralPool) u32 {
            const data = key.getData(lp);
            return @truncate(Hash.hash(key.seed, data));
        }
    };

    const Adapter = struct {
        lp: *const LiteralPool,

        pub fn eql(ctx: @This(), key: Key, b_void: void, b_map_index: usize) bool {
            _ = b_void;
            const other = ctx.lp.keys.items[b_map_index];
            return key.eql(other, ctx.lp);
        }

        pub fn hash(ctx: @This(), key: Key) u32 {
            return key.hash(ctx.lp);
        }
    };

    pub const Index = u32;
};

const Section = struct {
    header: macho.section_64,
    segment_id: u8,
    atoms: std.ArrayListUnmanaged(Ref) = .{},
    thunks: std.ArrayListUnmanaged(Thunk.Index) = .{},
    out: std.ArrayListUnmanaged(u8) = .{},
    relocs: std.ArrayListUnmanaged(macho.relocation_info) = .{},
};

pub const SymtabCtx = struct {
    ilocal: u32 = 0,
    istab: u32 = 0,
    iexport: u32 = 0,
    iimport: u32 = 0,
    nlocals: u32 = 0,
    nstabs: u32 = 0,
    nexports: u32 = 0,
    nimports: u32 = 0,
    stroff: u32 = 0,
    strsize: u32 = 0,
};

pub const null_sym = macho.nlist_64{
    .n_strx = 0,
    .n_type = 0,
    .n_sect = 0,
    .n_desc = 0,
    .n_value = 0,
};

/// A reference to atom or symbol in an input file.
/// If file == 0, symbol is an undefined global.
pub const Ref = struct {
    index: u32,
    file: File.Index,

    pub fn eql(ref: Ref, other: Ref) bool {
        return ref.index == other.index and ref.file == other.file;
    }

    pub fn lessThan(ref: Ref, other: Ref) bool {
        if (ref.file == other.file) {
            return ref.index < other.index;
        }
        return ref.file < other.file;
    }

    pub fn getFile(ref: Ref, macho_file: *MachO) ?File {
        return macho_file.getFile(ref.file);
    }

    pub fn getAtom(ref: Ref, macho_file: *MachO) ?*Atom {
        const file = ref.getFile(macho_file) orelse return null;
        return file.getAtom(ref.index);
    }

    pub fn getSymbol(ref: Ref, macho_file: *MachO) ?*Symbol {
        const file = ref.getFile(macho_file) orelse return null;
        return switch (file) {
            inline else => |x| &x.symbols.items[ref.index],
        };
    }

    pub fn format(
        ref: Ref,
        comptime unused_fmt_string: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = unused_fmt_string;
        _ = options;
        try writer.print("%{d} in file({d})", .{ ref.index, ref.file });
    }
};

pub const SymbolResolver = struct {
    keys: std.ArrayListUnmanaged(Key) = .{},
    values: std.ArrayListUnmanaged(Ref) = .{},
    table: std.AutoArrayHashMapUnmanaged(void, void) = .{},

    const Result = struct {
        found_existing: bool,
        index: Index,
        ref: *Ref,
    };

    pub fn deinit(resolver: *SymbolResolver, allocator: Allocator) void {
        resolver.keys.deinit(allocator);
        resolver.values.deinit(allocator);
        resolver.table.deinit(allocator);
    }

    pub fn getOrPut(
        resolver: *SymbolResolver,
        allocator: Allocator,
        ref: Ref,
        macho_file: *MachO,
    ) !Result {
        const adapter = Adapter{ .keys = resolver.keys.items, .macho_file = macho_file };
        const key = Key{ .index = ref.index, .file = ref.file };
        const gop = try resolver.table.getOrPutAdapted(allocator, key, adapter);
        if (!gop.found_existing) {
            try resolver.keys.append(allocator, key);
            _ = try resolver.values.addOne(allocator);
        }
        return .{
            .found_existing = gop.found_existing,
            .index = @intCast(gop.index + 1),
            .ref = &resolver.values.items[gop.index],
        };
    }

    pub fn get(resolver: SymbolResolver, index: Index) ?Ref {
        if (index == 0) return null;
        return resolver.values.items[index - 1];
    }

    pub fn reset(resolver: *SymbolResolver) void {
        resolver.keys.clearRetainingCapacity();
        resolver.values.clearRetainingCapacity();
        resolver.table.clearRetainingCapacity();
    }

    const Key = struct {
        index: Symbol.Index,
        file: File.Index,

        fn getName(key: Key, macho_file: *MachO) [:0]const u8 {
            const ref = Ref{ .index = key.index, .file = key.file };
            return ref.getSymbol(macho_file).?.getName(macho_file);
        }

        fn getFile(key: Key, macho_file: *MachO) ?File {
            const ref = Ref{ .index = key.index, .file = key.file };
            return ref.getFile(macho_file);
        }

        fn eql(key: Key, other: Key, macho_file: *MachO) bool {
            const key_name = key.getName(macho_file);
            const other_name = other.getName(macho_file);
            return mem.eql(u8, key_name, other_name);
        }

        fn hash(key: Key, macho_file: *MachO) u32 {
            const name = key.getName(macho_file);
            return @truncate(Hash.hash(0, name));
        }
    };

    const Adapter = struct {
        keys: []const Key,
        macho_file: *MachO,

        pub fn eql(ctx: @This(), key: Key, b_void: void, b_map_index: usize) bool {
            _ = b_void;
            const other = ctx.keys[b_map_index];
            return key.eql(other, ctx.macho_file);
        }

        pub fn hash(ctx: @This(), key: Key) u32 {
            return key.hash(ctx.macho_file);
        }
    };

    pub const Index = u32;
};

pub const UndefRefs = union(enum) {
    force_undefined,
    entry,
    dyld_stub_binder,
    objc_msgsend,
    refs: std.ArrayListUnmanaged(Ref),

    pub fn deinit(self: *UndefRefs, allocator: Allocator) void {
        switch (self.*) {
            .refs => |*refs| refs.deinit(allocator),
            else => {},
        }
    }
};

pub const String = struct {
    pos: u32 = 0,
    len: u32 = 0,
};

pub const base_tag = Ld.Tag.macho;

const aarch64 = @import("aarch64.zig");
const assert = std.debug.assert;
const build_options = @import("build_options");
const builtin = @import("builtin");
const calcUuid = @import("MachO/uuid.zig").calcUuid;
const dead_strip = @import("MachO/dead_strip.zig");
const dwarf = std.dwarf;
const eh_frame = @import("MachO/eh_frame.zig");
const fat = @import("MachO/fat.zig");
const fmt = std.fmt;
const fs = std.fs;
const load_commands = @import("MachO/load_commands.zig");
const log = std.log.scoped(.link);
const macho = std.macho;
const math = std.math;
const mem = std.mem;
const meta = std.meta;
const relocatable = @import("MachO/relocatable.zig");
const synthetic = @import("MachO/synthetic.zig");
const state_log = std.log.scoped(.state);
const std = @import("std");
const trace = @import("tracy.zig").trace;

const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Archive = @import("MachO/Archive.zig");
const Atom = @import("MachO/Atom.zig");
const AtomicBool = std.atomic.Value(bool);
const Bind = synthetic.Bind;
const CodeSignature = @import("MachO/CodeSignature.zig");
const DataInCode = synthetic.DataInCode;
const Dylib = @import("MachO/Dylib.zig");
const ExportTrie = synthetic.ExportTrie;
const File = @import("MachO/file.zig").File;
const GotSection = synthetic.GotSection;
const Hash = std.hash.Wyhash;
const Indsymtab = synthetic.Indsymtab;
const InternalObject = @import("MachO/InternalObject.zig");
const Ld = @import("Ld.zig");
const MachO = @This();
const Md5 = std.crypto.hash.Md5;
const Object = @import("MachO/Object.zig");
const ObjcStubsSection = synthetic.ObjcStubsSection;
pub const Options = @import("MachO/Options.zig");
const LazyBind = synthetic.LazyBind;
const LaSymbolPtrSection = synthetic.LaSymbolPtrSection;
const LibStub = @import("tapi.zig").LibStub;
const Rebase = @import("MachO/dyld_info/Rebase.zig");
const Symbol = @import("MachO/Symbol.zig");
const StringTable = @import("StringTable.zig");
const StubsSection = synthetic.StubsSection;
const StubsHelperSection = synthetic.StubsHelperSection;
const Thunk = @import("MachO/Thunk.zig");
const ThreadPool = std.Thread.Pool;
const TlvPtrSection = synthetic.TlvPtrSection;
const UnwindInfo = @import("MachO/UnwindInfo.zig");
const WaitGroup = std.Thread.WaitGroup;
const WeakBind = synthetic.WeakBind;
