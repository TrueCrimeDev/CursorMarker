#Requires AutoHotkey v2.1-alpha.30

; MarkerIcon — the app's icon: Icons\Cursor.png, scaled into a real multi-size
; .ico that serves the tray, both window icon slots (taskbar and Alt+Tab), and
; any shortcut you make by hand.
;
; The .ico is rebuilt whenever it is missing or older than the artwork, so
; replacing Icons\Cursor.png is all it takes to change the app icon.
;
; If the artwork is missing entirely it falls back to drawing one — a rounded
; plate with CursorPainter's own arrow outline on it — so the app always has an
; icon rather than inheriting the default AutoHotkey one.

class MarkerIcon {
    static Plate := 0x5B9FEF                ; Ocean Blue, the studio's accent
    static Rim := 0x1E4F8F                  ; darker edge so it reads on a pale taskbar
    static Glyph := 0xFFFFFF
    static GlyphEdge := 0x0F2A4A
    static Sizes := [16, 20, 24, 32, 48, 64]

    static hSmall := 0
    static hBig := 0
    static source := 0

    ; Engine\MarkerIcon.ahk -> the studio folder that owns Icons\. A compiled
    ; build has no source path to walk up from, so the app sets Root instead.
    static Root := ""
    static Home => MarkerIcon.Root != "" ? MarkerIcon.Root
                                         : RegExReplace(A_LineFile, "\\[^\\]+\\[^\\]+$")
    static SourcePath => MarkerIcon.Home "\Icons\Cursor.png"

    static Apply(hwnd, path) {
        if MarkerIcon.Stale(path)
            MarkerIcon.SaveIco(path)
        TraySetIcon(path)
        MarkerIcon.Release()
        MarkerIcon.hSmall := MarkerIcon.LoadSize(path, 16)
        MarkerIcon.hBig := MarkerIcon.LoadSize(path, 32)
        ; WM_SETICON: ICON_SMALL drives the title bar and Alt+Tab, ICON_BIG the
        ; taskbar button. The window does not take ownership of either handle.
        if MarkerIcon.hSmall
            DllCall("User32\SendMessageW", "Ptr", hwnd, "UInt", 0x80, "Ptr", 0, "Ptr", MarkerIcon.hSmall)
        if MarkerIcon.hBig
            DllCall("User32\SendMessageW", "Ptr", hwnd, "UInt", 0x80, "Ptr", 1, "Ptr", MarkerIcon.hBig)
        return path
    }

    static LoadSize(path, px) => DllCall("User32\LoadImageW", "Ptr", 0, "Str", path
                                       , "UInt", 1, "Int", px, "Int", px, "UInt", 0x10, "Ptr")

    ; Rebuild when the .ico is missing or older than the artwork it came from.
    static Stale(path) {
        if !FileExist(path)
            return true
        art := MarkerIcon.SourcePath
        if !FileExist(art)
            return false
        return DateDiff(FileGetTime(art, "M"), FileGetTime(path, "M"), "Seconds") > 0
    }

    ; The artwork is decoded once per .ico build, not once per size.
    static OpenSource() {
        MarkerIcon.CloseSource()
        art := MarkerIcon.SourcePath
        if !FileExist(art)
            return false
        if DllCall("gdiplus\GdipCreateBitmapFromFile", "Str", art, "Ptr*", &image := 0, "UInt")
            return false
        MarkerIcon.source := image
        return true
    }

    static CloseSource() {
        if MarkerIcon.source
            DllCall("gdiplus\GdipDisposeImage", "Ptr", MarkerIcon.source)
        MarkerIcon.source := 0
    }

    ; SourceCopy rather than SourceOver: the artwork's own alpha is what the icon
    ; needs, not the artwork composited onto transparent black.
    static Paint(gfx, box) {
        if !MarkerIcon.source
            return false
        DllCall("gdiplus\GdipSetCompositingMode", "Ptr", gfx, "Int", 1)
        DllCall("gdiplus\GdipSetInterpolationMode", "Ptr", gfx, "Int", 7)   ; HighQualityBicubic
        DllCall("gdiplus\GdipSetPixelOffsetMode", "Ptr", gfx, "Int", 2)     ; Half
        return !DllCall("gdiplus\GdipDrawImageRectI", "Ptr", gfx, "Ptr", MarkerIcon.source
                      , "Int", 0, "Int", 0, "Int", box, "Int", box, "UInt")
    }

