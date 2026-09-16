#Requires AutoHotkey v2.1-alpha.30

; HighlightEngine — a cursor spotlight for screen recordings: a soft ring (with
; optional inner fill) pinned to the pointer, plus expanding ripples on each mouse
; click, colour-coded per button.
;
; The overlay is a layered, click-through window carrying real per-pixel alpha:
; a top-down 32-bit DIB section that GDI+ draws into directly (PixelFormat
; 32bppPARGB), pushed out with UpdateLayeredWindow + AC_SRC_ALPHA. Unlike the
; loupe it never reads the screen, so it is safe to leave visible to a recording —
; that is the whole point of it.
;
; The surface is sized once, around the cursor. A ripple whose click point drifts
; further than half that surface away gets clipped, which in practice only shows
; up if you fling the pointer across the screen mid-ripple.
;
; Standalone: this file needs nothing else. Set the statics, call Start().

class HighlightEngine {
    static RingRadius := 28
    static RingWidth := 4
    static RingColor := 0xF59E42            ; RGB
    static RingAlpha := 85                  ; percent
    static ShowFill := false
    static FillColor := 0xF59E42
    static FillAlpha := 25
    static Ripple := true
    static RippleMax := 60
    static RippleMs := 420
    static ColorL := 0x7BC96F
    static ColorM := 0x22D3EE
    static ColorR := 0xDC3545
    static Interval := 16

    static gui := 0
    static token := 0
    static hMemDC := 0
    static hBitmap := 0
    static hOldBmp := 0
    static pBitmap := 0
    static pGraphics := 0
    static side := 0
    static tick := 0
    static hooks := Map()
    static drops := []

    static pos := Buffer(8, 0)
    static dim := Buffer(8, 0)
    static zero := Buffer(8, 0)
    static blend := Buffer(4, 0)

    static Active => HighlightEngine.gui != 0

    static Toggle() {
        if HighlightEngine.gui
            HighlightEngine.Stop()
        else
            HighlightEngine.Start()
    }

    static Start() {
        if HighlightEngine.gui
            HighlightEngine.Stop()

        HighlightEngine.GdipStart()
        reach := Max(HighlightEngine.RingRadius + HighlightEngine.RingWidth
                   , HighlightEngine.Ripple ? HighlightEngine.RippleMax : 0)
        HighlightEngine.side := 2 * (reach + 8)
        HighlightEngine.drops := []

        g := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x20 +E0x80000")
        HighlightEngine.gui := g
        g.Show("NA x0 y0 w0 h0")

        HighlightEngine.OpenSurface()
        NumPut("UInt", 0x01FF0000, HighlightEngine.blend, 0)   ; AC_SRC_OVER | AC_SRC_ALPHA, alpha 255
        NumPut("Int", HighlightEngine.side, "Int", HighlightEngine.side, HighlightEngine.dim)

        if HighlightEngine.Ripple
            HighlightEngine.HookClicks(true)

        HighlightEngine.tick := ObjBindMethod(HighlightEngine, "Update")
        SetTimer(HighlightEngine.tick, HighlightEngine.Interval)
        HighlightEngine.Update()
    }

    static Stop() {
        if !HighlightEngine.gui
            return
        if HighlightEngine.tick
            SetTimer(HighlightEngine.tick, 0)
        HighlightEngine.tick := 0
        HighlightEngine.HookClicks(false)
        HighlightEngine.CloseSurface()
        HighlightEngine.gui.Destroy()
        HighlightEngine.gui := 0
        HighlightEngine.drops := []
    }

    static Refresh() {
        if HighlightEngine.gui
            HighlightEngine.Start()
    }

    static HookClicks(on) {
        static buttons := ["LButton", "MButton", "RButton"]
        for name in buttons {
            if on {
                if !HighlightEngine.hooks.Has(name)
                    HighlightEngine.hooks[name] := ObjBindMethod(HighlightEngine, "OnClick", name)
                Hotkey("~" name, HighlightEngine.hooks[name], "On")
            } else if HighlightEngine.hooks.Has(name) {
                try Hotkey("~" name, HighlightEngine.hooks[name], "Off")
                catch Error as err
                    OutputDebug("HighlightEngine: could not release ~" name " — " err.Message)
            }
        }
    }

