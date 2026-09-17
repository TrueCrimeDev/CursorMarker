#Requires AutoHotkey v2.1-alpha.30
#SingleInstance Force

; CursorMarker — a studio for building screen loupes and custom pointers.
;
; Four tabs, three live engines and one exporter:
;   Loupe      a magnifier lens that follows (or offsets from) the cursor
;   Cursor     a pointer designer that writes a real .cur and can install it
;   Highlight  a halo + click ripples that make the pointer easy to follow
;   Export     bakes any combination into a standalone .ahk with the engine
;              source inlined, so the result runs with nothing beside it
;
; Everything previews live. Settings persist to CursorMarker.ini beside this
; script; named presets live in Presets\ and exports land in Export\.

#Include Engine\MarkerCommon.ahk
#Include Engine\LoupeEngine.ahk
#Include Engine\HighlightEngine.ahk
#Include Engine\CursorPainter.ahk
#Include Engine\MarkerIcon.ahk
#Include Engine\ScriptExporter.ahk
; Dark mode is optional. With DarkModeModular.ahk in a Lib folder beside this
; one (github.com/TrueCrimeDev/DarkMode) the window is dark; without it the
; studio still runs, just in Windows' default colours.
#Include *i ..\Lib\DarkModeModular.ahk

CursorMarker.Run()

class CursorMarker {
    static Title := "CursorMarker — magnifier, pointer and mouse highlight"
    static W := 780
    static H := 604
    static COLA := 26
    static COLB := 396
    static LABW := 100
    static CTRW := 158
    static VALW := 54
    static GAP := 10
    static TOP := 52
    static ROW := 32

    static gui := 0
    static ctl := Map()
    static items := Map()
    static values := Map()
    static readout := Map()
    static suffix := Map()
    static previewBig := 0
    static previewReal := 0
    static hotLabel := 0
    static tabs := 0
    static cursorToggle := 0
    static presetList := 0
    static presetName := 0
    static status := 0
    static logBox := 0
    static onChange := 0
    static applyTimer := 0
    static syncTimer := 0
    static iniPath := ""
    static iconPath := ""
    static exportDir := ""
    static presetDir := ""

    ; Run from source, everything hangs off this file's own folder rather than
    ; A_ScriptDir, so the studio keeps its settings, presets and exports together
    ; even when some other script is the entry point.
    ;
    ; Compiled, A_LineFile is "*#1" — a resource marker, not a path — so there is
    ; nothing to hang anything off. A single exe should not scatter files into
    ; whatever folder it was double-clicked from either, so it uses AppData.
    static Home => A_IsCompiled ? A_AppData "\CursorMarker" : RegExReplace(A_LineFile, "\\[^\\]+$")

