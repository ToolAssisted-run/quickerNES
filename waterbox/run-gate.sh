#!/bin/bash
# The core-level gate for the waterbox port: for every rom given, the sandboxed
# core must produce byte-identical video, audio, lag and memory-domain digests to
# the original shared library, and must survive a whole-machine savestate
# round-trip around every frame.
#
# This is the gate CI runs on every push, over the roms that are free to
# distribute. It needs only gcc, meson and python3 - no .NET, Mono or X - so it
# is the fast half of the witness. The frontend half (movies replayed through
# EmuHawk against goldens) lives in ../minihawk/tests.
#
# Usage:
#   ./run-gate.sh [-n <native build dir>] [-g <guest build dir>] [-f <frames>] [rom...]
# with no roms, it uses the free-to-distribute set vendored in the repo.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
nat="$root/build/meson-native"
gst="$root/build/meson-guest"
frames=600
while getopts "n:g:f:" opt; do
	case "$opt" in
		n) nat="$OPTARG" ;;
		g) gst="$OPTARG" ;;
		f) frames="$OPTARG" ;;
		*) exit 2 ;;
	esac
done
shift $((OPTIND - 1))

roms=("$@")
if [ ${#roms[@]} -eq 0 ]; then
	# Free to distribute, vendored in the repo, so this runs anywhere.
	roms=(
		"$root/tests/roms/sprilo.nes"
		"$root/minihawk/tests/suite/roms/nova.nes"   # MMC1 SXROM: 32K banked PRG RAM
	)
fi

native="$nat/libquicknes.so"
[ -f "$native" ] && [ -x "$nat/run-wbx" ] || {
	echo "native build missing: meson setup build/meson-native -Dwaterbox=true && ninja -C build/meson-native" >&2; exit 1; }
[ -f "$gst/core.wbx" ] || {
	echo "guest build missing: sh waterbox/setup-guest.sh && ninja -C build/meson-guest core.wbx" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
digests() { grep -E '^(frames|videoHash|audioHash|lagFrames|domain\[)'; }
# What a turbo run can be held to: everything except the whole-run video hash,
# which a run that skipped the first half cannot possibly match - the second
# half it did draw is compared instead.
turboDigests() { grep -E '^(frames|tailVideoHash|audioHash|lagFrames|domain\[)'; }

ok=0
failed=0
skipped=0
# A SKIP is a leg that could not be ASKED, not a leg that answered wrong: the rom
# is not here, or the tool the leg needs was not built. Counting one as a failure
# made this gate red on every CI run for eleven passing legs and one honest skip,
# so the three outcomes are counted apart and only a FAIL decides the exit code.
report() {
	printf "%-28s %-9s %s\n" "$1" "$2" "$3"
	case "$2" in
		PASS) ok=$((ok + 1)) ;;
		SKIP) skipped=$((skipped + 1)) ;;
		*) failed=$((failed + 1)) ;;
	esac
}

printf "%-28s %-9s %s\n" "Check" "Result" "Detail"
printf "%-28s %-9s %s\n" "-----" "------" "------"

