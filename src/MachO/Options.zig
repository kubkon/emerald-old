const Options = @This();

const std = @import("std");
const builtin = @import("builtin");
const io = std.io;
const macho = std.macho;
const mem = std.mem;
const process = std.process;

const Allocator = mem.Allocator;
const CrossTarget = std.zig.CrossTarget;
const MachO = @import("../MachO.zig");
const Ld = @import("../Ld.zig");

pub const SearchStrategy = enum {
    paths_first,
    dylibs_first,
};

const usage =
    \\Usage: {s} [files...]
    \\
    \\General Options:
    \\-adhoc_codesign                    Generates adhoc code signature (default for Apple Silicon)
    \\-no_adhoc_codesign                 Does not generate adhoc code signature
    \\-all_load                          Loads all members of all static archive libraries
    \\-arch [name]                       Specifies which architecture the output file should be
    \\-arch_multiple                     Specifies that the linker should augment error and warning
    \\                                   messages with the architecture name.
    \\-current_version [value]           Specifies the current version number of the library
    \\-compatibility_version [value]     Specifies the compatibility version number of the library
    \\-dead_strip                        Remove functions and data that are unreachable by the entry point or 
    \\                                   exported symbols
    \\-dead_strip_dylibs                 Remove dylibs that were unreachable by the entry point or exported symbols
    \\--debug-log [scope]                Turn on debugging logs for [scope] (requires linker compiled with -Dlog)
    \\-dylib                             Create dynamic library
    \\-dynamic                           Perform dynamic linking
    \\-e [name]                          Specifies the entry point of main executable
    \\-execute                           Create an executable (default)
    \\-exported_symbol [name]            Marks symbol [name] as global
    \\-exported_symbols_list [filename]  Specifies which symbols are to be marked as global
    \\--entitlements                     Add path to entitlements file for embedding in code signature
    \\-filelist [file[,dirname]]         Specifies a list of files to link. If the optional [dirname] is
    \\                                   specified, it is prepended to each filename in the list file.
    \\-final_output                      Specify dylib install name if -install_name is not used. This flags
    \\                                   is used by compiler driver for multiple -arch arguments.
    \\-flat_namespace                    Use flat namespace dylib resolution strategy
    \\-force_load [path]                 Loads all members of the specified static archive library
    \\-framework [name]                  Link against framework
    \\-F[path]                           Add search path for frameworks
    \\-headerpad [value]                 Set minimum space for future expansion of the load commands
    \\                                   in hexadecimal notation
    \\-headerpad_max_install_names       Set enough space as if all paths were MAXPATHLEN
    \\--help                             Print this help and exit
    \\-hidden-l[name]                    Link against a static library but treat symbols as visibility hidden.
    \\  -load_hidden [name]
    \\-install_name                      Add dylib's install name
    \\  -dylib_install_name
    \\-l[name]                           Link against library
    \\-L[path]                           Add search path for libraries
    \\-macos_version_min [version]       Set oldest macOS version that the output can be used on.
    \\-needed_framework [name]           Link against framework (even if unused)
    \\-needed-l[name]                    Link against library (even if unused)
    \\  -needed_library [name]           
    \\-no_deduplicate                    Do not run deduplication pass in linker
    \\-no_fixup_chains                   Do not emit fixup chains
    \\-no_implicit_dylibs                Do not hoist public dylibs/frameworks into the final image.
    \\-o [path]                          Specify output path for the final artifact
    \\-ObjC                              Force load all members of static archives that implement an
    \\                                   Objective-C class or category
    \\-Ox                                Set optimisation level from values: [0, 1, 2].
    \\                                   This option is currently unused.
    \\-pagezero_size [value]             Size of the __PAGEZERO segment in hexademical notation
    \\-platform_version [platform] [min_version] [sdk_version]
    \\                                   Sets the platform, oldest supported version of that platform and 
    \\                                   the SDK it was built against
    \\-r                                 Create a relocatable object file
    \\-reexport-l[name]                  Link against library and re-export it for the clients
    \\  -reexport_library [name]
    \\-rpath [path]                      Specify runtime path
    \\-S                                 Do not put debug information (STABS or DWARF) in the symbol table
    \\-search_paths_first                Search each dir in library search paths for `libx.dylib` then `libx.a`
    \\-search_dylibs_first               Search `libx.dylib` in each dir in library search paths, then `libx.a`
    \\-stack_size [value]                Size of the default stack in hexadecimal notation
    \\-syslibroot [path]                 Specify the syslibroot
    \\-two_levelnamespace                Use two-level namespace dylib resolution strategy (default)
    \\-u [name]                          Specifies symbol which has to be resolved at link time for the link to succeed
    \\-undefined [value]                 Specify how undefined symbols are to be treated: 
    \\                                   error (default), warning, suppress, or dynamic_lookup.
    \\-v                                 Print version
    \\--verbose                          Print full linker invocation to stderr
    \\-weak_framework [name]             Link against framework and mark it and all referenced symbols as weak
    \\-weak-l[name]                      Link against library and mark it and all referenced symbols as weak
    \\  -weak_library [name]
    \\-x                                 Do not put non-global symbols in the symbol table
    \\
    \\ld64.emerald: supported targets: macho-x86-64, macho-arm64
    \\ld64.emerald: supported emulations: macho_x86_64, macho_arm64
