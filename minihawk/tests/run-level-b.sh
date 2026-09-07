#!/bin/bash
# miniHawk Level B witness driver — Linux port of run-level-b.ps1.
# Plays each test's project through EmuHawk (under Mono) against the WATERBOX
# package - core.wbx driven by miniHawk's one generic adapter - and dumps the
# final 2KB RAM. Input comes from the movie, so the gate exercises the same path
# a user does; the movies are generated from the .sol sequences by
# tools/make-movies.sh. In --record mode the dumps become goldens; otherwise
# dumps are byte-compared against the stored goldens.
#
# The goldens predate the waterbox port: they were recorded through the retired
# managed package and cross-validated against the native tester's own dumps
# (goldens/native/). Reproducing them byte-for-byte is exactly the proof that
# sandboxing changed no emulation.
#
# EmuHawk instances run on a private Xvfb display (no window appears) and up to
# --parallel of them run concurrently, each with private config/job files.
#
# Usage:
#   ./run-level-b.sh                  # verify the free-to-distribute set (CI default)
#   ./run-level-b.sh --set full       # the whole witness set (commercial roms)
#   ./run-level-b.sh --record         # record goldens from current build
#   ./run-level-b.sh --filter super   # only tests whose name matches (regex)
#   ./run-level-b.sh --minihawk-root <path>  # miniHawk checkout (default: sibling
#                                            # ../../../miniHawk, then ../../../BizHawk)
set -u

record=0
skip_existing=0
# Which tests to run. "free" is the default because it is the only set that can
# run anywhere: its roms are redistributable and vendored in suite/roms, so CI
# needs nothing provisioned. "full" adds the commercial-rom tests, which live in
# a local rom library - run it for significant changes, before a push, and
# whenever the core or the ABI moves.
set_name=free
filter=""
checkpoint=0
parallel=8
# Per-test wall-clock cap. superOffroad.anyPercent is 182,180 frames - minutes of
# wall clock even at replay speed, so the default has to clear it or the longest
# test in the set reports TIMEOUT.
timeout_sec=7200
minihawk_root=""
while [ $# -gt 0 ]; do
	case "$1" in
		--record) record=1 ;;
		--skip-existing) skip_existing=1 ;;
		--set) set_name="$2"; shift ;;
		--filter) filter="$2"; shift ;;
		--checkpoint) checkpoint="$2"; shift ;;
		--parallel) parallel="$2"; shift ;;
		--timeout) timeout_sec="$2"; shift ;;
		--minihawk-root) minihawk_root="$2"; shift ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
	shift
done
case "$set_name" in free|full) ;; *) echo "--set must be free or full" >&2; exit 2 ;; esac

# Tests whose roms are free to distribute and are vendored in suite/roms. This is
# the CI set: it needs nothing provisioned.
free_set=(
	"sprilo.anyPercent"
	"novaTheSquirrel.anyPercent"
)

harness_dir="$(cd "$(dirname "$0")" && pwd)"
if [ -z "$minihawk_root" ]; then
	for candidate in "$harness_dir/../../../miniHawk" "$harness_dir/../../../BizHawk"; do
		[ -d "$candidate" ] && { minihawk_root="$candidate"; break; }
	done
fi
[ -n "$minihawk_root" ] && [ -d "$minihawk_root" ] || { echo "miniHawk checkout not found; pass --minihawk-root <path>" >&2; exit 1; }
repo_root="$(cd "$minihawk_root" && pwd)"
# vendored snapshot of the quickerNES regression suite (upstream: TASEmulators/quickerNES, tests/)
tests_dir="$harness_dir/suite"
roms_dirs=("$tests_dir/roms" "$HOME/TAS/roms/nes")
emu_hawk="$repo_root/build/Chimera.exe"
# cores load explicitly (no discovery): every instance is told which package to use
core_package="$repo_root/build/Cores/quickernes.chimeraCore"
[ -f "$core_package" ] || { echo "core package not found at $core_package (run quickerNES/waterbox/build-package.sh first)" >&2; exit 1; }
work_dir="$harness_dir/work"
run_dir="$work_dir/run"
golden_dir="$harness_dir/goldens/levelB"
play_lua="$harness_dir/playmovie.lua"

