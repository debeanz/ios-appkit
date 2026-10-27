# ios-appkit

A clean-room, from-scratch subset of macOS **AppKit** for iOS, built on UIKit and Metal.

It exists because the macOS Steam client (and the Chromium framework it renders Big
Picture with) imports **833** system symbols that iOS doesn't provide, and **385 of
those are AppKit** — the single biggest obstacle to running the native Mac client on an
iPhone. This library is the stand-in for that layer. It contains none of Valve's or
Apple's code; it reimplements the AppKit API against the iOS frameworks that do exist.

The symbol requirements come from the import analysis in `../steam-mac/report`, so what
gets built is driven by what the client actually calls, not guesswork. See
[`COVERAGE.md`](COVERAGE.md) for the live map (generated, not hand-written).

## Status

**12 of 833 symbols implemented.** This is a foundation, not a finished layer. What's here:

| Class | Backed by | Notes |
|---|---|---|
| `NSApplication` | `UIApplication` | run loop, delegate, event queue for `-postEvent:`/`-nextEventMatchingMask:` |
| `NSWindow` | container view in one shared `UIWindow` | each window is a full-screen view; `orderFront:` z-orders them |
| `NSView` | `UIView` subclass | `-drawRect:` override point, subview tree, flipped (top-left) coordinates |
| `NSResponder` | — | the event/responder chain |
| `NSEvent` | — | storage + factory for synthetic and bridged input events |
| `NSScreen` | `UIScreen` | frame, scale, safe-area `visibleFrame` |
| `NSColor` | `UIColor` | RGBA + the system colors the client uses |
| `NSGeometry` | CoreGraphics | `NSRect`/`NSPoint`/`NSSize` are the CG types, as on 64-bit macOS |

## The honest part

- **The symbol count understates the work.** Objective-C methods are dispatched
  dynamically, so the hundreds of messages CEF sends to `NSView`/`NSWindow`/`NSEvent`
  don't show up as undefined symbols — only the class references do. Making the layer
  *behave* like AppKit (live resize, text input, the event loop CEF's compositor
  expects) is most of the real effort and isn't captured by "12/833".
- **The 704 CEF symbols are the mountain.** Chromium is the hardest consumer: it pokes
  at private AppKit internals and expects a real NSView hierarchy and event stream. The
  other consumers (SDL3, `steamui`, `steamclient`) are far smaller and more mechanical.
- **Not built or verified here.** This was written on Windows; it has not been
  compiled. Objective-C against the iOS SDK needs a Mac. Use Codemagic (below) or a
  local Mac to get the first real compile.

## Building

Needs a Mac with Xcode.

```sh
make SDK=sim      # arm64 iOS Simulator
make SDK=device   # arm64 device
make test SDK=sim # build + link + run the smoke test
make coverage     # regenerate COVERAGE.md from the import analysis
```

No Mac on hand: Codemagic runs [`ci.sh`](ci.sh) on every push (see
[`codemagic.yaml`](codemagic.yaml)). It builds the static library for device and
simulator, links the smoke test, runs it on a booted simulator, and posts the full log
as a comment on the pushed commit. No signing, so it works on Codemagic's free tier.

One-time setup:

1. Sign in to [codemagic.io](https://codemagic.io) with GitHub and add this repo
   (choose `codemagic.yaml` as the configuration).
2. On GitHub, create a fine-grained personal access token limited to this repo,
   with **Contents: Read and write**.
3. In the Codemagic app, go to **Environment variables**, add `GITHUB_TOKEN` with that
   token, mark it **Secret**, and put it in a group named `github`.

After that, every push builds automatically and the log shows up on the commit:
`gh api repos/debeanz/ios-appkit/commits/<sha>/comments`.

## Layout

```
include/AppKitShim/   public headers (AppKit.h is the umbrella)
src/                  implementations (*.m) + implemented.json
tests/smoke.m         compile + link + round-trip smoke test
tools/gen-coverage.js turns ../steam-mac/report/gap-*.txt into COVERAGE.md
Makefile              iOS device / simulator build
codemagic.yaml        Mac CI: build both SDKs, run the smoke test
```

## How this fits the larger goal

This is step 1 of running the native Mac Steam client on iOS. The other pieces — the
remaining missing frameworks (CoreGraphics window/display APIs, Carbon keyboard layout,
etc.), re-tagging and loading the arm64 Steam binaries, JIT for CEF's JavaScript engine,
and single-process Chromium — are tracked separately. This layer is the prerequisite
everything visual depends on.

## License

Clean-room reimplementation of a published API. Add your chosen license before sharing.
No Apple or Valve code is included.
