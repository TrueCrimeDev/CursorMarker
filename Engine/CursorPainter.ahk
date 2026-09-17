#Requires AutoHotkey v2.1-alpha.30

; CursorPainter — draws a cursor design with GDI+, writes it out as a real .cur
; file, and can swap it in as a system cursor.
;
; Rendering goes into a straight (non-premultiplied) 32bpp ARGB buffer, which is
; exactly the pixel layout a .cur file's XOR bitmap wants, so saving is a row
; flip and a header — no conversion pass.
;
; A .cur is an .ico with idType 2, where the two "planes/bitcount" slots of each
; directory entry carry the hotspot instead. The AND mask is left zeroed: at
; 32bpp the alpha channel decides what shows, and every Windows version that
; matters reads it that way.
;
; SetSystemCursor changes the pointer for the whole session, so Restore() is
; wired to OnExit by the caller and is always one button away in the GUI.

class CursorPainter {
    static Shapes := ["Arrow", "Arrow + halo", "Crosshair", "Dot", "Ring", "Target"]
    static Targets := ["Normal arrow", "Crosshair", "Hand", "Text beam", "All pointers"]

    ; Outline of a classic pointer, as fractions of the design box. The first
    ; point is the tip, which is what every hotspot calculation keys off.
    static ArrowPts := [[0.03, 0.03], [0.03, 0.76], [0.22, 0.58], [0.33, 0.88]
                      , [0.46, 0.82], [0.35, 0.54], [0.60, 0.54]]

    static token := 0
    static applied := false

    static Startup() {
        if CursorPainter.token
            return
        if !DllCall("GetModuleHandleW", "Str", "gdiplus", "Ptr")
            DllCall("LoadLibraryW", "Str", "gdiplus.dll", "Ptr")
        input := Buffer(24, 0)
        NumPut("UInt", 1, input, 0)
        if DllCall("gdiplus\GdiplusStartup", "Ptr*", &token := 0, "Ptr", input, "Ptr", 0, "UInt")
            throw OSError("GdiplusStartup failed — cursor rendering is unavailable.", -1)
        CursorPainter.token := token
    }

    static Shutdown() {
        if !CursorPainter.token
            return
        DllCall("gdiplus\GdiplusShutdown", "Ptr", CursorPainter.token)
        CursorPainter.token := 0
    }

    ; Natural hotspot for a shape: the pointer tip for arrows, dead centre for
    ; the radial designs. spec["HotX"] / ["HotY"] of -1 means "use this".
    static Hotspot(spec, &hx, &hy) {
        box := spec["Size"]
        if (spec["Shape"] = "Arrow") {
            hx := Round(CursorPainter.ArrowPts[1][1] * box)
            hy := Round(CursorPainter.ArrowPts[1][2] * box)
        } else {
            hx := box // 2
            hy := box // 2
        }
        if (spec["HotX"] >= 0)
            hx := Min(box - 1, spec["HotX"])
        if (spec["HotY"] >= 0)
            hy := Min(box - 1, spec["HotY"])
    }

