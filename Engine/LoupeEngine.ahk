#Requires AutoHotkey v2.1-alpha.30

; LoupeEngine — a screen magnifier drawn as a layered, click-through window.
; Every frame it StretchBlt's a patch of the desktop under the cursor into an
; offscreen DC, paints a shaped border (and optional crosshair) over it, and
; pushes the result through UpdateLayeredWindow.
;
; Pure GDI on purpose: no magnification.dll, so an abnormal exit can never leave
; a colour transform attached to the desktop.
;
; Lineage: the StretchBlt + UpdateLayeredWindow approach comes from RockssJoke's
; AHK forum magnifier, packaged as a class by The-CoDingman ("The Loupe", MIT).
; This version adds shapes, follow modes, capture visibility, a crosshair and
; runtime zoom, and releases the pens/bitmaps the original leaked per restart.
;
; Standalone: this file needs nothing else. Set the statics, call Start().

class LoupeEngine {
    static LensSize := 180                  ; lens edge in physical pixels
    static Zoom := 2.5                      ; magnification factor
    static BorderWidth := 3
    static BorderColor := 0x5B9FEF          ; RGB, not BGR
    static Interval := 16                   ; frame period in ms
    static Shape := "Circle"                ; Circle | Square | Rounded
    static Follow := "Cursor"               ; Cursor | Offset | Corner
    static OffsetX := 0
    static OffsetY := 0
    static Corner := "Top-right"            ; Top-left | Top-right | Bottom-left | Bottom-right
    static HideFromCapture := true          ; WDA_EXCLUDEFROMCAPTURE
    static Crosshair := false
    static Smooth := true                   ; HALFTONE vs COLORONCOLOR stretching
    static WheelZoom := true                ; Ctrl+Wheel zooms, Ctrl+Shift+Wheel resizes
    static ZoomStep := 0.5                  ; magnification added per wheel notch
    static SizeStep := 20                   ; lens pixels added per wheel notch
    static MinZoom := 1.1
    static MaxZoom := 12.0
    static MinSize := 80
    static MaxSize := 600

    static gui := 0
    static hScreenDC := 0
    static hMemDC := 0
    static hBitmap := 0
    static hOldBmp := 0
    static hOldPen := 0
    static hOldBrush := 0
    static hPen := 0
    static hCrossPen := 0
    static tick := 0
    static wheelHooks := Map()

    static pos := Buffer(8, 0)              ; POINT — window top-left
    static dim := Buffer(8, 0)              ; SIZE  — lens edge
    static zero := Buffer(8, 0)             ; POINT — source origin, always 0,0
    static blend := Buffer(4, 0)            ; BLENDFUNCTION

    static Active => LoupeEngine.gui != 0

    static Toggle() {
        if LoupeEngine.gui
            LoupeEngine.Stop()
        else
            LoupeEngine.Start()
    }

    static Start() {
        if LoupeEngine.gui
            LoupeEngine.Stop()

        ; WS_EX_TRANSPARENT (0x20) lets clicks fall through to whatever is below;
        ; WS_EX_LAYERED (0x80000) is what UpdateLayeredWindow requires.
        g := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x20 +E0x80000")
        LoupeEngine.gui := g

        affinity := LoupeEngine.HideFromCapture ? 0x11 : 0x00   ; WDA_EXCLUDEFROMCAPTURE : WDA_NONE
        if !DllCall("User32\SetWindowDisplayAffinity", "Ptr", g.Hwnd, "UInt", affinity, "Int") {
            if LoupeEngine.HideFromCapture {
                g.Destroy()
                LoupeEngine.gui := 0
                throw OSError("SetWindowDisplayAffinity failed; without it the lens magnifies itself.", -1)
            }
        }

        g.Show("NA x0 y0 w0 h0")
        DllCall("User32\SetWindowRgn", "Ptr", g.Hwnd, "Ptr", LoupeEngine.MakeRegion(), "Int", 1)

        LoupeEngine.OpenSurfaces()
        NumPut("UInt", 0x00FF0000, LoupeEngine.blend, 0)   ; AC_SRC_OVER, alpha 255, no per-pixel alpha
        NumPut("Int", LoupeEngine.LensSize, "Int", LoupeEngine.LensSize, LoupeEngine.dim)

        LoupeEngine.HookWheel(true)
        LoupeEngine.tick := ObjBindMethod(LoupeEngine, "Update")
        SetTimer(LoupeEngine.tick, LoupeEngine.Interval)
        LoupeEngine.Update()
    }