;

const version =
    \\ld64.emerald 0.0.4 (compatible with Apple ld64)
;

const cmd = "ld64.emerald";

emit: Ld.Emit,
dylib: bool = false,
relocatable: bool = false,
dynamic: bool = false,
cpu_arch: ?std.Target.Cpu.Arch = null,
arch_multiple: bool = false,
platform: ?Platform = null,
sdk_version: ?Version = null,
inferred_platform_versions: [supported_platforms.len]Platform = undefined,
positionals: []const MachO.LinkObject,
lib_dirs: []const []const u8,
framework_dirs: []const []const u8,
rpath_list: []const []const u8,
syslibroot: ?[]const u8 = null,
stack_size: ?u64 = null,
strip: bool = false,
strip_locals: bool = false,
entry: ?[]const u8 = null,
force_undefined_symbols: []const []const u8 = &[0][]const u8{},
current_version: ?Version = null,
compatibility_version: ?Version = null,
install_name: ?[]const u8 = null,
entitlements: ?[]const u8 = null,
pagezero_size: ?u64 = null,
search_strategy: ?SearchStrategy = null,
headerpad: ?u32 = null,
headerpad_max_install_names: bool = false,
dead_strip: bool = false,
dead_strip_dylibs: bool = false,
undefined_treatment: UndefinedTreatment = .@"error",
no_deduplicate: bool = false,
no_implicit_dylibs: bool = false,
namespace: Namespace = .two_level,
all_load: bool = false,
force_load_objc: bool = false,
adhoc_codesign: ?bool = null,
exported_symbols: []const []const u8 = &[0][]const u8{},
fixup_chains: bool = false, // TODO default should be true but probably depends on the host version
final_output: ?[]const u8 = null,

