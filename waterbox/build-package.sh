#!/bin/sh
# Builds the quickerNES waterbox core package and installs it into a miniHawk
# checkout as build/Cores/quickernes.chimeraCore.
#
# A package is exactly two files - core.wbx (fixed name) plus waterbox.config -
# and miniHawk loads it through its one built-in generic adapter. There is no
# managed assembly and no native library in a package any more.
#
# Usage: ./build-package.sh [-m <miniBox dir>] [-r <miniHawk root>] [-o <build dir>]
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
mb="${MINIBOX_DIR:-}"
out="$root/build"
minihawk_root=""
while getopts "m:r:o:" opt; do
	case "$opt" in
		m) mb="$OPTARG" ;;
		r) minihawk_root="$OPTARG" ;;
		o) out="$OPTARG" ;;
		*) exit 2 ;;
	esac
done

if [ -z "$minihawk_root" ]; then
	for candidate in "$here/../../chimera" "$HOME/chimera" "$here/../../miniHawk" "$HOME/miniHawk"; do
		[ -d "$candidate" ] && { minihawk_root="$candidate"; break; }
	done
fi
[ -n "$minihawk_root" ] && [ -d "$minihawk_root" ] || {
	echo "miniHawk checkout not found; pass -r <path>" >&2; exit 1; }
minihawk_root="$(cd "$minihawk_root" && pwd)"

# miniBox lives in the miniHawk checkout as a submodule; the guest toolchain
# (musl + libstdc++ for the C++ guest) is part of its meson graph.
[ -n "$mb" ] || mb="$minihawk_root/extern/chimera-common-minibox"
mbuild="$mb/build/meson-cpp"
[ -f "$mbuild/build.ninja" ] || meson setup "$mbuild" "$mb" -Dguest_cpp=true
ninja -C "$mbuild"

# the guest, via the meson cross build
[ -f "$root/build/meson-guest/build.ninja" ] || MINIBOX_DIR="$mb" sh "$here/setup-guest.sh" -m "$mb"
ninja -C "$root/build/meson-guest" core.wbx
sh "$mb/source/guest/check-wbx.sh" "$root/build/meson-guest/core.wbx"

staging="$out/package-staging"
rm -rf "$staging"
mkdir -p "$staging"
cp "$root/build/meson-guest/core.wbx" "$staging/core.wbx"
cp "$here/waterbox.config" "$staging/waterbox.config"
# The default bindings for the controller this package declares. miniHawk ships none of its own -
# the package that declares a controller says how it is played by default.
cp "$here/default_keybinds.json" "$staging/default_keybinds.json"
# The core-declared file form for the project wizard (slots, cardinality,
# formats, tooltips) - the frontend renders it, this file decides it.
cp "$here/file_slots.json" "$staging/file_slots.json"
# the terms travel with the binary: this package may be downloaded on its
# own, and the emulator inside it is somebody else's work under somebody
# else's licence (see waterbox/package-licenses.json)
python3 "$mb/source/guest/package-licenses.py" "$here/.." "$staging"

# ---- version ----
# A core's authoritative version is the commit it was built from, stamped by the
# automated build that publishes the artifact. CORE_VERSION is what that build
# passes in; anything built by hand says so, so a local package can never pass
# itself off as a published one - and a movie that cites a version therefore cites
# something that exists in the history.
core_version="${CORE_VERSION:-}"
if [ -z "$core_version" ]; then
	if commit="$(git -C "$here/.." rev-parse --short=12 HEAD 2>/dev/null)"; then
		git -C "$here/.." diff --quiet HEAD 2>/dev/null || commit="$commit-dirty"
		core_version="$commit+local"
	else
		core_version="unversioned+local"
	fi
fi

# The version goes into the packaged config, not the one in the repo: the file
# under version control has no business carrying a version that changes with every
# commit. waterbox.config's "version" is what the frontend shows and what a movie
# records as the core's identity.
python3 - "$staging/waterbox.config" "$core_version" <<'PYVER'
import json, sys
path, version = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)
cfg["version"] = version
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PYVER