    static Stop() {
        if !LoupeEngine.gui
            return
        if LoupeEngine.tick
            SetTimer(LoupeEngine.tick, 0)
        LoupeEngine.tick := 0
        LoupeEngine.HookWheel(false)
        LoupeEngine.CloseSurfaces()
        LoupeEngine.gui.Destroy()
        LoupeEngine.gui := 0
    }

    ; Restart in place so structural changes (size, shape, capture affinity) take
    ; effect without the caller tracking whether the lens was up.
    static Refresh() {
        if LoupeEngine.gui
            LoupeEngine.Start()
    }

    static SetZoom(factor) {
        LoupeEngine.Zoom := Round(Min(LoupeEngine.MaxZoom, Max(LoupeEngine.MinZoom, factor)), 1)
        return LoupeEngine.Zoom
    }

    static ZoomBy(delta) => LoupeEngine.SetZoom(LoupeEngine.Zoom + delta)

    ; Growing the lens means a bigger bitmap and a new window region, so the
    ; surfaces are rebuilt in place — cheaper and steadier than restarting the
    ; whole overlay under someone's wheel finger.
    static SetSize(px) {
        px := Round(Min(LoupeEngine.MaxSize, Max(LoupeEngine.MinSize, px)))
        if (px = LoupeEngine.LensSize)
            return LoupeEngine.LensSize
        LoupeEngine.LensSize := px
        if LoupeEngine.gui {
            LoupeEngine.CloseSurfaces()
            LoupeEngine.OpenSurfaces()
            ; SetWindowRgn takes ownership of the new region and frees the old one.
            DllCall("User32\SetWindowRgn", "Ptr", LoupeEngine.gui.Hwnd
                  , "Ptr", LoupeEngine.MakeRegion(), "Int", 1)
            NumPut("Int", px, "Int", px, LoupeEngine.dim)
            LoupeEngine.Update()
        }
        return LoupeEngine.LensSize
    }

    static SizeBy(delta) => LoupeEngine.SetSize(LoupeEngine.LensSize + delta)

    ; The wheel is claimed only for as long as the lens is on screen. Binding it
    ; permanently would swallow Ctrl+Wheel zooming in whatever is underneath, so
    ; Start hooks it and Stop hands it straight back.
    static HookWheel(on) {
        binds := Map()
        binds["^WheelUp"] := ["Zoom", 1]
        binds["^WheelDown"] := ["Zoom", -1]
        binds["^+WheelUp"] := ["Size", 1]
        binds["^+WheelDown"] := ["Size", -1]
        for combo, spec in binds {
            if !LoupeEngine.wheelHooks.Has(combo)
                LoupeEngine.wheelHooks[combo] := ObjBindMethod(LoupeEngine, "OnWheel", spec[1], spec[2])
            try
                Hotkey(combo, LoupeEngine.wheelHooks[combo], (on && LoupeEngine.WheelZoom) ? "On" : "Off")
            catch Error as err
                OutputDebug("LoupeEngine: " combo " could not be bound — " err.Message)
        }
    }

    static OnWheel(kind, sign, *) {
        if !LoupeEngine.gui
            return
        if (kind = "Size") {
            LoupeEngine.SizeBy(sign * LoupeEngine.SizeStep)
            return                      ; SetSize redraws once the surfaces are back
        }
        LoupeEngine.ZoomBy(sign * LoupeEngine.ZoomStep)
        ; Redraw now rather than waiting on the timer, so a long Interval still
        ; feels immediate under the wheel.
        LoupeEngine.Update()
    }

