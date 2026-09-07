# quickerNES as a miniHawk waterbox core

This is the live port. A miniHawk core package is exactly two files —
`core.wbx` (the sandboxed guest binary) and `waterbox.config` — loaded by
miniHawk's single built-in generic adapter. There is no managed assembly and no
native library in a package; the retired format that had those is described in
[`../minihawk/README.md`](../minihawk/README.md).

- `waterbox.cpp` — the guest ABI layer over the unmodified core. Everything
  system-specific lives here: input packing for the console's ports, the
  self-described memory domains, and the core-managed tooling (viewer surfaces,
  CPU registers, address buses, instruction trace). The frontend knows none of
  it.
- `waterbox.config` — the static machine surface: video/audio geometry, the
  controller declaration (buttons and axes), the guest heap layout, and default
  values for the user settings the guest reads at Init.
- `default_keybinds.json` — the default bindings for the controller this package
  declares, transcribed from BizHawk's `Assets/defctrl.json`. miniHawk ships no
  bindings of its own: a package that declares a controller says how it is played
  by default, and the frontend uses that for a controller the user's config has
  never seen. Player 1 only, plus the mouse for the arkanoid paddles and fire,
  which is BizHawk's own choice.
- `setup-guest.sh` — writes the meson cross file for miniBox's guest toolchain
  and configures `build/meson-guest`. The build itself is the repository's
  `meson.build`: a cross configure is the guest (`core.wbx`), and
  `-Dwaterbox=true` natively is `libquicknes` plus the three drivers below.
- `build-package.sh` — builds the package and installs it into a miniHawk
  checkout as `build/Cores/quickernes.chimeraCore`.
- `run-native.c` / `run-wbx.c` — the equivalence gate: the same rom, frame count
  and per-frame button pattern through the original shared library and through
  the sandbox. Video, audio and every memory domain must hash identically.
- `run-tooling.c` — exercises the optional tooling exports the way the frontend
  probes them.

## Building

```sh
./build-package.sh -r <miniHawk checkout>     # core.wbx + waterbox.config -> build/Cores/quickernes.chimeraCore
```

The C++ guest toolchain (musl + libstdc++ built for the sandbox) comes from the
miniBox checkout inside miniHawk (`extern/chimera-common-minibox`); `build-package.sh`
configures and builds it on demand.

## Gates

```sh
N=build/meson-native; G=build/meson-guest

# equivalence: sandboxed emulation must be byte-identical to the native library
$N/run-native $N/libquicknes.so <rom.nes> 300 > native.txt
$N/run-wbx    $G/core.wbx       <rom.nes> 300 > box.txt   # compare the digest lines
$N/run-wbx    $G/core.wbx       <rom.nes> 120 --rerecord  # + savestate round-trip every frame

# tooling: what the frontend will find and what it will show
$N/run-tooling $G/core.wbx <rom.nes> 120
```

The full frontend gate — 26 real movies replayed through EmuHawk against
goldens — lives in [`../minihawk/tests`](../minihawk/tests).

## Settings

`waterbox.config`'s `settings` block holds the defaults; miniHawk merges the
user's sync settings over them and mounts the result as JSON, which the guest
reads during Init. Changing one reboots the core, because these shape the
machine.

| key | values | meaning |
|---|---|---|
| `port1` | `gamepad` (default), `fourscore`, `arkanoidNES`, `arkanoidFamicom` | peripheral in console port 1 |
| `port2` | `none` (default), `gamepad`, `fourscore` | peripheral in console port 2 |

The controller declaration is the *union* of what those peripherals need (four
pads, two fire buttons, two paddle axes), because a package declares one
controller definition. The guest reads only the controls the configured ports
actually have.
