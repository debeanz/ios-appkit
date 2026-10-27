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

**40 of 833 symbols implemented** (40 of AppKit's 385). This is a foundation, not a
finished layer. What's here:

| Class | Backed by | Notes |
|---|---|---|
| `NSApplication` | `UIApplication` | run loop, delegate, event queue; `-sendEvent:` routes input to the event's window |
| `NSWindow` | container view in one shared `UIWindow` | full screen inside the safe area; per-window first responder; mouse → view under the pointer, keys → first responder, hover enter/exit/move |
| `NSView` | `UIView` subclass | `-drawRect:`, subview tree, superview as next responder, input context, tracking areas, flipped (top-left) coordinates |
| `NSResponder` | — | the responder chain, `interpretKeyEvents:`, `tryToPerform:with:`, `doCommandBySelector:` |
| `NSEvent` | — | AppKit's key/mouse/other factories, key repeat, scrolling deltas, window numbers |
| `NSTextInputContext` | — | turns key events into `insertText:replacementRange:` / editing commands for an `NSTextInputClient` (how Chromium's text fields get input) |
| `NSPasteboard`, `NSPasteboardItem` | `UIPasteboard` | general pasteboard is the system clipboard |
| `NSCursor` | — | system cursors, push/pop; records the current cursor (iPhones have none) |
| `NSMenu`, `NSMenuItem` | — | full model + Cmd-shortcut dispatch; never shown (Big Picture draws its own) |
| `NSTrackingArea` | — | drives `mouseEntered:`/`mouseExited:`/`mouseMoved:` |
| `NSScreen` | `UIScreen` | frame, scale, safe-area `visibleFrame` |
| `NSColor` | `UIColor` | RGBA + the system colors the client uses |
| `NSGeometry` | CoreGraphics | `NSRect`/`NSPoint`/`NSSize` are the CG types, as on 64-bit macOS |

### Input on iPhone and iPad

[`src/InputBridge.m`](src/InputBridge.m) turns UIKit input into NSEvents and sends them
through `[NSApp sendEvent:]`, so they reach views exactly as on the Mac:

- **Touch** → left mouse down/drag/up (one pointer at a time); secondary click → right button.
- **Hardware keyboard** → key down/up with macOS key codes and Mac-style key repeat;
  modifier keys → `flagsChanged:`. Editing keys map to AppKit's standard commands
  (`deleteBackward:`, `moveLeft:`, `insertNewline:`...).
- **iPhone keyboard** → each character becomes a key down/up pair. Whether it shows is
  set by `AKShimSetSoftwareKeyboardPolicy` ([`AKShimInput.h`](include/AppKitShim/AKShimInput.h)):
  by default it appears only while a text field has focus — which Chromium signals by
  returning a non-nil `-inputContext` — so Steam's sign-in fields bring it up and it goes
  away elsewhere.
- **iPad trackpad / mouse** → hover becomes `mouseMoved:` (with enter/exit via tracking
  areas), two-finger scrolling becomes precise `scrollWheel:` events.

Not yet: IME composition (marked text for CJK input), drag and drop, context menus.

## The honest part

- **The symbol count understates the work.** Objective-C methods are dispatched
  dynamically, so the hundreds of messages CEF sends to `NSView`/`NSWindow`/`NSEvent`
  don't show up as undefined symbols — only the class references do. Making the layer
  *behave* like AppKit (live resize, text input, the event loop CEF's compositor
  expects) is most of the real effort and isn't captured by "40/833".
- **The 704 CEF symbols are the mountain.** Chromium is the hardest consumer: it pokes
  at private AppKit internals and expects a real NSView hierarchy and event stream. The
  other consumers (SDL3, `steamui`, `steamclient`) are far smaller and more mechanical.
- **Compiled, not yet run on screen.** The library builds for device and simulator on
  Codemagic (Xcode 26.6, iOS 26.5 SDK) and the smoke test links against real UIKit. The
  smoke test pushes events through the input path but puts nothing on screen; real
  touch/keyboard behaviour needs a hosted app on a device.

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