for rom in "${roms[@]}"; do
	name="$(basename "$rom" .nes)"
	if [ ! -f "$rom" ]; then report "$name" SKIP "rom not found"; continue; fi

	if ! "$nat/run-native" "$native" "$rom" "$frames" 2>"$work/nat.err" | digests > "$work/nat.txt"; then
		report "$name:equivalence" FAIL "native runner error: $(head -1 "$work/nat.err")"; continue
	fi
	if ! "$nat/run-wbx" "$gst/core.wbx" "$rom" "$frames" 2>"$work/box.err" | digests > "$work/box.txt"; then
		report "$name:equivalence" FAIL "waterbox runner error: $(head -1 "$work/box.err")"; continue
	fi
	if cmp -s "$work/nat.txt" "$work/box.txt"; then
		report "$name:equivalence" PASS "$frames frames, native == waterboxed"
	else
		report "$name:equivalence" FAIL "$(diff "$work/nat.txt" "$work/box.txt" | tr '\n' ' ' | head -c 120)"
	fi

	# Round-trip the whole machine through save/load state around every frame:
	# the digests must come out exactly as they do without it.
	if ! "$nat/run-wbx" "$gst/core.wbx" "$rom" "$frames" --rerecord 2>/dev/null | digests > "$work/rr.txt"; then
		report "$name:savestate" FAIL "rerecord runner error"; continue
	fi
	if cmp -s "$work/box.txt" "$work/rr.txt"; then
		report "$name:savestate" PASS "per-frame round-trip is lossless"
	else
		report "$name:savestate" FAIL "$(diff "$work/box.txt" "$work/rr.txt" | tr '\n' ' ' | head -c 120)"
	fi

	# Turbo: run the same frames with the core's drawing switched off for the
	# first half and back on for the second. The machine, the sound, the lag
	# count and every picture of that second half must be what they would have
	# been. A core that got this wrong shows up here as a different picture even
	# when every byte of RAM still agrees.
	if "$nat/run-wbx" "$gst/core.wbx" "$rom" "$frames" 2>/dev/null | turboDigests > "$work/norm.txt" &&
	   "$nat/run-wbx" "$gst/core.wbx" "$rom" "$frames" --turbo 2>/dev/null | turboDigests > "$work/turbo.txt"; then
		if cmp -s "$work/norm.txt" "$work/turbo.txt"; then
			report "$name:turbo" PASS "$frames frames, half of them undrawn, same machine and same pictures"
		else
			report "$name:turbo" FAIL "$(diff "$work/norm.txt" "$work/turbo.txt" | tr '\n' ' ' | head -c 120)"
		fi
	else
		report "$name:turbo" FAIL "turbo runner error"
	fi

	# The optional tooling exports the frontend probes for: absence is allowed,
	# but a core that claims a surface must render one.
	if [ -x "$nat/run-tooling" ]; then
		if "$nat/run-tooling" "$gst/core.wbx" "$rom" 120 > "$work/tool.txt" 2>&1; then
			if grep -q "RENDER FAILED" "$work/tool.txt"; then
				report "$name:tooling" FAIL "a declared surface did not render"
			else
				report "$name:tooling" PASS "$(grep -c '^  \[' "$work/tool.txt") tooling entries reported"
			fi
		else
			report "$name:tooling" FAIL "runner error"
		fi
	fi
done

# ---- what a project PLUGS IN decides what a movie has columns for ----------
# This package declares the union of every peripheral its two ports can hold -
# four players' pads, both Arkanoid fire buttons, both paddles - because a
# declaration is static and cannot know what a project chose. Every NES project
# therefore showed all thirty-four columns whatever was in its ports: players
# three and four with no Four Score anywhere, a paddle with no Arkanoid.
#
# The core answers IsButtonActive/IsAxisActive once, after Init, and the engine
# builds the entry from what the machine HAS. So the shape of one recorded frame
# is the whole claim, and it is exact rather than approximate: a column that
# should not be there is a character that should not be there.
#
# Needs the engine's headless runner, which lives in the chimera checkout this
# repository is a submodule of.
chimera_root="${CHIMERA_ROOT:-$root/../../..}"
crun="$chimera_root/build/meson-linux/chimera-run"
cpkg="$chimera_root/build/Cores/quickernes.chimeraCore"
if [ ! -x "$crun" ] || [ ! -f "$cpkg" ]; then
	report "ports:columns" SKIP "needs chimera-run and a built package (set CHIMERA_ROOT)"