    static Release() {
        for handle in [MarkerIcon.hSmall, MarkerIcon.hBig] {
            if handle
                DllCall("User32\DestroyIcon", "Ptr", handle)
        }
        MarkerIcon.hSmall := 0
        MarkerIcon.hBig := 0
    }

    ; An .ico is a .cur with idType 1, where the two hotspot slots go back to
    ; being planes and bit count. Several images just means several entries.
    static SaveIco(path, sizes := 0) {
        CursorPainter.Startup()
        MarkerIcon.OpenSource()
        try
            return MarkerIcon.WriteIco(path, sizes ? sizes : MarkerIcon.Sizes)
        finally
            MarkerIcon.CloseSource()
    }

    static WriteIco(path, list) {
        images := []
        total := 6 + 16 * list.Length
        for px in list {
            stride := px * 4
            maskBytes := ((px + 31) // 32) * 4 * px
            entry := Map()
            entry["Px"] := px
            entry["Pixels"] := MarkerIcon.RenderARGB(px)
            entry["Bytes"] := 40 + stride * px + maskBytes
            images.Push(entry)
            total += entry["Bytes"]
        }

        out := Buffer(total, 0)
        NumPut("UShort", 0, out, 0)
        NumPut("UShort", 1, out, 2)                    ; idType: 1 = icon
        NumPut("UShort", list.Length, out, 4)

        offset := 6 + 16 * list.Length
        for i, image in images {
            px := image["Px"]
            stride := px * 4
            maskBytes := ((px + 31) // 32) * 4 * px
            entryAt := 6 + (i - 1) * 16

            NumPut("UChar", px, out, entryAt + 0)
            NumPut("UChar", px, out, entryAt + 1)
            NumPut("UChar", 0, out, entryAt + 2)       ; colour count
            NumPut("UChar", 0, out, entryAt + 3)       ; reserved
            NumPut("UShort", 1, out, entryAt + 4)      ; planes
            NumPut("UShort", 32, out, entryAt + 6)     ; bit count
            NumPut("UInt", image["Bytes"], out, entryAt + 8)
            NumPut("UInt", offset, out, entryAt + 12)

            NumPut("UInt", 40, out, offset + 0)        ; BITMAPINFOHEADER
            NumPut("Int", px, out, offset + 4)
            NumPut("Int", px * 2, out, offset + 8)     ; XOR + AND stacked
            NumPut("UShort", 1, out, offset + 12)
            NumPut("UShort", 32, out, offset + 14)
            NumPut("UInt", 0, out, offset + 16)        ; BI_RGB
            NumPut("UInt", stride * px + maskBytes, out, offset + 20)

            ; DIB rows run bottom-up; the render is top-down.
            base := offset + 40
            pixels := image["Pixels"]
            loop px {
                src := (px - A_Index) * stride
                dst := base + (A_Index - 1) * stride
                DllCall("RtlMoveMemory", "Ptr", out.Ptr + dst, "Ptr", pixels.Ptr + src, "Ptr", stride)
            }
            offset += image["Bytes"]
        }

        file := FileOpen(path, "w")
        if !file
            throw OSError("Could not open " path " for writing.", -1)
        try
            file.RawWrite(out, total)
        finally
            file.Close()
        return path
    }

    ; Opens the artwork itself when nobody else has, so a one-off render is not
    ; quietly downgraded to the fallback drawing. SaveIco still opens it once for
    ; the whole batch, and this leaves that batch handle alone.
    static RenderARGB(box) {
        CursorPainter.Startup()
        mine := MarkerIcon.source ? false : MarkerIcon.OpenSource()
        pixels := Buffer(box * box * 4, 0)
        if DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", box, "Int", box, "Int", box * 4
                 , "Int", 0x0026200A, "Ptr", pixels.Ptr, "Ptr*", &pBitmap := 0, "UInt")
            throw OSError("GdipCreateBitmapFromScan0 failed at " box "px.", -1)
        DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pBitmap, "Ptr*", &gfx := 0)
        DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", gfx, "Int", 4)
        if !MarkerIcon.Paint(gfx, box)
            MarkerIcon.Draw(gfx, box)
        DllCall("gdiplus\GdipFlush", "Ptr", gfx, "Int", 1)
        DllCall("gdiplus\GdipDeleteGraphics", "Ptr", gfx)
        DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
        if mine
            MarkerIcon.CloseSource()
        return pixels
    }

