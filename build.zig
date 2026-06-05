const std = @import("std");

// Dropbear build using `zig build` (Zig 0.16).
//
// This replaces the autoconf/Makefile build for producing release binaries.
// It compiles the bundled libtommath and libtomcrypt as static libraries and
// links them into a single multi-call `dropbearmulti` binary (containing the
// dropbear server, dbclient, dropbearkey, dropbearconvert and scp applets).
//
// A target-appropriate `config.h` is generated at configure time so the build
// works for cross-compilation (notably Linux/musl) without running ./configure.

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const upx = b.option(bool, "upx", "Compress the binary with UPX (requires upx in PATH)") orelse false;

    const os_tag = target.result.os.tag;

    // When cross-compiling to macOS (e.g. building x86_64 on an arm64 runner)
    // the SDK is passed via `--sysroot $(xcrun --show-sdk-path)`. zig uses it
    // for linking, but does NOT add the SDK's usr/include to the C header
    // search path, so we add it explicitly (else <util.h> etc. won't resolve).
    // No effect on Linux builds (b.sysroot is null there).
    const macos_sdk: ?[]const u8 =
        if ((os_tag == .macos or os_tag == .ios or os_tag == .tvos or os_tag == .watchos) and b.sysroot != null)
            b.sysroot
        else
            null;

    // ---- Generated headers ---------------------------------------------------
    const wf = b.addWriteFiles();
    const config_h = wf.add("config.h", genConfigH(b, os_tag));
    _ = wf.add("default_options_guard.h", genGuard(b));
    // Both generated files live in the same directory.
    const gen_dir = config_h.dirname();

    // Shared include directories for every translation unit.
    const includes = [_]std.Build.LazyPath{
        gen_dir,
        b.path("src"),
        b.path("libtomcrypt/src/headers"),
        b.path("libtommath"),
    };

    // Common preprocessor / compiler flags.
    var common_flags: std.ArrayList([]const u8) = .empty;
    common_flags.appendSlice(b.allocator, &.{
        "-D_GNU_SOURCE",
        "-std=gnu99",
        "-fno-strict-aliasing",
        "-Wno-pointer-sign",
    }) catch @panic("OOM");
    if (os_tag == .linux) {
        common_flags.append(b.allocator, "-D_FILE_OFFSET_BITS=64") catch @panic("OOM");
    }

    // ---- libtommath ----------------------------------------------------------
    const ltm = b.addLibrary(.{
        .name = "tommath",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    for (includes) |inc| ltm.root_module.addIncludePath(inc);
    if (macos_sdk) |sdk| addMacosSdkInclude(b, ltm.root_module, sdk);
    ltm.step.dependOn(&wf.step);
    ltm.root_module.addCSourceFiles(.{
        .root = b.path("."),
        .files = collectCSources(b, "libtommath", false),
        .flags = common_flags.items,
    });

    // ---- libtomcrypt ---------------------------------------------------------
    var ltc_flags: std.ArrayList([]const u8) = .empty;
    ltc_flags.appendSlice(b.allocator, common_flags.items) catch @panic("OOM");
    ltc_flags.append(b.allocator, "-DLTC_SOURCE") catch @panic("OOM");

    const ltc = b.addLibrary(.{
        .name = "tomcrypt",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    for (includes) |inc| ltc.root_module.addIncludePath(inc);
    if (macos_sdk) |sdk| addMacosSdkInclude(b, ltc.root_module, sdk);
    ltc.step.dependOn(&wf.step);
    ltc.root_module.addCSourceFiles(.{
        .root = b.path("."),
        .files = collectCSources(b, "libtomcrypt/src", true),
        .flags = ltc_flags.items,
    });

    // ---- dropbearmulti -------------------------------------------------------
    var db_flags: std.ArrayList([]const u8) = .empty;
    db_flags.appendSlice(b.allocator, common_flags.items) catch @panic("OOM");
    db_flags.appendSlice(b.allocator, &.{
        "-DDROPBEAR_SERVER",
        "-DDROPBEAR_CLIENT",
        "-DDROPBEAR_MULTI",
        "-DDBMULTI_dropbear",
        "-DDBMULTI_dbclient",
        "-DDBMULTI_dropbearkey",
        "-DDBMULTI_dropbearconvert",
        "-DDBMULTI_scp",
        "-DPROGRESS_METER",
    }) catch @panic("OOM");

    const exe = b.addExecutable(.{
        .name = "dropbearmulti",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = if (optimize != .Debug) true else null,
        }),
    });
    for (includes) |inc| exe.root_module.addIncludePath(inc);
    if (macos_sdk) |sdk| addMacosSdkInclude(b, exe.root_module, sdk);
    exe.step.dependOn(&wf.step);
    exe.root_module.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &dropbear_sources,
        .flags = db_flags.items,
    });
    exe.root_module.linkLibrary(ltc);
    exe.root_module.linkLibrary(ltm);

    const install = b.addInstallArtifact(exe, .{});

    if (upx) {
        const upx_step = b.addSystemCommand(&.{
            "upx",                                   "--best", "--lzma",
            b.getInstallPath(.bin, "dropbearmulti"),
        });
        upx_step.step.dependOn(&install.step);
        b.getInstallStep().dependOn(&upx_step.step);
    } else {
        b.getInstallStep().dependOn(&install.step);
    }
}