pub fn parse(arena: Allocator, args: []const []const u8, ctx: anytype) !Options {
    if (args.len == 0) ctx.fatal(usage ++ "\n", .{cmd});

    var positionals = std.ArrayList(MachO.LinkObject).init(arena);
    var lib_dirs = std.StringArrayHashMap(void).init(arena);
    var framework_dirs = std.StringArrayHashMap(void).init(arena);
    var rpath_list = std.StringArrayHashMap(void).init(arena);
    var force_undefined_symbols = std.StringArrayHashMap(void).init(arena);
    var exported_symbols = std.StringArrayHashMap(void).init(arena);
    var print_version = false;
    var verbose = false;
    var opts: Options = .{
        .emit = .{
            .directory = std.fs.cwd(),
            .sub_path = "a.out",
        },
        .positionals = undefined,
        .lib_dirs = undefined,
        .framework_dirs = undefined,
        .rpath_list = undefined,
    };
    var unknown_options = std.ArrayList(u8).init(arena);

    var it = Ld.Options.ArgsIterator{ .args = args };
    var p = Ld.ArgParser(@TypeOf(ctx)){ .it = &it, .ctx = ctx };
    while (p.hasMore()) {
        if (p.flag2("help")) {
            ctx.fatal(usage ++ "\n", .{cmd});
        } else if (p.arg2("debug-log")) |scope| {
            try ctx.log_scopes.append(scope);
        } else if (p.arg2("entitlements")) |path| {
            opts.entitlements = path;
        } else if (p.flag1("v")) {
            print_version = true;
        } else if (p.flag2("verbose")) {
            verbose = true;
        } else if (p.arg1("syslibroot")) |path| {
            opts.syslibroot = path;
        } else if (p.flag1("search_paths_first")) {
            opts.search_strategy = .paths_first;
        } else if (p.flag1("search_dylibs_first")) {
            opts.search_strategy = .dylibs_first;
        } else if (p.arg1("framework")) |path| {
            try positionals.append(.{ .path = path, .tag = .framework });
        } else if (p.arg1("F")) |path| {
            try framework_dirs.put(path, {});
        } else if (p.arg1("hidden-l")) |path| {
            try positionals.append(.{ .path = path, .tag = .lib, .hidden = true });
        } else if (p.arg1("needed-l")) |path| {
            try positionals.append(.{ .path = path, .tag = .lib, .needed = true });
        } else if (p.arg1("needed_library")) |path| {
            try positionals.append(.{ .path = path, .tag = .lib, .needed = true });
        } else if (p.arg1("needed_framework")) |path| {
            try positionals.append(.{ .path = path, .tag = .framework, .needed = true });
        } else if (p.arg1("reexport-l")) |path| {
            try positionals.append(.{ .path = path, .tag = .lib, .reexport = true });
        } else if (p.arg1("reexport_library")) |path| {
            try positionals.append(.{ .path = path, .tag = .lib, .reexport = true });
        } else if (p.arg1("weak-l")) |path| {
            try positionals.append(.{ .path = path, .tag = .lib, .weak = true });
        } else if (p.arg1("weak_library")) |path| {
            try positionals.append(.{ .path = path, .tag = .lib, .weak = true });
        } else if (p.arg1("weak_framework")) |path| {
            try positionals.append(.{ .path = path, .tag = .framework, .weak = true });
        } else if (p.arg1("o")) |path| {
            opts.emit.sub_path = path;
        } else if (p.arg1("stack_size")) |value| {
            opts.stack_size = std.fmt.parseUnsigned(u64, value, 0) catch
                ctx.fatal("Could not parse value '{s}' into integer\n", .{value});
        } else if (p.flag1("dylib")) {
            opts.dylib = true;
        } else if (p.flag1("dynamic")) {
            opts.dynamic = true;
        } else if (p.flag1("static")) {
            opts.dynamic = false;
        } else if (p.arg1("rpath")) |path| {
            try rpath_list.put(path, {});
        } else if (p.arg1("compatibility_version")) |raw| {
            opts.compatibility_version = Version.parse(raw) orelse
                ctx.fatal("Unable to parse version from '{s}'\n", .{raw});
        } else if (p.arg1("current_version")) |raw| {
            opts.current_version = Version.parse(raw) orelse
                ctx.fatal("Unable to parse version from '{s}'\n", .{raw});
        } else if (p.arg1("install_name")) |name| {
            opts.install_name = name;
        } else if (p.arg1("dylib_install_name")) |name| {
            opts.install_name = name;
        } else if (p.arg1("headerpad")) |value| {
            opts.headerpad = std.fmt.parseUnsigned(u32, value, 0) catch
                ctx.fatal("Could not parse value '{s}' into integer\n", .{value});
        } else if (p.flag1("headerpad_max_install_names")) {
            opts.headerpad_max_install_names = true;
        } else if (p.arg1("pagezero_size")) |value| {
            opts.pagezero_size = std.fmt.parseUnsigned(u64, value, 0) catch
                ctx.fatal("Could not parse value '{s}' into integer\n", .{value});
        } else if (p.flag1("dead_strip")) {
            opts.dead_strip = true;
        } else if (p.flag1("dead_strip_dylibs")) {
            opts.dead_strip_dylibs = true;
        } else if (p.arg1("exported_symbol")) |name| {
            try exported_symbols.put(name, {});
        } else if (p.arg1("exported_symbols_list")) |filename| {
            parseExportedSymbolsListFromFile(arena, filename, &exported_symbols) catch |err| switch (err) {
                error.FileNotFound => ctx.fatal("Specified file in -exported_symbols_list {s} does not exist\n", .{filename}),
                else => |e| return e,
            };
        } else if (p.flag1("execute")) {
            opts.dylib = false;
        } else if (p.arg1("e")) |name| {
            opts.entry = name;
        } else if (p.arg1("undefined")) |treatment| {
            if (mem.eql(u8, treatment, "error")) {
                opts.undefined_treatment = .@"error";
            } else if (mem.eql(u8, treatment, "warning")) {
                opts.undefined_treatment = .warn;
            } else if (mem.eql(u8, treatment, "suppress")) {
                opts.undefined_treatment = .suppress;
            } else if (mem.eql(u8, treatment, "dynamic_lookup")) {
                opts.undefined_treatment = .dynamic_lookup;
            } else {
                ctx.fatal("Unknown option -undefined {s}\n", .{treatment});
            }
        } else if (p.arg1("u")) |name| {
            try force_undefined_symbols.put(name, {});
        } else if (p.flag1("S")) {
            opts.strip = true;
        } else if (p.flag1("x")) {
            opts.strip_locals = true;
        } else if (p.flag1("r")) {
            opts.relocatable = true;
        } else if (p.flag1("all_load")) {
            opts.all_load = true;
        } else if (p.arg1("force_load")) |path| {
            try positionals.append(.{ .path = path, .tag = .obj, .must_link = true });
        } else if (p.arg1("load_hidden")) |path| {
            try positionals.append(.{ .path = path, .tag = .obj, .hidden = true });
        } else if (p.arg1("arch")) |value| {
            if (mem.eql(u8, value, "arm64")) {
                opts.cpu_arch = .aarch64;
            } else if (mem.eql(u8, value, "x86_64")) {
                opts.cpu_arch = .x86_64;
            } else {
                ctx.fatal("Could not parse CPU architecture from '{s}'\n", .{value});
            }
        } else if (p.flag1("arch_multiple")) {
            opts.arch_multiple = true;
        } else if (p.arg1("macos_version_min")) |ver| {
            const min_ver = Version.parse(ver) orelse
                ctx.fatal("Unable to parse version from '{s}'\n", .{version});
            opts.platform = .{ .platform = .MACOS, .version = min_ver };
        } else if (p.arg1("platform_version")) |platform_s| {
            // TODO clunky!
            const min_v = it.next() orelse
                ctx.fatal("Expected minimum platform version after '{s}' '{s}'\n", .{ p.arg, platform_s });
            const sdk_v = it.next() orelse
                ctx.fatal("Expected SDK version after '{s}' '{s}' '{s}'\n", .{ p.arg, platform_s, min_v });

            var tmp_platform: macho.PLATFORM = undefined;

            // First, try parsing platform as a numeric value.
            if (std.fmt.parseUnsigned(u32, platform_s, 10)) |ord| {
                tmp_platform = @as(macho.PLATFORM, @enumFromInt(ord));
            } else |_| {
                if (mem.eql(u8, platform_s, "macos")) {
                    tmp_platform = .MACOS;
                } else if (mem.eql(u8, platform_s, "ios")) {
                    tmp_platform = .IOS;
                } else if (mem.eql(u8, platform_s, "tvos")) {
                    tmp_platform = .TVOS;
                } else if (mem.eql(u8, platform_s, "watchos")) {
                    tmp_platform = .WATCHOS;
                } else if (mem.eql(u8, platform_s, "xros")) {
                    tmp_platform = .VISIONOS;
                } else if (mem.eql(u8, platform_s, "ios-simulator")) {
                    tmp_platform = .IOSSIMULATOR;
                } else if (mem.eql(u8, platform_s, "tvos-simulator")) {
                    tmp_platform = .TVOSSIMULATOR;
                } else if (mem.eql(u8, platform_s, "watchos-simulator")) {
                    tmp_platform = .WATCHOSSIMULATOR;
                } else if (mem.eql(u8, platform_s, "xros-simulator")) {
                    tmp_platform = .VISIONOSSIMULATOR;
                } else {
                    ctx.fatal("Unsupported Apple OS: {s}\n", .{platform_s});
                }
            }

            const min_ver = Version.parse(min_v) orelse
                ctx.fatal("Unable to parse version from '{s}'\n", .{min_v});
            opts.sdk_version = Version.parse(sdk_v) orelse
                ctx.fatal("Unable to parse version from '{s}'\n", .{sdk_v});
            opts.platform = .{ .platform = tmp_platform, .version = min_ver };
        } else if (p.arg1("lto_library")) |path| {
            std.log.debug("TODO unimplemented -lto_library {s} option", .{path});
        } else if (p.flag1("demangle")) {
            std.log.debug("TODO unimplemented -demangle option", .{});
        } else if (p.arg1("l")) |path| {
            try positionals.append(.{ .path = path, .tag = .lib });
        } else if (p.arg1("L")) |path| {
            try lib_dirs.put(path, {});
        } else if (p.flag1("no_deduplicate")) {
            opts.no_deduplicate = true;
        } else if (p.flag1("no_implicit_dylibs")) {
            opts.no_implicit_dylibs = true;
        } else if (p.flag1("no_fixup_chains")) {
            opts.fixup_chains = false;
        } else if (p.flag1("two_levelnamespace")) {
            opts.namespace = .two_level;
        } else if (p.flag1("flat_namespace")) {
            opts.namespace = .flat;
        } else if (p.flag1("ObjC")) {
            opts.force_load_objc = true;
        } else if (p.arg1("O")) |level_string| {
            // Purposely ignored but still validate for acceptable values.
            const level = std.fmt.parseUnsigned(u8, level_string, 0) catch
                ctx.fatal("Could not parse value '{s}' into integer\n", .{level_string});
            switch (level) {
                0...2 => {},
                else => ctx.fatal("Invalid optimisation level value '{d}', allowed [0, 1, 2]", .{level}),
            }
        } else if (p.flag1("adhoc_codesign")) {
            opts.adhoc_codesign = true;
        } else if (p.flag1("no_adhoc_codesign")) {
            opts.adhoc_codesign = false;
        } else if (p.arg1("filelist")) |filename_with_dirname| {
            parseFileList(arena, filename_with_dirname, &positionals) catch |err| switch (err) {
                error.FileNotFound => ctx.fatal("Specified file in -filelist {s} does not exist\n", .{
                    filename_with_dirname,
                }),
                else => |e| return e,
            };
        } else if (p.argLLVM()) |opt| {
            // Skip any LTO flags since we cannot handle it at the moment anyhow.
            std.log.debug("TODO unimplemented -mllvm {s} option", .{opt});
        } else if (p.arg1("final_output")) |name| {
            opts.final_output = name;
        } else if (mem.startsWith(u8, p.arg, "-")) {
            try unknown_options.appendSlice(p.arg);
            try unknown_options.append('\n');
        } else {
            try positionals.append(.{ .path = p.arg, .tag = .obj });
        }
    }

    if (verbose) {
        std.debug.lockStdErr();
        defer std.debug.unlockStdErr();
        ctx.print("{s} ", .{cmd});
        for (args[0 .. args.len - 1]) |arg| {
            ctx.print("{s} ", .{arg});
        }
        ctx.print("{s}\n", .{args[args.len - 1]});
    }

    if (print_version) {
        std.debug.lockStdErr();
        defer std.debug.unlockStdErr();
        ctx.print("{s}\n", .{version});
    }

    if (unknown_options.items.len > 0) {
        ctx.fatal("Unknown options:\n{s}", .{unknown_options.items});
    }

    if (positionals.items.len == 0) {
        ctx.fatal("Expected at least one positional argument\n", .{});
    }

    if (opts.namespace == .two_level) switch (opts.undefined_treatment) {
        .warn, .suppress => |x| ctx.fatal("illegal flags: '-undefined {s}' with '-two_levelnamespace'\n", .{
            @tagName(x),
        }),
        else => {},
    };

    if (opts.adhoc_codesign) |cs| {
        if (!cs and opts.entitlements != null) {
            ctx.fatal("illegal flags: '--entitlements {s}' with -no_adhoc_codesign\n", .{opts.entitlements.?});
        }
    }

    // Add some defaults
    try lib_dirs.put("/usr/lib", {});
    try framework_dirs.put("/System/Library/Frameworks", {});

    opts.positionals = positionals.items;
    opts.lib_dirs = lib_dirs.keys();
    opts.framework_dirs = framework_dirs.keys();
    opts.rpath_list = rpath_list.keys();
    opts.force_undefined_symbols = force_undefined_symbols.keys();
    opts.exported_symbols = exported_symbols.keys();

    try opts.inferPlatformVersions(arena);

    return opts;
}