    ; Below 24px the rim and the glyph outline are sub-pixel, so they are dropped
    ; rather than smeared — a flat white arrow on blue reads better at tray size.
    static Draw(gfx, box) {
        rim := box >= 24 ? Max(1.0, box * 0.045) : 0
        inset := rim / 2 + box * 0.02
        side := box - inset * 2
        path := MarkerIcon.RoundedPath(inset, inset, side, side, side * 0.26)

        plate := CursorPainter.Brush(CursorPainter.Argb(MarkerIcon.Plate, 100))
        DllCall("gdiplus\GdipFillPath", "Ptr", gfx, "Ptr", plate, "Ptr", path)
        DllCall("gdiplus\GdipDeleteBrush", "Ptr", plate)

        if (rim > 0) {
            pen := CursorPainter.Pen(CursorPainter.Argb(MarkerIcon.Rim, 100), rim)
            DllCall("gdiplus\GdipDrawPath", "Ptr", gfx, "Ptr", pen, "Ptr", path)
            DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
        }
        DllCall("gdiplus\GdipDeletePath", "Ptr", path)

        MarkerIcon.DrawGlyph(gfx, box)
    }

    static RoundedPath(x, y, w, h, r) {
        DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", &path := 0)
        d := r * 2
        DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x, "Float", y
              , "Float", d, "Float", d, "Float", 180, "Float", 90)
        DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x + w - d, "Float", y
              , "Float", d, "Float", d, "Float", 270, "Float", 90)
        DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x + w - d, "Float", y + h - d
              , "Float", d, "Float", d, "Float", 0, "Float", 90)
        DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x, "Float", y + h - d
              , "Float", d, "Float", d, "Float", 90, "Float", 90)
        DllCall("gdiplus\GdipClosePathFigure", "Ptr", path)
        return path
    }

    ; The glyph is measured rather than hard-placed, so it stays centred if
    ; CursorPainter's arrow outline is ever reshaped.
    static DrawGlyph(gfx, box) {
        pts := CursorPainter.ArrowPts
        minX := 1.0
        minY := 1.0
        maxX := 0.0
        maxY := 0.0
        for pt in pts {
            minX := Min(minX, pt[1])
            maxX := Max(maxX, pt[1])
            minY := Min(minY, pt[2])
            maxY := Max(maxY, pt[2])
        }
        scale := (box * 0.60) / (maxY - minY)
        offX := (box - (maxX - minX) * scale) / 2 - minX * scale
        offY := (box - (maxY - minY) * scale) / 2 - minY * scale

        buf := Buffer(pts.Length * 8, 0)
        for i, pt in pts {
            NumPut("Float", offX + pt[1] * scale
                 , "Float", offY + pt[2] * scale, buf, (i - 1) * 8)
        }

        brush := CursorPainter.Brush(CursorPainter.Argb(MarkerIcon.Glyph, 100))
        DllCall("gdiplus\GdipFillPolygon", "Ptr", gfx, "Ptr", brush, "Ptr", buf, "Int", pts.Length, "Int", 0)
        DllCall("gdiplus\GdipDeleteBrush", "Ptr", brush)

        if (box >= 24) {
            pen := CursorPainter.Pen(CursorPainter.Argb(MarkerIcon.GlyphEdge, 100), Max(1.0, box * 0.03))
            DllCall("gdiplus\GdipDrawPolygon", "Ptr", gfx, "Ptr", pen, "Ptr", buf, "Int", pts.Length)
            DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
        }
    }
}
