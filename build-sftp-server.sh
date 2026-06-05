#!/bin/sh
# Cross-compile OpenSSH's sftp-server using `zig cc` as the C compiler.
#
# Dropbear's server execs an external sftp-server binary for the SFTP subsystem;
# it does not ship one itself. This script produces a statically linked
# sftp-server that can be bundled alongside dropbearmulti.
#
# Usage: build-sftp-server.sh <zig-target> <out-dir> [openssh-version]
#   <zig-target>      e.g. x86_64-linux-musl, aarch64-linux-musl, arm-linux-musleabihf
#   <out-dir>         directory to copy the resulting `sftp-server` into
#   [openssh-version] OpenSSH portable version (default below)
set -eu

ZIG_TARGET="${1:?usage: build-sftp-server.sh <zig-target> <out-dir> [openssh-version]}"
OUT_DIR="${2:?usage: build-sftp-server.sh <zig-target> <out-dir> [openssh-version]}"
OPENSSH_VERSION="${3:-9.9p2}"

# Use the zig target triple directly as the autoconf --host so configure runs in
# cross-compile mode; zig cc performs the actual codegen via -target.
HOST="$ZIG_TARGET"

# Resolve OUT_DIR to an absolute path now, before we cd into the (temporary)
# OpenSSH build tree. Otherwise a relative path would resolve against that
# temp dir and the copied binary would be deleted with it.
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

tarball="openssh-${OPENSSH_VERSION}.tar.gz"
url="https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/${tarball}"
echo "==> Downloading ${url}"
curl -fsSL -o "$workdir/$tarball" "$url"
tar -xzf "$workdir/$tarball" -C "$workdir"
src="$workdir/openssh-${OPENSSH_VERSION}"

cd "$src"

# Avoid leaking the host toolchain's CPPFLAGS/CFLAGS/LDFLAGS into the cross build.
unset CPPFLAGS CFLAGS LDFLAGS LIBS

echo "==> Configuring OpenSSH for ${ZIG_TARGET}"
./configure \
    --host="$HOST" \
    CC="zig cc -target $ZIG_TARGET" \
    AR="zig ar" \
    RANLIB="zig ranlib" \
    --without-openssl \
    --without-zlib \
    --without-pam \
    --without-selinux \
    --without-kerberos5 \
    --without-libedit \
    --without-ldns \
    --with-sandbox=no \
    --disable-strip \
    CFLAGS="-Os" \
    LDFLAGS="-static"

echo "==> Building sftp-server"
make sftp-server -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"

mkdir -p "$OUT_DIR"
cp sftp-server "$OUT_DIR/sftp-server"
echo "==> Built $OUT_DIR/sftp-server"