fn parseExportedSymbolsListFromFile(arena: Allocator, filename: []const u8, exported_symbols: *std.StringArrayHashMap(void)) !void {
    const file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();
    const data = try file.readToEndAlloc(arena, std.math.maxInt(u32));
    var it = mem.tokenizeScalar(u8, data, '\n');
    while (it.next()) |line| {
        const trimmed = mem.trim(u8, line, " ");
        if (trimmed.len == 0) continue;
        try exported_symbols.put(trimmed, {});
    }
}

fn parseFileList(arena: Allocator, filename_with_dirname: []const u8, positionals: *std.ArrayList(MachO.LinkObject)) !void {
    const dirname, const filename = if (std.mem.indexOfScalar(u8, filename_with_dirname, ',')) |index|
        .{ filename_with_dirname[index + 1 ..], filename_with_dirname[0..index] }
    else
        .{ null, filename_with_dirname };
    const file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();
    const data = try file.readToEndAlloc(arena, std.math.maxInt(u32));
    var it = mem.tokenizeScalar(u8, data, '\n');
    while (it.next()) |line| {
        const trimmed = mem.trim(u8, line, " ");
        if (trimmed.len == 0) continue;
        const full_path = if (dirname) |dir|
            try std.fs.path.join(arena, &.{ dir, trimmed })
        else
            trimmed;
        try positionals.append(.{ .path = full_path, .tag = .obj });
    }
}