    ; Straight ARGB, top-down, stride = box*4. The Buffer is returned so the
    ; caller owns it for as long as the pixels are needed.
    static RenderARGB(spec, box) {
        CursorPainter.Startup()
        pixels := Buffer(box * box * 4, 0)
        if DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", box, "Int", box, "Int", box * 4
                 , "Int", 0x0026200A, "Ptr", pixels.Ptr, "Ptr*", &pBitmap := 0, "UInt")
            throw OSError("GdipCreateBitmapFromScan0 failed at " box "px.", -1)
        DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pBitmap, "Ptr*", &gfx := 0)
        DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", gfx, "Int", 4)
        CursorPainter.Draw(gfx, spec, box)
        DllCall("gdiplus\GdipFlush", "Ptr", gfx, "Int", 1)
        DllCall("gdiplus\GdipDeleteGraphics", "Ptr", gfx)
        DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
        return pixels
    }

    ; An opaque HBITMAP for a Picture control: dark backing, a faint checker so
    ; transparency reads as transparency, then the design over the top.
    ; drawBox is the size the design is rendered at — pass the real cursor size
    ; for a 1:1 view, or leave it at 0 to blow the design up to fill the canvas.
    ; The caller owns the handle — assign it with "HBITMAP:*" and delete it.
    static RenderPreview(spec, canvas, bgRgb, checkRgb, drawBox := 0) {
        CursorPainter.Startup()
        pixels := Buffer(canvas * canvas * 4, 0)
        if DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", canvas, "Int", canvas, "Int", canvas * 4
                 , "Int", 0x0026200A, "Ptr", pixels.Ptr, "Ptr*", &pBitmap := 0, "UInt")
            throw OSError("GdipCreateBitmapFromScan0 failed at " canvas "px.", -1)
        DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pBitmap, "Ptr*", &gfx := 0)
        DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", gfx, "Int", 4)

        DllCall("gdiplus\GdipGraphicsClear", "Ptr", gfx, "UInt", 0xFF000000 | (bgRgb & 0xFFFFFF))
        cell := Max(6, canvas // 16)
        checker := CursorPainter.Brush(0xFF000000 | (checkRgb & 0xFFFFFF))
        row := 0
        while (row * cell < canvas) {
            col := 0
            while (col * cell < canvas) {
                if (Mod(row + col, 2) = 0) {
                    DllCall("gdiplus\GdipFillRectangle", "Ptr", gfx, "Ptr", checker
                          , "Float", col * cell, "Float", row * cell, "Float", cell, "Float", cell)
                }
                col += 1
            }
            row += 1
        }
        DllCall("gdiplus\GdipDeleteBrush", "Ptr", checker)

        box := (drawBox > 0) ? Min(drawBox, canvas) : canvas
        inset := (canvas - box) / 2
        if (inset != 0)
            DllCall("gdiplus\GdipTranslateWorldTransform", "Ptr", gfx
                  , "Float", inset, "Float", inset, "Int", 0)          ; MatrixOrderPrepend
        CursorPainter.Draw(gfx, spec, box)
        DllCall("gdiplus\GdipFlush", "Ptr", gfx, "Int", 1)
        DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "Ptr", pBitmap, "Ptr*", &hbm := 0, "UInt", 0xFF000000)
        DllCall("gdiplus\GdipDeleteGraphics", "Ptr", gfx)
        DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
        return hbm
    }

    static Draw(gfx, spec, box) {
        scale := box / 48                              ; design units are authored at 48px
        ow := Max(0, spec["OutlineWidth"]) * scale
        fillArgb := CursorPainter.Argb(spec["Fill"], spec["Alpha"])
        lineArgb := CursorPainter.Argb(spec["Outline"], spec["Alpha"])

        if spec["Halo"] {
            hr := box * 0.46
            halo := CursorPainter.Brush(CursorPainter.Argb(spec["HaloColor"], spec["HaloAlpha"]))
            DllCall("gdiplus\GdipFillEllipse", "Ptr", gfx, "Ptr", halo
                  , "Float", box / 2 - hr, "Float", box / 2 - hr, "Float", hr * 2, "Float", hr * 2)
            DllCall("gdiplus\GdipDeleteBrush", "Ptr", halo)
        }

        switch spec["Shape"] {
            case "Arrow + halo":
                CursorPainter.PaintArrow(gfx, box, box / 2, box / 2, 0.46, fillArgb, lineArgb, ow)
            case "Crosshair":
                CursorPainter.PaintCross(gfx, box, 0.12, 0.46, fillArgb, lineArgb, ow)
            case "Dot":
                CursorPainter.PaintDisc(gfx, box, 0.30, fillArgb, lineArgb, ow)
            case "Ring":
                CursorPainter.PaintRing(gfx, box, 0.36, fillArgb, lineArgb, ow)
            case "Target":
                CursorPainter.PaintRing(gfx, box, 0.32, fillArgb, lineArgb, ow)
                CursorPainter.PaintCross(gfx, box, 0.40, 0.48, fillArgb, lineArgb, ow)
                CursorPainter.PaintDisc(gfx, box, 0.05, fillArgb, lineArgb, 0)
            default:
                CursorPainter.PaintArrow(gfx, box, CursorPainter.ArrowPts[1][1] * box
                                       , CursorPainter.ArrowPts[1][2] * box, 1.0, fillArgb, lineArgb, ow)
        }
    }

    static PaintArrow(gfx, box, tipX, tipY, scale, fillArgb, lineArgb, ow) {
        pts := CursorPainter.ArrowPts
        buf := Buffer(pts.Length * 8, 0)
        anchorX := pts[1][1]
        anchorY := pts[1][2]
        for i, pt in pts {
            NumPut("Float", tipX + (pt[1] - anchorX) * scale * box
                 , "Float", tipY + (pt[2] - anchorY) * scale * box, buf, (i - 1) * 8)
        }
        brush := CursorPainter.Brush(fillArgb)
        DllCall("gdiplus\GdipFillPolygon", "Ptr", gfx, "Ptr", brush, "Ptr", buf, "Int", pts.Length, "Int", 0)
        DllCall("gdiplus\GdipDeleteBrush", "Ptr", brush)
        if (ow > 0) {
            pen := CursorPainter.Pen(lineArgb, ow)
            DllCall("gdiplus\GdipDrawPolygon", "Ptr", gfx, "Ptr", pen, "Ptr", buf, "Int", pts.Length)
            DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
        }
    }

    ; Four arms between gap and reach (both fractions of the box), drawn as a
    ; wide outline stroke first and a narrower fill stroke on top.
    static PaintCross(gfx, box, gap, reach, fillArgb, lineArgb, ow) {
        c := box / 2
        g := box * gap
        r := box * reach
        core := Max(1.5, box * 0.055)
        arms := [[c - r, c, c - g, c], [c + g, c, c + r, c], [c, c - r, c, c - g], [c, c + g, c, c + r]]
        if (ow > 0) {
            pen := CursorPainter.Pen(lineArgb, core + ow * 2)
            for a in arms
                DllCall("gdiplus\GdipDrawLine", "Ptr", gfx, "Ptr", pen
                      , "Float", a[1], "Float", a[2], "Float", a[3], "Float", a[4])
            DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
        }
        pen := CursorPainter.Pen(fillArgb, core)
        for a in arms
            DllCall("gdiplus\GdipDrawLine", "Ptr", gfx, "Ptr", pen
                  , "Float", a[1], "Float", a[2], "Float", a[3], "Float", a[4])
        DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
    }

    static PaintDisc(gfx, box, radius, fillArgb, lineArgb, ow) {
        r := box * radius
        c := box / 2
        brush := CursorPainter.Brush(fillArgb)
        DllCall("gdiplus\GdipFillEllipse", "Ptr", gfx, "Ptr", brush
              , "Float", c - r, "Float", c - r, "Float", r * 2, "Float", r * 2)
        DllCall("gdiplus\GdipDeleteBrush", "Ptr", brush)
        if (ow > 0) {
            pen := CursorPainter.Pen(lineArgb, ow)
            DllCall("gdiplus\GdipDrawEllipse", "Ptr", gfx, "Ptr", pen
                  , "Float", c - r, "Float", c - r, "Float", r * 2, "Float", r * 2)
            DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
        }
    }

    static PaintRing(gfx, box, radius, fillArgb, lineArgb, ow) {
        r := box * radius
        c := box / 2
        ring := Max(2.0, box * 0.10)
        if (ow > 0) {
            pen := CursorPainter.Pen(lineArgb, ring + ow * 2)
            DllCall("gdiplus\GdipDrawEllipse", "Ptr", gfx, "Ptr", pen
                  , "Float", c - r, "Float", c - r, "Float", r * 2, "Float", r * 2)
            DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
        }
        pen := CursorPainter.Pen(fillArgb, ring)
        DllCall("gdiplus\GdipDrawEllipse", "Ptr", gfx, "Ptr", pen
              , "Float", c - r, "Float", c - r, "Float", r * 2, "Float", r * 2)
        DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
    }

    static SaveCur(path, spec) {
        box := spec["Size"]
        pixels := CursorPainter.RenderARGB(spec, box)
        CursorPainter.Hotspot(spec, &hx, &hy)

        stride := box * 4
        maskStride := ((box + 31) // 32) * 4
        maskBytes := maskStride * box
        imageBytes := 40 + stride * box + maskBytes
        total := 22 + imageBytes
        out := Buffer(total, 0)

        NumPut("UShort", 0, out, 0)                   ; idReserved
        NumPut("UShort", 2, out, 2)                   ; idType: 2 = cursor
        NumPut("UShort", 1, out, 4)                   ; idCount
        NumPut("UChar", box >= 256 ? 0 : box, out, 6)
        NumPut("UChar", box >= 256 ? 0 : box, out, 7)
        NumPut("UChar", 0, out, 8)                    ; colour count
        NumPut("UChar", 0, out, 9)                    ; reserved
        NumPut("UShort", hx, out, 10)                 ; hotspot X (planes slot)
        NumPut("UShort", hy, out, 12)                 ; hotspot Y (bitcount slot)
        NumPut("UInt", imageBytes, out, 14)
        NumPut("UInt", 22, out, 18)                   ; offset of the image data

        NumPut("UInt", 40, out, 22)                   ; BITMAPINFOHEADER
        NumPut("Int", box, out, 26)
        NumPut("Int", box * 2, out, 30)               ; XOR + AND stacked
        NumPut("UShort", 1, out, 34)
        NumPut("UShort", 32, out, 36)
        NumPut("UInt", 0, out, 38)                    ; BI_RGB
        NumPut("UInt", stride * box + maskBytes, out, 42)

        ; DIB rows run bottom-up; the render is top-down, so walk it backwards.
        base := 22 + 40
        loop box {
            src := (box - A_Index) * stride
            dst := base + (A_Index - 1) * stride
            DllCall("RtlMoveMemory", "Ptr", out.Ptr + dst, "Ptr", pixels.Ptr + src, "Ptr", stride)
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

    static TargetIds(name) {
        switch name {
            case "Crosshair":    return [32515]
            case "Hand":         return [32649]
            case "Text beam":    return [32513]
            case "All pointers": return [32512, 32515, 32649]
            default:             return [32512]
        }
    }

    ; The size the .cur declares, read from the first directory entry. A stored 0
    ; means 256, which is how the format encodes its largest size.
    static CurSize(path) {
        file := FileOpen(path, "r")
        if !file
            return 0
        try {
            header := Buffer(8, 0)
            if (file.RawRead(header, 8) < 8)
                return 0
            if (NumGet(header, 2, "UShort") != 2)          ; idType 2 = cursor
                return 0
            width := NumGet(header, 6, "UChar")
            return width ? width : 256
        } finally
            file.Close()
    }

    ; SetSystemCursor consumes the handle it is given, so each slot gets its own
    ; copy and anything it refuses is destroyed here rather than leaked.
    ;
    ; Loaded with LoadImage at an explicit size, NOT LoadCursorFromFile: that one
    ; is LoadImage with LR_DEFAULTSIZE, which forces SM_CXCURSOR (32x32) whatever
    ; the file holds — so every design used to arrive the same size no matter what
    ; the Size slider said.
    static ApplySystem(path, targetName) {
        size := CursorPainter.CurSize(path)
        if size
            source := DllCall("User32\LoadImageW", "Ptr", 0, "Str", path, "UInt", 2
                            , "Int", size, "Int", size, "UInt", 0x10, "Ptr")
        else
            source := DllCall("User32\LoadCursorFromFile", "Str", path, "Ptr")
        if !source
            throw OSError("Could not load the cursor from " path, -1)
        for id in CursorPainter.TargetIds(targetName) {
            copy := DllCall("User32\CopyImage", "Ptr", source, "UInt", 2
                          , "Int", size, "Int", size, "UInt", 0, "Ptr")
            if !copy
                continue
            if !DllCall("User32\SetSystemCursor", "Ptr", copy, "UInt", id, "Int")
                DllCall("User32\DestroyCursor", "Ptr", copy)
        }
        DllCall("User32\DestroyCursor", "Ptr", source)
        CursorPainter.applied := true
    }

    ; Reloads every pointer from the user's own scheme in the registry, which
    ; undoes ApplySystem no matter how many slots were touched.
    static RestoreSystem() {
        DllCall("User32\SystemParametersInfoW", "UInt", 0x0057, "UInt", 0, "Ptr", 0, "UInt", 0)
        CursorPainter.applied := false
    }

    static Brush(argb) {
        DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &brush := 0)
        return brush
    }

    static Pen(argb, width) {
        DllCall("gdiplus\GdipCreatePen1", "UInt", argb, "Float", width, "Int", 2, "Ptr*", &pen := 0)
        return pen
    }

    static Argb(rgb, percent) => ((Round(percent * 255 / 100) & 0xFF) << 24) | (rgb & 0xFFFFFF)
}
