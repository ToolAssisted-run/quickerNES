#!/bin/bash
# Generates the witness movies: one .chimeraProject per test, converted from its .sol input
# sequence by sol2project, which builds the mnemonics from the core's own
# ControllerDefinition.
#
# The free-set movies are committed, so CI needs nothing. Regenerate when the
# controller declaration in waterbox.config changes, or when what a port holds
# does - the columns a movie carries are the ones the machine has - and the
# goldens will tell you loudly if you forget, since every movie desyncs at once.
#
# Usage:
#   ./make-movies.sh                        # free-to-distribute set (default)
#   ./make-movies.sh --set full             # every test whose rom is available
#   ./make-movies.sh --chimera-root <path>
set -u

set_name=free
chimera_root=""
package_dir=""
while [ $# -gt 0 ]; do
	case "$1" in
		--set) set_name="$2"; shift ;;
		--chimera-root) chimera_root="$2"; shift ;;
		--package) package_dir="$2"; shift ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
	shift
done

here="$(cd "$(dirname "$0")" && pwd)"
tests_dir="$(cd "$here/.." && pwd)"
repo_root="$(cd "$tests_dir/../.." && pwd)"
suite="$tests_dir/suite"
out_dir="$tests_dir/movies"
mkdir -p "$out_dir"

if [ -z "$chimera_root" ]; then
	for candidate in "$repo_root/../chimera" "$HOME/chimera"; do
		[ -d "$candidate" ] && { chimera_root="$candidate"; break; }
	done
fi
[ -n "$chimera_root" ] && [ -d "$chimera_root" ] || { echo "chimera checkout not found; pass --chimera-root" >&2; exit 1; }
chimera_root="$(cd "$chimera_root" && pwd)"
dll="$chimera_root/build/dll"

# The built package: core.wbx + waterbox.config, which is where the controller
# declaration the movies are keyed to comes from. build-package.sh leaves it
# here on its way into the chimera checkout, so the movies are keyed to the very
# package the witness replays - and to what its ports report, since the columns a
# movie carries are the ones the machine actually has.
[ -n "$package_dir" ] || package_dir="$repo_root/build/package-staging"
[ -f "$package_dir/core.wbx" ] || { echo "package not built: $package_dir/core.wbx (run waterbox/build-package.sh)" >&2; exit 1; }

# free set: roms that are free to distribute and vendored in suite/roms
free_set=(
	"sprilo.anyPercent"
	"novaTheSquirrel.anyPercent"
)

converter="$here/sol2project.exe"
if [ ! -f "$converter" ] || [ "$here/sol2project.cs" -nt "$converter" ]; then
	echo "building sol2project..."
	mcs -langversion:latest -out:"$converter" "$here/sol2project.cs" \
		-r:"$dll/Chimera.Emulation.Common.dll" -r:"$dll/Chimera.Client.Common.dll" \
		-r:"$dll/Chimera.Common.dll" -r:"$dll/Chimera.NativeInvoke.dll" -r:"$dll/Newtonsoft.Json.dll" || exit 1
fi

roms_dirs=("$suite/roms" "$HOME/TAS/roms/nes")
made=0
skipped=0
for test_file in "$suite"/*.test; do
	name="$(basename "$test_file" .test)"
	if [ "$set_name" = "free" ]; then
		in_free=0
		for f in "${free_set[@]}"; do [ "$name" = "$f" ] && in_free=1; done
		[ "$in_free" -eq 1 ] || continue
	fi

	# Read BOTH the rom and the sequence file from the .test. The sol is NOT
	# always <name>.sol: saintSeiyaOugonDensetsu replays KanketsuHen's sequence
	# against a different rom. Deriving the name instead of reading the field
	# built that movie from the wrong inputs, and the only symptom was a RAM
	# mismatch 76,723 frames later.
	# one per line, not space-separated: rom names contain spaces
	{ read -r rom_file; read -r seq_file; } <<< "$(python3 -c "
import json, io
t = json.load(io.open('$test_file', encoding='utf-8-sig'))
print(t.get('Rom File', ''))
print(t.get('Sequence File', ''))
")"
	rom_path=""
	for dir in "${roms_dirs[@]}"; do
		[ -f "$dir/${rom_file#roms/}" ] && { rom_path="$dir/${rom_file#roms/}"; break; }
	done
	if [ -z "$rom_path" ]; then
		printf "  %-36s SKIP (rom not found: %s)\n" "$name" "$rom_file"
		skipped=$((skipped + 1))
		continue
	fi

	# sol2project loads the core to read its controller definition, so it needs the
	# host library on the search path
	if LD_LIBRARY_PATH="$dll" MONO_PATH="$dll" mono "$converter" \
		"$package_dir" "$rom_path" "$test_file" "$suite/$seq_file" "$out_dir/$name.chimeraProject" > /dev/null 2>&1; then
		printf "  %-36s ok\n" "$name"
		made=$((made + 1))
	else
		printf "  %-36s FAILED\n" "$name"
		skipped=$((skipped + 1))
	fi
done

echo ""
echo "$made movies written to $out_dir, $skipped skipped"
[ "$made" -eq 0 ] && exit 1
exit 0