fn inferPlatformVersions(opts: *Options, arena: Allocator) !void {
    inline for (&opts.inferred_platform_versions, 0..) |*platform, i| {
        platform.* = .{ .platform = supported_platforms[i][0], .version = .{ .value = 0 } };
    }

    inline for (&opts.inferred_platform_versions, 0..) |*platform, i| {
        if (supported_platforms[i][3].len > 0) {
            const var_name = supported_platforms[i][3];
            if (std.process.getEnvVarOwned(arena, var_name)) |env_var| {
                const v = Version.parse(env_var) orelse Version{ .value = 0 };
                platform.* = .{ .platform = supported_platforms[i][0], .version = v };
            } else |_| {}
        }
    }
}

pub const Platform = struct {
    platform: macho.PLATFORM,
    version: Version,

    /// Using Apple's ld64 as our blueprint, `min_version` as well as `sdk_version` are set to
    /// the extracted minimum platform version.
    pub fn fromLoadCommand(lc: macho.LoadCommandIterator.LoadCommand) Platform {
        switch (lc.cmd()) {
            .BUILD_VERSION => {
                const lc_cmd = lc.cast(macho.build_version_command).?;
                return .{
                    .platform = lc_cmd.platform,
                    .version = .{ .value = lc_cmd.minos },
                };
            },
            .VERSION_MIN_MACOSX,
            .VERSION_MIN_IPHONEOS,
            .VERSION_MIN_TVOS,
            .VERSION_MIN_WATCHOS,
            => {
                const lc_cmd = lc.cast(macho.version_min_command).?;
                return .{
                    .platform = switch (lc.cmd()) {
                        .VERSION_MIN_MACOSX => .MACOS,
                        .VERSION_MIN_IPHONEOS => .IOS,
                        .VERSION_MIN_TVOS => .TVOS,
                        .VERSION_MIN_WATCHOS => .WATCHOS,
                        else => unreachable,
                    },
                    .version = .{ .value = lc_cmd.version },
                };
            },
            else => unreachable,
        }
    }

    pub fn isBuildVersionCompatible(plat: Platform) bool {
        inline for (supported_platforms) |sup_plat| {
            if (sup_plat[0] == plat.platform) {
                return sup_plat[1] <= plat.version.value;
            }
        }
        return false;
    }
};

