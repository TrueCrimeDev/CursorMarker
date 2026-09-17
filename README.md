# CursorMarker

Three tools that make your mouse easy to follow in a screen recording, a window to set
them up in, and a button that turns your settings into a script you can just
double-click.

## Download

Grab **CursorMarker.exe** from the
[latest release](https://github.com/TrueCrimeDev/CursorMarker/releases/latest) and
double-click it. Nothing to install, and you do **not** need AutoHotkey — it is built in,
dark window and all.

A few things worth knowing about the exe:

- It keeps its settings, presets and exported scripts in `%AppData%\CursorMarker`, so it
  never scatters files into whatever folder you ran it from.
- Windows SmartScreen will probably warn the first time — it's an unsigned exe off the
  internet. **More info → Run anyway.** Some antivirus engines flag AutoHotkey-compiled
  exes generically; if that bothers you, run from source instead.

## Running from source instead

- Windows 10 or 11.
- AutoHotkey **v2.1-alpha.30 or newer** — stock alpha.30/.31 is fine.

Clone the repo and run `CursorMarker.ahk`. Nothing to install, nothing to configure.

**Dark mode is optional.** Put [`DarkModeModular.ahk`](https://github.com/TrueCrimeDev/DarkMode)
in a `Lib` folder *next to* the CursorMarker folder and the window turns dark. Without it
everything still works, just in Windows' default colours.

```text
SomeFolder\
  Lib\DarkModeModular.ahk   <- optional, for the dark window
  CursorMarker\CursorMarker.ahk
```

## The three tools

| Tab | What it does |
| --- | --- |
| **Magnifier** | A magnifying glass that follows your mouse. Whatever sits under the pointer shows up enlarged inside a lens, and you can click straight through it. |
| **Cursor** | Design your own mouse pointer — shape, colour, outline, size, glow. Save it as a `.cur` file, or make it your actual pointer. |
| **Highlight** | A coloured ring around the mouse so viewers can follow it, plus a ripple wherever you click, in a different colour per button. |
| **Export** | Turns whatever you have set up into a single `.ahk` file that runs on its own. |

## Quick start

**Make your mouse easy to follow in a recording**

1. Open the **Highlight** tab, press **Start highlight**, and move the mouse around.
2. Adjust the ring size and colours until you like it, then press **Stop**.
3. Go to **Export**, tick *Include the mouse highlight*, give it a name and press
   **Generate script**. Run that file whenever you record.

**Zoom in on something mid-recording**

1. On the **Magnifier** tab, press **Start magnifier**. A lens follows your mouse.
2. Hold **Ctrl** and roll the wheel to zoom in and out, or **Ctrl+Shift** and roll to
   make the lens itself bigger and smaller.
3. By default the lens is *hidden* from recordings — only you see it. To record the lens
   itself, set **In recordings** to *Visible*, and set **Lens sits** to *Offset from the
   cursor* or *In a screen corner* so it is not sitting on top of what it is magnifying.

**Give yourself a big obvious pointer**

1. On the **Cursor** tab pick a design and a colour; the preview updates as you go.
2. **Use this pointer** makes it your real mouse pointer. The same button turns it back
   off, and so does closing the window — you can't get stuck with a pointer you hate.
3. Leave it on and keep tweaking: the design changes land on your real pointer as you go.

Your settings are remembered on their own in `CursorMarker.ini`. **Save preset** keeps a
whole named setup in `Presets\`, so you can switch between looks.

## Folder layout

```text
CursorMarker.ahk          the studio — run this
Engine\MarkerCommon.ahk   settings store (INI) + colour helpers
Engine\LoupeEngine.ahk   the magnifier          (standalone, no dependencies)
Engine\HighlightEngine.ahk  halo + click ripples (standalone, no dependencies)
Engine\CursorPainter.ahk GDI+ drawing, .cur writer, system-cursor swap
Engine\MarkerIcon.ahk     builds CursorMarker.ico from Icons\Cursor.png
Icons\Cursor.png         the app artwork (256x256 PNG)
Engine\ScriptExporter.ahk generates the standalone scripts
CursorMarker.ico          the app icon, generated on first run
Export\                  generated .ahk and .cur files land here
Presets\                 named .ini presets
```

Paths are resolved from the studio's own folder, not `A_ScriptDir`, so it keeps its
settings, presets and exports together wherever you put it.

The three engine classes are deliberately dependency-free, which is what lets the
exporter inline one into a generated script with nothing else attached.

## How the magnifier works

Every frame it `StretchBlt`s the patch of desktop under the cursor into an offscreen
DC, paints the border, and pushes the result out through `UpdateLayeredWindow` on a
click-through layered window.

It is **pure GDI — no `magnification.dll`**. That matters: the Magnification API
attaches a colour transform to the desktop that survives a hard kill, and this one
cannot leave anything behind.

**The wheel.** While the lens is on screen:

| Gesture | Effect |
| --- | --- |
| `Ctrl` + wheel | Zoom, by the **Zoom per notch** setting (0.1x–2.0x), clamped to 1.1x–12x |
| `Ctrl`+`Shift` + wheel | Resize the lens, 20 px per notch, clamped to 80–600 px |

Resizing rebuilds the bitmap and the window region in place rather than restarting the
overlay, which keeps it steady under a rolling wheel. Both bindings are claimed in
`LoupeEngine.Start` and released in `Stop`, so ordinary Ctrl+Wheel zooming in whatever is
underneath comes straight back the moment the lens is dismissed. They work in the studio
and in exported scripts alike, and the **Mouse wheel controls the lens** checkbox turns
them off if you would rather keep the wheel to yourself.

Because the wheel moves size and zoom behind the studio's back, the studio re-reads both
from the engine four times a second while the lens is up, so the sliders never push a
stale value back onto it.

**Whether the lens shows up in a recording.** `In recordings -> Hidden` sets
`WDA_EXCLUDEFROMCAPTURE`, which keeps the lens out of recording software *and* out of the
frame it is reading — that second part is what stops it magnifying its own picture. Set
it to `Visible` to record the lens itself, and then move it off the pointer with `Offset`
or a corner, or it reads its own output.

## How the cursor designer works

The design is rendered by GDI+ into a straight 32-bit ARGB buffer, which is already the
pixel layout a `.cur` file's XOR bitmap wants — saving is a row flip plus a header.
A `.cur` is an `.ico` with `idType 2`, where each directory entry's planes/bit-count
slots carry the hotspot instead.

**Applying to the system is reversible.** `SetSystemCursor` changes the pointer for the
whole session, so:

- **Use this pointer** is a toggle — the same button that switched it on switches it
  off, so the way back is never somewhere else. The tray menu has a restore item too.
- Closing CursorMarker restores it automatically.
- Exported scripts restore on exit **and** bind `Ctrl+Alt+F12` as a manual undo in case
  the script is ever killed abruptly.

All of these call `SystemParametersInfo(SPI_SETCURSORS)`, which reloads every pointer
from your own scheme in the registry.

## Exported scripts

`Generate script` writes `Export\<name>.ahk`. It contains a settings block, your
hotkeys, and the engine classes inlined — no `#Include`, nothing to copy beside it
except the `.cur` when the cursor swap is switched on.

```ahk
; Loupe settings
LoupeEngine.LensSize := 180
LoupeEngine.Zoom := 2.5
LoupeEngine.WheelZoom := true
LoupeEngine.ZoomStep := 0.5
...
F9::LoupeEngine.Toggle()
^NumpadAdd::LoupeEngine.ZoomBy(0.5)
```

The keyboard hotkeys configured in the studio apply to the **exported** script, not to
the studio window — the studio uses its own Start/Stop buttons so it never fights a
running export for a key. The wheel gestures are the exception: they belong to the
engine, so they work wherever the lens is running.

## The app icon

`Icons\Cursor.png` — a rounded plate with a pointer on it — scaled into `CursorMarker.ico`
as a real multi-size icon (16/20/24/32/48/64 px) and used for the tray, the taskbar
button and Alt+Tab. Because it is a genuine `.ico` on disk you can point a shortcut at it
too.

**To change the icon, replace `Icons\Cursor.png`.** The `.ico` is rebuilt whenever it is
missing or older than the artwork, so the next launch picks the new one up on its own.

Scaling uses `CompositingModeSourceCopy` with high-quality bicubic interpolation, so the
artwork's own alpha lands in the icon rather than being composited onto black — which is
what keeps the rounded corners clean all the way down to 16 px.

If the artwork is missing entirely, `MarkerIcon` falls back to drawing one (a rounded
plate carrying `CursorPainter`'s arrow outline), so the app never silently inherits the
default AutoHotkey icon.

## Notes and limits

- Click ripples are drawn on a surface pinned to the pointer, so flinging the mouse
  across the screen mid-ripple clips the tail.
- The lens follows the cursor in physical pixels (`-DPIScale`); it is DPI-correct on a
  scaled display because it never mixes logical and physical coordinates.
- Repeated start/stop cycles were measured at **zero** GDI and USER handle growth.

## Credits

- The loupe's `StretchBlt` + `UpdateLayeredWindow` approach comes from **RockssJoke**'s
  magnifier on the AutoHotkey forums, packaged as a class by **The-CoDingman** as
  [The-Loupe](https://github.com/The-CoDingman/The-Loupe) (MIT). This version adds
  shapes, follow modes, capture visibility, a crosshair and runtime zoom, and releases
  the pens and bitmaps the original leaked on each restart.
- The ring-and-ripple idea came from **mesutakcan**'s
  [OBS-Cursor-Tools](https://github.com/mesutakcan/OBS-Cursor-Tools) (GPL-3.0).
  No code was taken from it — `HighlightEngine.ahk` is an independent implementation,
  so nothing here inherits that project's licence.