    static OnClick(button, *) {
        if !HighlightEngine.gui
            return
        CoordMode("Mouse", "Screen")
        MouseGetPos(&mx, &my)
        drop := Map()
        drop["X"] := mx
        drop["Y"] := my
        drop["T0"] := A_TickCount
        switch button {
            case "MButton": drop["Color"] := HighlightEngine.ColorM
            case "RButton": drop["Color"] := HighlightEngine.ColorR
            default:        drop["Color"] := HighlightEngine.ColorL
        }
        HighlightEngine.drops.Push(drop)
    }

    static Update() {
        if !HighlightEngine.gui {
            if HighlightEngine.tick
                SetTimer(HighlightEngine.tick, 0)
            return
        }

        CoordMode("Mouse", "Screen")
        MouseGetPos(&mx, &my)
        edge := HighlightEngine.side
        originX := mx - (edge // 2)
        originY := my - (edge // 2)
        centre := edge / 2

        gfx := HighlightEngine.pGraphics
        DllCall("gdiplus\GdipGraphicsClear", "Ptr", gfx, "UInt", 0x00000000)

        if HighlightEngine.ShowFill {
            r := HighlightEngine.RingRadius
            brush := HighlightEngine.SolidBrush(HighlightEngine.FillColor, HighlightEngine.FillAlpha)
            DllCall("gdiplus\GdipFillEllipse", "Ptr", gfx, "Ptr", brush
                  , "Float", centre - r, "Float", centre - r, "Float", r * 2, "Float", r * 2)
            DllCall("gdiplus\GdipDeleteBrush", "Ptr", brush)
        }

        if (HighlightEngine.RingWidth > 0) {
            r := HighlightEngine.RingRadius
            pen := HighlightEngine.Pen(HighlightEngine.RingColor, HighlightEngine.RingAlpha, HighlightEngine.RingWidth)
            DllCall("gdiplus\GdipDrawEllipse", "Ptr", gfx, "Ptr", pen
                  , "Float", centre - r, "Float", centre - r, "Float", r * 2, "Float", r * 2)
            DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
        }

        HighlightEngine.PaintDrops(gfx, originX, originY)
        DllCall("gdiplus\GdipFlush", "Ptr", gfx, "Int", 1)

        NumPut("Int", originX, "Int", originY, HighlightEngine.pos)
        DllCall("User32\UpdateLayeredWindow", "Ptr", HighlightEngine.gui.Hwnd, "Ptr", 0
              , "Ptr", HighlightEngine.pos, "Ptr", HighlightEngine.dim, "Ptr", HighlightEngine.hMemDC
              , "Ptr", HighlightEngine.zero, "UInt", 0, "Ptr", HighlightEngine.blend, "UInt", 2)
    }

    static PaintDrops(gfx, originX, originY) {
        if !HighlightEngine.drops.Length
            return
        now := A_TickCount
        span := Max(60, HighlightEngine.RippleMs)
        alive := []
        for drop in HighlightEngine.drops {
            p := (now - drop["T0"]) / span
            if (p >= 1)
                continue
            alive.Push(drop)
            ; Ease-out so the ring leaps away from the click and then settles.
            r := HighlightEngine.RippleMax * (1 - (1 - p) ** 2)
            fade := Round(HighlightEngine.RingAlpha * (1 - p))
            if (fade < 2 || r < 1)
                continue
            width := Max(1.0, HighlightEngine.RingWidth * (1 - p) + 1)
            pen := HighlightEngine.Pen(drop["Color"], fade, width)
            cx := drop["X"] - originX
            cy := drop["Y"] - originY
            DllCall("gdiplus\GdipDrawEllipse", "Ptr", gfx, "Ptr", pen
                  , "Float", cx - r, "Float", cy - r, "Float", r * 2, "Float", r * 2)
            DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
        }
        HighlightEngine.drops := alive
    }

    static SolidBrush(rgb, percent) {
        DllCall("gdiplus\GdipCreateSolidFill", "UInt", HighlightEngine.Argb(rgb, percent), "Ptr*", &brush := 0)
        return brush
    }

    static Pen(rgb, percent, width) {
        DllCall("gdiplus\GdipCreatePen1", "UInt", HighlightEngine.Argb(rgb, percent)
              , "Float", width, "Int", 2, "Ptr*", &pen := 0)          ; UnitPixel
        return pen
    }

    static Argb(rgb, percent) => ((Round(percent * 255 / 100) & 0xFF) << 24) | (rgb & 0xFFFFFF)

    static GdipStart() {
        if HighlightEngine.token
            return
        if !DllCall("GetModuleHandleW", "Str", "gdiplus", "Ptr")
            DllCall("LoadLibraryW", "Str", "gdiplus.dll", "Ptr")
        input := Buffer(24, 0)
        NumPut("UInt", 1, input, 0)
        if DllCall("gdiplus\GdiplusStartup", "Ptr*", &token := 0, "Ptr", input, "Ptr", 0, "UInt")
            throw OSError("GdiplusStartup failed — the highlight overlay cannot draw.", -1)
        HighlightEngine.token := token
    }

    ; A top-down 32bpp DIB section is the one surface both GDI+ and
    ; UpdateLayeredWindow can share without an intermediate copy per frame.
    static OpenSurface() {
        edge := HighlightEngine.side
        header := Buffer(40, 0)
        NumPut("UInt", 40, header, 0)
        NumPut("Int", edge, header, 4)
        NumPut("Int", -edge, header, 8)
        NumPut("UShort", 1, header, 12)
        NumPut("UShort", 32, header, 14)
        NumPut("UInt", 0, header, 16)                              ; BI_RGB

        screen := DllCall("User32\GetDC", "Ptr", 0, "Ptr")
        HighlightEngine.hMemDC := DllCall("Gdi32\CreateCompatibleDC", "Ptr", screen, "Ptr")
        DllCall("User32\ReleaseDC", "Ptr", 0, "Ptr", screen)

        HighlightEngine.hBitmap := DllCall("Gdi32\CreateDIBSection", "Ptr", HighlightEngine.hMemDC
                                         , "Ptr", header, "UInt", 0, "Ptr*", &bits := 0
                                         , "Ptr", 0, "UInt", 0, "Ptr")
        if !HighlightEngine.hBitmap
            throw OSError("CreateDIBSection failed for the highlight overlay.", -1)
        HighlightEngine.hOldBmp := DllCall("Gdi32\SelectObject", "Ptr", HighlightEngine.hMemDC
                                         , "Ptr", HighlightEngine.hBitmap, "Ptr")

        if DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", edge, "Int", edge, "Int", edge * 4
                 , "Int", 0x000E200B, "Ptr", bits, "Ptr*", &pBitmap := 0, "UInt")   ; 32bppPARGB
            throw OSError("GdipCreateBitmapFromScan0 failed for the highlight overlay.", -1)
        HighlightEngine.pBitmap := pBitmap
        DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pBitmap, "Ptr*", &gfx := 0)
        HighlightEngine.pGraphics := gfx
        DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", gfx, "Int", 4)               ; AntiAlias
    }

    static CloseSurface() {
        if HighlightEngine.pGraphics
            DllCall("gdiplus\GdipDeleteGraphics", "Ptr", HighlightEngine.pGraphics)
        if HighlightEngine.pBitmap
            DllCall("gdiplus\GdipDisposeImage", "Ptr", HighlightEngine.pBitmap)
        if HighlightEngine.hMemDC {
            if HighlightEngine.hOldBmp
                DllCall("Gdi32\SelectObject", "Ptr", HighlightEngine.hMemDC, "Ptr", HighlightEngine.hOldBmp, "Ptr")
            DllCall("Gdi32\DeleteDC", "Ptr", HighlightEngine.hMemDC)
        }
        if HighlightEngine.hBitmap
            DllCall("Gdi32\DeleteObject", "Ptr", HighlightEngine.hBitmap)
        HighlightEngine.pGraphics := HighlightEngine.pBitmap := 0
        HighlightEngine.hMemDC := HighlightEngine.hBitmap := HighlightEngine.hOldBmp := 0
    }
}