const UndefinedTreatment = enum {
    @"error",
    warn,
    suppress,
    dynamic_lookup,
};

const Namespace = enum {
    two_level,
    flat,
};

pub const Version = struct {
    value: u32,

    pub fn major(v: Version) u16 {
        return @as(u16, @truncate(v.value >> 16));
    }

    pub fn minor(v: Version) u8 {
        return @as(u8, @truncate(v.value >> 8));
    }

    pub fn patch(v: Version) u8 {
        return @as(u8, @truncate(v.value));
    }

    pub fn parse(raw: []const u8) ?Version {
        var parsed: [3]u16 = [_]u16{0} ** 3;
        var count: usize = 0;
        var it = std.mem.splitAny(u8, raw, ".");
        while (it.next()) |comp| {
            if (count >= 3) return null;
            parsed[count] = std.fmt.parseInt(u16, comp, 10) catch return null;
            count += 1;
        }
        if (count == 0) return null;
        const maj = parsed[0];
        const min = std.math.cast(u8, parsed[1]) orelse return null;
        const pat = std.math.cast(u8, parsed[2]) orelse return null;
        return Version.new(maj, min, pat);
    }

    pub fn new(maj: u16, min: u8, pat: u8) Version {
        return .{ .value = (@as(u32, @intCast(maj)) << 16) | (@as(u32, @intCast(min)) << 8) | pat };
    }

    pub fn format(
        v: Version,
        comptime unused_fmt_string: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = unused_fmt_string;
        _ = options;
        try writer.print("{d}.{d}.{d}", .{
            v.major(),
            v.minor(),
            v.patch(),
        });
    }
};

