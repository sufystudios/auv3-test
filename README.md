# auv3-test

A command-line host that tests an Audio Unit v3 plugin on macOS **the way Logic Pro and GarageBand load it**: out of process, rendering on a real-time audio thread, with a host tempo and transport, MIDI, automation and the plugin's own window open. It reports what went wrong in plain words, with the usual cause and fix, or as JSON for scripts and coding agents.

```
$ auv3-test aumu Dron Sufy
auv3-test 0.2.0
Plugin:  DroneSynth by Sufy Studios  [aumu Dron Sufy]  version 1.6.0
         AUv3, 81 parameters, has its own window

✓ Parameters are well formed
✓ Opens its window
✓ Plays a held chord
    375 blocks rendered on time; worst render call 2.9 ms of a 10.7 ms block.
✓ Keeps time while the host automates every parameter (render thread)
✓ Still plays after automation
✓ Keeps time while the host sets parameters from another thread
✓ Reads back what the host set
✗ Saves and restores its state
    55 parameters didn't come back: cutoff: saved 200, restored 19179…
    → Setting fullState must restore every parameter. Make sure all of them are
      saved in it, and the tree's values are updated when it's applied.

FAILED  (1 of 8 checks failed, 0 warnings)
```

## Why

`auval` checks that a plugin follows the Audio Unit rules, and [pluginval](https://github.com/Tracktion/pluginval) is a thorough validator, but it doesn't find AUv3 app extensions. Neither one hosts a plugin the way a real DAW does. Bugs that only show up there often get through: the render thread waiting on the main thread while automation plays (silence, then the DAW freezes), state that doesn't survive a save, or the host's copy of a parameter drifting from the plugin's. auv3-test reproduces those conditions on the command line, in a few seconds, with no DAW.

It needs no dependencies, just Apple's frameworks, and works with any Audio Unit macOS can see: AUv3 app extensions (including iOS/Mac Catalyst ones) and AUv2 components.

## Install

Requires macOS 14 or later and Xcode 16 or later (Swift 6 toolchain).

```sh
git clone https://github.com/sufystudios/auv3-test.git
cd auv3-test
swift build -c release
cp .build/release/auv3-test /usr/local/bin/    # optional
```

## Use

```sh
auv3-test --list                    # every Audio Unit macOS can see, with its codes
auv3-test aumu Dron Sufy            # test an instrument: type, subtype, manufacturer
auv3-test aufx dely appl            # test an effect
auv3-test aumu "dls " appl --json   # codes with spaces need quotes
```

| Option | What it does |
|---|---|
| `--list` | List installed Audio Units with their four-character codes. |
| `--json` | Print the report as JSON. |
| `--seconds <n>` | Seconds of audio per phase (default 4). |
| `--sample-rate <hz>` | Default 48000. |
| `--block-size <n>` | Frames per render call (default 512). |
| `--no-ui` | Don't open the plugin's window (headless machines, CI). |
| `--fast` | Render as fast as possible instead of in real time. Quicker, but timing checks mean less. |
| `--save-audio <dir>` | Save each phase's audio there as a WAV file, to listen to what the checks measured. |
| `--snapshot <png>` | After the checks, save a PNG of the plugin's window, its own drawing included (for store screenshots or docs). The window is raised above other apps for the shot, so keep it unobscured. May need the Screen Recording permission for the terminal. Not with `--no-ui`. |
| `--window-size <WxH>` | Open the plugin's window at this content size in points (e.g. `1400x460`), instead of the size the plugin asks for. Many plugins pick their layout from the size. |
| `--verbose` | Print progress to stderr. |

**Exit codes:** `0` every check passed (there may be warnings), `1` at least one check failed, `2` the plugin couldn't be found or loaded, or the options were wrong.

An AUv3 must be registered before macOS can see it: open its containing app once. If you have two copies of the app (an App Store one and a debug build, say), macOS may load either; keep one, and run `killall -9 AudioComponentRegistrar` after replacing it.

## The checks

| ID | Checks that the plugin… | Fails when |
|---|---|---|
| `parameters` | has a well-formed parameter tree | addresses or identifiers repeat, a range is inverted or not finite, or a parameter starts outside its range |
| `window` | opens its own view in a window (skipped with `--no-ui`) | (a warning) it has no view, or it doesn't arrive in 15 s |
| `plays` | makes sound from a held chord (instruments) or processes a test tone (effects) | render errors, NaN or infinite samples, silence, or late renders |
| `render-thread-automation` | keeps time while every parameter is automated on every block from the render thread, as a DAW plays back automation | any render call over 100 ms, more than 2% of calls late, or any call taking twice its block |
| `sound-after-automation` | still plays once automation stops | it's silent: automation left it stuck |
| `host-thread-automation` | keeps time while parameters are set 50 times a second from another thread (a host's controls or control surface) | as for render-thread automation |
| `clicks` | changes parameters without clicking: each smoothly variable parameter in turn jumps between a quarter and three quarters of its range while a chord holds, as stepped automation does | (a warning) a jump makes an edge in the waveform at least 4× sharper than anything the steady sound has at either value |
| `parameter-readback` | reads back a parameter after it's set: straight away for an AUv2, as hosts and auval do, or within 300 ms for an out-of-process AUv3, whose values reach the host asynchronously | (a warning) a value doesn't read back |
| `state` | restores every parameter from a saved `fullState` after they've been scrambled | any parameter doesn't come back |

Each failure or warning comes with a hint: the usual cause and fix.

**What the sound checks don't hear.** They catch silence, NaN and infinite samples, extreme levels and clicks (a sudden step in the waveform, like a gain applied in one sample). They don't yet catch *zipper noise*: a parameter moving in small audible steps as automation updates it. A filter cutoff jumping to a new value changes how bright the sound is without a step in the waveform, so it doesn't count as a click. Use `--save-audio` and listen when you're chasing that.

Rendering happens on a dedicated `.userInteractive` thread, paced in real time, calling the plugin's `renderBlock` directly as a host's audio thread does. The host supplies a 120 BPM 4/4 `musicalContextBlock` and a playing `transportStateBlock`, and schedules MIDI and automation from the render thread with `scheduleMIDIEventBlock` and `scheduleParameterBlock`. The plugin's window stays open throughout, because many render-thread bugs only appear while the UI is alive.

## Development

```sh
swift test --scratch-path /tmp/auv3-test-build
```

The tests check the click detector on made-up signals where the right answer is known. Pass a `--scratch-path` outside `~/Documents` if that folder syncs to iCloud: the extended attributes iCloud adds make code signing the test bundle fail.

## For coding agents

`--json` output is stable and meant to be parsed; see [AGENTS.md](AGENTS.md) for how an agent should run auv3-test and act on its results.

## Related projects

- [pluginval](https://github.com/Tracktion/pluginval): cross-platform plugin validator (VST3, AU; no AUv3 app extensions on macOS).
- [AUv3Host](https://github.com/bradhowes/AUv3Host) by Brad Howes: an interactive iOS host for trying AUv3s by hand, with multiple instances and presets.
- [auv3-support](https://github.com/bradhowes/auv3-support) by Brad Howes: a Swift package for building AUv3 plugins.

## License

MIT; see [LICENSE](LICENSE).