# Tests excluded from the witness set (see miniHawk's docs/design-principles.md for rationale)
excluded=(
	"castlevania3.playaround"        # mapper 5 deliberately disabled in pinned core
	"arkanoid2.arkFamicomController" # local ROM dump SHA1 mismatch
	"microMachines.race20"           # starts from quickerNES-native .state (Level A only)
	"saiyuukiWorld.lastHalf"         # starts from quickerNES-native .state (Level A only)
)

mkdir -p "$work_dir" "$run_dir"
[ "$record" -eq 1 ] && mkdir -p "$golden_dir"

# ---------- EmuHawk-under-Mono environment ----------
export LD_LIBRARY_PATH="$repo_root/build/dll:$repo_root/build:/usr/lib/x86_64-linux-gnu"
export MONO_CRASH_NOFILE=1
export MONO_WINFORMS_XIM_STYLE=disabled # see https://bugzilla.xamarin.com/show_bug.cgi?id=28047#c9
export ALSOFT_DRIVERS=null              # no audio device on the test display

# Private Xvfb display for the whole run (the Linux analogue of the hidden
# Windows desktop), unless the caller already exported one.
xvfb_pid=""
cleanup() { [ -n "$xvfb_pid" ] && kill "$xvfb_pid" 2>/dev/null; }
trap cleanup EXIT
if [ -z "${DISPLAY:-}" ]; then
	command -v Xvfb >/dev/null || { echo "Xvfb not found (apt install xvfb), and no DISPLAY set" >&2; exit 1; }
	for n in 90 91 92 93 94; do
		if [ ! -e "/tmp/.X11-unix/X$n" ]; then
			Xvfb ":$n" -screen 0 1280x1024x24 -nolisten tcp &
			xvfb_pid=$!
			export DISPLAY=":$n"
			break
		fi
	done
	[ -n "${DISPLAY:-}" ] || { echo "no free X display found" >&2; exit 1; }
	sleep 1
	kill -0 "$xvfb_pid" 2>/dev/null || { echo "Xvfb failed to start on $DISPLAY" >&2; exit 1; }
fi

# ---------- config handling ----------
# Base config: created by EmuHawk on first ever run; harness settings enforced here.
# On a fresh checkout no config exists yet — run EmuHawk once with a lua script
# that exits immediately, so it writes its defaults to our config path.
config_file="$work_dir/config.ini"
if [ ! -f "$config_file" ]; then
	echo "bootstrapping $config_file (first run)..."
	( cd "$repo_root" && timeout 120 mono "$emu_hawk" "--headless" "--config=$config_file" \
		"--lua=$harness_dir/bootstrap.lua" ) > "$run_dir/bootstrap.log" 2>&1
	[ -f "$config_file" ] || { echo "bootstrap failed to produce config.ini (see tests/work/run/bootstrap.log)" >&2; exit 1; }
fi
if [ -f "$config_file" ]; then
	python3 - "$config_file" <<'EOF'
import io, json, sys
path = sys.argv[1]
cfg = json.load(io.open(path, encoding="utf-8-sig"))
cfg["SoundEnabled"] = False
# NOT setting OpposingDirPolicy: the SOCD filter sits in the HOST input path
# (what gets recorded), and movie playback goes straight from the movie to the
# output controller, so it cannot touch replayed input. Verified by replaying
# with the filter set to Forbid: the dump is unchanged. It mattered when this
# harness injected input from Lua.
# GDI+ display: on the hidden test display, OpenGL means Mesa's llvmpipe
# software rasterizer - ~32 threads per instance, catastrophic under
# parallel gates. Display method cannot affect emulation (pillar).
cfg["DispMethod"] = 1
# Rewind captures a savestate EVERY frame. A replay never rewinds, so that is
# pure cost - and for a waterbox core it dominates everything else, an order of
# magnitude more than the emulation itself. Savestate faithfulness is proven at
# the core level (waterbox/run-gate.sh), not here.
cfg.setdefault("Rewind", {})["Enabled"] = False
io.open(path, "w", encoding="utf-8").write(json.dumps(cfg, indent=2))
EOF
fi