// dropbear source files (relative to `src/`). This is the union of the object
// lists in Makefile.in needed for a multi-call binary that bundles the server,
// client, dropbearkey, dropbearconvert and scp.
const dropbear_sources = [_][]const u8{
    // dbmulti dispatcher
    "dbmulti.c",
    // COMMONOBJS
    "dbutil.c",
    "buffer.c",
    "dbhelpers.c",
    "dss.c",
    "bignum.c",
    "signkey.c",
    "rsa.c",
    "dbrandom.c",
    "queue.c",
    "atomicio.c",
    "compat.c",
    "fake-rfc2553.c",
    "ltc_prng.c",
    "ecc.c",
    "ecdsa.c",
    "sk-ecdsa.c",
    "crypto_desc.c",
    "curve25519.c",
    "ed25519.c",
    "sk-ed25519.c",
    "dbmalloc.c",
    "gensignkey.c",
    "gendss.c",
    "genrsa.c",
    "gened25519.c",
    // CLISVROBJS
    "common-session.c",
    "packet.c",
    "common-algo.c",
    "common-kex.c",
    "common-channel.c",
    "common-chansession.c",
    "termcodes.c",
    "loginrec.c",
    "tcp-accept.c",
    "listener.c",
    "process-packet.c",
    "dh_groups.c",
    "common-runopts.c",
    "circbuffer.c",
    "list.c",
    "netio.c",
    "chachapoly.c",
    "gcm.c",
    "kex-x25519.c",
    "kex-dh.c",
    "kex-ecdh.c",
    "kex-pqhybrid.c",
    "sntrup761.c",
    "mlkem768.c",
    // SVROBJS
    "svr-kex.c",
    "svr-auth.c",
    "sshpty.c",
    "svr-authpasswd.c",
    "svr-authpubkey.c",
    "svr-authpubkeyoptions.c",
    "svr-session.c",
    "svr-service.c",
    "svr-chansession.c",
    "svr-runopts.c",
    "svr-agentfwd.c",
    "svr-main.c",
    "svr-x11fwd.c",
    "svr-forward.c",
    "svr-tcpfwd.c",
    "svr-streamfwd.c",
    "svr-authpam.c",
    // CLIOBJS
    "cli-main.c",
    "cli-auth.c",
    "cli-authpasswd.c",
    "cli-kex.c",
    "cli-session.c",
    "cli-runopts.c",
    "cli-chansession.c",
    "cli-authpubkey.c",
    "cli-tcpfwd.c",
    "cli-channel.c",
    "cli-authinteract.c",
    "cli-agentfwd.c",
    "cli-readconf.c",
    // KEYOBJS
    "dropbearkey.c",
    // CONVERTOBJS
    "dropbearconvert.c",
    "keyimport.c",
    "signkey_ossh.c",
    // SCPOBJS (atomicio.c / compat.c already present above)
    "scp.c",
    "progressmeter.c",
    "scpmisc.c",
};

// Walk a directory under the build root and collect every `.c` file, returning
// paths relative to the build root.
fn collectCSources(b: *std.Build, comptime sub: []const u8, recursive: bool) [][]const u8 {
    const io = b.graph.io;
    var list: std.ArrayList([]const u8) = .empty;
    var dir = b.build_root.handle.openDir(io, sub, .{ .iterate = true }) catch |err| {
        std.debug.panic("failed to open {s}: {s}", .{ sub, @errorName(err) });
    };
    defer dir.close(io);

    if (recursive) {
        var walker = dir.walk(b.allocator) catch @panic("OOM");
        defer walker.deinit();
        while (walker.next(io) catch @panic("walk failed")) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".c")) continue;
            // *tab.c files in libtomcrypt are lookup tables that are #included
            // by other sources, not compiled on their own.
            if (std.mem.endsWith(u8, entry.basename, "tab.c")) continue;
            const rel = std.fs.path.join(b.allocator, &.{ sub, entry.path }) catch @panic("OOM");
            list.append(b.allocator, rel) catch @panic("OOM");
        }
    } else {
        var it = dir.iterate();
        while (it.next(io) catch @panic("iterate failed")) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".c")) continue;
            const rel = std.fs.path.join(b.allocator, &.{ sub, entry.name }) catch @panic("OOM");
            list.append(b.allocator, rel) catch @panic("OOM");
        }
    }
    return list.toOwnedSlice(b.allocator) catch @panic("OOM");
}

