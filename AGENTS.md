# auv3-test for coding agents

Use this when you're working on an Audio Unit plugin and need to know whether it behaves in a real host, without a human opening Logic Pro. It's for you whether you're Claude Code, Codex, Cursor or anything else that can run a shell command.

## The loop

1. Build the plugin's containing app and install or run it once, so macOS registers the Audio Unit.
2. Run `auv3-test <type> <subtype> <manufacturer> --json`. Find the codes with `auv3-test --list` or the plugin's `Info.plist` (`AudioComponents`).
3. Read the exit code, then `checks[].status`.
4. For each `failed` (then `warning`) check, read `detail` (what happened, with numbers) and `hint` (the usual cause and fix). Fix the plugin, rebuild, reinstall and run again.

A full run takes about 30 seconds in real time. Add `--fast` for a quick iteration, but rerun without it before concluding a timing problem is fixed, because `--fast` doesn't pace like a real audio thread.

## Make sure you're testing the build you just made

This is the most common way to waste a session:

- macOS loads the *registered* copy of the plugin, which may not be the one you just built. If an App Store copy and a debug copy both exist, either can load. Copies in the Trash stay registered too.
- After replacing the app, run `killall -9 AudioComponentRegistrar` and wait a few seconds.
- Check the installed binary's timestamp. In debug builds, the code lives in `<Name>.appex/Contents/MacOS/<Name>.debug.dylib`. To check that a Swift function is there, use `nm <dylib> | xcrun swift-demangle | grep <name>`, not `strings`: Swift stores strings of 15 bytes or fewer inline in the code.
- Xcode's build folder can change. Find the build you made, rather than assuming the path.

## The report

```json
{
  "tool": "auv3-test",
  "toolVersion": "0.2.0",
  "plugin": { "name": "…", "manufacturer": "…", "codes": "aumu Dron Sufy", "version": "1.6.0",
              "isAUv3": true, "hasCustomView": true, "parameterCount": 81 },
  "settings": { "sampleRate": "48000 Hz", "blockSize": "512 frames", "…": "…" },
  "checks": [
    {
      "id": "render-thread-automation",
      "title": "Keeps time while the host automates every parameter (render thread)",
      "status": "passed | warning | failed",
      "detail": "375 blocks rendered on time; worst render call 7.9 ms of a 10.7 ms block.",
      "hint": "The render thread must never wait: …",
      "measurements": { "blocks": 375, "lateBlocks": 0, "stalls": 0, "worstRenderMs": 7.9, "blockMs": 10.67, "peak": 0.42 }
    }
  ],
  "setupError": null
}
```

- `setupError` is set (exit code 2) when the plugin couldn't be found or loaded; `checks` is empty then.
- `id` values are stable: `parameters`, `window`, `plays`, `render-thread-automation`, `sound-after-automation`, `host-thread-automation`, `clicks`, `parameter-readback`, `state`. Match on them, not on titles.
- `hint` is present on every check but only means something when the check didn't pass.
- `measurements` is for comparing runs. `worstRenderMs` against `blockMs` tells you how close the plugin is to dropping out.

## What failures usually mean

| Check | Usual cause |
|---|---|
| `render-thread-automation` stalls, then `sound-after-automation` silent | The parameter observer does main-thread work on the render thread: SwiftUI `@Published` / `ObservableObject` updates, UI, locks the main thread holds, allocation. Collect host sets in a lock-free or briefly locked buffer and apply them on the main thread; read back the pending value meanwhile. |
| `host-thread-automation` late | The same, from a host's other threads, or the main thread being kept busy by the change. |
| `parameter-readback` | The value provider returns the applied value, not the one just set, while the set is still pending. For an out-of-process AUv3, the host's copy can also lag straight after render-thread automation while the plugin has the value: compare its `fullState` before changing code. |
| `state` | `fullState`'s getter misses sets still waiting to be applied; the setter applies the patch but doesn't tell the parameter tree (an out-of-process host keeps its own copy of every value); or older pending sets land on top of the restored state. |
| `clicks` | A gain or mix level is applied in one sample. Glide to the new value over 5-30 ms (a one-pole smoother or a ramp). A delay's time needs a crossfade instead. |
| `plays` render errors | `kAudioUnitErr_NoConnection` for an effect usually means the input bus isn't enabled or connected; `TooManyFramesToProcess` means `maximumFramesToRender` isn't respected. |

## Listening

Run with `--save-audio <dir>` to get each phase as a 32-bit float WAV (`01-plays.wav`, `05-clicks.wav`…), and `audioFiles` in the JSON lists them. If you can analyse audio, use them to confirm a fix. If you can't, tell the user which file to listen to. The clicks recording runs through each parameter in turn, 0.36 s apiece, in the order of the parameter tree.

Run with `--snapshot <file.png>` (and optionally `--window-size <WxH>`) to save an image of the plugin's window after the checks. An AUv3's view is drawn by the plugin's own process, so auv3-test captures that part of the screen with its window raised to the front; `settings.snapshot` in the JSON says where it went, or why it wasn't saved. Look at the image before using it: if the macOS has an older copy of the plugin registered, that's the one shown.

Zipper noise (stepped, crackly automation) isn't detected yet; listen for it in `02-render-thread-automation.wav`.

## Don't

- Don't loosen a check to make a plugin pass. The thresholds match what's audible in a DAW.
- Don't treat a warning as a pass when the user reported the matching symptom.
- Don't close the plugin's window early or pass `--no-ui` to make a timing failure go away. The UI being alive is often the cause, and real hosts keep it open.
