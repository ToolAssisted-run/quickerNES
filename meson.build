project('quickerNES','c','cpp',
  version: '1.0.0',
  license: 'GPL-3.0-only',
  default_options : ['cpp_std=c++20', 'default_library=shared', 'buildtype=release'],
  subproject_dir : 'extern'
)

# ---------------------------------------------------------------------------
# The Chimera core build lives in waterbox/ and shares nothing with the tooling
# below it: no SDL, no ncurses, no test roms, and in the guest's case not even a
# host libc. A cross build IS the guest, so it selects itself; -Dwaterbox=true
# selects the native half (libquicknes plus the gate's drivers).
if meson.is_cross_build() or get_option('waterbox')
  minibox_dir = get_option('minibox_dir')
  if minibox_dir == ''
    mb_candidate = meson.current_source_dir() / '../chimera/extern/chimera-common-minibox'
    if import('fs').is_dir(mb_candidate)
      minibox_dir = mb_candidate
    else
      error('pass -Dminibox_dir=<miniBox checkout> (or keep one at ../chimera/extern/chimera-common-minibox)')
    endif
  endif
  dl_dep = meson.get_compiler('c').find_library('dl', required: false)

  # The Chimera core: quickerNES in miniBox's sandbox, and the two builds the
  # equivalence gate compares.
  #
  #   guest (core.wbx)   sh waterbox/setup-guest.sh
  #                      ninja -C build/meson-guest core.wbx
  #   native reference   meson setup build/meson-native -Dwaterbox=true
  #                      ninja -C build/meson-native
  #
  # The native side is not a rebuild of the guest sources against a shim: it is
  # libquicknes, the ORIGINAL shared library with the qn_* C API, which run-native
  # dlopens. So the gate compares the sandboxed core against the core as everyone
  # else builds it, which is the stronger of the two claims.

  # The core, exactly the list source/quickerNES/meson.build compiles. It is
  # repeated rather than reused because that file declares its dependency with
  # SDL2 attached, and neither the guest nor libquicknes has SDL.
  core_sources = files(
    'source/quickerNES/core/apu/apu.cpp',
    'source/quickerNES/core/apu/blipBuffer.cpp',
    'source/quickerNES/core/apu/buffer.cpp',
    'source/quickerNES/core/apu/effectsBuffer.cpp',
    'source/quickerNES/core/apu/fme7/apu_fme7.cpp',
    'source/quickerNES/core/apu/multiBuffer.cpp',
    'source/quickerNES/core/apu/namco/apu_namco.cpp',
    'source/quickerNES/core/apu/NESEffectsBuffer.cpp',
    'source/quickerNES/core/apu/oscs.cpp',
    'source/quickerNES/core/apu/vrc6/apu_vrc6.cpp',
    'source/quickerNES/core/apu/vrc7/apu_vrc7.cpp',
    'source/quickerNES/core/apu/vrc7/emu2413.cpp',
    'source/quickerNES/core/apu/vrc7/emu2413_state.cpp',
    'source/quickerNES/core/cpuFlat.cpp',
    'source/quickerNES/core/cpuPaged.cpp',
    'source/quickerNES/core/emu.cpp',
    'source/quickerNES/core/mappers/mapper.cpp',
    'source/quickerNES/core/ppu/ppu.cpp',
    'source/quickerNES/core/ppu/ppuImpl.cpp',
    'source/quickerNES/core/ppu/ppuRendering.cpp',
  )

  core_inc = include_directories(
    'source',
    'source/quickerNES',
    'source/quickerNES/core',
    'extern/jaffarCommon/include',
  )

  # The core is a pile of #ifdefs: whole features compile out when their macro is
  # absent, silently. These MUST be the same on both sides of the gate, or the
  # two builds are not the same emulator:
  #   _QUICKERNES_SUPPORT_ARKANOID_INPUTS - without it the paddle path (and the
  #     whole arkanoid branch of read_io) does not exist, so an Arkanoid movie
  #     desyncs while every joypad game still passes.
  #   _QUICKERNES_DETECT_JOYPAD_READS - without it joypad_read_count never moves,
  #     so InputWasRead always says "not read" and EVERY frame looks like a lag
  #     frame to the frontend.
  #   _QUICKERNES_ENABLE_TRACEBACK_SUPPORT - the per-instruction trace hook the
  #     tooling ABI binds. One predictable branch per instruction; it does not
  #     change emulation output, and the gate is run with it on.
  # (_QUICKERNES_PRINT_CART_INFO only prints, so it stays with libquicknes.)
  core_defs = [
    '-D_QUICKERNES_ENABLE_TRACEBACK_SUPPORT',
    '-D_QUICKERNES_SUPPORT_ARKANOID_INPUTS',
    '-D_QUICKERNES_DETECT_JOYPAD_READS',
    '-fno-strict-aliasing',   # the core type-puns the cart header; without this
                              # the iNES header is misparsed under -O2
    '-D__JAFFAR_COMMON_INLINE__=__attribute__((__used__)) inline',
  ]

  if meson.is_cross_build()
    # ---- the guest: core.wbx --------------------------------------------------
    # miniBox's musl + libstdc++ toolchain arrives through the cross file
    # (setup-guest.sh); the link recipe is the guest kit's - --no-relax for the
    # large code model, cxxglue and emulibc from the miniBox build, and the four
    # weak pthread symbols static libstdc++ expects to resolve.
    mbdir = meson.get_external_property('minibox_dir')
    mbuild = meson.get_external_property('minibox_build')
    sr = meson.get_external_property('guest_sysroot')

    executable('core', core_sources + files('waterbox/waterbox.cpp'),
      name_suffix: 'wbx',
      include_directories: [core_inc, include_directories('waterbox')],
      cpp_args: core_defs + ['-fno-exceptions', '-fno-rtti'],
      link_args: [
        '-static', '-no-pie',
        '-Wl,--eh-frame-hdr', '-Wl,-O2', '-Wl,--no-relax',
        '-T', mbdir / 'source/guest/linkscript.T',
        '-Wl,-u,pthread_once', '-Wl,-u,pthread_cond_wait',
        '-Wl,-u,pthread_cond_broadcast', '-Wl,-u,pthread_key_create',
        mbuild / 'source/guest/cxxglue.c.o',
        mbuild / 'source/guest/emulibc.c.o',
        '-L' + sr / 'lib', '-lstdc++', '-lgcc', '-lgcc_eh', '-lc'])
  else
    # ---- libquicknes: the native reference -------------------------------------
    # The flags are the ones the shared library has always been built with (the
    # retired minihawk/native/Makefile): -O3 with LTO, internal visibility, and
    # -Werror, because this is also the compile-check of the core proper.
    # -soname makes a later dlopen("libquicknes.so") resolve to the module the
    # frontend preloaded from the package dir by absolute path.
    shared_library('quicknes',
      core_sources + files('minihawk/native/bizinterface.cpp'),
      include_directories: core_inc,
      cpp_args: core_defs + ['-D_GNU_SOURCE', '-D_QUICKERNES_PRINT_CART_INFO',
                             '-Wall', '-Wfatal-errors', '-Werror',
                             '-fomit-frame-pointer', '-flto',
                             '-fvisibility=internal', '-fvisibility-inlines-hidden'],
      link_args: ['-flto', '-Wl,-soname,libquicknes.so'],
      name_prefix: 'lib',
      override_options: ['optimization=3'])

    # ---- the gate's drivers ---------------------------------------------------
    # run-native dlopens libquicknes; run-wbx and run-tooling run the guest
    # through miniBox's host library.
    executable('run-native', files('waterbox/run-native.c'), dependencies: [dl_dep])

    mbhost = minibox_dir / 'build/meson-cpp/source/host'
    foreach driver : ['run-wbx', 'run-tooling']
      executable(driver, files('waterbox' / driver + '.c'),
        c_args: ['-I' + minibox_dir / 'source/host'],
        link_args: [mbhost / 'libminiboxhost.so', '-Wl,-rpath,' + mbhost])
    endforeach
  endif
  subdir_done()