// Generate default_options_guard.h from src/default_options.h by wrapping every
// `#define X Y` in an `#ifndef X ... #endif` guard (equivalent to
// src/ifndef_wrapper.sh). The guards let the generated config.h override any
// Add the macOS SDK's system header directory so cross-compiling (e.g. x86_64
// on an arm64 runner) can resolve system headers like <util.h>. Linking is
// handled by --sysroot, so only the include path is added here.
fn addMacosSdkInclude(b: *std.Build, m: *std.Build.Module, sdk: []const u8) void {
    m.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr", "include" }) });
}

// default (e.g. disabling DROPBEAR_SVR_DROP_PRIVS on platforms without
// setresgid()).
fn genGuard(b: *std.Build) []const u8 {
    const io = b.graph.io;
    const input = b.build_root.handle.readFileAlloc(
        io,
        "src/default_options.h",
        b.allocator,
        .unlimited,
    ) catch |err| {
        std.debug.panic("failed to read default_options.h: {s}", .{@errorName(err)});
    };

    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(
        b.allocator,
        "/* Generated by build.zig from default_options.h - do not edit */\n",
    ) catch @panic("OOM");

    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |line| {
        if (definedName(line)) |name| {
            const wrapped = std.fmt.allocPrint(
                b.allocator,
                "#ifndef {s}\n{s}\n#endif\n",
                .{ name, line },
            ) catch @panic("OOM");
            out.appendSlice(b.allocator, wrapped) catch @panic("OOM");
        } else {
            out.appendSlice(b.allocator, line) catch @panic("OOM");
            out.append(b.allocator, '\n') catch @panic("OOM");
        }
    }
    return out.toOwnedSlice(b.allocator) catch @panic("OOM");
}

// Returns the macro name if `line` is `<spaces>#define <NAME> <value...>`.
fn definedName(line: []const u8) ?[]const u8 {
    var s = line;
    while (s.len > 0 and (s[0] == ' ' or s[0] == '\t')) s = s[1..];
    const prefix = "#define ";
    if (!std.mem.startsWith(u8, s, prefix)) return null;
    s = s[prefix.len..];
    while (s.len > 0 and (s[0] == ' ' or s[0] == '\t')) s = s[1..];
    var i: usize = 0;
    while (i < s.len and s[i] != ' ' and s[i] != '\t') i += 1;
    if (i == 0) return null;
    // Require a value after the name (matching the sed `.* ` semantics).
    if (i >= s.len) return null;
    return s[0..i];
}

fn genConfigH(b: *std.Build, os_tag: std.Target.Os.Tag) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(b.allocator, common_config) catch @panic("OOM");
    switch (os_tag) {
        .macos, .ios, .tvos, .watchos => out.appendSlice(b.allocator, macos_config) catch @panic("OOM"),
        else => out.appendSlice(b.allocator, linux_config) catch @panic("OOM"),
    }
    out.appendSlice(b.allocator, "\n#endif /* DROPBEAR_CONFIG_H */\n") catch @panic("OOM");
    return out.toOwnedSlice(b.allocator) catch @panic("OOM");
}