    static Update() {
        if !LoupeEngine.gui {
            if LoupeEngine.tick
                SetTimer(LoupeEngine.tick, 0)
            return
        }

        CoordMode("Mouse", "Screen")
        MouseGetPos(&mx, &my)

        edge := LoupeEngine.LensSize
        src := Max(4, Round(edge / LoupeEngine.Zoom))
        sx := mx - (src // 2)
        sy := my - (src // 2)
        LoupeEngine.LensOrigin(mx, my, edge, &wx, &wy)
        NumPut("Int", wx, "Int", wy, LoupeEngine.pos)

        DllCall("Gdi32\StretchBlt", "Ptr", LoupeEngine.hMemDC, "Int", 0, "Int", 0, "Int", edge, "Int", edge
              , "Ptr", LoupeEngine.hScreenDC, "Int", sx, "Int", sy, "Int", src, "Int", src, "UInt", 0x00CC0020)
        LoupeEngine.PaintChrome(edge)

        DllCall("User32\UpdateLayeredWindow", "Ptr", LoupeEngine.gui.Hwnd, "Ptr", 0
              , "Ptr", LoupeEngine.pos, "Ptr", LoupeEngine.dim, "Ptr", LoupeEngine.hMemDC
              , "Ptr", LoupeEngine.zero, "UInt", 0, "Ptr", LoupeEngine.blend, "UInt", 2)
    }

    static LensOrigin(mx, my, edge, &wx, &wy) {
        switch LoupeEngine.Follow {
            case "Offset":
                wx := mx - (edge // 2) + LoupeEngine.OffsetX
                wy := my - (edge // 2) + LoupeEngine.OffsetY
            case "Corner":
                pad := 24
                switch LoupeEngine.Corner {
                    case "Top-left":
                        wx := pad
                        wy := pad
                    case "Bottom-left":
                        wx := pad
                        wy := A_ScreenHeight - edge - pad
                    case "Bottom-right":
                        wx := A_ScreenWidth - edge - pad
                        wy := A_ScreenHeight - edge - pad
                    default:
                        wx := A_ScreenWidth - edge - pad
                        wy := pad
                }
            default:
                wx := mx - (edge // 2)
                wy := my - (edge // 2)
        }
    }

    static PaintChrome(edge) {
        bw := LoupeEngine.BorderWidth
        if (bw > 0) {
            half := bw // 2
            switch LoupeEngine.Shape {
                case "Square":
                    DllCall("Gdi32\Rectangle", "Ptr", LoupeEngine.hMemDC
                          , "Int", half, "Int", half, "Int", edge - half, "Int", edge - half)
                case "Rounded":
                    r := Max(8, edge // 6)
                    DllCall("Gdi32\RoundRect", "Ptr", LoupeEngine.hMemDC
                          , "Int", half, "Int", half, "Int", edge - half, "Int", edge - half, "Int", r, "Int", r)
                default:
                    DllCall("Gdi32\Ellipse", "Ptr", LoupeEngine.hMemDC
                          , "Int", half, "Int", half, "Int", edge - half, "Int", edge - half)
            }
        }

        if !LoupeEngine.Crosshair
            return
        c := edge // 2
        arm := Max(6, edge // 10)
        DllCall("Gdi32\SelectObject", "Ptr", LoupeEngine.hMemDC, "Ptr", LoupeEngine.hCrossPen, "Ptr")
        DllCall("Gdi32\MoveToEx", "Ptr", LoupeEngine.hMemDC, "Int", c - arm, "Int", c, "Ptr", 0)
        DllCall("Gdi32\LineTo", "Ptr", LoupeEngine.hMemDC, "Int", c + arm, "Int", c)
        DllCall("Gdi32\MoveToEx", "Ptr", LoupeEngine.hMemDC, "Int", c, "Int", c - arm, "Ptr", 0)
        DllCall("Gdi32\LineTo", "Ptr", LoupeEngine.hMemDC, "Int", c, "Int", c + arm)
        DllCall("Gdi32\SelectObject", "Ptr", LoupeEngine.hMemDC, "Ptr", LoupeEngine.hPen, "Ptr")
    }

    ; The region is handed to SetWindowRgn, which takes ownership — never delete it.
    static MakeRegion() {
        edge := LoupeEngine.LensSize
        switch LoupeEngine.Shape {
            case "Square":
                return DllCall("Gdi32\CreateRectRgn", "Int", 0, "Int", 0, "Int", edge, "Int", edge, "Ptr")
            case "Rounded":
                r := Max(8, edge // 6)
                return DllCall("Gdi32\CreateRoundRectRgn", "Int", 0, "Int", 0
                             , "Int", edge + 1, "Int", edge + 1, "Int", r, "Int", r, "Ptr")
            default:
                return DllCall("Gdi32\CreateEllipticRgn", "Int", 0, "Int", 0, "Int", edge, "Int", edge, "Ptr")
        }
    }

    static OpenSurfaces() {
        edge := LoupeEngine.LensSize
        bgr := LoupeEngine.Bgr(LoupeEngine.BorderColor)

        LoupeEngine.hScreenDC := DllCall("User32\GetDC", "Ptr", 0, "Ptr")
        LoupeEngine.hMemDC := DllCall("Gdi32\CreateCompatibleDC", "Ptr", LoupeEngine.hScreenDC, "Ptr")
        LoupeEngine.hBitmap := DllCall("Gdi32\CreateCompatibleBitmap", "Ptr", LoupeEngine.hScreenDC
                                     , "Int", edge, "Int", edge, "Ptr")
        LoupeEngine.hOldBmp := DllCall("Gdi32\SelectObject", "Ptr", LoupeEngine.hMemDC
                                     , "Ptr", LoupeEngine.hBitmap, "Ptr")

        LoupeEngine.hPen := DllCall("Gdi32\CreatePen", "Int", 0, "Int", Max(1, LoupeEngine.BorderWidth)
                                  , "UInt", bgr, "Ptr")
        LoupeEngine.hCrossPen := DllCall("Gdi32\CreatePen", "Int", 0, "Int", 1, "UInt", bgr, "Ptr")
        LoupeEngine.hOldPen := DllCall("Gdi32\SelectObject", "Ptr", LoupeEngine.hMemDC
                                     , "Ptr", LoupeEngine.hPen, "Ptr")
        ; NULL_BRUSH keeps Ellipse/Rectangle to an outline instead of flooding the lens.
        LoupeEngine.hOldBrush := DllCall("Gdi32\SelectObject", "Ptr", LoupeEngine.hMemDC
                                       , "Ptr", DllCall("Gdi32\GetStockObject", "Int", 5, "Ptr"), "Ptr")

        DllCall("Gdi32\SetStretchBltMode", "Ptr", LoupeEngine.hMemDC, "Int", LoupeEngine.Smooth ? 4 : 3)
        if LoupeEngine.Smooth
            DllCall("Gdi32\SetBrushOrgEx", "Ptr", LoupeEngine.hMemDC, "Int", 0, "Int", 0, "Ptr", 0)
    }

    static CloseSurfaces() {
        if LoupeEngine.hMemDC {
            if LoupeEngine.hOldBrush
                DllCall("Gdi32\SelectObject", "Ptr", LoupeEngine.hMemDC, "Ptr", LoupeEngine.hOldBrush, "Ptr")
            if LoupeEngine.hOldPen
                DllCall("Gdi32\SelectObject", "Ptr", LoupeEngine.hMemDC, "Ptr", LoupeEngine.hOldPen, "Ptr")
            if LoupeEngine.hOldBmp
                DllCall("Gdi32\SelectObject", "Ptr", LoupeEngine.hMemDC, "Ptr", LoupeEngine.hOldBmp, "Ptr")
            DllCall("Gdi32\DeleteDC", "Ptr", LoupeEngine.hMemDC)
        }
        for handle in [LoupeEngine.hBitmap, LoupeEngine.hPen, LoupeEngine.hCrossPen] {
            if handle
                DllCall("Gdi32\DeleteObject", "Ptr", handle)
        }
        if LoupeEngine.hScreenDC
            DllCall("User32\ReleaseDC", "Ptr", 0, "Ptr", LoupeEngine.hScreenDC)

        LoupeEngine.hScreenDC := LoupeEngine.hMemDC := LoupeEngine.hBitmap := 0
        LoupeEngine.hOldBmp := LoupeEngine.hOldPen := LoupeEngine.hOldBrush := 0
        LoupeEngine.hPen := LoupeEngine.hCrossPen := 0
    }

    static Bgr(rgb) => ((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF)
}