endif

# Loading dependencies
subdir('source')

# Grabbing hqn dependency

hqnSubproject = subproject('hqn')
hqnDependency = hqnSubproject.get_variable('hqnDependency')

# Do not build any targets if this is a subproject
if meson.is_subproject() == false

# Common application flags
commonCompileArgs = [ '-Wfatal-errors', '-Wall']

# Grabbing jaffarCommon dependency

jaffarCommonSubproject = subproject('jaffarCommon')
jaffarCommonDependency = jaffarCommonSubproject.get_variable('jaffarCommonDependency')

# Building playback tool
  if get_option('buildPlayer') == true
    executable('player',
      'source/player.cpp',
      cpp_args            : [ commonCompileArgs, '-DNCURSES' ],
      dependencies        : [ jaffarCommonDependency, quickerNESDependency, toolDependency, dependency('sdl2'), dependency('SDL2_image'), hqnDependency ],
      link_args           : [ '-lncurses' ]
    )
  endif

  # Building tester tool for QuickerNES

  quickerNESTester = executable('quickerNESTester',
    'source/tester.cpp',
    cpp_args            : [ commonCompileArgs, '-Werror' ],
    dependencies        : [ jaffarCommonDependency, quickerNESDependency, toolDependency ]
  )

  # Building tester tool for the original QuickNES

  if get_option('buildQuickNES') == true
  quickNESTester = executable('quickNESTester',
    'source/tester.cpp',
    cpp_args            : [ commonCompileArgs, '-w', '-DDISABLE_AUTO_FILE', '-D__LIBRETRO__', '-DNDEBUG', '-DBLARGG_NONPORTABLE'  ],
    dependencies        : [ jaffarCommonDependency, quickNESDependency, toolDependency ]
  )
  endif

  # Building tests
  if get_option('buildQuickNES') == true
  subdir('tests')
  endif
  
endif # If not subproject