# How to rebuild this exact package: the version, the source it came from, and the
# toolchain that compiled the guest. A package's SHA1 is
# relative to all of it - the same sources through a different gcc are different
# bytes and so a different build - and that is only bewildering if the package does
# not say so. It now says so.
#
# Everything here is a function of the inputs. Nothing time-, machine- or
# path-dependent may join it: that would make two builds of one commit differ, which
# is the property the deterministic packaging below exists to keep.
gccver="$(gcc -dumpfullversion)"
musl_version="$(cat "$mb/extern/musl/VERSION" 2>/dev/null || echo unknown)"
binutils_version="$(ld --version | head -1 | grep -o '[0-9][0-9.]*$' || echo unknown)"
os_id="$(. /etc/os-release 2>/dev/null && printf '%s %s' "${ID:-unknown}" "${VERSION_ID:-}" || echo unknown)"
guest_kit="$(git -C "$mb" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
python3 - "$staging/build.json" "$core_version" "$root" <<PYPROV
import json, os, subprocess, sys

out_path, version, repo = sys.argv[1], sys.argv[2], sys.argv[3]


def git(*args, default="unknown"):
    try:
        return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True,
                              check=True).stdout.strip()
    except Exception:
        return default


prov = {"version": version, "source": {
    "commit": git("rev-parse", "HEAD"),
    "origin": git("config", "--get", "remote.origin.url", default=""),
    "dirty": version.endswith("+local") and "-dirty" in version,
}, "toolchain": {
    "compiler": "gcc $gccver",
    "libstdc++": "$gccver",
    "binutils": "$binutils_version",
    "target": "x86_64-linux-musl",
    "musl": "$musl_version",
}, "guestKit": {"name": "miniBox", "commit": "$guest_kit"},
   "builtOn": "$os_id"}

with open(out_path, "w") as f:
    json.dump(prov, f, indent=2, sort_keys=True)
    f.write("\n")
PYPROV

cores_dir="$minihawk_root/build/Cores"
mkdir -p "$cores_dir"
zip_path="$cores_dir/quickernes.chimeraCore"
rm -f "$zip_path"
# The package's SHA1 is the core's identity: it is what a movie records to say which
# machine produced it. So the same sources must produce the same bytes - which an
# ordinary zip does not, because it stores each file's mtime and mode. Entries are
# written sorted, with a fixed timestamp, fixed permissions and a pinned compression
# level; the guest ELF is already reproducible on its own.
python3 - "$staging" "$zip_path" <<'PYEOF'
import os, sys, zipfile

staging, zip_path = sys.argv[1], sys.argv[2]

# 1980-01-01 is the earliest a zip can express, and the point is that it never moves
FIXED_DATE = (1980, 1, 1, 0, 0, 0)


def write_package(path):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for root, dirs, files in os.walk(staging):
            dirs.sort()
            for name in sorted(files):
                full = os.path.join(root, name)
                info = zipfile.ZipInfo(os.path.relpath(full, staging), date_time=FIXED_DATE)
                info.compress_type = zipfile.ZIP_DEFLATED
                info.create_system = 3  # unix, so the mode below is what is stored
                info.external_attr = 0o644 << 16
                with open(full, "rb") as f:
                    z.writestr(info, f.read())


write_package(zip_path)

# A self-check, because "identical sources give an identical package" is a promise
# that rots silently: pack a second time and compare.
import hashlib
import tempfile

with tempfile.NamedTemporaryFile(suffix=".zip") as tmp:
    write_package(tmp.name)
    again = hashlib.sha1(open(tmp.name, "rb").read()).hexdigest()
first = hashlib.sha1(open(zip_path, "rb").read()).hexdigest()
if first != again:
    sys.exit(f"packaging is not deterministic: {first} then {again}")
print(f"package sha1 {first}")
PYEOF

# the frontend extracts packages into build/CoreCache keyed by content; drop any
# stale extraction so the next load picks this build up
for cache in "$minihawk_root"/build/CoreCache/quickernes-*; do
	[ -d "$cache" ] && rm -rf "$cache" || true
done
echo "packaged -> $zip_path"