const common_config =
    \\/* Generated by build.zig - do not edit */
    \\#ifndef DROPBEAR_CONFIG_H
    \\#define DROPBEAR_CONFIG_H
    \\
    \\#define BUNDLED_LIBTOM 1
    \\#define DROPBEAR_FUZZ 0
    \\#define DROPBEAR_PLUGIN 0
    \\
    \\/* Login recording is disabled for the portable zig build. */
    \\#define DISABLE_PAM 1
    \\#define DISABLE_ZLIB 1
    \\#define DISABLE_LASTLOG 1
    \\#define DISABLE_UTMP 1
    \\#define DISABLE_UTMPX 1
    \\#define DISABLE_WTMP 1
    \\#define DISABLE_WTMPX 1
    \\
    \\#define HAVE_BASENAME 1
    \\#define HAVE_CLOCK_GETTIME 1
    \\#define HAVE_CONST_GAI_STRERROR_PROTO 1
    \\#define HAVE_CRYPT 1
    \\#define HAVE_DAEMON 1
    \\#define HAVE_FORK 1
    \\#define HAVE_FREEADDRINFO 1
    \\#define HAVE_GAI_STRERROR 1
    \\#define HAVE_GETADDRINFO 1
    \\#define HAVE_GETGROUPLIST 1
    \\#define HAVE_GETNAMEINFO 1
    \\#define HAVE_GETPASS 1
    \\#define HAVE_GETUSERSHELL 1
    \\#define HAVE_INTTYPES_H 1
    \\#define HAVE_LIBGEN_H 1
    \\#define HAVE_NETDB_H 1
    \\#define HAVE_NETINET_IN_H 1
    \\#define HAVE_NETINET_IN_SYSTM_H 1
    \\#define HAVE_NETINET_TCP_H 1
    \\#define HAVE_PATHS_H 1
    \\#define HAVE_PUTENV 1
    \\#define HAVE_STDINT_H 1
    \\#define HAVE_STDIO_H 1
    \\#define HAVE_STDLIB_H 1
    \\#define HAVE_STRINGS_H 1
    \\#define HAVE_STRING_H 1
    \\#define HAVE_STRUCT_ADDRINFO 1
    \\#define HAVE_STRUCT_IN6_ADDR 1
    \\#define HAVE_STRUCT_SOCKADDR_IN6 1
    \\#define HAVE_STRUCT_SOCKADDR_STORAGE 1
    \\#define HAVE_STRUCT_SOCKADDR_STORAGE_SS_FAMILY 1
    \\#define HAVE_SYS_RANDOM_H 1
    \\#define HAVE_SYS_SELECT_H 1
    \\#define HAVE_SYS_SOCKET_H 1
    \\#define HAVE_SYS_STAT_H 1
    \\#define HAVE_SYS_TYPES_H 1
    \\#define HAVE_SYS_UIO_H 1
    \\#define HAVE_SYS_WAIT_H 1
    \\#define HAVE_UINT16_T 1
    \\#define HAVE_UINT32_T 1
    \\#define HAVE_UINT8_T 1
    \\#define HAVE_UNDERSCORE_STATIC_ASSERT 1
    \\#define HAVE_UNISTD_H 1
    \\#define HAVE_U_INT16_T 1
    \\#define HAVE_U_INT32_T 1
    \\#define HAVE_U_INT8_T 1
    \\#define HAVE_WRITEV 1
    \\
    \\#define SELECT_TYPE_ARG1 int
    \\#define SELECT_TYPE_ARG234 (fd_set *)
    \\#define SELECT_TYPE_ARG5 (struct timeval *)
    \\#define STDC_HEADERS 1
    \\
    \\#define PACKAGE_NAME ""
    \\#define PACKAGE_STRING ""
    \\#define PACKAGE_TARNAME ""
    \\#define PACKAGE_VERSION ""
    \\#define PACKAGE_BUGREPORT ""
    \\#define PACKAGE_URL ""
    \\
;

const linux_config =
    \\/* Linux / musl specific */
    \\#define HAVE_CRYPT_H 1
    \\#define HAVE_SHADOW_H 1
    \\#define HAVE_GETSPNAM 1
    \\#define HAVE_PTY_H 1
    \\#define HAVE_OPENPTY 1
    \\#define HAVE_ENDIAN_H 1
    \\#define HAVE_DECL_HTOLE64 1
    \\#define HAVE_SYS_PRCTL_H 1
    \\#define HAVE_LINUX_PKT_SCHED_H 1
    \\#define HAVE_CLEARENV 1
    \\#define HAVE_FEXECVE 1
    \\#define HAVE_EXPLICIT_BZERO 1
    \\#define HAVE_SETRESGID 1
    \\#define HAVE_GETRANDOM 1
    \\
;

const macos_config =
    \\/* macOS specific */
    \\#define HAVE_DECL_HTOLE64 1
    \\#define HAVE_SYS_ENDIAN_H 1
    \\#define HAVE_MACH_ABSOLUTE_TIME 1
    \\#define HAVE_MACH_MACH_TIME_H 1
    \\#define HAVE_MEMSET_S 1
    \\#define HAVE_OPENPTY 1
    \\#define HAVE_UTIL_H 1
    \\#define HAVE_STRLCAT 1
    \\#define HAVE_STRLCPY 1
    \\/* macOS/BSD lack setresgid(); disable server privilege dropping that needs it. */
    \\#define DROPBEAR_SVR_MULTIUSER 0
    \\#define DROPBEAR_SVR_DROP_PRIVS 0
    \\
;