# Peripherals (Four Score, Arkanoid paddles) are carried in the project's own
# settings now, so every test runs from the same base config.

rom_path_for() { # "roms/<name>" -> absolute path or empty
	local name="${1#roms/}"
	for dir in "${roms_dirs[@]}"; do
		[ -f "$dir/$name" ] && { echo "$dir/$name"; return; }
	done
	echo ""
}

# ---------- build the job list ----------
declare -a results=() # lines: "name|RESULT|detail"
declare -a job_names=() job_roms=() job_movies=()

for test_file in "$tests_dir"/*.test; do
	name="$(basename "$test_file" .test)"
	skip=0
	for ex in "${excluded[@]}"; do [ "$name" = "$ex" ] && skip=1; done
	[ "$skip" -eq 1 ] && continue
	if [ -n "$filter" ] && ! [[ "$name" =~ $filter ]]; then continue; fi
	if [ "$set_name" = "free" ]; then
		in_free=0
		for f in "${free_set[@]}"; do [ "$name" = "$f" ] && in_free=1; done
		[ "$in_free" -eq 1 ] || continue
	fi

	# .test JSON fields: "Rom File", "Expected ROM SHA1", "Sequence File",
	# "Controller 1 Type", "Controller 2 Type"
	mapfile -t fields < <(python3 - "$test_file" <<'EOF'
import io, json, sys
t = json.load(io.open(sys.argv[1], encoding="utf-8-sig"))
for k in ("Rom File", "Expected ROM SHA1", "Sequence File", "Controller 1 Type", "Controller 2 Type"):
    print(t.get(k, ""))
EOF
)
	rom_file="${fields[0]}" expected_sha1="${fields[1]}" seq_file="${fields[2]}" c1="${fields[3]}" c2="${fields[4]}"

	rom_path="$(rom_path_for "$rom_file")"
	if [ -z "$rom_path" ]; then
		results+=("$name|SKIP|ROM not found: $rom_file")
		continue
	fi
	sha1="$(sha1sum "$rom_path" | cut -d' ' -f1 | tr a-f A-F)"
	if [ "$sha1" != "$(echo "$expected_sha1" | tr a-f A-F)" ]; then
		results+=("$name|SKIP|ROM SHA1 mismatch")
		continue
	fi
	if [ "$record" -eq 1 ] && [ "$skip_existing" -eq 1 ] && [ -f "$golden_dir/$name.simple.ram.bin" ]; then
		results+=("$name|RECORDED|already present (skipped)")
		continue
	fi
	movie="$harness_dir/movies/$name.chimeraProject"
	if [ ! -f "$movie" ]; then
		results+=("$name|SKIP|no movie: run tools/make-movies.sh")
		continue
	fi
	job_names+=("$name"); job_roms+=("$rom_path"); job_movies+=("$movie")
done

# ---------- run with up to $parallel concurrent EmuHawks ----------
declare -a run_names=() run_pids=() run_starts=() run_outs=() run_metas=()

start_test_job() { # index into job_* arrays
	local i="$1"
	local name="${job_names[$i]}"
	local out_file="$work_dir/$name.simple.ram.bin"
	local meta_file="$work_dir/$name.simple.meta.txt"
	rm -f "$out_file" "$meta_file"

	# private config + job file per instance (EmuHawk rewrites config on exit)
	local cfg_run="$run_dir/config.$name.ini"
	cp "$config_file" "$cfg_run" 2>/dev/null || true
	local job_file="$run_dir/job.$name.txt"
	{
		echo "out=$out_file"
		echo "meta=$meta_file"
	} > "$job_file"

	( cd "$repo_root" && MINIHAWK_JOB="$job_file" exec mono "$emu_hawk" "--headless" \
		"--config=$cfg_run" "--core=$core_package" "--movie=${job_movies[$i]}" "--lua=$play_lua" \
		"${job_roms[$i]}" ) > "$run_dir/$name.log" 2>&1 &
	run_names+=("$name"); run_pids+=($!); run_starts+=("$SECONDS")
	run_outs+=("$out_file"); run_metas+=("$meta_file")
}

complete_test_job() { # slot index
	local s="$1"
	local name="${run_names[$s]}" out_file="${run_outs[$s]}" meta_file="${run_metas[$s]}"
	local secs=$((SECONDS - run_starts[s]))
	if [ ! -f "$meta_file" ]; then
		results+=("$name|FAIL|no meta produced (see tests/work/run/$name.log)")
		return
	fi
	local status detail frames
	status="$(sed -n 's/^status=//p' "$meta_file" | head -1)"
	detail="$(sed -n 's/^detail=//p' "$meta_file" | head -1)"
	frames="$(sed -n 's/^frames=//p' "$meta_file" | head -1)"
	if [ "$status" != "OK" ]; then
		results+=("$name|FAIL|$status: $detail")
		return
	fi
	if [ "$record" -eq 1 ]; then
		cp "$out_file" "$golden_dir/$name.simple.ram.bin"
		results+=("$name|RECORDED|$frames frames in ${secs}s")
		return
	fi
	local golden_file="$golden_dir/$name.simple.ram.bin"
	if [ ! -f "$golden_file" ]; then
		results+=("$name|NOGOLDEN|")
		return
	fi
	if cmp -s "$out_file" "$golden_file"; then
		results+=("$name|PASS|$frames frames in ${secs}s")
	else
		results+=("$name|FAIL|$frames frames in ${secs}s (RAM mismatch)")
	fi
}

next_job=0
while [ "$next_job" -lt "${#job_names[@]}" ] || [ "${#run_pids[@]}" -gt 0 ]; do
	while [ "$next_job" -lt "${#job_names[@]}" ] && [ "${#run_pids[@]}" -lt "$parallel" ]; do
		start_test_job "$next_job"
		next_job=$((next_job + 1))
	done
	sleep 0.25
	for ((s=${#run_pids[@]}-1; s>=0; s--)); do
		pid="${run_pids[$s]}"
		if ! kill -0 "$pid" 2>/dev/null; then
			wait "$pid" 2>/dev/null
			complete_test_job "$s"
			unset 'run_names[s]' 'run_pids[s]' 'run_starts[s]' 'run_outs[s]' 'run_metas[s]'
			run_names=("${run_names[@]}"); run_pids=("${run_pids[@]}"); run_starts=("${run_starts[@]}")
			run_outs=("${run_outs[@]}"); run_metas=("${run_metas[@]}")
		elif [ $((SECONDS - run_starts[s])) -gt "$timeout_sec" ]; then
			kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
			results+=("${run_names[$s]}|TIMEOUT|${timeout_sec}s")
			unset 'run_names[s]' 'run_pids[s]' 'run_starts[s]' 'run_outs[s]' 'run_metas[s]'
			run_names=("${run_names[@]}"); run_pids=("${run_pids[@]}"); run_starts=("${run_starts[@]}")
			run_outs=("${run_outs[@]}"); run_metas=("${run_metas[@]}")
		fi
	done
done

# ---------- report ----------
ok=0; failed=0; skipped=0
printf "\n%-36s %-9s %s\n" "Test" "Result" "Detail"
printf "%-36s %-9s %s\n" "----" "------" "------"
while IFS='|' read -r name result detail; do
	printf "%-36s %-9s %s\n" "$name" "$result" "$detail"
	case "$result" in
		PASS|RECORDED) ok=$((ok+1)) ;;
		SKIP) skipped=$((skipped+1)) ;;
		*) failed=$((failed+1)) ;;
	esac
done < <(printf "%s\n" "${results[@]}" | sort)
echo ""
echo "$ok ok, $failed failed, $skipped skipped  (set: $set_name)"
[ "$failed" -gt 0 ] && exit 1
exit 0
