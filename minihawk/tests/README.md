# QuickerNES witness harness for miniHawk

Lives in the quickerNES repository (miniHawk itself carries no core-specific
material). Both drivers locate the miniHawk checkout via `--minihawk-root` /
`-MiniHawkRoot` (default: sibling checkout named `miniHawk` or `BizHawk`).

The core under test is the **waterbox package** — `core.wbx` plus
`waterbox.config`, built by [`../../waterbox/build-package.sh`](../../waterbox)
and loaded through miniHawk's single generic adapter. The goldens predate that
port: they were recorded through the retired managed package and cross-validated
against the native tester's own dumps (`goldens/native/`). Reproducing them
byte-for-byte is precisely the proof that sandboxing changed no emulation.

The suite (`suite/*.test` + `.sol` input sequences) is a vendored snapshot of
`tests/` from [TASEmulators/quickerNES](https://github.com/TASEmulators/quickerNES).

## What this gate does and does not cover

It covers the **frontend path**: the package loads through the real loader, input
reaches the core through the real controller chain, and 45,000 frames later the
RAM is what the native core produced.

It does **not** test savestates. That property — the whole machine round-tripping
through save/load around every frame, byte-identically — is proven directly and
hundreds of times faster by [`../../waterbox/run-gate.sh`](../../waterbox), at
the core level where it belongs.

## Which tests to run

| set | contents | when |
|---|---|---|
| `free` (**default**) | tests whose roms are free to distribute and vendored in `suite/roms` | every run, and in CI — it needs nothing provisioned |
| `full` | adds the commercial-rom tests, resolved from a local rom library | before a release, and whenever the core, the guest ABI or the adapter changes |

```sh
./run-level-b.sh                            # free set
./run-level-b.sh --set full                 # the whole witness set
./run-level-b.sh --set full --parallel 26   # one instance per test, if you have the cores
./run-level-b.sh --record                   # (re)record goldens from the current build
./run-level-b.sh --filter super             # subset by regex
```

`run-level-b.ps1` is the Windows equivalent (`-Set full`, …); it runs instances
on a hidden Windows desktop instead of Xvfb, and `hidden-run.ps1` is a standalone
helper for one-off hidden runs.

## How a test runs

For each test: launch EmuHawk with `--headless --movie=<test>.chimeraProject`, play the
movie to its end on a hidden display (no window appears), and dump the final 2KB
`RAM` domain. Input comes from the **movie**, so the gate exercises the same path
a user does — the movie session driving the controller chain — and nothing runs
per frame in script. Up to `--parallel` instances run concurrently, each with
private config/job files. `--headless` makes any modal dialog log its text and
exit with code 64 instead of blocking invisibly.

A movie here is a **Chimera project** (`.chimeraProject`): one JSON file holding
the core pin, the settings, the header metadata and the input log. The project IS
the movie (chimera's `docs/project.md`), and it is the only movie form Chimera
reads — the zip the BizHawk lineage carried is gone, and a file that is not a
project is refused before it is opened.

Movies are generated from the `.sol` sequences by `tools/make-movies.sh`, which
uses the frontend's own `LogEntryGenerator` against the core's
`ControllerDefinition` — so the mnemonic layout comes from the code that reads it
back, not a hand-written guess. That definition is the one the **machine** has,
not the one the package declares: the ports were read at boot, so a movie carries
columns for the peripherals its own settings plugged in and no others. **Change
the controller declaration in waterbox.config, or what a port holds, and the
movies must be regenerated**; forget, and every test desyncs at once, which is the
intended alarm. Free-set movies are committed, so CI needs no conversion step.

Ports (Four Score, Arkanoid paddles) travel in the project's own `settings`, which
is where they belong: with the input they apply to, rather than in a config file
off to the side.

Things that were required for byte-exact agreement with the native tester, each
found the hard way:

- Console Reset/Power flags in `.sol` files are parsed but **not** applied — the
  native tester ignores them during replay (solarJetman has a reset).
- `OpposingDirPolicy` no longer matters, though it used to. The SOCD filter sits
  in the *host* input path — what gets recorded — and movie playback goes from the
  movie straight to the output controller, so it cannot touch replayed input.
  Verified by replaying with the filter set to `Forbid`: the dump is unchanged.
  It mattered when this harness injected input from Lua, because the movies use
  simultaneous L+R/U+D.
- A movie needs a `Core` header naming the core as the **registry** knows it
  (`waterbox.config`'s `coreName`, e.g. `quickerNES`) — not the adapter's
  `[PortedCore]` attribute, which is `Waterbox` for every waterbox core alike.
  Without it, playback stops on a dialog, which headless turns into exit code 64.
- Rewind is disabled in the harness config. A replay never rewinds, and for a
  waterbox core a per-frame savestate costs more than the emulation.

## Timing

Wall clock is dominated by the frontend, not the core. With host servicing
rate-limited in headless mode, a 45,472-frame movie replays in ~36s; the whole
free set runs in well under a minute. The per-test timeout defaults to 7200s
because `superOffroad.anyPercent` is 182,180 frames and `nigelMansell.anyPercent`
is 296,590.

Goldens live in `goldens/levelB/`. A run passes when every dump is
byte-identical to its golden, and goldens must themselves match
`goldens/native/` (cross-validated whenever they are re-recorded).

## Witness set

26 tests of 31 run; exclusions and rationale are in the drivers' `excluded` list
(mapper 5 disabled in the pinned fork, one wrong local rom dump, two tests that
start from a quickerNES-native `.state` and so are Level-A-only).
`novaTheSquirrel` was excluded until the core gained MMC1 banked PRG RAM; it is
now part of the free set.
