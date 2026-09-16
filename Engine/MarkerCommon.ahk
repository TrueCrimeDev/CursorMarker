#Requires AutoHotkey v2.1-alpha.30

; Shared plumbing for the CursorMarker studio: a flat settings store backed by an
; INI file, and colour helpers. The three engines beside this file deliberately
; do NOT depend on it — that is what lets ScriptExporter inline any one of them
; into a standalone script with nothing else attached.

class MarkerColor {
    static _custom := Buffer(64, 0)      ; 16 COLORREF slots for the common dialog

    ; "5B9FEF", "#5B9FEF" and "0x5B9FEF" all yield 0x5B9FEF. Junk falls back.
    static ToRGB(hex, fallback := 0x5B9FEF) {
        s := StrReplace(Trim(hex), "#", "")
        if (SubStr(s, 1, 2) = "0x")
            s := SubStr(s, 3)
        if !RegExMatch(s, "^[0-9a-fA-F]{6}$")
            return fallback
        return Integer("0x" s)
    }

    static ToHex(rgb) => Format("{:06X}", rgb & 0xFFFFFF)
    static ToBGR(rgb) => ((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF)
    static FromBGR(bgr) => ((bgr & 0xFF) << 16) | (bgr & 0xFF00) | ((bgr >> 16) & 0xFF)
    static ToARGB(rgb, percent) => ((Round(percent * 255 / 100) & 0xFF) << 24) | (rgb & 0xFFFFFF)

    ; Windows' own colour picker. Returns the chosen RGB, or the original on cancel.
    static Pick(ownerHwnd, rgb) {
        cc := Buffer(72, 0)
        NumPut("UInt", 72, cc, 0)
        NumPut("Ptr", ownerHwnd, cc, 8)
        NumPut("UInt", MarkerColor.ToBGR(rgb), cc, 24)
        NumPut("Ptr", MarkerColor._custom.Ptr, cc, 32)
        NumPut("UInt", 0x03, cc, 40)              ; CC_RGBINIT | CC_FULLOPEN
        if !DllCall("comdlg32\ChooseColorW", "Ptr", cc, "Int")
            return rgb
        return MarkerColor.FromBGR(NumGet(cc, 24, "UInt"))
    }
}

; One flat Map of scalars. Keys are "Section.Name" so Save/Load map straight onto
; INI sections, which keeps presets readable and hand-editable.
class MarkerConfig {
    static Defaults := Map()
    static Values := Map()

    static __New() {
        d := Map()

        d["Loupe.LensSize"] := 180
        d["Loupe.Zoom"] := 25                     ; tenths, so 25 = 2.5x
        d["Loupe.BorderWidth"] := 3
        d["Loupe.BorderColor"] := "5B9FEF"
        d["Loupe.Interval"] := 16
        d["Loupe.Shape"] := "Circle"
        d["Loupe.Follow"] := "Cursor"
        d["Loupe.OffsetX"] := 0
        d["Loupe.OffsetY"] := 0
        d["Loupe.Corner"] := "Top-right"
        d["Loupe.Capture"] := "Hide from capture"
        d["Loupe.Crosshair"] := 0
        d["Loupe.Smooth"] := 1
        d["Loupe.WheelZoom"] := 1
        d["Loupe.ZoomStep"] := 5                  ; tenths, so 5 = 0.5x per notch
        d["Loupe.HotToggle"] := "F9"
        d["Loupe.HotZoomIn"] := "^NumpadAdd"
        d["Loupe.HotZoomOut"] := "^NumpadSub"

        d["Hl.RingRadius"] := 28
        d["Hl.RingWidth"] := 4
        d["Hl.RingColor"] := "F59E42"
        d["Hl.RingAlpha"] := 85
        d["Hl.Fill"] := 0
        d["Hl.FillColor"] := "F59E42"
        d["Hl.FillAlpha"] := 25
        d["Hl.Ripple"] := 1
        d["Hl.RippleMax"] := 60
        d["Hl.RippleMs"] := 420
        d["Hl.ColorL"] := "7BC96F"
        d["Hl.ColorM"] := "22D3EE"
        d["Hl.ColorR"] := "DC3545"
        d["Hl.Interval"] := 16
        d["Hl.HotToggle"] := "F10"

        d["Cur.Shape"] := "Arrow"
        d["Cur.Size"] := 48
        d["Cur.Fill"] := "FFFFFF"
        d["Cur.Outline"] := "101010"
        d["Cur.OutlineWidth"] := 2
        d["Cur.Alpha"] := 100
        d["Cur.Halo"] := 0
        d["Cur.HaloColor"] := "5B9FEF"
        d["Cur.HaloAlpha"] := 40
        d["Cur.HotX"] := -1                       ; -1 = use the shape's natural hotspot
        d["Cur.HotY"] := -1
        d["Cur.Target"] := "Normal arrow"

        d["Exp.Name"] := "MyLoupe"
        d["Exp.Loupe"] := 1
        d["Exp.Highlight"] := 0
        d["Exp.Cursor"] := 0

        MarkerConfig.Defaults := d
        MarkerConfig.Reset()
    }

    static Get(key) {
        if MarkerConfig.Values.Has(key)
            return MarkerConfig.Values[key]
        if MarkerConfig.Defaults.Has(key)
            return MarkerConfig.Defaults[key]
        throw ValueError("Unknown setting: " key, -1)
    }

    ; Controls hand back text, and an Edit the user has cleared hands back "".
    ; Fall back to the default rather than letting Integer() throw mid-render.
    static Num(key) {
        raw := MarkerConfig.Get(key)
        if !IsNumber(raw)
            raw := MarkerConfig.Defaults[key]
        return Integer(raw)
    }

    static RGB(key) => MarkerColor.ToRGB(MarkerConfig.Get(key))
    static Set(key, value) => MarkerConfig.Values[key] := value

    static Reset() {
        MarkerConfig.Values := Map()
        for k, v in MarkerConfig.Defaults
            MarkerConfig.Values[k] := v
    }

    static Save(path) {
        for k, v in MarkerConfig.Values {
            parts := StrSplit(k, ".")
            IniWrite(v, path, parts[1], parts[2])
        }
        return path
    }

    ; Reads every known key, so a truncated or hand-edited INI still loads with
    ; defaults filling the gaps instead of throwing.
    static Load(path) {
        if !FileExist(path)
            return false
        for k, fallback in MarkerConfig.Defaults {
            parts := StrSplit(k, ".")
            MarkerConfig.Values[k] := IniRead(path, parts[1], parts[2], fallback)
        }
        return true
    }
}