    ; The exporter reads the two engine files to inline them, and the icon builder
    ; reads the artwork. A compiled exe has neither beside it, so both ride along
    ; inside the exe and are unpacked once on first run.
    static Unpack() {
        if !A_IsCompiled
            return
        for sub in ["Engine", "Icons"] {
            if !DirExist(CursorMarker.Home "\" sub)
                DirCreate(CursorMarker.Home "\" sub)
        }
        FileInstall("Engine\LoupeEngine.ahk", CursorMarker.Home "\Engine\LoupeEngine.ahk", 1)
        FileInstall("Engine\HighlightEngine.ahk", CursorMarker.Home "\Engine\HighlightEngine.ahk", 1)
        FileInstall("Icons\Cursor.png", CursorMarker.Home "\Icons\Cursor.png", 1)
    }

    static Run() {
        ; A shown Gui normally keeps the script alive, but that is not a promise
        ; worth betting the window on — without this, the process can end the
        ; moment AHK decides it has nothing left to do.
        Persistent
        if !DirExist(CursorMarker.Home)
            DirCreate(CursorMarker.Home)
        CursorMarker.Unpack()
        ; Both helpers locate themselves from their own source file, which a
        ; compiled build does not have — point them at the real folder instead.
        MarkerIcon.Root := CursorMarker.Home
        ScriptExporter.Root := CursorMarker.Home
        CursorMarker.iniPath := CursorMarker.Home "\CursorMarker.ini"
        CursorMarker.iconPath := CursorMarker.Home "\CursorMarker.ico"
        CursorMarker.exportDir := CursorMarker.Home "\Export"
        CursorMarker.presetDir := CursorMarker.Home "\Presets"
        for dir in [CursorMarker.exportDir, CursorMarker.presetDir] {
            if !DirExist(dir)
                DirCreate(dir)
        }
        MarkerConfig.Load(CursorMarker.iniPath)

        CursorMarker.onChange := ObjBindMethod(CursorMarker, "HandleChange")
        CursorMarker.applyTimer := ObjBindMethod(CursorMarker, "ApplyLive")
        OnExit(ObjBindMethod(CursorMarker, "Shutdown"))

        if IsSet(DarkGui)
            DarkGui.Global()
        CursorMarker.BuildTray()
        CursorMarker.Build()
        CursorMarker.RefreshPresets()
        CursorMarker.UpdateReadouts()
        CursorMarker.PushLoupe()
        CursorMarker.PushHighlight()
        CursorMarker.RefreshPreview()
        CursorMarker.gui.Show(Format("w{} h{}", CursorMarker.W, CursorMarker.H))
        CursorMarker.Say("Ready. Nothing is installed system-wide until you ask for it.")
    }

    static BuildTray() {
        tray := A_TrayMenu
        tray.Delete()
        tray.Add("Show CursorMarker", ObjBindMethod(CursorMarker, "OnShow"))
        tray.Add("Restore system cursors", ObjBindMethod(CursorMarker, "OnRestoreCursor"))
        tray.Add()
        tray.Add("Exit", ObjBindMethod(CursorMarker, "OnClose"))
        tray.Default := "Show CursorMarker"
    }

    static Build() {
        g := Gui("-MaximizeBox", CursorMarker.Title)
        g.MarginX := 0
        g.MarginY := 0
        g.OnEvent("Close", ObjBindMethod(CursorMarker, "OnClose"))

        tabs := g.Add("Tab3", "x10 y10 w760 h536", ["Magnifier", "Cursor", "Highlight", "Export"])
        tabs.UseTab(1)
        CursorMarker.BuildLoupeTab(g)
        tabs.UseTab(2)
        CursorMarker.BuildCursorTab(g)
        tabs.UseTab(3)
        CursorMarker.BuildHighlightTab(g)
        tabs.UseTab(4)
        CursorMarker.BuildExportTab(g)
        tabs.UseTab()
        ; Switching tabs shows the incoming tab's controls but never invalidates
        ; them, so the owner-drawn ones come back blank until something else
        ; happens to repaint them. Force the repaint on every tab change.
        tabs.OnEvent("Change", ObjBindMethod(CursorMarker, "OnTabChange"))
        CursorMarker.tabs := tabs

        CursorMarker.status := g.Add("Text", "x26 y562 w404 h22 +0x200", "")
        reset := g.Add("Button", "x440 y556 w110 h30", "Reset defaults")
        reset.OnEvent("Click", ObjBindMethod(CursorMarker, "OnReset"))
        save := g.Add("Button", "x558 y556 w110 h30", "Save settings")
        save.OnEvent("Click", ObjBindMethod(CursorMarker, "OnSaveSettings"))
        close := g.Add("Button", "x676 y556 w78 h30", "Close")
        close.OnEvent("Click", ObjBindMethod(CursorMarker, "OnClose"))

        CursorMarker.gui := g
        CursorMarker.DressWindow(g)
    }

    ; The icon is cosmetic, so a failure here reports itself and gets out of the
    ; way rather than taking the window down with it.
    static DressWindow(g) {
        A_IconTip := "CursorMarker"
        try
            MarkerIcon.Apply(g.Hwnd, CursorMarker.iconPath)
        catch Error as err {
            CursorMarker.Say("Icon unavailable: " err.Message)
            OutputDebug("CursorMarker: icon not applied — " err.Message)
        }
    }

    static BuildLoupeTab(g) {
        a := CursorMarker.COLA
        y := CursorMarker.TOP

        CursorMarker.Slider(g, "Loupe.LensSize", a, y, "Lens size", "80-600", " px")
        y += CursorMarker.ROW
        CursorMarker.Slider(g, "Loupe.Zoom", a, y, "Magnification", "10-80", "")
        y += CursorMarker.ROW
        CursorMarker.Slider(g, "Loupe.ZoomStep", a, y, "Zoom per notch", "1-20", "")
        y += CursorMarker.ROW
        CursorMarker.Slider(g, "Loupe.BorderWidth", a, y, "Border width", "0-16", " px")
        y += CursorMarker.ROW
        CursorMarker.Slider(g, "Loupe.Interval", a, y, "Redraw every", "8-100", " ms")
        y += CursorMarker.ROW
        CursorMarker.Choice(g, "Loupe.Shape", a, y, "Lens shape"
                          , ["Circle", "Square", "Rounded square"], ["Circle", "Square", "Rounded"])
        y += CursorMarker.ROW
        CursorMarker.Colour(g, "Loupe.BorderColor", a, y, "Border colour")
        y += CursorMarker.ROW + 10

        start := g.Add("Button", Format("x{} y{} w150 h32", a, y), "Start magnifier")
        start.OnEvent("Click", ObjBindMethod(CursorMarker, "OnLoupeStart"))
        stop := g.Add("Button", Format("x{} y{} w104 h32", a + 158, y), "Stop")
        stop.OnEvent("Click", ObjBindMethod(CursorMarker, "OnLoupeStop"))

        note := "A magnifying glass that follows your mouse. Whatever sits under "
              . "the pointer shows up enlarged inside the lens, and you can still "
              . "click straight through it.`n`n"
              . "Recording your screen? Leave `"In recordings`" on Hidden and the "
              . "lens stays out of the video — only you see it. Set it to Visible "
              . "to record the lens itself, but then park it away from the pointer "
              . "(Offset, or a corner), or it ends up magnifying its own picture.`n`n"
              . "While the lens is up: hold Ctrl and roll the wheel to zoom in and "
              . "out, or Ctrl+Shift and roll to make the lens itself bigger and "
              . "smaller. Let the lens go and the wheel behaves normally again.`n`n"
              . "The keys on the right belong to the script you make on the Export "
              . "tab. In this window, use the buttons."
        g.Add("Text", Format("x{} y{} w340 h210", a, y + 44), note)

        CursorMarker.BuildLoupeSide(g)
    }

    static BuildLoupeSide(g) {
        b := CursorMarker.COLB
        y := CursorMarker.TOP
        CursorMarker.Choice(g, "Loupe.Follow", b, y, "Lens sits"
                          , ["On the cursor", "Offset from the cursor", "In a screen corner"]
                          , ["Cursor", "Offset", "Corner"])
        y += CursorMarker.ROW
        CursorMarker.Number(g, "Loupe.OffsetX", b, y, "Offset across", "-600-600")
        y += CursorMarker.ROW
        CursorMarker.Number(g, "Loupe.OffsetY", b, y, "Offset down", "-600-600")
        y += CursorMarker.ROW
        CursorMarker.Choice(g, "Loupe.Corner", b, y, "Which corner"
                          , ["Top-left", "Top-right", "Bottom-left", "Bottom-right"])
        y += CursorMarker.ROW
        CursorMarker.Choice(g, "Loupe.Capture", b, y, "In recordings"
                          , ["Hidden", "Visible"], ["Hide from capture", "Show in capture"])
        y += CursorMarker.ROW
        CursorMarker.Check(g, "Loupe.Crosshair", b, y, "Crosshair in the middle")
        y += CursorMarker.ROW
        CursorMarker.Check(g, "Loupe.Smooth", b, y, "Smooth the enlarged image")
        y += CursorMarker.ROW
        CursorMarker.Check(g, "Loupe.WheelZoom", b, y, "Mouse wheel controls the lens")
        y += CursorMarker.ROW
        CursorMarker.HotkeyRow(g, "Loupe.HotToggle", b, y, "Show/hide key")
        y += CursorMarker.ROW
        CursorMarker.HotkeyRow(g, "Loupe.HotZoomIn", b, y, "Zoom in key")
        y += CursorMarker.ROW
        CursorMarker.HotkeyRow(g, "Loupe.HotZoomOut", b, y, "Zoom out key")
    }

    static BuildCursorTab(g) {
        a := CursorMarker.COLA
        b := CursorMarker.COLB
        y := CursorMarker.TOP

        CursorMarker.Choice(g, "Cur.Shape", a, y, "Design"
                          , ["Arrow", "Arrow with glow", "Crosshair", "Dot", "Ring", "Target"]
                          , CursorPainter.Shapes)
        y += CursorMarker.ROW
        CursorMarker.Slider(g, "Cur.Size", a, y, "Size", "16-128", " px")
        y += CursorMarker.ROW
        CursorMarker.Colour(g, "Cur.Fill", a, y, "Pointer colour")
        y += CursorMarker.ROW
        CursorMarker.Colour(g, "Cur.Outline", a, y, "Outline colour")
        y += CursorMarker.ROW
        CursorMarker.Slider(g, "Cur.OutlineWidth", a, y, "Outline width", "0-8", " px")
        y += CursorMarker.ROW
        CursorMarker.Slider(g, "Cur.Alpha", a, y, "Opacity", "10-100", "%")
        y += CursorMarker.ROW
        CursorMarker.Check(g, "Cur.Halo", a, y, "Glow behind the pointer")
        y += CursorMarker.ROW
        CursorMarker.Colour(g, "Cur.HaloColor", a, y, "Glow colour")
        y += CursorMarker.ROW
        CursorMarker.Slider(g, "Cur.HaloAlpha", a, y, "Glow opacity", "5-90", "%")
        y += CursorMarker.ROW
        CursorMarker.Number(g, "Cur.HotX", a, y, "Click point X", "-1-256")
        y += CursorMarker.ROW
        CursorMarker.Number(g, "Cur.HotY", a, y, "Click point Y", "-1-256")
        y += CursorMarker.ROW
        CursorMarker.Choice(g, "Cur.Target", a, y, "Replaces"
                          , ["The normal arrow", "The crosshair", "The hand", "The text beam", "All of them"]
                          , CursorPainter.Targets)
        y += CursorMarker.ROW

        saveBtn := g.Add("Button", Format("x{} y{} w110 h32", a, y), "Save .cur…")
        saveBtn.OnEvent("Click", ObjBindMethod(CursorMarker, "OnSaveCur"))
        CursorMarker.cursorToggle := g.Add("Button", Format("x{} y{} w240 h32", a + 118, y), "Use this pointer")
        CursorMarker.cursorToggle.OnEvent("Click", ObjBindMethod(CursorMarker, "OnToggleCursor"))

        note := "The click point is the pixel that does the clicking — leave it at -1 "
              . "to let the design choose. `"Use this pointer`" swaps your real pointer "
              . "for this one and the same button turns it off; so does closing this "
              . "window, so you cannot get stuck with it."
        g.Add("Text", Format("x{} y{} w340 h70", a, y + 40), note)

        g.Add("Text", Format("x{} y{} w260 h20 +0x200", b, CursorMarker.TOP), "Preview — scaled up")
        CursorMarker.previewBig := g.Add("Picture", Format("x{} y{} w260 h260 Background141414", b, CursorMarker.TOP + 24))
        CursorMarker.hotLabel := g.Add("Text", Format("x{} y{} w260 h20 +0x200", b, CursorMarker.TOP + 292), "")
        g.Add("Text", Format("x{} y{} w260 h20 +0x200", b, CursorMarker.TOP + 316), "Actual size on screen")
        CursorMarker.previewReal := g.Add("Picture", Format("x{} y{} w136 h136 Background141414", b, CursorMarker.TOP + 340))
    }

    static BuildHighlightTab(g) {
        a := CursorMarker.COLA
        b := CursorMarker.COLB
        y := CursorMarker.TOP

        CursorMarker.Slider(g, "Hl.RingRadius", a, y, "Ring size", "8-140", " px")
        y += CursorMarker.ROW
        CursorMarker.Slider(g, "Hl.RingWidth", a, y, "Ring thickness", "0-24", " px")
        y += CursorMarker.ROW
        CursorMarker.Colour(g, "Hl.RingColor", a, y, "Ring colour")
        y += CursorMarker.ROW
        CursorMarker.Slider(g, "Hl.RingAlpha", a, y, "Ring opacity", "5-100", "%")
        y += CursorMarker.ROW
        CursorMarker.Check(g, "Hl.Fill", a, y, "Fill the ring in")
        y += CursorMarker.ROW
        CursorMarker.Colour(g, "Hl.FillColor", a, y, "Fill colour")
        y += CursorMarker.ROW
        CursorMarker.Slider(g, "Hl.FillAlpha", a, y, "Fill opacity", "5-100", "%")
        y += CursorMarker.ROW
        CursorMarker.Slider(g, "Hl.Interval", a, y, "Redraw every", "8-60", " ms")
        y += CursorMarker.ROW + 10

        start := g.Add("Button", Format("x{} y{} w150 h32", a, y), "Start highlight")
        start.OnEvent("Click", ObjBindMethod(CursorMarker, "OnHighlightStart"))
        stop := g.Add("Button", Format("x{} y{} w104 h32", a + 158, y), "Stop")
        stop.OnEvent("Click", ObjBindMethod(CursorMarker, "OnHighlightStop"))

        note := "Puts a coloured ring around your mouse so viewers can follow it, "
              . "and a ripple wherever you click — a different colour for each "
              . "button, so a right-click looks different from a left-click.`n`n"
              . "Unlike the magnifier, this one always shows up in a recording. "
              . "Start it before you hit record and leave it running."
        g.Add("Text", Format("x{} y{} w340 h130", a, y + 44), note)

        y := CursorMarker.TOP
        CursorMarker.Check(g, "Hl.Ripple", b, y, "Ripple on every click")
        y += CursorMarker.ROW
        CursorMarker.Slider(g, "Hl.RippleMax", b, y, "Ripple size", "20-200", " px")
        y += CursorMarker.ROW
        CursorMarker.Slider(g, "Hl.RippleMs", b, y, "Ripple lasts", "120-1200", " ms")
        y += CursorMarker.ROW
        CursorMarker.Colour(g, "Hl.ColorL", b, y, "Left click")
        y += CursorMarker.ROW
        CursorMarker.Colour(g, "Hl.ColorM", b, y, "Middle click")
        y += CursorMarker.ROW
        CursorMarker.Colour(g, "Hl.ColorR", b, y, "Right click")
        y += CursorMarker.ROW
        CursorMarker.HotkeyRow(g, "Hl.HotToggle", b, y, "Show/hide key")
    }

    static BuildExportTab(g) {
        a := CursorMarker.COLA
        b := CursorMarker.COLB
        y := CursorMarker.TOP

        CursorMarker.Label(g, a, y, CursorMarker.LABW, "Script name")
        nameBox := g.Add("Edit", Format("x{} y{} w240 h24", a + CursorMarker.LABW + CursorMarker.GAP, y)
                       , MarkerConfig.Get("Exp.Name"))
        nameBox.OnEvent("Change", CursorMarker.onChange)
        CursorMarker.ctl["Exp.Name"] := nameBox
        y += CursorMarker.ROW + 8

        CursorMarker.Check(g, "Exp.Loupe", a, y, "Include the magnifier")
        y += CursorMarker.ROW
        CursorMarker.Check(g, "Exp.Highlight", a, y, "Include the mouse highlight")
        y += CursorMarker.ROW
        CursorMarker.Check(g, "Exp.Cursor", a, y, "Include the custom pointer")
        y += CursorMarker.ROW + 10

        gen := g.Add("Button", Format("x{} y{} w150 h32", a, y), "Generate script")
        gen.OnEvent("Click", ObjBindMethod(CursorMarker, "OnGenerate"))
        open := g.Add("Button", Format("x{} y{} w160 h32", a + 158, y), "Open export folder")
        open.OnEvent("Click", ObjBindMethod(CursorMarker, "OnOpenFolder"))

        py := CursorMarker.TOP
        CursorMarker.Label(g, b, py, CursorMarker.LABW, "Preset name")
        CursorMarker.presetName := g.Add("Edit", Format("x{} y{} w{} h24"
                                      , b + CursorMarker.LABW + CursorMarker.GAP, py, CursorMarker.CTRW), "Default")
        py += CursorMarker.ROW + 4
        savePreset := g.Add("Button", Format("x{} y{} w118 h28", b, py), "Save preset")
        savePreset.OnEvent("Click", ObjBindMethod(CursorMarker, "OnSavePreset"))
        loadPreset := g.Add("Button", Format("x{} y{} w118 h28", b + 126, py), "Load preset")
        loadPreset.OnEvent("Click", ObjBindMethod(CursorMarker, "OnLoadPreset"))
        py += CursorMarker.ROW + 4
        CursorMarker.Label(g, b, py, CursorMarker.LABW, "Saved presets")
        CursorMarker.presetList := g.Add("DropDownList", Format("x{} y{} w{} h240"
                                      , b + CursorMarker.LABW + CursorMarker.GAP, py, CursorMarker.CTRW))

        note := "Tick what you want, give it a name, then press Generate script. You get "
              . "a single .ahk file that runs on its own — this window does not have to "
              . "stay open, and you can copy that one file to another PC. A preset just "
              . "remembers every setting in this window so you can come back to it later."
        g.Add("Text", "x26 y244 w728 h46", note)

        g.Add("Text", "x26 y298 w728 h20 +0x200", "Log")
        CursorMarker.logBox := g.Add("Edit", "x26 y320 w728 h206 ReadOnly Multi +VScroll -Wrap")
    }


    static OnTabChange(*) {
        if !CursorMarker.FormAlive()
            return
        ; RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW
        DllCall("User32\RedrawWindow", "Ptr", CursorMarker.gui.Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x0185)
    }

    static Label(g, x, y, w, text) {
        return g.Add("Text", Format("x{} y{} w{} h24 +0x200", x, y, w), text)
    }

    static Slider(g, key, x, y, label, range, suffix) {
        CursorMarker.Label(g, x, y, CursorMarker.LABW, label)
        cx := x + CursorMarker.LABW + CursorMarker.GAP
        bar := g.Add("Slider", Format("x{} y{} w{} h24 Range{} ToolTip", cx, y, CursorMarker.CTRW, range))
        bar.Value := MarkerConfig.Num(key)
        bar.OnEvent("Change", CursorMarker.onChange)
        CursorMarker.ctl[key] := bar
        CursorMarker.readout[key] := CursorMarker.Label(g, cx + CursorMarker.CTRW + 8, y, CursorMarker.VALW, "")
        CursorMarker.suffix[key] := suffix
        return bar
    }

    ; Dropdowns read in plain English while still storing what the engines and
    ; the exporter expect, so wording can be softened without touching either.
    ; Pass `stored` when the two differ; otherwise the labels are the values.
    static Choice(g, key, x, y, label, list, stored := 0) {
        CursorMarker.Label(g, x, y, CursorMarker.LABW, label)
        cx := x + CursorMarker.LABW + CursorMarker.GAP
        box := g.Add("DropDownList", Format("x{} y{} w{} h240", cx, y, CursorMarker.CTRW), list)
        box.OnEvent("Change", CursorMarker.onChange)
        CursorMarker.ctl[key] := box
        CursorMarker.items[key] := list
        CursorMarker.values[key] := stored ? stored : list
        CursorMarker.SelectItem(key, MarkerConfig.Get(key))
        return box
    }

    static ChoiceValue(key) {
        stored := CursorMarker.values[key]
        index := CursorMarker.ctl[key].Value
        return (index >= 1 && index <= stored.Length) ? stored[index] : stored[1]
    }

    static Colour(g, key, x, y, label) {
        CursorMarker.Label(g, x, y, CursorMarker.LABW, label)
        cx := x + CursorMarker.LABW + CursorMarker.GAP
        box := g.Add("Edit", Format("x{} y{} w86 h24 Limit7", cx, y), MarkerColor.ToHex(MarkerConfig.RGB(key)))
        box.OnEvent("Change", CursorMarker.onChange)
        CursorMarker.ctl[key] := box
        pick := g.Add("Button", Format("x{} y{} w64 h24", cx + 92, y), "Pick…")
        pick.OnEvent("Click", ObjBindMethod(CursorMarker, "OnPickColour", key))
        return box
    }

    static Number(g, key, x, y, label, range) {
        CursorMarker.Label(g, x, y, CursorMarker.LABW, label)
        cx := x + CursorMarker.LABW + CursorMarker.GAP
        box := g.Add("Edit", Format("x{} y{} w{} h24", cx, y, CursorMarker.CTRW - 18))
        g.Add("UpDown", "Range" range, MarkerConfig.Num(key))
        box.OnEvent("Change", CursorMarker.onChange)
        CursorMarker.ctl[key] := box
        return box
    }

    static Check(g, key, x, y, label) {
        width := CursorMarker.LABW + CursorMarker.GAP + CursorMarker.CTRW
        box := g.Add("CheckBox", Format("x{} y{} w{} h24 Checked{}", x, y, width, MarkerConfig.Num(key)), label)
        box.OnEvent("Click", CursorMarker.onChange)
        CursorMarker.ctl[key] := box
        return box
    }

    static HotkeyRow(g, key, x, y, label) {
        CursorMarker.Label(g, x, y, CursorMarker.LABW, label)
        cx := x + CursorMarker.LABW + CursorMarker.GAP
        box := g.Add("Hotkey", Format("x{} y{} w{} h24", cx, y, CursorMarker.CTRW))
        box.Value := MarkerConfig.Get(key)
        box.OnEvent("Change", CursorMarker.onChange)
        CursorMarker.ctl[key] := box
        return box
    }

    ; Matches on the stored value, not the visible label, so an old preset keeps
    ; selecting the right row after wording changes.
    static SelectItem(key, value) {
        pick := 1
        for index, item in CursorMarker.values[key] {
            if (item = value)
                pick := index
        }
        CursorMarker.ctl[key].Value := pick
    }

    ; A hard kill (task manager, logoff, a crash) tears the window down before
    ; OnExit runs, and a destroyed control reads back empty instead of throwing.
    ; Reading the form is only meaningful while the window is still alive.
    static FormAlive() {
        if !CursorMarker.gui
            return false
        ; The Gui object outlives its window: after Destroy, .Hwnd throws rather
        ; than returning 0, so the lookup itself has to be guarded.
        try
            hwnd := CursorMarker.gui.Hwnd
        catch Error
            return false
        return DllCall("User32\IsWindow", "Ptr", hwnd, "Int") ? true : false
    }

    ; Every control is keyed by its own setting name, so reading the whole form
    ; back is one pass with no per-control wiring to fall out of sync. Returns
    ; false when there was nothing safe to read, so callers never persist junk.
    static Collect() {
        if !CursorMarker.FormAlive()
            return false
        for key, ctrl in CursorMarker.ctl {
            if (ctrl.Type = "DDL")
                MarkerConfig.Set(key, CursorMarker.ChoiceValue(key))
            else
                MarkerConfig.Set(key, ctrl.Value)
        }
        return true
    }

    static Fill() {
        for key, ctrl in CursorMarker.ctl {
            switch ctrl.Type {
                case "DDL":
                    CursorMarker.SelectItem(key, MarkerConfig.Get(key))
                case "Slider", "CheckBox":
                    ctrl.Value := MarkerConfig.Num(key)
                default:
                    ctrl.Value := MarkerConfig.Get(key)
            }
        }
    }

    static UpdateReadouts() {
        for key, label in CursorMarker.readout {
            value := CursorMarker.ctl[key].Value
            if (key = "Loupe.Zoom" || key = "Loupe.ZoomStep")
                label.Value := Format("{:.1f}x", value / 10)
            else
                label.Value := value CursorMarker.suffix[key]
        }
    }

    ; Sliders fire per tick, so the expensive half (re-rendering previews and
    ; rebuilding a running overlay) is debounced behind a one-shot timer.
    static HandleChange(*) {
        CursorMarker.Collect()
        CursorMarker.UpdateReadouts()
        SetTimer(CursorMarker.applyTimer, -180)
    }

    static ApplyLive(*) {
        CursorMarker.PushLoupe()
        CursorMarker.PushHighlight()
        if LoupeEngine.Active
            LoupeEngine.Refresh()
        if HighlightEngine.Active
            HighlightEngine.Refresh()
        CursorMarker.RefreshPreview()
        ; While the pointer is switched on, a design change should land on the
        ; real pointer too — otherwise the preview and the pointer disagree.
        if CursorPainter.applied {
            try
                CursorMarker.ApplyCursorNow()
            catch Error as err
                CursorMarker.Say("Could not update the pointer: " err.Message)
        }
        return 0
    }

    static PushLoupe() {
        LoupeEngine.LensSize := MarkerConfig.Num("Loupe.LensSize")
        LoupeEngine.Zoom := Round(MarkerConfig.Num("Loupe.Zoom") / 10, 1)
        LoupeEngine.BorderWidth := MarkerConfig.Num("Loupe.BorderWidth")
        LoupeEngine.BorderColor := MarkerConfig.RGB("Loupe.BorderColor")
        LoupeEngine.Interval := MarkerConfig.Num("Loupe.Interval")
        LoupeEngine.Shape := MarkerConfig.Get("Loupe.Shape")
        LoupeEngine.Follow := MarkerConfig.Get("Loupe.Follow")
        LoupeEngine.OffsetX := MarkerConfig.Num("Loupe.OffsetX")
        LoupeEngine.OffsetY := MarkerConfig.Num("Loupe.OffsetY")
        LoupeEngine.Corner := MarkerConfig.Get("Loupe.Corner")
        LoupeEngine.HideFromCapture := InStr(MarkerConfig.Get("Loupe.Capture"), "Hide") ? true : false
        LoupeEngine.Crosshair := MarkerConfig.Num("Loupe.Crosshair") ? true : false
        LoupeEngine.Smooth := MarkerConfig.Num("Loupe.Smooth") ? true : false
        LoupeEngine.ZoomStep := Round(MarkerConfig.Num("Loupe.ZoomStep") / 10, 1)
        LoupeEngine.WheelZoom := MarkerConfig.Num("Loupe.WheelZoom") ? true : false
        ; The hook lives with the running lens, so a mid-session toggle needs it re-read.
        if LoupeEngine.Active
            LoupeEngine.HookWheel(true)
    }

    static PushHighlight() {
        HighlightEngine.RingRadius := MarkerConfig.Num("Hl.RingRadius")
        HighlightEngine.RingWidth := MarkerConfig.Num("Hl.RingWidth")
        HighlightEngine.RingColor := MarkerConfig.RGB("Hl.RingColor")
        HighlightEngine.RingAlpha := MarkerConfig.Num("Hl.RingAlpha")
        HighlightEngine.ShowFill := MarkerConfig.Num("Hl.Fill") ? true : false
        HighlightEngine.FillColor := MarkerConfig.RGB("Hl.FillColor")
        HighlightEngine.FillAlpha := MarkerConfig.Num("Hl.FillAlpha")
        HighlightEngine.Ripple := MarkerConfig.Num("Hl.Ripple") ? true : false
        HighlightEngine.RippleMax := MarkerConfig.Num("Hl.RippleMax")
        HighlightEngine.RippleMs := MarkerConfig.Num("Hl.RippleMs")
        HighlightEngine.ColorL := MarkerConfig.RGB("Hl.ColorL")
        HighlightEngine.ColorM := MarkerConfig.RGB("Hl.ColorM")
        HighlightEngine.ColorR := MarkerConfig.RGB("Hl.ColorR")
        HighlightEngine.Interval := MarkerConfig.Num("Hl.Interval")
    }

    static CursorSpec() {
        spec := Map()
        spec["Shape"] := MarkerConfig.Get("Cur.Shape")
        spec["Size"] := Max(8, MarkerConfig.Num("Cur.Size"))
        spec["Fill"] := MarkerConfig.RGB("Cur.Fill")
        spec["Outline"] := MarkerConfig.RGB("Cur.Outline")
        spec["OutlineWidth"] := MarkerConfig.Num("Cur.OutlineWidth")
        spec["Alpha"] := MarkerConfig.Num("Cur.Alpha")
        spec["Halo"] := MarkerConfig.Num("Cur.Halo") ? true : false
        spec["HaloColor"] := MarkerConfig.RGB("Cur.HaloColor")
        spec["HaloAlpha"] := MarkerConfig.Num("Cur.HaloAlpha")
        spec["HotX"] := MarkerConfig.Num("Cur.HotX")
        spec["HotY"] := MarkerConfig.Num("Cur.HotY")
        return spec
    }

    ; "HBITMAP:*" makes AHK copy the bitmap, which leaves this side responsible
    ; for the handle it just rendered — hence the DeleteObject on each pass.
    static RefreshPreview() {
        if !CursorMarker.previewBig
            return
        spec := CursorMarker.CursorSpec()
        try {
            big := CursorPainter.RenderPreview(spec, 280, 0x141414, 0x1C1C1C)
            CursorMarker.previewBig.Value := "HBITMAP:*" big
            DllCall("Gdi32\DeleteObject", "Ptr", big)
            real := CursorPainter.RenderPreview(spec, 136, 0x141414, 0x1C1C1C, spec["Size"])
            CursorMarker.previewReal.Value := "HBITMAP:*" real
            DllCall("Gdi32\DeleteObject", "Ptr", real)
        } catch Error as err {
            CursorMarker.Say("Preview failed: " err.Message)
            return
        }
        CursorPainter.Hotspot(spec, &hx, &hy)
        CursorMarker.hotLabel.Value := Format("{}x{} px  ·  hotspot {},{}", spec["Size"], spec["Size"], hx, hy)
    }

    static OnLoupeStart(*) {
        CursorMarker.Collect()
        CursorMarker.PushLoupe()
        try
            LoupeEngine.Start()
        catch Error as err {
            CursorMarker.Say("Magnifier failed to start: " err.Message)
            return
        }
        CursorMarker.StartSync()
        CursorMarker.Say("Magnifier running. Ctrl+Wheel zooms, Ctrl+Shift+Wheel resizes.")
    }

    static OnLoupeStop(*) {
        LoupeEngine.Stop()
        CursorMarker.StopSync()
        CursorMarker.Say("Magnifier stopped.")
    }

    ; The wheel changes size and zoom behind the studio's back, so while the lens
    ; is up the two sliders that can move on their own are pulled back into line.
    ; Without this, touching any other control would push a stale size back onto
    ; the lens and undo whatever the wheel just did.
    static StartSync() {
        if !CursorMarker.syncTimer
            CursorMarker.syncTimer := ObjBindMethod(CursorMarker, "SyncFromLens")
        SetTimer(CursorMarker.syncTimer, 250)
    }

    static StopSync() {
        if CursorMarker.syncTimer
            SetTimer(CursorMarker.syncTimer, 0)
    }

    static SyncFromLens() {
        if !LoupeEngine.Active {
            CursorMarker.StopSync()
            return
        }
        CursorMarker.SyncSlider("Loupe.LensSize", LoupeEngine.LensSize)
        CursorMarker.SyncSlider("Loupe.Zoom", Round(LoupeEngine.Zoom * 10))
        CursorMarker.UpdateReadouts()
    }

    static SyncSlider(key, value) {
        ctrl := CursorMarker.ctl[key]
        if (ctrl.Value != value)
            ctrl.Value := value
        MarkerConfig.Set(key, ctrl.Value)
    }

    static OnHighlightStart(*) {
        CursorMarker.Collect()
        CursorMarker.PushHighlight()
        try
            HighlightEngine.Start()
        catch Error as err {
            CursorMarker.Say("Highlight failed to start: " err.Message)
            return
        }
        CursorMarker.Say("Highlight running. Click anywhere to see the ripples.")
    }

    static OnHighlightStop(*) {
        HighlightEngine.Stop()
        CursorMarker.Say("Highlight stopped.")
    }

    static OnPickColour(key, *) {
        box := CursorMarker.ctl[key]
        chosen := MarkerColor.Pick(CursorMarker.gui.Hwnd, MarkerColor.ToRGB(box.Value))
        box.Value := MarkerColor.ToHex(chosen)
        ; Assigning .Value in code does not raise Change, so drive the update here.
        CursorMarker.HandleChange()
    }

    static OnSaveCur(*) {
        CursorMarker.Collect()
        suggested := CursorMarker.exportDir "\" CursorMarker.SafeName(MarkerConfig.Get("Exp.Name")) ".cur"
        path := FileSelect("S16", suggested, "Save cursor", "Cursor files (*.cur)")
        if (path = "")
            return
        if !RegExMatch(path, "i)\.cur$")
            path .= ".cur"
        try
            CursorPainter.SaveCur(path, CursorMarker.CursorSpec())
        catch Error as err {
            CursorMarker.Say("Could not save: " err.Message)
            return
        }
        CursorMarker.Say("Cursor saved.")
        CursorMarker.Log("Cursor written: " path)
    }

    static CursorFilePath() =>
        CursorMarker.exportDir "\" CursorMarker.SafeName(MarkerConfig.Get("Exp.Name")) ".cur"

    static ApplyCursorNow() {
        path := CursorMarker.CursorFilePath()
        CursorPainter.SaveCur(path, CursorMarker.CursorSpec())
        CursorPainter.ApplySystem(path, MarkerConfig.Get("Cur.Target"))
        return path
    }

    ; One button for both directions, so there is never a state where the pointer
    ; has been changed and the way back is not the thing you just pressed.
    static OnToggleCursor(*) {
        CursorMarker.Collect()
        if CursorPainter.applied {
            CursorPainter.RestoreSystem()
            CursorMarker.RefreshCursorButton()
            CursorMarker.Say("Your normal pointer is back.")
            return
        }
        try
            path := CursorMarker.ApplyCursorNow()
        catch Error as err {
            CursorMarker.Say("Could not use that pointer: " err.Message)
            return
        }
        CursorMarker.RefreshCursorButton()
        CursorMarker.Log("Pointer applied to " MarkerConfig.Get("Cur.Target") ": " path)
        CursorMarker.Say("That is your pointer now — press the button again to undo it.")
    }

    static RefreshCursorButton() {
        if !CursorMarker.cursorToggle
            return
        CursorMarker.cursorToggle.Text := CursorPainter.applied
            ? "Stop using this pointer"
            : "Use this pointer"
    }

    static OnRestoreCursor(*) {
        CursorPainter.RestoreSystem()
        CursorMarker.RefreshCursorButton()
        CursorMarker.Say("System pointers restored from your own scheme.")
    }

    static OnGenerate(*) {
        CursorMarker.Collect()
        name := CursorMarker.SafeName(MarkerConfig.Get("Exp.Name"))
        parts := Map()
        parts["Name"] := name
        parts["Loupe"] := MarkerConfig.Num("Exp.Loupe")
        parts["Highlight"] := MarkerConfig.Num("Exp.Highlight")
        parts["Cursor"] := MarkerConfig.Num("Exp.Cursor")
        target := CursorMarker.exportDir "\" name ".ahk"
        try {
            if parts["Cursor"] {
                curPath := CursorMarker.exportDir "\" name ".cur"
                CursorPainter.SaveCur(curPath, CursorMarker.CursorSpec())
                parts["CursorFile"] := curPath
                CursorMarker.Log("Cursor written: " curPath)
            }
            ScriptExporter.Write(target, ScriptExporter.Build(parts))
        } catch Error as err {
            CursorMarker.Log("Export failed: " err.Message)
            CursorMarker.Say("Export failed: " err.Message)
            return
        }
        CursorMarker.Log("Script written: " target)
        CursorMarker.Say("Exported " name ".ahk — it runs on its own, nothing to copy beside it.")
    }

    static OnOpenFolder(*) {
        Run('explorer.exe "' CursorMarker.exportDir '"')
    }

    static OnSavePreset(*) {
        CursorMarker.Collect()
        name := CursorMarker.SafeName(CursorMarker.presetName.Value)
        path := CursorMarker.presetDir "\" name ".ini"
        try
            MarkerConfig.Save(path)
        catch Error as err {
            CursorMarker.Say("Could not save preset: " err.Message)
            return
        }
        CursorMarker.RefreshPresets()
        CursorMarker.SelectPreset(name)
        CursorMarker.Log("Preset saved: " path)
        CursorMarker.Say("Preset saved as " name)
    }

    static OnLoadPreset(*) {
        name := CursorMarker.presetList.Text
        if (name = "") {
            CursorMarker.Say("No preset selected.")
            return
        }
        if !MarkerConfig.Load(CursorMarker.presetDir "\" name ".ini") {
            CursorMarker.Say("That preset file has gone missing.")
            return
        }
        CursorMarker.Fill()
        CursorMarker.UpdateReadouts()
        CursorMarker.ApplyLive()
        CursorMarker.Say("Preset loaded: " name)
    }

    static RefreshPresets() {
        found := []
        pattern := CursorMarker.presetDir "\*.ini"
        Loop Files, pattern
            found.Push(RegExReplace(A_LoopFileName, "i)\.ini$"))
        CursorMarker.presetList.Delete()
        if found.Length
            CursorMarker.presetList.Add(found)
    }

    static SelectPreset(name) {
        try
            CursorMarker.presetList.Text := name
        catch Error as err
            OutputDebug("CursorMarker: preset " name " not in the list — " err.Message)
    }

    static OnReset(*) {
        MarkerConfig.Reset()
        CursorMarker.Fill()
        CursorMarker.UpdateReadouts()
        CursorMarker.ApplyLive()
        CursorMarker.Say("Back to defaults. Save settings to keep them.")
    }

    static OnSaveSettings(*) {
        CursorMarker.Collect()
        try
            MarkerConfig.Save(CursorMarker.iniPath)
        catch Error as err {
            CursorMarker.Say("Could not save: " err.Message)
            return
        }
        CursorMarker.Say("Saved to CursorMarker.ini")
    }

    static OnShow(*) {
        CursorMarker.gui.Show()
    }

    static OnClose(*) {
        ExitApp()
    }

    static Shutdown(*) {
        try {
            ; Never overwrite good settings with the readings of a dying window.
            if CursorMarker.Collect()
                MarkerConfig.Save(CursorMarker.iniPath)
            else
                OutputDebug("CursorMarker: window already gone at exit — settings left as they were.")
        } catch Error as err {
            OutputDebug("CursorMarker: settings not saved on exit — " err.Message)
        }
        LoupeEngine.Stop()
        HighlightEngine.Stop()
        if CursorPainter.applied
            CursorPainter.RestoreSystem()
        MarkerIcon.Release()
        CursorPainter.Shutdown()
        return 0
    }

    static Say(text) {
        if CursorMarker.status
            CursorMarker.status.Value := text
    }

    static Log(text) {
        if !CursorMarker.logBox
            return
        prefix := CursorMarker.logBox.Value = "" ? "" : "`r`n"
        CursorMarker.logBox.Value := CursorMarker.logBox.Value prefix FormatTime(A_Now, "HH:mm:ss") "  " text
    }

    static SafeName(text) {
        clean := RegExReplace(Trim(text), '[\\/:*?"<>|]', "-")
        return clean = "" ? "CursorMarker" : clean
    }
}