const SupportedPlatform = struct {
    macho.PLATFORM, // Platform identifier
    u32, // Min platform version for which to emit LC_BUILD_VERSION
    u32, // Min supported platform version
    []const u8, // Env var to look for
};

// Source: https://github.com/apple-oss-distributions/ld64/blob/59a99ab60399c5e6c49e6945a9e1049c42b71135/src/ld/PlatformSupport.cpp#L52
const supported_platforms = [_]SupportedPlatform{
    .{ .MACOS, 0xA0E00, 0xA0800, "MACOSX_DEPLOYMENT_TARGET" },
    .{ .IOS, 0xC0000, 0x70000, "IPHONEOS_DEPLOYMENT_TARGET" },
    .{ .TVOS, 0xC0000, 0x70000, "TVOS_DEPLOYMENT_TARGET" },
    .{ .WATCHOS, 0x50000, 0x20000, "WATCHOS_DEPLOYMENT_TARGET" },
    .{ .VISIONOS, 0x10000, 0x10000, "XROS_DEPLOYMENT_TARGET" },
    .{ .IOSSIMULATOR, 0xD0000, 0x80000, "" },
    .{ .TVOSSIMULATOR, 0xD0000, 0x80000, "" },
    .{ .WATCHOSSIMULATOR, 0x60000, 0x20000, "" },
    .{ .VISIONOSSIMULATOR, 0x10000, 0x10000, "" },
};

pub fn inferSdkVersionFromSdkPath(path: []const u8) ?Version {
    const stem = std.fs.path.stem(path);
    const start = for (stem, 0..) |c, i| {
        if (std.ascii.isDigit(c)) break i;
    } else stem.len;
    const end = for (stem[start..], start..) |c, i| {
        if (std.ascii.isDigit(c) or c == '.') continue;
        break i;
    } else stem.len;
    return Version.parse(stem[start..end]);
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

fn testParseVersionSuccess(exp: u32, raw: []const u8) !void {
    const maybe_ver = Version.parse(raw);
    try expect(maybe_ver != null);
    const ver = maybe_ver.?.value;
    try expectEqual(exp, ver);
}

test "parseVersionString" {
    try testParseVersionSuccess(0xD0400, "13.4");
    try testParseVersionSuccess(0xD0401, "13.4.1");
    try testParseVersionSuccess(0xB0F00, "11.15");

    try expect(Version.parse("") == null);
    try expect(Version.parse("11.xx") == null);
    try expect(Version.parse("11.11.11.11") == null);
}