else
	printf '[Input]\nLogKey:#\n' > "$work/none.txt"
	shape() { # <settings json> -> the one entry a frame records
		"$crun" "$cpkg" "$root/tests/roms/nova.nes" "$work/none.txt" \
			--settings "$1" --frames 1 --record "$work/shape.txt" >/dev/null 2>&1 \
			&& head -1 "$work/shape.txt"
	}
	# a pad is eight columns; a paddle is its value and a fire button. The
	# leading "||" is the opening pipe and the (empty) console group.
	wrong=""
	check() { # <settings> <expected entry> <what it means>
		got="$(shape "$1")"
		[ "$got" = "$2" ] || wrong="$wrong; $3 gave [${got:-nothing}] want [$2]"
	}
	check '{}' \
		'||........|' "one pad in port one"
	check '{"port2":"gamepad"}' \
		'||........|........|' "a pad in each port"
	check '{"port1":"fourScore","port2":"fourScore"}' \
		'||........|........|........|........|' "a Four Score"
	check '{"port1":"arkanoidNES"}' \
		'|||    0,.|' "an Arkanoid, which has no d-pad at all"
	check '{"port1":"arkanoidFamicom"}' \
		'||........||    0,.|' "a Famicom Arkanoid, which keeps the pad"
	check '{"port1":"none"}' \
		'||' "nothing plugged in anywhere"
	if [ -z "$wrong" ]; then
		report "ports:columns" PASS "a movie carries the controls the machine has, and no others"
	else
		report "ports:columns" FAIL "${wrong#; }"
	fi
fi

# ---- save data: out, and back in -------------------------------------------
#
# A battery-backed cart keeps its saves in WRAM. They leave through the savedata
# channel (what Export Save Data writes) and come back through the savedata slot
# (what a project mounts), and this proves the pair with a save the machine
# could not have written. sprilo has no battery, so the test flags one - the
# same trick the bundle tests use.
batt="$work/sprilo-battery.nes"
python3 - "$root/tests/roms/sprilo.nes" "$batt" <<'PYBATT'
import sys
d = bytearray(open(sys.argv[1], 'rb').read())
d[6] |= 0x02          # iNES flags 6, bit 1: battery-backed save RAM
open(sys.argv[2], 'wb').write(bytes(d))
PYBATT
"$nat/run-wbx" "$gst/core.wbx" "$batt" 60 --savedata-out "$work/nes.sav" >/dev/null 2>&1
if [ ! -s "$work/nes.sav" ]; then
	report "savedata:export" FAIL "a battery cart exported nothing"
else
	report "savedata:export" PASS "$(stat -c%s "$work/nes.sav") bytes of battery WRAM left through the channel"
	python3 - "$work/nes.sav" "$work/nes-seed.sav" <<'PYSEED'
import sys
d = bytearray(open(sys.argv[1], 'rb').read())
d[0:16] = b'CHIMERA-SEED-TST'
open(sys.argv[2], 'wb').write(bytes(d))
PYSEED
	"$nat/run-wbx" "$gst/core.wbx" "$batt" 60 --savedata-in "$work/nes-seed.sav" \
		--savedata-out "$work/nes-back.sav" >/dev/null 2>&1
	if ! head -c 16 "$work/nes-back.sav" 2>/dev/null | grep -q "CHIMERA-SEED-TST"; then
		report "savedata:seeded" FAIL "the save the project supplied did not reach the cart"
	else
		report "savedata:seeded" PASS "a save the project supplied reached the cart and returned"
	fi
	# ...and a cart with no battery says so rather than pretending
	if "$nat/run-wbx" "$gst/core.wbx" "$root/tests/roms/sprilo.nes" 10 \
		--savedata-in "$work/nes-seed.sav" >/dev/null 2>&1; then
		report "savedata:refused" FAIL "a cart with no battery accepted save data"
	else
		report "savedata:refused" PASS "a cart with no battery refuses save data it cannot keep"
	fi
fi

echo ""
echo "$ok ok, $failed failed, $skipped skipped"
[ "$failed" -gt 0 ] && exit 1
exit 0
