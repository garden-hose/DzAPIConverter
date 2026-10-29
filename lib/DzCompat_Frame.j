// ============================================================================
// Compatibility shim: reimplements the Dz*/KK* Frame & UI natives on top of
// Reforged's real Blz* frame API, preserving the original integer-handle
// calling convention used by Dz-platform map scripts.
//
// FRAME REGISTRY (hybrid design):
//   - Sequential integer IDs (stable, isolated from the engine handle allocator)
//   - Reverse lookup by real handle id (needed for DzGetTriggerUIEventFrame)
//   - Name+context hash table so DzFrameFindByName works
//     reliably for both shim-created frames and frames created outside it.
//
// STATUS KEY:
//   [APPROX]     - closest available native; behavior may differ in edge cases
//   [UNVERIFIED] - plausible constant name following Blizzard's naming pattern
//   [PORT LIMITATION] - function has limitations that have no known solution
// ============================================================================

    globals
        constant integer DZCOMPAT_MAX_FRAMES = 8192
        framehandle array gDzCompatFrame
        integer gDzCompatFrameCount = 0
        // Reverse: real engine handle id -> our sequential Dz integer id
        hashtable gDzCompatReverseLookup = InitHashtable()
        // Name+context lookup so DzFrameFindByName
        // is reliable even for frames created outside this shim.
        hashtable gDzCompatNameContext = InitHashtable()

        // Frame tree bookkeeping. A real engine frame frees all of its children when it is
        // destroyed, so every Dz id whose frame lives under a shim-created parent must be
        // invalidated together with that parent; otherwise later calls on the child id
        // (DzFrameShow / DzDestroyFrame / ...) reach a freed engine object and crash the game.
        // parent id -> (0 = child count, 1..n = child ids); child id -> (-1 = parent id)
        hashtable gDzCompatFrameChildren = InitHashtable()
        integer array gDzCompatDestroyQueue
    // Frames queued by DzDestroyFrame; the engine-side destroy is deferred (see DzCompat_DeferDestroyFrame)
    framehandle array gDzCompatReapFrame
    integer array gDzCompatReapAge
    integer gDzCompatReapCount = 0
    timer gDzCompatReapTimer = null
    constant real DZCOMPAT_REAP_PERIOD = 0.1
    constant integer DZCOMPAT_REAP_TICKS = 5

        // Name -> trigger registration table for the string-based
        // DzFrameSetScript variants. JASS can't resolve "a function by this
        // string name" at runtime the way Dz's engine natively could, and
        // arrays of type `code` are not legal JASS at all (not a vJass-only
        // restriction - plain JASS itself disallows `code array`), so each
        // registered function gets its own pre-built trigger (with the code
        // already attached as an action) stored by a hash of its name; the
        // by-name variants below reuse that same trigger for whatever frame
        // event they're asked to hook, rather than trying to extract a raw
        // `code` value back out of storage. Callers must pre-register each
        // function once via DzCompat_RegisterFuncName before using it with
        // DzFrameSetScript/DzFrameSetScriptAsync.
        hashtable gDzCompatFuncTriggers = InitHashtable()
        hashtable gDzCompatFocusTrack = InitHashtable()
        // DzFrameSetModelScale: the scale factor already applied to a model frame (the dll multiplies, it does not set).
        hashtable gDzCompatModelScale = InitHashtable()
        // DzFrameGetPoint*: the anchors a map set, as it passed them (before any margin shift). Parent = frame id,
        // child = point * 8 + field (0 relative frame, 1 relative point, 2 x, 3 y); the key itself marks "set".
        hashtable gDzCompatFramePoints = InitHashtable()

        // Cached GameUI origin frame (see DzCompat_GetGameUI).
        framehandle gDzCompatGameUI = null
    	framehandle gDzStableParent = null
        framehandle gDzCompatEdgeOwner = null
        // Per frame id (gDzCompatFrameGeo): 0 width, 1 height (as the map requested them), 3 Dz anchor point,
        // 4 x, 5 y, 6 "anchored with DzFrameSetAbsolutePoint", 7 "moved from the edge owner to the GameUI so it
        // draws over the console", 8 "registered as a console cover", 9 "centred on the GameUI (DzFrameSetPoint
        // point 4 -> GameUI point 4, 0, 0)", 10 "text frame", 12 "index + 1 in the squeezed-panel list".
        hashtable gDzCompatFrameGeo = InitHashtable()
        // With DZCOMPAT_EDGE_SHIFT the frames are no longer children of the GameUI. A child of the GameUI that
        // sticks out of the 4:3 area is SQUEEZED into it (not cropped), any other parent draws it at its natural
        // size. Maps made for KK are laid out for the squeezed look, so with the edge owner some frames come out
        // too big and the frames placed on them no longer fit. DZCOMPAT_EDGE_FIT repeats the squeeze where the
        // layout needs it (see DzCompat_AbsApply).
        constant boolean DZCOMPAT_EDGE_FIT = true
        // The edge owner is drawn UNDER the console art (HumanUITile01-04, InventoryCover, ...). With
        // DZCOMPAT_EDGE_COVER_CONSOLE a frame that covers the whole bottom console bar (x 0..0.8, y 0..0.13) is
        // moved to the GameUI instead (clipped to 4:3, not shifted), which draws over the console but ALSO over
        // every frame left on the edge owner. Off by default: the console art is hidden instead (see below).
        constant boolean DZCOMPAT_EDGE_COVER_CONSOLE = false
        constant real DZCOMPAT_CONSOLE_COVER_X0 = 0.01
        constant real DZCOMPAT_CONSOLE_COVER_X1 = 0.79
        constant real DZCOMPAT_CONSOLE_COVER_Y0 = 0.01
        constant real DZCOMPAT_CONSOLE_COVER_Y1 = 0.13
        // Large panels and full-screen backdrops (area >= DZCOMPAT_COVER_MIN_AREA, overlapping the console art)
        // cannot be drawn over the console and stay unclipped at the same time, so while one of them is visible
        // the console art (ConsoleTopBar, ConsoleBottomBar, SimpleInventoryCover) is hidden. Set
        // DZCOMPAT_EDGE_HIDE_CONSOLE to false to keep the console art always visible.
        constant boolean DZCOMPAT_EDGE_HIDE_CONSOLE = true
        // Also hide the minimap and its buttons, the Info/Menu/Allies/Log buttons and the resource indicators.
        constant boolean DZCOMPAT_COVER_HIDE_HUD = true
        constant real DZCOMPAT_COVER_MIN_AREA = 0.1
        constant real DZCOMPAT_COVER_PERIOD = 0.1
        constant real DZCOMPAT_CONSOLE_BOTTOM_TOP = 0.2558
        constant real DZCOMPAT_CONSOLE_TOP_BOTTOM = 0.568
        integer array gDzCompatCoverId
        integer gDzCompatCoverCount = 0
        boolean array gDzCompatCoverHid
        timer gDzCompatCoverTimer = null
        integer array gDzCompatPanelFrame
        real array gDzCompatPanelA
        real array gDzCompatPanelB
        real array gDzCompatPanelNA
        real array gDzCompatPanelNB
        real array gDzCompatPanelY0
        real array gDzCompatPanelY1
        integer gDzCompatPanelCount = 0

        // [DESYNC FIX] counter for nameless frames (was GetRandomInt, which advances the shared RNG)
        integer gDzCompatFrameGenCount = 0

        // (frame id, event id) -> the trigger DzFrameSetScriptByCode built for it.
        // DzAPI keeps ONE script per frame and event, so setting it again must replace
        // the earlier one instead of stacking a second callback on top of it.
        hashtable gDzCompatFrameEvt = InitHashtable()

        // ---- single-line TEXT frame auto-fit -------------------------------
        // A Dz TEXT frame never wraps or clips: a label longer than the width the map gave
        // it just draws past the edge. A Reforged TEXT frame wraps at its width, and on a
        // one-line-tall frame the wrapped text ends up clipped, so a longer label shows as
        // blank (seen with "Critical Hit Damage:140%" in a .1 x .01 frame). To keep Dz
        // behaviour, DzCompat_TextFit widens such a frame to its text. It only ever grows
        // the width, it keeps the text where the map put it (see DzCompat_TextFit), and it
        // leaves tall (multi-line) frames and text that contains a line break alone.
        // Per-frame data lives in gDzCompatTextFit, keyed by Dz frame id:
        //   0 isText   1 requested w   2 requested h   3 map called DzFrameSetSize
        //   4 point kind (0 none, 1 absolute, 2 relative)   5 point   6 relative frame id
        //   7 relative point   8 x   9 y   11 frame has more than one anchor (skip it)
        //   12 font height (0 = default)   13 horizontal justify (0 = default, left)
        //   15 width last applied
        hashtable gDzCompatTextFit = InitHashtable()
        // DzFrameSetTextAlignment: Dz frame id -> 0 vertical, 1 horizontal (ConvertTextAlignType indices)
        hashtable gDzCompatTextAlign = InitHashtable()
        // Set to false to turn the auto-fit off.
        constant boolean DZCOMPAT_TEXT_AUTOFIT = true
        // Estimated width of one character, as a fraction of the font height. Measured
        // loosely: 24 characters did not fit a .1 wide frame at the default font size and
        // 21 did, i.e. about .0042-.0048 per character, so .5 (= .005) errs slightly wide.
        // A frame that is too wide is harmless; one that is too narrow wraps.
        constant real DZCOMPAT_TEXT_CHAR_W_RATIO = 0.50
        // Font height assumed when the map never called DzFrameSetFont.
        constant real DZCOMPAT_TEXT_DEFAULT_FONT_H = 0.01
        // A frame taller than this many font heights is a deliberate multi-line box and is
        // not touched.
        constant real DZCOMPAT_TEXT_MAX_LINES_H = 2.5

        // ---- click handling ------------------------------------------------
        // In Reforged a click on a frame is reported as CONTROL_CLICK (1), as MOUSE_UP (4),
        // or as both in the same instant, depending on the frame's type and template. Dz
        // maps use 1 or 4 for "the frame was clicked". So both are registered, and the
        // gate below lets the first one through and drops its twin.
        boolexpr gDzCompatClickCond = null
        // was a single (frame, time) pair shared by every player - see
        // DzCompat_ClickGate. Keyed fid -> playerId -> last-accepted-click time, so two
        // different players clicking the same shared frame within the window are told
        // apart instead of the second player's real click being dropped as if it were
        // the first player's CONTROL_CLICK/MOUSE_UP twin.
        hashtable gDzCompatClickTimes = InitHashtable()
        timer gDzCompatClickClock = null
        // Two click events for the same frame closer together than this are one click.
        constant real DZCOMPAT_CLICK_WINDOW = 0.20
        // Dz ignores the alpha byte of a |cAARRGGBB colour code, and many maps write |c00RRGGBB
        // (alpha 00). Reforged honours it, so that text is drawn fully transparent. When true,
        // DzFrameSetText and DzFrameAddText turn every |c00 into |cff. Set to false to keep the
        // text exactly as the map wrote it.
        constant boolean DZCOMPAT_TEXT_FIX_ALPHA = true

        // A frame of type BUTTON that inherits no template does not report clicks in
        // Reforged (it still reports mouse enter/leave); GLUETEXTBUTTON does. When true,
        // DzCreateFrameByTagName falls back to GLUETEXTBUTTON for such a BUTTON.
        constant boolean DZCOMPAT_BUTTON_AS_GLUE_BUTTON = true
        // The screen-edge fix. A frame whose parent is the GameUI is not drawn once it lies outside
        // the 4:3 area, so with this on (1) a Dz anchor to the GameUI is widened by the margin the
        // real screen has beside the 4:3 area (DzCompat_AnchorX), (2) frames the map creates under
        // the GameUI get DZCOMPAT_EDGE_OWNER as their parent instead, and (3) the hero bar proxy
        // follows the real hero button. The placement test showed that children of
        // ConsoleUIBackdrop are drawn at the screen edge, while children of the GameUI, the world
        // frame, ConsoleUI, ConsoleTopBar, ConsoleBottomBar and the hero button are not.
        constant boolean DZCOMPAT_EDGE_SHIFT = true
        constant string DZCOMPAT_EDGE_OWNER = "ConsoleUIBackdrop"

		// ---- deferred hover registration -----------------------------------
		// FRAMEEVENT_MOUSE_ENTER/MOUSE_LEAVE silently never fire if the native
		// registration happens before the game has actually finished loading - a
		// documented Reforged engine timing bug. A converted map's own UI setup
		// frequently runs from its config/init function, which is exactly that window,
		// so hover registration is queued here and the real BlzTriggerRegisterFrameEvent
		// call is made from a single 0-second timer instead of at call time. Click and
		// every other frame event are unaffected by this bug and keep registering
		// immediately (see DzCompat_RegisterFrameEvents below).
		boolean gDzCompatHoverDeferArmed = false
		boolean gDzCompatHoverDeferReady = false
		trigger array gDzCompatHoverDeferTrig
		framehandle array gDzCompatHoverDeferFrame
		integer array gDzCompatHoverDeferEvent
		integer gDzCompatHoverDeferCount = 0
		// ---- DzGetMouseFocus -------------------------------------------------
		// There's no native that reports a generic "focused UI element id"; this instead
		// tracks the handle id of whichever hover-registered frame (see
		// DzCompat_RegisterHoverEvent below) the mouse most recently entered, which is
		// [APPROX] but real for exactly the frames a map wires up for hover - the only
		// ones "focus" is ever likely to be asked about.
		integer gDzCompatMouseFocusId = 0
    // CLICKFIX_MODE 3: clear the clicked frame's focus 0.05s after the click, outside the click event
    framehandle array gDzCompatFixFrame
    integer gDzCompatFixCount = 0
    timer gDzCompatFixTimer = null
    // HOVER VIA TOOLTIP: Reforged has a long-standing engine bug (reported since 1.33) where script-registered
    // MOUSE_ENTER / MOUSE_LEAVE on glue buttons loop forever and make the cursor jump. With this on, hover is
    // detected without those events: every hover-registered frame gets an invisible tooltip frame, the engine
    // shows it while the frame is hovered, and a poll timer turns its visibility changes into ENTER / LEAVE.
    constant boolean DZCOMPAT_HOVER_VIA_TOOLTIP = true
    framehandle array gDzCompatHoverTip
    hashtable gDzCompatHoverState = InitHashtable()
    integer array gDzCompatHoverWatchId
    integer gDzCompatHoverWatchCount = 0
    timer gDzCompatHoverPollTimer = null
    // A LEAVE only counts as real once no further LEAVE for the same frame arrives within this many seconds:
    // while the cursor sits on a hover-registered frame Reforged keeps sending LEAVE every ~0.1s.
    constant real DZCOMPAT_HOVER_LEAVE_QUIET = 0.3
    timer gDzCompatHoverClock = null
    // HOVER ONE-SHOT: Reforged keeps re-firing LEAVE/ENTER on a frame that has a script-registered
    // MOUSE_ENTER while the cursor sits on it, and the cursor flickers with it. With this on, a frame's
    // ENTER registration is dropped right after it fires and re-created when the mouse leaves.
    constant boolean DZCOMPAT_HOVER_ONESHOT = false
    // 0 = disable/enable the clicked frame (flips the engine hover state once per click),
    // 1 = nothing, 3 = clear the frame's keyboard focus 0.05s after the click (default; clearing it inside the click event breaks later calls on frames that have a tooltip)
    constant integer DZCOMPAT_CLICKFIX_MODE = 3
    code gDzCompatHoverRelayCode
    code gDzCompatHoverEnterCode
    integer array gDzCompatHoverDisarmId
    integer gDzCompatHoverDisarmCount = 0
    timer gDzCompatHoverDisarmTimer = null
    // DzFrameSetSize coalescing: several resizes of one frame in the same tick collapse into the
    // last one, and a resize that leaves the size unchanged is dropped. In Reforged every
    // BlzFrameSetSize relayouts the frame and re-fires MOUSE_LEAVE/MOUSE_ENTER while the cursor is over it.
    // Map hover handlers that resize in response (via DzSyncData round trips) therefore loop forever.
    // keys per frame id: 0/1 = last applied w/h, 2/3 = pending w/h, boolean 4 = pending
    hashtable gDzCompatSizeCache = InitHashtable()
    integer array gDzCompatSizePendingId
    integer gDzCompatSizePendingCount = 0
    timer gDzCompatSizeTimer = null
    hashtable gDzCompatHoverPending = InitHashtable()
    integer array gDzCompatHoverPendingId
    integer gDzCompatHoverPendingCount = 0
    timer gDzCompatHoverFlushTimer = null
    boolean gDzCompatHoverOverride = false
    integer gDzCompatHoverOverrideId = 0
    endglobals

    // ---- internal focus-tracking helper ----
    function DzCompat_TrackFocus takes integer frame, boolean state returns nothing
        call SaveBoolean(gDzCompatFocusTrack, frame, 0, state)
    endfunction

    // ---- internal handle registry (hybrid sequential + name/context) ------
    // Sequential IDs keep the integer space stable and isolated from the
    // engine's handle allocator. Reverse lookup by real handle id is required
    // for DzGetTriggerUIEventFrame. Name+context hashing makes 
	// DzFrameFindByName work for frames created outside the shim.
    function DzCompat_RegisterFrame takes framehandle f returns integer
        local integer id
        if f == null then
            return 0
        endif
        set id = LoadInteger(gDzCompatReverseLookup, GetHandleId(f), 0)
        if id != 0 then
            return id
        endif
        set gDzCompatFrameCount = gDzCompatFrameCount + 1
        set id = gDzCompatFrameCount
        set gDzCompatFrame[id] = f
        call SaveInteger(gDzCompatReverseLookup, GetHandleId(f), 0, id)
        return id
    endfunction

    function DzCompat_RegisterFrameNamed takes framehandle f, string name, integer context returns integer
        local integer id = DzCompat_RegisterFrame(f)
        if id != 0 and name != null and name != "" then
            call SaveInteger(gDzCompatNameContext, StringHash(name + I2S(context)), 0, id)
        endif
        return id
    endfunction

    function DzCompat_GetFrame takes integer id returns framehandle
        if id <= 0 or id > gDzCompatFrameCount then
            return null
        endif
        return gDzCompatFrame[id]
    endfunction

    function DzCompat_HoverRearm takes integer id returns nothing
        local framehandle f = DzCompat_GetFrame(id)
        local trigger t
        if not DZCOMPAT_HOVER_ONESHOT or f == null or gDzCompatHoverRelayCode == null or gDzCompatHoverEnterCode == null then
            set f = null
            return
        endif
        if LoadTriggerHandle(gDzCompatFrameEvt, id, 2) != null or LoadTriggerHandle(gDzCompatFrameEvt, id, 22) == null then
            set f = null
            return
        endif
        set t = CreateTrigger()
        call TriggerAddAction(t, gDzCompatHoverEnterCode)
        call TriggerAddAction(t, gDzCompatHoverRelayCode)
        call BlzTriggerRegisterFrameEvent(t, f, ConvertFrameEventType(2))
        call SaveTriggerHandle(gDzCompatFrameEvt, id, 2, t)
        set t = null
        set f = null
    endfunction

    function DzCompat_HoverDisarmFlush takes nothing returns nothing
        local integer i = 0
        local integer n = gDzCompatHoverDisarmCount
        local integer id
        local trigger t
        set gDzCompatHoverDisarmCount = 0
        loop
            exitwhen i >= n
            set id = gDzCompatHoverDisarmId[i]
            set t = LoadTriggerHandle(gDzCompatFrameEvt, id, 2)
            if t != null and DzCompat_GetFrame(id) != null then
                call DestroyTrigger(t)
                call RemoveSavedHandle(gDzCompatFrameEvt, id, 2)
            endif
            set i = i + 1
        endloop
        set t = null
    endfunction

    // Record that frame id `child` was created under the shim-created frame id `parent`.
    function DzCompat_FrameAddChild takes integer parent, integer child returns nothing
        local integer n
        if parent <= 0 or child <= 0 or parent == child then
            return
        endif
        set n = LoadInteger(gDzCompatFrameChildren, parent, 0) + 1
        call SaveInteger(gDzCompatFrameChildren, parent, 0, n)
        call SaveInteger(gDzCompatFrameChildren, parent, n, child)
        call SaveInteger(gDzCompatFrameChildren, child, -1, parent)
    endfunction

    // Forget that `child` hangs under its recorded parent (used by DzFrameSetParent).
    function DzCompat_FrameRemoveChild takes integer child returns nothing
        local integer parent = LoadInteger(gDzCompatFrameChildren, child, -1)
        local integer n
        local integer i = 1
        if parent <= 0 then
            return
        endif
        set n = LoadInteger(gDzCompatFrameChildren, parent, 0)
        loop
            exitwhen i > n
            if LoadInteger(gDzCompatFrameChildren, parent, i) == child then
                call SaveInteger(gDzCompatFrameChildren, parent, i, 0)
                exitwhen true
            endif
            set i = i + 1
        endloop
        call RemoveSavedInteger(gDzCompatFrameChildren, child, -1)
    endfunction

    // Destroy ONE frame id and drop every table entry that refers to it. Callers must have
    // already released its descendants (see DzDestroyFrame).
    function DzCompat_ReapTick takes nothing returns nothing
        local integer i = 0
        local integer j = 0
        loop
            exitwhen i >= gDzCompatReapCount
            set gDzCompatReapAge[i] = gDzCompatReapAge[i] - 1
            if gDzCompatReapAge[i] <= 0 then
                call BlzDestroyFrame(gDzCompatReapFrame[i])
                set gDzCompatReapFrame[i] = null
            else
                if i != j then
                    set gDzCompatReapFrame[j] = gDzCompatReapFrame[i]
                    set gDzCompatReapAge[j] = gDzCompatReapAge[i]
                    set gDzCompatReapFrame[i] = null
                endif
                set j = j + 1
            endif
            set i = i + 1
        endloop
        set gDzCompatReapCount = j
        if j == 0 and gDzCompatReapTimer != null then
            call PauseTimer(gDzCompatReapTimer)
        endif
    endfunction

    function DzCompat_DeferDestroyFrame takes framehandle f returns nothing
        if f == null then
            return
        endif
        call BlzFrameSetVisible(f, false)
        call BlzFrameSetEnable(f, false)
        if gDzCompatReapCount >= 4000 then
            call BlzDestroyFrame(f)
            return
        endif
        set gDzCompatReapFrame[gDzCompatReapCount] = f
        set gDzCompatReapAge[gDzCompatReapCount] = DZCOMPAT_REAP_TICKS
        set gDzCompatReapCount = gDzCompatReapCount + 1
        if gDzCompatReapTimer == null then
            set gDzCompatReapTimer = CreateTimer()
        endif
        if gDzCompatReapCount == 1 then
            call TimerStart(gDzCompatReapTimer, DZCOMPAT_REAP_PERIOD, true, function DzCompat_ReapTick)
        endif
    endfunction

    function DzCompat_ReleaseFrame takes integer frame, boolean root returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        local integer eventId = 1
        local trigger trig
        if f == null then
            return
        endif
        loop
            exitwhen eventId > 40
            set trig = LoadTriggerHandle(gDzCompatFrameEvt, frame, eventId)
            if trig != null then
                call DestroyTrigger(trig)
            endif
            set eventId = eventId + 1
        endloop
        call FlushChildHashtable(gDzCompatFrameEvt, frame)
        call FlushChildHashtable(gDzCompatFocusTrack, frame)
        call FlushChildHashtable(gDzCompatTextFit, frame)
        call FlushChildHashtable(gDzCompatSizeCache, frame)
        call FlushChildHashtable(gDzCompatFrameGeo, frame)
        call FlushChildHashtable(gDzCompatHoverPending, frame)
        if gDzCompatHoverTip[frame] != null then
            call BlzDestroyFrame(gDzCompatHoverTip[frame])
            set gDzCompatHoverTip[frame] = null
        endif
        call FlushChildHashtable(gDzCompatFrameChildren, frame)
        call RemoveSavedInteger(gDzCompatReverseLookup, GetHandleId(f), 0)
        set gDzCompatFrame[frame] = null
        if root then
            // Destroying a frame the mouse is over (or was just over) can leave the engine's hover
            // tracking pointing at freed memory. Hide it now and destroy it a few ticks later;
            // descendants are freed together with this root.
            call DzCompat_DeferDestroyFrame(f)
        endif
        set trig = null
        set f = null
    endfunction
	
    // Lazily fetch and cache the GameUI origin frame. BlzGetOriginFrame is
    // cheap, but caching avoids a native call per frame-position call.
    function DzCompat_GetGameUI takes nothing returns framehandle
        if gDzCompatGameUI == null then
            set gDzCompatGameUI = BlzGetOriginFrame(ORIGIN_FRAME_GAME_UI, 0)
        endif
        return gDzCompatGameUI
    endfunction

    function DzCompat_GetRefFrame takes nothing returns framehandle
        return DzCompat_GetGameUI()
    endfunction

    // In KKAPI/Dz the GameUI frame spans the WHOLE screen, so x = 0 relative to it is the screen
    // edge. In Reforged the GameUI origin frame is only the centred 4:3 area (0.8 x 0.6), so on a
    // widescreen display x = 0 lands inside the screen (12.5% in on 16:9). Reforged will not take
    // an absolute point outside 0..0.8 (the frame falls back to filling its parent), and neither
    // the world frame nor a child frame reaches further than the GameUI. What does work is an
    // offset relative to the GameUI, so a Dz anchor to the GameUI is widened by the margin the
    // real screen has on each side of the 4:3 area: left-edge points move left, right-edge
    // points move right, centre points stay.
    // The margin is read from the client size (height is 0.6 units, so width = 0.6 * w / h).
    function DzCompat_ScreenMargin takes nothing returns real
        local integer cw = BlzGetLocalClientWidth()
        local integer ch = BlzGetLocalClientHeight()
        local real m
        if cw <= 0 or ch <= 0 then
            return 0.
        endif
        set m = (0.6 * I2R(cw) / I2R(ch) - 0.8) / 2.
        if m < 0. then
            return 0.
        endif
        return m
    endfunction

    // The frame that owns frames a map creates under the GameUI: DZCOMPAT_EDGE_OWNER when the
    // edge fix is on and that frame exists, the GameUI itself otherwise.
    function DzCompat_EdgeOwner takes nothing returns framehandle
        if not DZCOMPAT_EDGE_SHIFT then
            return DzCompat_GetGameUI()
        endif
        if gDzCompatEdgeOwner == null then
            set gDzCompatEdgeOwner = BlzGetFrameByName(DZCOMPAT_EDGE_OWNER, 0)
            if gDzCompatEdgeOwner == null then
                set gDzCompatEdgeOwner = DzCompat_GetGameUI()
            endif
        endif
        return gDzCompatEdgeOwner
    endfunction

    // The x offset to use for an anchor to frame r at relativePoint (0..8, Dz numbering: 0 top-
    // left, 1 top, 2 top-right, 3 left, 4 centre, 5 right, 6 bottom-left, 7 bottom, 8 bottom-
    // right). Anything but the GameUI is returned unchanged, and so is everything while
    // DZCOMPAT_EDGE_SHIFT is false.
    function DzCompat_AnchorX takes framehandle r, integer relativePoint, real x returns real
        if r != DzCompat_GetGameUI() then
            return x
        endif
        if not DZCOMPAT_EDGE_SHIFT then
            return x
        endif
        if relativePoint == 0 or relativePoint == 3 or relativePoint == 6 then
            return x - DzCompat_ScreenMargin()
        elseif relativePoint == 2 or relativePoint == 5 or relativePoint == 8 then
            return x + DzCompat_ScreenMargin()
        endif
        return x
    endfunction

    // Fraction of the width (0 left, 0.5 centre, 1 right) at which a Dz anchor point (0..8) sits.
    function DzCompat_PointFX takes integer point returns real
        if point == 1 or point == 4 or point == 7 then
            return 0.5
        elseif point == 2 or point == 5 or point == 8 then
            return 1.
        endif
        return 0.
    endfunction

    // Fraction of the height, measured from the bottom, at which a Dz anchor point (0..8) sits.
    function DzCompat_PointFY takes integer point returns real
        if point <= 2 then
            return 1.
        elseif point <= 5 then
            return 0.5
        endif
        return 0.
    endfunction

    // A frame as big as the Dz screen (0.8 x 0.6 or more) and centred on the GameUI is a full-screen
    // backdrop: the 4:3 GameUI squeezes it to 0.8 x 0.6, so on the edge owner it is given that height
    // and the width of the real screen (0.8 + 2 * margin).
    function DzCompat_IsFullScreen takes integer frame, real w, real h returns boolean
        if not (DZCOMPAT_EDGE_SHIFT and DZCOMPAT_EDGE_FIT) then
            return false
        endif
        if not LoadBoolean(gDzCompatFrameGeo, frame, 9) or w < 0.799 or h < 0.599 then
            return false
        endif
        return DzCompat_EdgeOwner() != DzCompat_GetGameUI()
    endfunction

    // Visible on screen: the frame and all its parents are visible and the frame is not fully transparent.
    function DzCompat_EffVisible takes framehandle f returns boolean
        local framehandle p = f
        local integer n = 0
        loop
            exitwhen p == null or p == DzCompat_EdgeOwner() or p == DzCompat_GetGameUI() or n >= 24
            if not BlzFrameIsVisible(p) then
                set p = null
                return false
            endif
            set p = BlzFrameGetParent(p)
            set n = n + 1
        endloop
        set p = null
        return BlzFrameGetAlpha(f) > 0
    endfunction

    function DzCompat_CoverApplyOne takes integer slot, framehandle f, boolean hide returns nothing
        if f != null then
            if hide then
                if BlzFrameIsVisible(f) then
                    call BlzFrameSetVisible(f, false)
                    call BlzFrameSetAlpha(f, 0)
                    set gDzCompatCoverHid[slot] = true
                endif
            elseif gDzCompatCoverHid[slot] then
                set gDzCompatCoverHid[slot] = false
                call BlzFrameSetAlpha(f, 255)
                call BlzFrameSetVisible(f, true)
            endif
        endif
    endfunction

    // Hides the console art (and, with DZCOMPAT_COVER_HIDE_HUD, the minimap, system buttons and resource
    // bar) while a registered cover is visible and restores it afterwards.
    function DzCompat_CoverTick takes nothing returns nothing
        local integer i = 0
        local boolean any = false
        local framehandle f
        loop
            exitwhen i >= gDzCompatCoverCount or any
            set f = DzCompat_GetFrame(gDzCompatCoverId[i])
            if f != null and DzCompat_EffVisible(f) then
                set any = true
            endif
            set i = i + 1
        endloop
        set f = null
        call DzCompat_CoverApplyOne(0, BlzGetFrameByName("ConsoleTopBar", 0), any)
        call DzCompat_CoverApplyOne(1, BlzGetFrameByName("ConsoleBottomBar", 0), any)
        call DzCompat_CoverApplyOne(2, BlzGetFrameByName("SimpleInventoryCover", 0), any)
        if DZCOMPAT_COVER_HIDE_HUD then
            // minimap and its buttons
            call DzCompat_CoverApplyOne(3, BlzGetOriginFrame(ORIGIN_FRAME_MINIMAP, 0), any)
            set i = 0
            loop
                exitwhen i > 4
                call DzCompat_CoverApplyOne(4 + i, BlzGetOriginFrame(ORIGIN_FRAME_MINIMAP_BUTTON, i), any)
                set i = i + 1
            endloop
            // Info, Menu, Allies, Log
            set i = 0
            loop
                exitwhen i > 3
                call DzCompat_CoverApplyOne(9 + i, BlzGetOriginFrame(ORIGIN_FRAME_SYSTEM_BUTTON, i), any)
                set i = i + 1
            endloop
            call DzCompat_CoverApplyOne(13, BlzGetFrameByName("UpperButtonBarFrame", 0), any)
            // resource indicators (gold, lumber, food, upkeep)
            call DzCompat_CoverApplyOne(14, BlzGetFrameByName("ResourceBarFrame", 0), any)
        endif
    endfunction

    function DzCompat_CoverRegister takes integer frame returns nothing
        if not DZCOMPAT_EDGE_HIDE_CONSOLE or gDzCompatCoverCount >= 64 or LoadBoolean(gDzCompatFrameGeo, frame, 8) then
            return
        endif
        call SaveBoolean(gDzCompatFrameGeo, frame, 8, true)
        set gDzCompatCoverId[gDzCompatCoverCount] = frame
        set gDzCompatCoverCount = gDzCompatCoverCount + 1
        if gDzCompatCoverTimer == null then
            set gDzCompatCoverTimer = CreateTimer()
            call TimerStart(gDzCompatCoverTimer, DZCOMPAT_COVER_PERIOD, true, function DzCompat_CoverTick)
        endif
    endfunction

    // Remembers a panel that the 4:3 GameUI would squeeze: [a, b] is the squeezed x range, [na, nb] the
    // natural one, y0..y1 its height.
    function DzCompat_PanelAdd takes integer frame, real a, real b, real na, real nb, real y0, real y1 returns nothing
        local integer i = LoadInteger(gDzCompatFrameGeo, frame, 12) - 1
        if i < 0 then
            if gDzCompatPanelCount >= 8 then
                return
            endif
            set i = gDzCompatPanelCount
            set gDzCompatPanelCount = i + 1
            call SaveInteger(gDzCompatFrameGeo, frame, 12, i + 1)
        endif
        set gDzCompatPanelFrame[i] = frame
        set gDzCompatPanelA[i] = a
        set gDzCompatPanelB[i] = b
        set gDzCompatPanelNA[i] = na
        set gDzCompatPanelNB[i] = nb
        set gDzCompatPanelY0[i] = y0
        set gDzCompatPanelY1[i] = y1
    endfunction

    // Horizontal move of text frames. They move left by about 5% of 
	// the 4:3 width (0.3 * margin = 0.04 at 16:9, 0 at 4:3).
    function DzCompat_TextShiftExtra takes framehandle f, real x, real y returns real
        local string n = StringCase(BlzFrameGetName(f), false)
        if x > 0.125 and x < 0.135 and y > 0.115 and y < 0.125 then
            return -0.3 * DzCompat_ScreenMargin()
        endif
        return 0.
    endfunction

    // Places a frame that the map anchored with DzFrameSetAbsolutePoint (called again whenever its size
    // changes, because the placement depends on it). On the edge owner:
    //  1. (DZCOMPAT_EDGE_COVER_CONSOLE, off by default) a frame covering the whole bottom console bar moves to the GameUI;
    //  2. a frame that sticks out of the 4:3 area by 25% or more of its squeezed width is remembered as a
    //     squeezed panel; a frame that lies inside the squeezed part of an earlier panel is stretched with
    //     the panel (the 4:3 GameUI would have squeezed both);
    //  2b. a text frame whose left edge lies on a squeezed panel (up to 0.1 above or below it) is moved with
    //     it (position only, the size is left to the text fit);
    //  3. every frame is cut to the real screen, as the GameUI would do (a squeezed panel keeps its height:
    //     it is a decoration that is meant to run off the screen);
    //  4. a large frame over the console art is registered so the console art is hidden while it is shown.
    function DzCompat_AbsApply takes integer frame returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        local framehandle par
        local integer point
        local integer i
        local real x
        local real y
        local real w
        local real h
        local real m = DzCompat_ScreenMargin()
        local real x0
        local real y0
        local real x1
        local real y1
        local real ox0
        local real ox1
        local real oy0
        local real oy1
        local real a
        local real b
        local real k
        local real nw
        local real nh
        local boolean cover = false
        local boolean mapped = false
        local boolean isPanel = false
        local boolean found = false
        local real extra
        local real tx0
        local real tol
        local integer pass
        if f == null or not LoadBoolean(gDzCompatFrameGeo, frame, 6) then
            return
        endif
        set point = LoadInteger(gDzCompatFrameGeo, frame, 3)
        set x = LoadReal(gDzCompatFrameGeo, frame, 4)
        set y = LoadReal(gDzCompatFrameGeo, frame, 5)
        set w = LoadReal(gDzCompatFrameGeo, frame, 0)
        set h = LoadReal(gDzCompatFrameGeo, frame, 1)
        set nw = w
        set nh = h
        set ox0 = x - w * DzCompat_PointFX(point)
        set oy0 = y - h * DzCompat_PointFY(point)
        set ox1 = ox0 + w
        set oy1 = oy0 + h
        if DZCOMPAT_EDGE_SHIFT and DzCompat_EdgeOwner() != DzCompat_GetGameUI() then
            if DZCOMPAT_EDGE_COVER_CONSOLE and w > 0. and h > 0. then
                set cover = ox0 <= DZCOMPAT_CONSOLE_COVER_X0 and ox1 >= DZCOMPAT_CONSOLE_COVER_X1 and oy0 <= DZCOMPAT_CONSOLE_COVER_Y0 and oy1 >= DZCOMPAT_CONSOLE_COVER_Y1
            endif
            set par = BlzFrameGetParent(f)
            if cover and par == DzCompat_EdgeOwner() then
                call BlzFrameSetParent(f, DzCompat_GetGameUI())
                call SaveBoolean(gDzCompatFrameGeo, frame, 7, true)
            elseif not cover and LoadBoolean(gDzCompatFrameGeo, frame, 7) and par == DzCompat_GetGameUI() then
                call BlzFrameSetParent(f, DzCompat_EdgeOwner())
                call SaveBoolean(gDzCompatFrameGeo, frame, 7, false)
            endif
            if w > 0. and h > 0. and BlzFrameGetParent(f) == DzCompat_EdgeOwner() then
                if DZCOMPAT_EDGE_FIT and not LoadBoolean(gDzCompatFrameGeo, frame, 10) then
                    set x0 = ox0
                    set x1 = ox1
                    set y0 = oy0
                    set y1 = oy1
                    // squeezed panel: remember it, or stretch a frame that lies on an earlier one
                    set a = -1.
                    set b = -1.
                    if ox0 < -0.01 and ox1 > 0.01 and (ox1 - ox0) / ox1 >= 1.25 then
                        set a = 0.
                        set b = ox1
                    elseif ox1 > 0.81 and ox0 < 0.79 and (ox1 - ox0) / (0.8 - ox0) >= 1.25 then
                        set a = ox0
                        set b = 0.8
                    endif
                    if b >= 0. then
                        call DzCompat_PanelAdd(frame, a, b, ox0, ox1, oy0, oy1)
                        set isPanel = true
                    else
                        set i = 0
                        loop
                            exitwhen i >= gDzCompatPanelCount or mapped
                            if gDzCompatPanelFrame[i] != frame and ox0 >= gDzCompatPanelA[i] - 0.0001 and ox1 <= gDzCompatPanelB[i] + 0.0001 and oy1 > gDzCompatPanelY0[i] and oy0 < gDzCompatPanelY1[i] then
                                set k = (gDzCompatPanelNB[i] - gDzCompatPanelNA[i]) / (gDzCompatPanelB[i] - gDzCompatPanelA[i])
                                set x0 = gDzCompatPanelNA[i] + (ox0 - gDzCompatPanelA[i]) * k
                                set x1 = gDzCompatPanelNA[i] + (ox1 - gDzCompatPanelA[i]) * k
                                set mapped = true
                            endif
                            set i = i + 1
                        endloop
                    endif
                    // cut to the real screen
                    if x0 < -m then
                        set x0 = -m
                    endif
                    if x1 > 0.8 + m then
                        set x1 = 0.8 + m
                    endif
                    if not isPanel then
                        if y0 < 0. then
                            set y0 = 0.
                        endif
                        if y1 > 0.6 then
                            set y1 = 0.6
                        endif
                    endif
                    if x1 > x0 and y1 > y0 then
                        set nw = x1 - x0
                        set nh = y1 - y0
                        set x = x0 + nw * DzCompat_PointFX(point)
                        set y = y0 + nh * DzCompat_PointFY(point)
                    endif
                endif
                if (oy0 < DZCOMPAT_CONSOLE_BOTTOM_TOP or oy1 > DZCOMPAT_CONSOLE_TOP_BOTTOM) and w * h >= DZCOMPAT_COVER_MIN_AREA then
                    call DzCompat_CoverRegister(frame)
                endif
            endif
            // text on a squeezed panel moves left/right with it (its size is left to the text fit): the
            // frame's left edge is mapped like the panel content and the whole frame is moved by the difference
            if DZCOMPAT_EDGE_FIT and LoadBoolean(gDzCompatTextFit, frame, 0) and BlzFrameGetParent(f) == DzCompat_EdgeOwner() then
                set extra = DzCompat_TextShiftExtra(f, LoadReal(gDzCompatFrameGeo, frame, 4), y)
                if extra != 0. then
                    set x = x + extra
                else
                    set tx0 = x - w * DzCompat_PointFX(point)
                    set pass = 0
                    loop
                        exitwhen pass > 1 or found
                        set i = 0
                        loop
                            exitwhen i >= gDzCompatPanelCount or found
                            set tol = 0.1 * pass
                            if tx0 >= gDzCompatPanelA[i] - 0.0001 and tx0 <= gDzCompatPanelB[i] + 0.0001 and y >= gDzCompatPanelY0[i] - tol and y <= gDzCompatPanelY1[i] + tol then
                                set k = (gDzCompatPanelNB[i] - gDzCompatPanelNA[i]) / (gDzCompatPanelB[i] - gDzCompatPanelA[i])
                                set x = x + gDzCompatPanelNA[i] + (tx0 - gDzCompatPanelA[i]) * k - tx0
                                set found = true
                            endif
                            set i = i + 1
                        endloop
                        set pass = pass + 1
                    endloop
                endif
            endif
        endif
        if nw != w or nh != h then
            call BlzFrameSetSize(f, nw, nh)
        endif
        call BlzFrameSetAbsPoint(f, ConvertFramePointType(point), x, y)
        set f = null
        set par = null
    endfunction

    function DzCompat_AbsSet takes integer frame, integer point, real x, real y returns nothing
        call SaveBoolean(gDzCompatFrameGeo, frame, 6, true)
        call SaveInteger(gDzCompatFrameGeo, frame, 3, point)
        call SaveReal(gDzCompatFrameGeo, frame, 4, x)
        call SaveReal(gDzCompatFrameGeo, frame, 5, y)
        call DzCompat_AbsApply(frame)
    endfunction

    // The frame that should own a new frame. A parent id that is 0 or does not name a
    // frame (for example one that was already destroyed) falls back to the GameUI, so a
    // frame is never created with a null owner.
    function DzCompat_GetOwnerFrame takes integer parent returns framehandle
        local framehandle f = DzCompat_GetFrame(parent)
        if f == null or f == DzCompat_GetGameUI() then
            return DzCompat_EdgeOwner()
        endif
        return f
    endfunction

    // ---- single-line TEXT frame auto-fit helpers (see gDzCompatTextFit) ------
    // Visible character count of a label: |cAARRGGBB and |r are not drawn. Returns -1 when
    // the text has a line break (|n), meaning the map wants more than one line.
    // JASS strings are indexed by byte, so a non-ASCII character counts as several
    // characters; that only makes the estimate wider, which is the safe direction.
    function DzCompat_TextVisibleLen takes string text returns integer
        local integer i = 0
        local integer n = StringLength(text)
        local integer count = 0
        local string c
        local string d
        loop
            exitwhen i >= n
            set c = SubString(text, i, i + 1)
            if c == "|" and i + 1 < n then
                set d = StringCase(SubString(text, i + 1, i + 2), false)
                if d == "c" then
                    set i = i + 10
                elseif d == "r" then
                    set i = i + 2
                elseif d == "n" then
                    return -1
                else
                    set count = count + 1
                    set i = i + 1
                endif
            elseif c == "\n" then
                return -1
            else
                set count = count + 1
                set i = i + 1
            endif
        endloop
        return count
    endfunction

    // Re-applies size and anchor of a TEXT frame so its text fits on one line, keeping the
    // text where the map placed it. The anchor offset is moved by (a - f) * growth, where
    // a is where on the frame the anchor sits (0 left, .5 centre, 1 right) and f is the
    // same for the text's own justification: left text keeps its left edge, centred text
    // its centre, right text its right edge. forceApply = false skips the work when the width
    // would not change (a map may call DzFrameSetText every tick).
    function DzCompat_TextFit takes integer frame, boolean forceApply returns nothing
        local framehandle f
        local framehandle r
        local real reqW
        local real reqH
        local real fontH
        local real w
        local real a = 0.
        local real jf = 0.
        local real x
        local real y
        local integer kind
        local integer pt
        local integer horz
        local integer len
        if not DZCOMPAT_TEXT_AUTOFIT then
            return
        endif
        if not LoadBoolean(gDzCompatTextFit, frame, 0) then
            return
        endif
        set kind = LoadInteger(gDzCompatTextFit, frame, 4)
        if not LoadBoolean(gDzCompatTextFit, frame, 3) or kind == 0 or LoadBoolean(gDzCompatTextFit, frame, 11) then
            return
        endif
        set f = DzCompat_GetFrame(frame)
        if f == null then
            return
        endif
        set reqW = LoadReal(gDzCompatTextFit, frame, 1)
        set reqH = LoadReal(gDzCompatTextFit, frame, 2)
        set fontH = LoadReal(gDzCompatTextFit, frame, 12)
        if fontH <= 0. then
            set fontH = DZCOMPAT_TEXT_DEFAULT_FONT_H
        endif
        set w = reqW
        if reqH <= fontH * DZCOMPAT_TEXT_MAX_LINES_H then
            set len = DzCompat_TextVisibleLen(BlzFrameGetText(f))
            if len > 0 and I2R(len) * fontH * DZCOMPAT_TEXT_CHAR_W_RATIO > w then
                set w = I2R(len) * fontH * DZCOMPAT_TEXT_CHAR_W_RATIO
            endif
        endif
        if not forceApply and w == LoadReal(gDzCompatTextFit, frame, 15) then
            return
        endif
        call SaveReal(gDzCompatTextFit, frame, 15, w)
        call BlzFrameSetSize(f, w, reqH)
        set pt = LoadInteger(gDzCompatTextFit, frame, 5)
        set x = LoadReal(gDzCompatTextFit, frame, 8)
        set y = LoadReal(gDzCompatTextFit, frame, 9)
        if pt == 1 or pt == 4 or pt == 7 then
            set a = 0.5
        elseif pt == 2 or pt == 5 or pt == 8 then
            set a = 1.
        endif
        set horz = LoadInteger(gDzCompatTextFit, frame, 13)
        if horz == 4 then
            set jf = 0.5
        elseif horz == 5 then
            set jf = 1.
        endif
        set x = x + (a - jf) * (w - reqW)
        if kind == 1 then
            call SaveBoolean(gDzCompatFrameGeo, frame, 10, true)
            call SaveReal(gDzCompatFrameGeo, frame, 0, w)
            call SaveReal(gDzCompatFrameGeo, frame, 1, reqH)
            call DzCompat_AbsSet(frame, pt, x, y)
        else
            set r = DzCompat_GetFrame(LoadInteger(gDzCompatTextFit, frame, 6))
            if r != null then
                call BlzFrameSetPoint(f, ConvertFramePointType(pt), r, ConvertFramePointType(LoadInteger(gDzCompatTextFit, frame, 7)), DzCompat_AnchorX(r, LoadInteger(gDzCompatTextFit, frame, 7), x), y)
            endif
        endif
        set f = null
        set r = null
    endfunction

    function DzCreateFrame takes string frame, integer parent, integer id returns integer
        return DzCompat_RegisterFrameNamed(BlzCreateFrame(frame, DzCompat_GetOwnerFrame(parent), 0, id), frame, id)
    endfunction

    // Falls back to a normal frame when the name is not a simple-frame template.
    function DzCreateSimpleFrame takes string frame, integer parent, integer id returns integer
        local framehandle owner = DzCompat_GetOwnerFrame(parent)
        local framehandle created = BlzCreateSimpleFrame(frame, owner, id)
        if created == null then
            set created = BlzCreateFrame(frame, owner, 0, id)
        endif
        return DzCompat_RegisterFrameNamed(created, frame, id)
    endfunction

    // Creates the frame, trying progressively simpler forms until the engine returns one:
    //   1. the requested type with the requested template;
    //   2. the type with no template (a template that is not defined in any loaded FDF
    //      makes the engine return null);
    //   3. for a BUTTON, GLUETEXTBUTTON instead of BUTTON when no template applies
    //      (see DZCOMPAT_BUTTON_AS_GLUE_BUTTON), and BUTTON itself as the last resort.
    function DzCreateFrameByTagName takes string frameType, string name, integer parent, string template, integer id returns integer
        local string regName = name
        local framehandle owner = DzCompat_GetOwnerFrame(parent)
        local framehandle f = null
        local string plainType = frameType
        local integer fid
        if regName == null or regName == "" then
            set gDzCompatFrameGenCount = gDzCompatFrameGenCount + 1
            set regName = "__FrameGen_" + I2S(gDzCompatFrameGenCount)
        endif
        if DZCOMPAT_BUTTON_AS_GLUE_BUTTON and frameType == "BUTTON" then
            set plainType = "GLUETEXTBUTTON"
        endif
        if template != null and template != "" then
            set f = BlzCreateFrameByType(frameType, regName, owner, template, id)
        endif
        if f == null then
            set f = BlzCreateFrameByType(plainType, regName, owner, "", id)
        endif
        if f == null and plainType != frameType then
            set f = BlzCreateFrameByType(frameType, regName, owner, "", id)
        endif
        set fid = DzCompat_RegisterFrameNamed(f, regName, id)
        if fid != 0 and StringCase(frameType, true) == "TEXT" then
            call SaveBoolean(gDzCompatTextFit, fid, 0, true)
        endif
        if fid != 0 and DzCompat_GetFrame(parent) != null and DzCompat_GetFrame(parent) != DzCompat_GetGameUI() then
            call DzCompat_FrameAddChild(parent, fid)
        endif
        return fid
    endfunction

    // [FIXED] leak: DzFrameSetScriptByCode (and the Block/Async variants that call
    // it) create one owned trigger per (frame, eventId) and store it in
    // gDzCompatFrameEvt, but this function used to just null the frame slot and
    // never destroyed those triggers - every frame that ever had a script
    // attached leaked one trigger handle (and its hashtable entry) per event for
    // the rest of the game. Loop the known FRAMEEVENT eventId range (matches
    // DzCompat_ConvertFrameEvent's domain) and destroy anything stored for this
    // frame before tearing it down. The by-name variant (DzFrameSetScript) is
    // untouched here on purpose: its trigger is shared across every frame
    // registered to that function name, so it must outlive any single frame.
    function DzDestroyFrame takes integer frame returns nothing
        local integer head = 0
        local integer tail = 1
        local integer id
        local integer n
        local integer i
        if DzCompat_GetFrame(frame) == null then
            return
        endif
        // [FIXED] crash: destroying a frame whose Dz children were created under it used to
        // free those children inside the engine while their Dz ids stayed valid. The next
        // DzFrameShow / DzFrameSetEnable / DzDestroyFrame on such an id touched a freed frame
        // (access violation). Collect the whole subtree, then release children before parents.
        set gDzCompatDestroyQueue[0] = frame
        loop
            exitwhen head >= tail
            set id = gDzCompatDestroyQueue[head]
            set head = head + 1
            set n = LoadInteger(gDzCompatFrameChildren, id, 0)
            set i = 1
            loop
                exitwhen i > n or tail >= DZCOMPAT_MAX_FRAMES
                if DzCompat_GetFrame(LoadInteger(gDzCompatFrameChildren, id, i)) != null then
                    set gDzCompatDestroyQueue[tail] = LoadInteger(gDzCompatFrameChildren, id, i)
                    set tail = tail + 1
                endif
                set i = i + 1
            endloop
        endloop
        call DzCompat_FrameRemoveChild(frame)
        set i = tail - 1
        loop
            exitwhen i < 0
            call DzCompat_ReleaseFrame(gDzCompatDestroyQueue[i], i == 0)
            set i = i - 1
        endloop
    endfunction

    function DzFrameFindByName takes string name, integer id returns integer
        local integer stored
        local framehandle f
        // Prefer the name+context table (fast path, works for frames we created)
        set stored = LoadInteger(gDzCompatNameContext, StringHash(name + I2S(id)), 0)
        if stored != 0 then
            return stored
        endif
        // Fall back to the real engine lookup and register the result so
        // subsequent finds and trigger-context queries stay consistent.
        set f = BlzGetFrameByName(name, id)
        if f == null then
            return 0
        endif
        return DzCompat_RegisterFrameNamed(f, name, id)
    endfunction

    function DzSimpleFrameFindByName takes string name, integer id returns integer
        return DzFrameFindByName(name, id)
    endfunction

    // ---- KK-prefixed alias of the same real BlzFrameIsVisible check ----
    // (self-contained: DzFrameIsVisible is defined further down, and JASS needs a function
    // to be declared before it is called)
    function KKSimpleFrameIsVisible takes integer simple_frame returns boolean
        local framehandle f = DzCompat_GetFrame(simple_frame)
        if f == null then
            return false
        endif
        return BlzFrameIsVisible(f)
    endfunction

    // ---- font-string / texture frame lookup by name -------------------
    // Same underlying real native (BlzGetFrameByName) as DzFrameFindByName -
    // Reforged doesn't distinguish frame-type at the lookup native level.
    function DzSimpleFontStringFindByName takes string name, integer id returns integer
        return DzFrameFindByName(name, id)
    endfunction

    function DzSimpleTextureFindByName takes string name, integer id returns integer
        return DzFrameFindByName(name, id)
    endfunction

	function DzGetGameUI takes nothing returns integer
        return DzCompat_RegisterFrameNamed(BlzGetOriginFrame(ORIGIN_FRAME_GAME_UI, 0), "GAMEUI", 0)
	endfunction

    function DzFrameGetCommandBarButton takes integer row, integer column returns integer
        return DzCompat_RegisterFrame(BlzGetOriginFrame(ORIGIN_FRAME_COMMAND_BUTTON, row * 4 + column))
    endfunction

    // The upper button bar: the origin frame SYSTEM_BUTTON, but the two numberings differ. The real client
    // reads the bar's fields +0x138, +0x130, +0x134, +0x160 for ids 0..3 (kkapi_local_plugin.dll 0x100770b0,
    // dzclient_api.dll 0x10018e00), which the bar's constructor in Game.dll (1.27a and 1.28.5) names
    // 0 Quests, 1 Menu, 2 Allies, 3 Log. Reforged's SYSTEM_BUTTON is 0 Menu, 1 Allies, 2 Log, 3 Quests
    // (proven in game: a map that asked for 1 to put the game menu behind its own button got Allies).
    function DzFrameGetUpperButtonBarButton takes integer buttonId returns integer
        if buttonId == 0 then
            return DzCompat_RegisterFrame(BlzGetOriginFrame(ORIGIN_FRAME_SYSTEM_BUTTON, 3))
        elseif buttonId >= 1 and buttonId <= 3 then
            return DzCompat_RegisterFrame(BlzGetOriginFrame(ORIGIN_FRAME_SYSTEM_BUTTON, buttonId - 1))
        endif
        return 0
    endfunction

function DzCompat_GetStableParent takes nothing returns framehandle
    if gDzStableParent == null then
        // ConsoleUI is the root of the UI hierarchy and was NOT restructured
        set gDzStableParent = BlzGetFrameByName("ConsoleUI", 0)
        if gDzStableParent == null then
            set gDzStableParent = DzCompat_GetGameUI()
        endif
    endif
    return gDzStableParent
endfunction

function DzFrameGetHeroBarButton takes integer buttonId returns integer
    local framehandle realBtn = BlzGetOriginFrame(ORIGIN_FRAME_HERO_BUTTON, buttonId)
    
    // Return a proxy frame that is a child of a STABLE parent. With the edge fix that parent is
    // the edge owner: a proxy under ConsoleUI was never laid out once it was anchored to a hero
    // button, so every frame anchored to it disappeared (the debug markers, which are children
    // of ConsoleUIBackdrop and anchored to the real buttons, were placed correctly).
    local framehandle proxy
    if DZCOMPAT_EDGE_SHIFT then
        set proxy = BlzCreateFrameByType("BACKDROP", "DzHeroProxy" + I2S(buttonId), DzCompat_EdgeOwner(), "", 0)
    else
        set proxy = BlzCreateFrameByType("BACKDROP", "DzHeroProxy" + I2S(buttonId), DzCompat_GetStableParent(), "", 0)
    endif
    
    // Make it invisible
    call BlzFrameSetAlpha(proxy, 0)
    
    // Give it the same size as the real button
    if realBtn != null then
        call BlzFrameSetSize(proxy, BlzFrameGetWidth(realBtn), BlzFrameGetHeight(realBtn))
    else
        call BlzFrameSetSize(proxy, 0.03, 0.03) // fallback size
    endif
    
    // Reforged moved the hero bar compared to classic, so follow the real button: the game
    // anchors the hero column to the real screen edge. The proxy is only anchored to it, never
    // made its child, so it survives the button being hidden. Without a real button, fall back
    // to the left edge of the screen with the old y position (0.55 - buttonId * 0.04).
    if realBtn != null and DZCOMPAT_EDGE_SHIFT then
        // Hidden hero buttons (no hero in that slot) are laid out like visible ones: the test
        // markers on buttons 1, 3 and 6 sat in one column 0.0513 apart, flush with the screen edge.
        call BlzFrameSetPoint(proxy, FRAMEPOINT_TOPLEFT, realBtn, FRAMEPOINT_TOPLEFT, 0.0, 0.0)
    else
        call BlzFrameSetPoint(proxy, FRAMEPOINT_TOPLEFT, DzCompat_GetGameUI(), FRAMEPOINT_TOPLEFT, DzCompat_AnchorX(DzCompat_GetGameUI(), 0, 0.), -(0.05 + (buttonId * 0.04)))
    endif
    return DzCompat_RegisterFrame(proxy)
endfunction

    function DzFrameGetHeroHPBar takes integer buttonId returns integer
        return DzCompat_RegisterFrame(BlzGetOriginFrame(ORIGIN_FRAME_HERO_HP_BAR, buttonId))
    endfunction

    function DzFrameGetHeroManaBar takes integer buttonId returns integer
        return DzCompat_RegisterFrame(BlzGetOriginFrame(ORIGIN_FRAME_HERO_MANA_BAR, buttonId))
    endfunction

    function DzFrameGetItemBarButton takes integer buttonId returns integer
        return DzCompat_RegisterFrame(BlzGetOriginFrame(ORIGIN_FRAME_ITEM_BUTTON, buttonId))
    endfunction

    function DzFrameGetMinimap takes nothing returns integer
        return DzCompat_RegisterFrameNamed(BlzGetOriginFrame(ORIGIN_FRAME_MINIMAP, 0), "MINIMAP", 0)
    endfunction

    // buttonId: 0=Signal, 1=Terrain, 2=Ally filter, 3=Creep filter, 4=Formation
    function DzFrameGetMinimapButton takes integer buttonId returns integer
        return DzCompat_RegisterFrameNamed(BlzGetOriginFrame(ORIGIN_FRAME_MINIMAP_BUTTON, buttonId), "MINIMAPBUTTON", buttonId)
    endfunction

    // Replaces the minimap's terrain picture with the given image file.
    function DzSetWar3MapMap takes string map returns nothing
        if map == null or map == "" then
            return
        endif
        call BlzChangeMinimapTerrainTex(map)
    endfunction

    function DzFrameGetTooltip takes nothing returns integer
        return DzCompat_RegisterFrame(BlzGetOriginFrame(ORIGIN_FRAME_TOOLTIP, 0))
    endfunction

    function DzFrameGetTopMessage takes nothing returns integer
        return DzCompat_RegisterFrame(BlzGetOriginFrame(ORIGIN_FRAME_TOP_MSG, 0))
    endfunction

    function DzFrameGetUnitMessage takes nothing returns integer
        return DzCompat_RegisterFrame(BlzGetOriginFrame(ORIGIN_FRAME_UNIT_MSG, 0))
    endfunction

    function DzFrameGetChatMessage takes nothing returns integer
        return DzCompat_RegisterFrame(BlzGetOriginFrame(ORIGIN_FRAME_CHAT_MSG, 0))
    endfunction

    function DzFrameGetPortrait takes nothing returns integer
        return DzCompat_RegisterFrame(BlzGetOriginFrame(ORIGIN_FRAME_PORTRAIT, 0))
    endfunction

    // [APPROX] closest real match for a "message" overlay on the 3D viewport
    function DzFrameGetWorldFrameMessage takes nothing returns integer
        return DzCompat_RegisterFrame(BlzGetOriginFrame(ORIGIN_FRAME_WORLD_FRAME, 0))
    endfunction

    // [APPROX for index > 0] ORIGIN_FRAME_UNIT_PANEL_BUFF_BAR is a container;
    // index 0 returns it, higher indices are its children (child index - 1). The child is
    // fetched here directly - DzFrameGetChild is defined further down, and JASS needs a
    // function to be declared before it is called.
    function DzFrameGetInfoPanelBuffButton takes integer index returns integer
        local framehandle container = BlzGetOriginFrame(ORIGIN_FRAME_UNIT_PANEL_BUFF_BAR, 0)
        local framehandle child = null
        if index <= 0 or container == null then
            return DzCompat_RegisterFrame(container)
        endif
        set child = BlzFrameGetChild(container, index - 1)
        if child == null then
            return 0
        endif
        return DzCompat_RegisterFrame(child)
    endfunction

    // Every function below resolves its frame ids first and does nothing (or returns a
    // neutral value) when an id does not name a frame: Dz maps pass 0 for "no frame", and a
    // null framehandle handed to a Blz* native is not something to rely on.
    // Point ids outside 0..8 are ignored for the same reason.

    // Remembers one anchor for the DzFrameGetPoint* getters. Reforged can set an anchor but cannot read it back.
    function DzCompat_TrackFramePoint takes integer frame, integer point, integer relativeFrame, integer relativePoint, real x, real y returns nothing
        call SaveInteger(gDzCompatFramePoints, frame, point * 8, relativeFrame)
        call SaveInteger(gDzCompatFramePoints, frame, point * 8 + 1, relativePoint)
        call SaveReal(gDzCompatFramePoints, frame, point * 8 + 2, x)
        call SaveReal(gDzCompatFramePoints, frame, point * 8 + 3, y)
    endfunction

    function DzFrameSetPoint takes integer frame, integer point, integer relativeFrame, integer relativePoint, real x, real y returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        local framehandle r = DzCompat_GetFrame(relativeFrame)
        if f == null or r == null or point < 0 or point > 8 or relativePoint < 0 or relativePoint > 8 then
            return
        endif
        call BlzFrameSetPoint(f, ConvertFramePointType(point), r, ConvertFramePointType(relativePoint), DzCompat_AnchorX(r, relativePoint, x), y)
        call DzCompat_TrackFramePoint(frame, point, relativeFrame, relativePoint, x, y)
        if LoadBoolean(gDzCompatFrameGeo, frame, 6) and LoadInteger(gDzCompatFrameGeo, frame, 3) == point then
        call SaveBoolean(gDzCompatFrameGeo, frame, 6, false)
        endif
        if r == DzCompat_GetGameUI() and point == 4 and relativePoint == 4 and x == 0. and y == 0. then
        call SaveBoolean(gDzCompatFrameGeo, frame, 9, true)
        endif
        if LoadBoolean(gDzCompatTextFit, frame, 0) then
            if LoadInteger(gDzCompatTextFit, frame, 4) != 0 and LoadInteger(gDzCompatTextFit, frame, 5) != point then
                call SaveBoolean(gDzCompatTextFit, frame, 11, true)
                call RemoveSavedReal(gDzCompatSizeCache, frame, 0)
            endif
            call SaveInteger(gDzCompatTextFit, frame, 4, 2)
            call SaveInteger(gDzCompatTextFit, frame, 5, point)
            call SaveInteger(gDzCompatTextFit, frame, 6, relativeFrame)
            call SaveInteger(gDzCompatTextFit, frame, 7, relativePoint)
            call SaveReal(gDzCompatTextFit, frame, 8, x)
            call SaveReal(gDzCompatTextFit, frame, 9, y)
            call DzCompat_TextFit(frame, true)
        endif
    endfunction

    function DzFrameSetAbsolutePoint takes integer frame, integer point, real x, real y returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        if f == null or point < 0 or point > 8 then
            return
        endif
        call DzCompat_AbsSet(frame, point, x, y)
        call DzCompat_TrackFramePoint(frame, point, 0, 0, x, y)
        if LoadBoolean(gDzCompatTextFit, frame, 0) then
            if LoadInteger(gDzCompatTextFit, frame, 4) != 0 and LoadInteger(gDzCompatTextFit, frame, 5) != point then
                call SaveBoolean(gDzCompatTextFit, frame, 11, true)
            endif
            call SaveInteger(gDzCompatTextFit, frame, 4, 1)
            call SaveInteger(gDzCompatTextFit, frame, 5, point)
            call SaveReal(gDzCompatTextFit, frame, 8, x)
            call SaveReal(gDzCompatTextFit, frame, 9, y)
            call DzCompat_TextFit(frame, true)
        endif
    endfunction

    function DzFrameSetAllPoints takes integer frame, integer relativeFrame returns boolean
        local framehandle f = DzCompat_GetFrame(frame)
        local framehandle r = DzCompat_GetFrame(relativeFrame)
        if f == null or r == null then
            return false
        endif
        if DZCOMPAT_EDGE_SHIFT and r == DzCompat_GetGameUI() and DzCompat_ScreenMargin() > 0. then
            // a full-screen Dz GameUI: stretch over the margins on both sides as well
            call BlzFrameSetPoint(f, FRAMEPOINT_TOPLEFT, r, FRAMEPOINT_TOPLEFT, DzCompat_AnchorX(r, 0, 0.), 0.)
            call BlzFrameSetPoint(f, FRAMEPOINT_BOTTOMRIGHT, r, FRAMEPOINT_BOTTOMRIGHT, DzCompat_AnchorX(r, 8, 0.), 0.)
        else
            call BlzFrameSetAllPoints(f, r)
        endif
        call SaveBoolean(gDzCompatFrameGeo, frame, 6, false)
        call DzCompat_TrackFramePoint(frame, 0, relativeFrame, 0, 0., 0.)
        call DzCompat_TrackFramePoint(frame, 8, relativeFrame, 8, 0., 0.)
        // size now comes from the other frame, so the auto-fit must leave this one alone
        call SaveBoolean(gDzCompatTextFit, frame, 11, true)
        return true
    endfunction

    function DzFrameClearAllPoints takes integer frame returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        if f != null then
            call BlzFrameClearAllPoints(f)
            call FlushChildHashtable(gDzCompatFramePoints, frame)
            call SaveBoolean(gDzCompatFrameGeo, frame, 6, false)
            call SaveInteger(gDzCompatTextFit, frame, 4, 0)
            call SaveBoolean(gDzCompatTextFit, frame, 11, false)
            call RemoveSavedReal(gDzCompatSizeCache, frame, 0)
        endif
    endfunction

    // ---- DzFrameGetPoint* ------------------------------------------------------------------------------
    // kkapi_local_plugin.dll 0x10076a10..0x10076a90 look the anchor up on the frame (the point argument is
    // the same 0..8 number DzFrameSetPoint takes) and read what was stored: valid = the anchor exists,
    // Relative = its relative frame, RelativePoint = its relative point, X / Y = its offsets. A point that
    // was never set gives false / 0 / 0.0. Reforged has no anchor getter, so the values come from
    // DzCompat_TrackFramePoint; the offsets are the ones the map passed, not the margin-shifted ones used
    // internally. A frame the map anchored through the game UI instead of this lib is not known here.
    function DzFrameGetPointValid takes integer frame, integer anchor returns boolean
        return HaveSavedInteger(gDzCompatFramePoints, frame, anchor * 8)
    endfunction

    function DzFrameGetPointRelative takes integer frame, integer anchor returns integer
        return LoadInteger(gDzCompatFramePoints, frame, anchor * 8)
    endfunction

    function DzFrameGetPointRelativePoint takes integer frame, integer anchor returns integer
        return LoadInteger(gDzCompatFramePoints, frame, anchor * 8 + 1)
    endfunction

    function DzFrameGetPointX takes integer frame, integer anchor returns real
        return LoadReal(gDzCompatFramePoints, frame, anchor * 8 + 2)
    endfunction

    function DzFrameGetPointY takes integer frame, integer anchor returns real
        return LoadReal(gDzCompatFramePoints, frame, anchor * 8 + 3)
    endfunction

    function DzCompat_SizeFlush takes nothing returns nothing
        local integer i = 0
        local integer id
        local framehandle f
        local real w
        local real h
        loop
            exitwhen i >= gDzCompatSizePendingCount
            set id = gDzCompatSizePendingId[i]
            set f = DzCompat_GetFrame(id)
            if f != null and LoadBoolean(gDzCompatSizeCache, id, 4) then
                set w = LoadReal(gDzCompatSizeCache, id, 2)
                set h = LoadReal(gDzCompatSizeCache, id, 3)
                call SaveBoolean(gDzCompatSizeCache, id, 4, false)
                if not (HaveSavedReal(gDzCompatSizeCache, id, 0) and w - LoadReal(gDzCompatSizeCache, id, 0) < 0.00001 and LoadReal(gDzCompatSizeCache, id, 0) - w < 0.00001 and h - LoadReal(gDzCompatSizeCache, id, 1) < 0.00001 and LoadReal(gDzCompatSizeCache, id, 1) - h < 0.00001) then
                    call SaveReal(gDzCompatSizeCache, id, 0, w)
                    call SaveReal(gDzCompatSizeCache, id, 1, h)
                    call BlzFrameSetSize(f, w, h)
                    // the edge-shift layout (squeezed panels, console cover) is computed from the size, so redo it now
                    call DzCompat_AbsApply(id)
                endif
            endif
            set f = null
            set i = i + 1
        endloop
        set gDzCompatSizePendingCount = 0
    endfunction

    function DzFrameSetSize takes integer frame, real w, real h returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        call SaveReal(gDzCompatFrameGeo, frame, 0, w)
        call SaveReal(gDzCompatFrameGeo, frame, 1, h)
        if DzCompat_IsFullScreen(frame, w, h) then
            set w = 0.8 + 2. * DzCompat_ScreenMargin()
            set h = 0.6
            call DzCompat_CoverRegister(frame)
        endif
        if f != null then
            if LoadBoolean(gDzCompatTextFit, frame, 0) then
                call BlzFrameSetSize(f, w, h)
                call SaveReal(gDzCompatTextFit, frame, 1, w)
                call SaveReal(gDzCompatTextFit, frame, 2, h)
                call SaveBoolean(gDzCompatTextFit, frame, 3, true)
                call DzCompat_TextFit(frame, true)
            else
                call SaveReal(gDzCompatSizeCache, frame, 2, w)
                call SaveReal(gDzCompatSizeCache, frame, 3, h)
                if not LoadBoolean(gDzCompatSizeCache, frame, 4) then
                    call SaveBoolean(gDzCompatSizeCache, frame, 4, true)
                    if gDzCompatSizePendingCount < 8000 then
                        set gDzCompatSizePendingId[gDzCompatSizePendingCount] = frame
                        set gDzCompatSizePendingCount = gDzCompatSizePendingCount + 1
                        if gDzCompatSizePendingCount == 1 then
                            if gDzCompatSizeTimer == null then
                                set gDzCompatSizeTimer = CreateTimer()
                            endif
                            call TimerStart(gDzCompatSizeTimer, 0., false, function DzCompat_SizeFlush)
                        endif
                    else
                        call BlzFrameSetSize(f, w, h)
                    endif
                endif
            endif
        endif
        call DzCompat_AbsApply(frame)
    endfunction

    function DzFrameSetParent takes integer frame, integer parent returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        local framehandle p = DzCompat_GetFrame(parent)
        if f != null and p != null then
            if p == DzCompat_GetGameUI() then
                set p = DzCompat_EdgeOwner()
            endif
            call BlzFrameSetParent(f, p)
            call DzCompat_FrameRemoveChild(frame)
            if DzCompat_GetFrame(parent) != DzCompat_GetGameUI() then
                call DzCompat_FrameAddChild(parent, frame)
            endif
        endif
    endfunction

    function DzFrameGetParent takes integer frame returns integer
        local framehandle f = DzCompat_GetFrame(frame)
        if f == null then
            return 0
        endif
        return DzCompat_RegisterFrame(BlzFrameGetParent(f))
    endfunction

    function DzFrameGetHeight takes integer frame returns real
        local framehandle f = DzCompat_GetFrame(frame)
        if f == null then
            return 0.
        endif
        return BlzFrameGetHeight(f)
    endfunction

    // [APPROX] Dz's "priority" (set at creation) is treated here as frame
    // Level, which controls sibling draw/click order post-creation. Close in
    // effect, not identical semantics.
    function DzFrameSetPriority takes integer frame, integer priority returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        if f != null then
            call BlzFrameSetLevel(f, priority)
        endif
    endfunction

    // ---- Visibility / enable state -------------------------------
    function DzFrameShow takes integer frame, boolean enable returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        if f != null then
            call BlzFrameSetVisible(f, enable)
            if not enable then
                if not DZCOMPAT_HOVER_VIA_TOOLTIP then
                    call DzCompat_HoverRearm(frame)
                endif
            endif
        endif
    endfunction

    function DzSimpleFrameShow takes integer frame, boolean enable returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        if f != null then
            call BlzFrameSetVisible(f, enable)
        endif
    endfunction

    function DzFrameIsVisible takes integer frame returns boolean
        local framehandle f = DzCompat_GetFrame(frame)
        if f == null then
            return false
        endif
        return BlzFrameIsVisible(f)
    endfunction

    function DzFrameSetEnable takes integer name, boolean enable returns nothing
        local framehandle f = DzCompat_GetFrame(name)
        if f != null then
            call BlzFrameSetEnable(f, enable)
        endif
    endfunction

    function DzFrameGetEnable takes integer frame returns boolean
        local framehandle f = DzCompat_GetFrame(frame)
        if f == null then
            return false
        endif
        return BlzFrameGetEnable(f)
    endfunction

    function DzFrameSetFocus takes integer frame, boolean enable returns boolean
        local framehandle f = DzCompat_GetFrame(frame)
        if f == null then
            return false
        endif
        call BlzFrameSetFocus(f, enable)
        call DzCompat_TrackFocus(frame, enable)
        return true
    endfunction

    // kkapi.dll 0x10073720: only acts on edit-box frames; false calls the frame's "lose focus" method, true
    // its "take focus" method. That is exactly BlzFrameSetFocus, so it goes through DzFrameSetFocus (which
    // also keeps the DzFrameIsFocus bookkeeping).
    function DzFrameSetEditBoxActive takes integer frame, boolean is_active returns nothing
        call DzFrameSetFocus(frame, is_active)
    endfunction

    // kkapi.dll 0x10073770 only flips an input-method flag on the edit box (IME on/off). Reforged exposes no
    // IME control, so there is nothing to port: accepted and ignored on purpose.
    function DzFrameSetEditBoxDisableIme takes integer frame, boolean is_disable returns nothing
    endfunction

    // alpha is clamped to 0..255, the range BlzFrameSetAlpha accepts.
    function DzFrameSetAlpha takes integer frame, integer alpha returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        if f == null then
            return
        endif
        if alpha < 0 then
            set alpha = 0
        elseif alpha > 255 then
            set alpha = 255
        endif
        call BlzFrameSetAlpha(f, alpha)
    endfunction

    function DzFrameGetAlpha takes integer frame returns integer
        local framehandle f = DzCompat_GetFrame(frame)
        if f == null then
            return 0
        endif
        return BlzFrameGetAlpha(f)
    endfunction

    function DzFrameSetScale takes integer frame, real scale returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        if f != null then
            call BlzFrameSetScale(f, scale)
        endif
    endfunction

    function DzFrameSetTexture takes integer frame, string texture, integer flag returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        if f == null then
            return
        endif
        if texture == null then
            set texture = ""
        endif
        call BlzFrameSetTexture(f, texture, flag, true)
    endfunction

    // [APPROX] Dz's 4th param ("flag") has nowhere to go: the real native is
    // BlzFrameSetModel(framehandle frame, string modelFile, integer cameraIndex)
    // - exactly 3 args, no room for a 4th. modelType maps to cameraIndex
    // (both select which camera/portrait slot the model uses). flag is
    // dropped on the floor with no engine equivalent - this is a hard
    // engine limitation. If your Dz maps pass anything other than 0 for flag
    // and rely on it doing something, that will probably not work properly
    function DzFrameSetModel takes integer frame, string modelFile, integer modelType, integer flag returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        if f == null then
            return
        endif
        if modelFile == null then
            set modelFile = ""
        endif
        call BlzFrameSetModel(f, modelFile, modelType)
    endfunction

    function DzFrameSetVertexColor takes integer frame, integer color returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        if f != null then
            call BlzFrameSetVertexColor(f, color)
        endif
    endfunction

    // [UNVERIFIED] Dz's "autocast" boolean is best-effort mapped onto
    // BlzFrameSetSpriteAnimate's flags param as bit 0 (1 = flag set, 0 =
    // clear). If animations play differently than expected (e.g.
    // looping/blending looks wrong), that's the first place to look - try
    // flipping this to 0/nonzero and compare, or drop it back to a
    // hardcoded 0 if it makes things worse.
    function DzFrameSetAnimate takes integer frame, integer animId, boolean autocast returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        local integer flags = 0
        if f == null then
            return
        endif
        if autocast then
            set flags = 1
        endif
        call BlzFrameSetSpriteAnimate(f, animId, flags)
    endfunction

    // ---- KK model frames -------------------------------------------------------------------------------
    // kkapi.dll creates its own model-frame object (DzFrameAddModel 0x10071ed0) whose model has a matrix,
    // a camera and effect attachments. The closest Reforged object is a SPRITE frame (BlzFrameSetModel),
    // so only the parts a sprite can express are ported: create, model path, color+alpha, scale, animation
    // index. Camera source/target, position, rotation, size, speed, texture, particle size and the
    // effect attachments have no sprite counterpart and are left to the stubs.
    function DzFrameAddModel takes integer parent_frame returns integer
        return DzCreateFrameByTagName("SPRITE", "", parent_frame, "", 0)
    endfunction

    // The team color argument cannot be set on a sprite frame and is ignored.
    function DzFrameSetModel2 takes integer model_frame, string model_file, integer team_color_id returns nothing
        local framehandle f = DzCompat_GetFrame(model_frame)
        if f == null then
            return
        endif
        if model_file == null then
            set model_file = ""
        endif
        call BlzFrameSetModel(f, model_file, 0)
    endfunction

    // The dll sets the color and uses the top byte of the same integer as the alpha (0x10073dd0:
    // param >> 24), the DzGetColor (a, r, g, b) layout, which BlzFrameSetVertexColor also takes.
    function DzFrameSetModelColor takes integer model_frame, integer color returns nothing
        call DzFrameSetVertexColor(model_frame, color)
    endfunction

    // [APPROX] the dll multiplies the model matrix by (x, y, z) on top of whatever it already was
    // (0x10074320), so repeated calls compound. BlzFrameSetScale is uniform, so the mean of the three factors
    // is compounded and applied.
    function DzFrameSetModelScale takes integer model_frame, real x, real y, real z returns nothing
        local framehandle f = DzCompat_GetFrame(model_frame)
        local real total = 1.0
        if f == null then
            return
        endif
        if HaveSavedReal(gDzCompatModelScale, model_frame, 0) then
            set total = LoadReal(gDzCompatModelScale, model_frame, 0)
        endif
        set total = total * (x + y + z) / 3.0
        call SaveReal(gDzCompatModelScale, model_frame, 0, total)
        call BlzFrameSetScale(f, total)
    endfunction

    function DzFrameSetModelAnimationByIndex takes integer model_frame, integer anim_index returns nothing
        local framehandle f = DzCompat_GetFrame(model_frame)
        if f != null then
            call BlzFrameSetSpriteAnimate(f, anim_index, 0)
        endif
    endfunction

    // The FIRST argument is the alpha: the real client builds (a1 << 24) | (a2 << 16) | (a3 << 8) | a4,
    // i.e. ARGB (kkapi_local_plugin.dll 0x10079030, dzclient_api.dll 0x10018b40, dz_w3_plugin.dll
    // 0x10026680). The KKWE GUI action reads "Alph, R, G, B", KK maps call DzGetColor(255, r, g, b) and M16
    // maps declare the native as (a, r, g, b); the r, g, b, a names some headers use are misleading.
    // With alpha taken from the 4th argument, DzGetColor(255, 255, 255, 0) (opaque yellow) came out invisible.
    function DzGetColor takes integer a, integer r, integer g, integer b returns integer
        return BlzConvertColor(a, r, g, b)
    endfunction

    // Turns every |c00RRGGBB in a label into |cffRRGGBB (see DZCOMPAT_TEXT_FIX_ALPHA). Both
    // spellings have the same length, so the visible length DzCompat_TextVisibleLen reports is
    // unchanged. Text without a |c00 is returned as it came in.
    function DzCompat_FixTextAlpha takes string text returns string
        local integer i = 0
        local integer start = 0
        local integer n = StringLength(text)
        local string result = ""
        local string c
        if not DZCOMPAT_TEXT_FIX_ALPHA then
            return text
        endif
        loop
            exitwhen i + 4 > n
            set c = SubString(text, i, i + 1)
            if c == "|" and StringCase(SubString(text, i + 1, i + 4), false) == "c00" then
                set result = result + SubString(text, start, i) + "|cff"
                set i = i + 4
                set start = i
            else
                set i = i + 1
            endif
        endloop
        if start == 0 then
            return text
        endif
        return result + SubString(text, start, n)
    endfunction

    function DzFrameSetText takes integer frame, string text returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        if f == null then
            return
        endif
        if text == null then
            set text = ""
        endif
        set text = DzCompat_FixTextAlpha(text)
        call BlzFrameSetText(f, text)
        call DzCompat_TextFit(frame, false)
    endfunction

    function DzFrameGetText takes integer frame returns string
        local framehandle f = DzCompat_GetFrame(frame)
        if f == null then
            return ""
        endif
        return BlzFrameGetText(f)
    endfunction

    function DzFrameAddText takes integer frame, string text returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        if f == null then
            return
        endif
        if text == null then
            set text = ""
        endif
        set text = DzCompat_FixTextAlpha(text)
        call BlzFrameAddText(f, text)
    endfunction

    function DzFrameSetTextColor takes integer frame, integer color returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        if f != null then
            call BlzFrameSetTextColor(f, color)
        endif
    endfunction

    function DzFrameSetTextSizeLimit takes integer frame, integer size returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        if f != null then
            call BlzFrameSetTextSizeLimit(f, size)
        endif
    endfunction

    function DzFrameGetTextSizeLimit takes integer frame returns integer
        local framehandle f = DzCompat_GetFrame(frame)
        if f == null then
            return 0
        endif
        return BlzFrameGetTextSizeLimit(f)
    endfunction

    // align is a set of BIT FLAGS in the real client: vertical 1 top, 2 middle, 4 bottom;
    // horizontal 8 left, 16 center, 32 right. The first bit found on each axis wins (1 > 2 > 4,
    // 8 > 16 > 32) and an axis with no bit keeps what the frame already had (kkapi_local_plugin.dll
    // 0x100788e0, dzclient_api.dll 0x1001afd0, dz_w3_plugin.dll 0x10029110: the same code in all three).
    // The M16 JN library builds the same bits (JNFrameSetTextAlignment: TOP 1, MIDDLE 2, BOTTOM 4 +
    // LEFT 8, CENTER 16, RIGHT 32). This is the data point the previous 0-100 reading was waiting for:
    // 50 = middle + center, 6 = middle (horizontal kept), 7 = top, and 0 changes nothing, so a label set
    // to 50 and then to 0 stays centered in the original game too.
    // Reforged sets both axes in one call, so the last value of each axis is kept per frame in
    // gDzCompatTextAlign ([APPROX]: an axis the map never set starts as middle / center, the frame's own
    // template justification is not readable).
    function DzFrameSetTextAlignment takes integer frame, integer align returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        local integer vert = 1 // TEXT_JUSTIFY_MIDDLE
        local integer horz = 4 // TEXT_JUSTIFY_CENTER
        if f == null or BlzBitAnd(align, 63) == 0 then
            return
        endif
        if HaveSavedInteger(gDzCompatTextAlign, frame, 0) then
            set vert = LoadInteger(gDzCompatTextAlign, frame, 0)
            set horz = LoadInteger(gDzCompatTextAlign, frame, 1)
        endif
        if BlzBitAnd(align, 1) != 0 then
            set vert = 0 // TEXT_JUSTIFY_TOP
        elseif BlzBitAnd(align, 2) != 0 then
            set vert = 1 // TEXT_JUSTIFY_MIDDLE
        elseif BlzBitAnd(align, 4) != 0 then
            set vert = 2 // TEXT_JUSTIFY_BOTTOM
        endif
        if BlzBitAnd(align, 8) != 0 then
            set horz = 3 // TEXT_JUSTIFY_LEFT
        elseif BlzBitAnd(align, 16) != 0 then
            set horz = 4 // TEXT_JUSTIFY_CENTER
        elseif BlzBitAnd(align, 32) != 0 then
            set horz = 5 // TEXT_JUSTIFY_RIGHT
        endif
        call SaveInteger(gDzCompatTextAlign, frame, 0, vert)
        call SaveInteger(gDzCompatTextAlign, frame, 1, horz)
        call BlzFrameSetTextAlignment(f, ConvertTextAlignType(vert), ConvertTextAlignType(horz))
        if LoadBoolean(gDzCompatTextFit, frame, 0) then
            call SaveInteger(gDzCompatTextFit, frame, 13, horz)
            call DzCompat_TextFit(frame, true)
        endif
    endfunction

    function DzFrameSetFont takes integer frame, string fileName, real height, integer flag returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        if f == null then
            return
        endif
        if fileName == null then
            set fileName = ""
        endif
        call BlzFrameSetFont(f, fileName, height, flag)
        if LoadBoolean(gDzCompatTextFit, frame, 0) then
            call SaveReal(gDzCompatTextFit, frame, 12, height)
            call DzCompat_TextFit(frame, true)
        endif
    endfunction

    function DzFrameGetName takes integer frame returns string
        local framehandle f = DzCompat_GetFrame(frame)
        if f == null then
            return ""
        endif
        return BlzFrameGetName(f)
    endfunction

    // ---- Slider/value controls --------------------------------------
    function DzFrameGetValue takes integer frame returns real
        local framehandle f = DzCompat_GetFrame(frame)
        if f == null then
            return 0.
        endif
        return BlzFrameGetValue(f)
    endfunction

    function DzFrameSetValue takes integer frame, real value returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        if f != null then
            call BlzFrameSetValue(f, value)
        endif
    endfunction

    function DzFrameSetMinMaxValue takes integer frame, real minValue, real maxValue returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        if f != null then
            call BlzFrameSetMinMaxValue(f, minValue, maxValue)
        endif
    endfunction

    function DzFrameSetStepValue takes integer frame, real step returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        if f != null then
            call BlzFrameSetStepSize(f, step) // corrected: real native is named "StepSize", not "StepValue"
        endif
    endfunction

    function DzFrameSetTooltip takes integer frame, integer tooltip returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        local framehandle t = DzCompat_GetFrame(tooltip)
        if f != null and t != null then
            call BlzFrameSetTooltip(f, t)
        endif
    endfunction

    // ---- Misc global UI ------------------------------------------
    // BlzLoadTOCFile returns false when the file cannot be loaded (missing from the map,
    // or a bad path). Every custom frame of that .toc/.fdf is then missing, which is
    // otherwise very hard to trace back - so it is reported (see DZCOMPAT_DEBUG_MESSAGES).
    function DzLoadToc takes string fileName returns nothing
        if fileName == null or fileName == "" then
            return
        endif
        if not BlzLoadTOCFile(fileName) then
            call DzCompat_Warn("DzLoadToc: could not load " + fileName + " - custom frames from it will be missing")
        endif
    endfunction

    function DzFrameHideInterface takes nothing returns nothing
        call BlzHideOriginFrames(true)
    endfunction

    function DzOriginalUIAutoResetPoint takes boolean enable returns nothing
        call BlzEnableUIAutoPosition(enable)
    endfunction

    // ---- Click simulation ----------------------------------------
    function DzClickFrame takes integer frame returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        if f != null then
            call BlzFrameClick(f)
        endif
    endfunction

    // ---- Mouse cage (confine cursor to frame bounds) ----------------
    function DzFrameCageMouse takes integer frame, boolean enable returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        if f != null then
            call BlzFrameCageMouse(f, enable)
        endif
    endfunction

    // ---- frame event registration -------------------------------------------
    // Dz's eventId integers mostly reuse Reforged's FRAMEEVENT_ numbering; the exceptions,
    // read from the real client, are in DzCompat_ConvertFrameEvent below.
    //
    // "sync" isn't reproducible as a separate mode - it's not a choice: a frame click's
    // trigger condition/action already runs on every client for every registrant (see
    // DzCompat_ClickGate and DzCompat_ClickFix below for what that actually implies -
    // code here must not branch on anything that can read differently per client, e.g. a
    // frame's local enabled/visible state). Every variant below (sync, async, block)
    // behaves identically as a result.

    // Dz frame-event ids, from the real client's translation table (kkapi_local_plugin.dll 0x10074e80,
    // dzclient_api.dll 0x10017e60, dz_w3_plugin.dll 0x10025420). The ids it produces are 1, 2, 3, 4, 6, 7,
    // 8, 9, 10, 11, 12, 14 and (KK 0.6 only) 15:
    //   1-4, 6-9 = Reforged 1-4, 6-9 (click, enter, leave, mouse up, wheel, checked, unchecked, text changed)
    //   10 = CControlReleaseEvent (0x40090065), not the popup menu: [APPROX] MOUSE_UP (4)
    //   11 = CMenuSelectionChangedEvent = POPUPMENU_ITEM_CHANGED (10)
    //   12 = double click = MOUSE_DOUBLECLICK (11)
    //   14 = CSliderValueChangeEvent = SLIDER_VALUE_CHANGED (13)
    //   15 = the edit box family (0x400b0064, kkapi_local_plugin.dll only): [UNVERIFIED] EDITBOX_ENTER (16)
    // 5, 13, 16 and 17 are never produced, so a script registered on them never ran in the original game:
    // null here, and DzCompat_RegisterFrameEvents registers nothing for them (it used to fire them as
    // MOUSE_DOWN, SPRITE_ANIM_UPDATE, DIALOG_ACCEPT and EDITBOX_ENTER).
    function DzCompat_ConvertFrameEvent takes integer eventId returns frameeventtype
        if eventId == 10 then
            return FRAMEEVENT_MOUSE_UP
        elseif eventId == 11 or eventId == 12 or eventId == 14 then
            return ConvertFrameEventType(eventId - 1)
        elseif eventId == 15 then
            return FRAMEEVENT_EDITBOX_ENTER
        elseif (eventId >= 1 and eventId <= 4) or (eventId >= 6 and eventId <= 9) then
            return ConvertFrameEventType(eventId)
        endif
        return null
    endfunction

    // Trigger condition for click registrations: passes the first click event of a frame
    // and rejects the twin event of the same click (see DZCOMPAT_CLICK_WINDOW).
    //
    // Click events fire (and this condition runs) identically for every client,
    // not just the clicking one - so the old single, player-less (frame, time) pair was
    // shared by everyone: if a second player clicked the SAME frame within the window
    // (a shared shop button, say), their real, separate click looked exactly like the
    // first player's own CONTROL_CLICK/MOUSE_UP twin and was silently dropped for
    // everyone. Keying by (frame, player) tells the two apart.
    function DzCompat_ClickGate takes nothing returns boolean
        local framehandle f = BlzGetTriggerFrame()
        local integer fid
        local integer pid
        local real now = 0.
        if f == null then
            return true
        endif
        set fid = GetHandleId(f)
        set pid = GetPlayerId(GetTriggerPlayer())
        if gDzCompatClickClock != null then
            set now = TimerGetElapsed(gDzCompatClickClock)
        endif
        if HaveSavedReal(gDzCompatClickTimes, fid, pid) and now - LoadReal(gDzCompatClickTimes, fid, pid) < DZCOMPAT_CLICK_WINDOW then
            return false
        endif
        call SaveReal(gDzCompatClickTimes, fid, pid, now)
        return true
    endfunction

    // The clock behind the click gate. Created once, here, rather than inside the gate
    // itself, simply so a hot path (every click, by every player) doesn't allocate a new
    // timer handle each time - not because of any client/local distinction. (See
    // DzCompat_ClickGate's own note: a frame click's condition and action run
    // identically on every client, so there is nothing local about this at all.)
    function DzCompat_ClickClockEnsure takes nothing returns nothing
        if gDzCompatClickClock == null then
            set gDzCompatClickClock = CreateTimer()
            call TimerStart(gDzCompatClickClock, 999999., false, null)
        endif
        if gDzCompatClickCond == null then
            set gDzCompatClickCond = Condition(function DzCompat_ClickGate)
        endif
    endfunction

    // Runs before the map's own callback for a click: hands the keyboard focus back. A
    // GLUETEXTBUTTON that keeps the focus after a click swallows the map's hotkeys.
    //
    // Keyboard focus is a per-client UI concern - restoring it is only
    // meaningful, and only safe, on the clicking player's own client. This used to run
    // unconditionally (for every client, since the click action itself runs for
    // everyone) and gated the toggle on BlzFrameGetEnable(f), which reads whatever that
    // ONE client's local view of the frame's enabled state happens to be. A very common
    // UI pattern disables a frame only inside a GetLocalPlayer()==player block (so only
    // that player sees it go grey), which makes BlzFrameGetEnable(f) disagree between
    // clients - so this toggle used to run on some clients and not others for the exact
    // same click: a desync. Guarding on GetLocalPlayer() == GetTriggerPlayer() instead
    // (matching how a real Dz build does this) keeps the effect local and identical in
    // spirit for whichever client actually needs it, with no state-dependent condition
    // in the way.
    function DzCompat_FixTick takes nothing returns nothing
        local integer i = 0
        local integer n = gDzCompatFixCount
        set gDzCompatFixCount = 0
        loop
            exitwhen i >= n
            if gDzCompatFixFrame[i] != null then
                call BlzFrameSetFocus(gDzCompatFixFrame[i], false)
            endif
            set gDzCompatFixFrame[i] = null
            set i = i + 1
        endloop
    endfunction

    function DzCompat_ClickFix takes nothing returns nothing
        local framehandle f = BlzGetTriggerFrame()
        if f != null and GetLocalPlayer() == GetTriggerPlayer() then
            if DZCOMPAT_CLICKFIX_MODE == 0 then
                call BlzFrameSetEnable(f, false)
                call BlzFrameSetEnable(f, true)
            elseif DZCOMPAT_CLICKFIX_MODE == 3 and gDzCompatFixCount < 8 then
                set gDzCompatFixFrame[gDzCompatFixCount] = f
                set gDzCompatFixCount = gDzCompatFixCount + 1
                if gDzCompatFixCount == 1 then
                    if gDzCompatFixTimer == null then
                        set gDzCompatFixTimer = CreateTimer()
                    endif
                    call TimerStart(gDzCompatFixTimer, 0.05, false, function DzCompat_FixTick)
                endif
            endif
        endif
        set f = null
    endfunction

    function DzCompat_MouseFocusEnter takes nothing returns nothing
        local framehandle f = BlzGetTriggerFrame()
        if f != null then
            set gDzCompatMouseFocusId = GetHandleId(f)
        endif
    endfunction

    function DzCompat_MouseFocusLeave takes nothing returns nothing
        set gDzCompatMouseFocusId = 0
    endfunction

    function DzGetMouseFocus takes nothing returns integer
        return gDzCompatMouseFocusId
    endfunction

    // Dz event ids 1 (CONTROL_CLICK) and 4 (MOUSE_UP) both mean "the frame was clicked".
    function DzCompat_IsClickEvent takes integer eventId returns boolean
        return eventId == 1 or eventId == 4
    endfunction

    function DzCompat_HoverDeferFlush takes nothing returns nothing
        local integer i = 0
        set gDzCompatHoverDeferReady = true
        loop
            exitwhen i >= gDzCompatHoverDeferCount
            call BlzTriggerRegisterFrameEvent(gDzCompatHoverDeferTrig[i], gDzCompatHoverDeferFrame[i], DzCompat_ConvertFrameEvent(gDzCompatHoverDeferEvent[i]))
            set i = i + 1
        endloop
    endfunction

    function DzCompat_RegisterHoverEvent takes trigger trig, framehandle f, integer eventId returns nothing
        // DzGetMouseFocus tracking (see above) - added ahead of the map's own
        // callback action so gDzCompatMouseFocusId is already current by the time it runs.
        if eventId == 2 then
            call TriggerAddAction(trig, function DzCompat_MouseFocusEnter)
        else
            call TriggerAddAction(trig, function DzCompat_MouseFocusLeave)
        endif
        if gDzCompatHoverDeferReady then
            call BlzTriggerRegisterFrameEvent(trig, f, DzCompat_ConvertFrameEvent(eventId))
            return
        endif
        if not gDzCompatHoverDeferArmed then
            set gDzCompatHoverDeferArmed = true
            call TimerStart(CreateTimer(), 0., false, function DzCompat_HoverDeferFlush)
        endif
        set gDzCompatHoverDeferTrig[gDzCompatHoverDeferCount] = trig
        set gDzCompatHoverDeferFrame[gDzCompatHoverDeferCount] = f
        set gDzCompatHoverDeferEvent[gDzCompatHoverDeferCount] = eventId
        set gDzCompatHoverDeferCount = gDzCompatHoverDeferCount + 1
    endfunction

    // Registers the frame event(s) for eventId on trig. A click event is registered as both
    // CONTROL_CLICK and MOUSE_UP, because which of the two Reforged sends depends on the
    // frame's type and template. MOUSE_ENTER/MOUSE_LEAVE (hover) go through the deferred
    // path above instead of registering immediately.
    function DzCompat_RegisterFrameEvents takes trigger trig, framehandle f, integer eventId returns nothing
        if DzCompat_ConvertFrameEvent(eventId) == null then
            return
        elseif DzCompat_IsClickEvent(eventId) then
            call BlzTriggerRegisterFrameEvent(trig, f, ConvertFrameEventType(1))
            call BlzTriggerRegisterFrameEvent(trig, f, ConvertFrameEventType(4))
        elseif eventId == 2 or eventId == 3 then
            call DzCompat_RegisterHoverEvent(trig, f, eventId)
        else
            call BlzTriggerRegisterFrameEvent(trig, f, DzCompat_ConvertFrameEvent(eventId))
        endif
    endfunction

    // One script per (frame, event), as in DzAPI: registering again replaces the previous
    // one. sync is not a real choice here - see the note above DzCompat_ClickGate: a
    // frame click's condition/action run on every client already, regardless of this
    // flag - so it is accepted and ignored, as before.
    function DzCompat_HoverDispatch takes integer id, integer eventId returns nothing
        local trigger user = LoadTriggerHandle(gDzCompatFrameEvt, id, eventId + 20)
        if user == null or DzCompat_GetFrame(id) == null then
            set user = null
            return
        endif
        set gDzCompatHoverOverride = true
        set gDzCompatHoverOverrideId = id
        call TriggerExecute(user)
        set gDzCompatHoverOverride = false
        set user = null
    endfunction

    function DzCompat_HoverPoll takes nothing returns nothing
        local integer i = 0
        local integer j = 0
        local integer k
        local integer n = gDzCompatHoverWatchCount
        local integer m
        local integer id
        local framehandle f
        local framehandle tip
        local boolean vis
        loop
            exitwhen i >= n
            set id = gDzCompatHoverWatchId[i]
            set f = DzCompat_GetFrame(id)
            set tip = gDzCompatHoverTip[id]
            if f == null or tip == null then
                call FlushChildHashtable(gDzCompatHoverState, id)
            else
                set gDzCompatHoverWatchId[j] = id
                set j = j + 1
                set vis = BlzFrameIsVisible(tip)
                if vis != LoadBoolean(gDzCompatHoverState, id, 0) then
                    call SaveBoolean(gDzCompatHoverState, id, 0, vis)
                    if vis then
                        set gDzCompatMouseFocusId = GetHandleId(f)
                        call DzCompat_HoverDispatch(id, 2)
                    else
                        if gDzCompatMouseFocusId == GetHandleId(f) then
                            set gDzCompatMouseFocusId = 0
                        endif
                        call DzCompat_HoverDispatch(id, 3)
                    endif
                endif
            endif
            set i = i + 1
        endloop
        set m = gDzCompatHoverWatchCount
        set k = n
        loop
            exitwhen k >= m
            set gDzCompatHoverWatchId[j] = gDzCompatHoverWatchId[k]
            set j = j + 1
            set k = k + 1
        endloop
        set gDzCompatHoverWatchCount = j
        if j == 0 and gDzCompatHoverPollTimer != null then
            call PauseTimer(gDzCompatHoverPollTimer)
        endif
        set f = null
        set tip = null
    endfunction

    function DzCompat_HoverEnroll takes integer id returns nothing
        local framehandle f = DzCompat_GetFrame(id)
        local framehandle tip
        if f == null then
            return
        endif
        if gDzCompatHoverTip[id] == null then
            set tip = BlzCreateFrameByType("FRAME", "DzCompatHoverTip", BlzGetOriginFrame(ORIGIN_FRAME_GAME_UI, 0), "", 0)
            if tip == null then
                set f = null
                return
            endif
            call BlzFrameSetSize(tip, 0.0001, 0.0001)
            call BlzFrameSetAbsPoint(tip, FRAMEPOINT_BOTTOMLEFT, 0., 0.)
            call BlzFrameSetTooltip(f, tip)
            set gDzCompatHoverTip[id] = tip
        endif
        if not LoadBoolean(gDzCompatHoverState, id, 1) and gDzCompatHoverWatchCount < 2000 then
            call SaveBoolean(gDzCompatHoverState, id, 1, true)
            set gDzCompatHoverWatchId[gDzCompatHoverWatchCount] = id
            set gDzCompatHoverWatchCount = gDzCompatHoverWatchCount + 1
            if gDzCompatHoverWatchCount == 1 then
                if gDzCompatHoverPollTimer == null then
                    set gDzCompatHoverPollTimer = CreateTimer()
                endif
                call TimerStart(gDzCompatHoverPollTimer, 0.03, true, function DzCompat_HoverPoll)
            endif
        endif
        set f = null
        set tip = null
    endfunction

    function DzCompat_HoverNow takes nothing returns real
        if gDzCompatHoverClock == null then
            set gDzCompatHoverClock = CreateTimer()
            call TimerStart(gDzCompatHoverClock, 3600., false, null)
        endif
        return TimerGetElapsed(gDzCompatHoverClock)
    endfunction

    function DzCompat_HoverFlushCore takes boolean forceAll returns nothing
        local integer i = 0
        local integer j = 0
        local integer n = gDzCompatHoverPendingCount
        local integer id
        local real now = DzCompat_HoverNow()
        loop
            exitwhen i >= n
            set id = gDzCompatHoverPendingId[i]
            if LoadBoolean(gDzCompatHoverPending, id, 0) then
                if forceAll or now - LoadReal(gDzCompatHoverPending, id, 1) >= DZCOMPAT_HOVER_LEAVE_QUIET then
                    call SaveBoolean(gDzCompatHoverPending, id, 0, false)
                    call DzCompat_HoverDispatch(id, 3)
                    call DzCompat_HoverRearm(id)
                else
                    set gDzCompatHoverPendingId[j] = id
                    set j = j + 1
                endif
            endif
            set i = i + 1
        endloop
        set gDzCompatHoverPendingCount = j
        if j == 0 and gDzCompatHoverFlushTimer != null then
            call PauseTimer(gDzCompatHoverFlushTimer)
        endif
    endfunction

    function DzCompat_HoverFlushLeaves takes nothing returns nothing
        call DzCompat_HoverFlushCore(true)
    endfunction

    function DzCompat_HoverLeaveTick takes nothing returns nothing
        call DzCompat_HoverFlushCore(false)
    endfunction

    function DzCompat_HoverRelay takes nothing returns nothing
        local framehandle f = BlzGetTriggerFrame()
        local integer id = 0
        if f != null and HaveSavedInteger(gDzCompatReverseLookup, GetHandleId(f), 0) then
            set id = LoadInteger(gDzCompatReverseLookup, GetHandleId(f), 0)
        endif
        set f = null
        if id == 0 then
            return
        endif
        if BlzGetTriggerFrameEvent() == FRAMEEVENT_MOUSE_ENTER then
            if LoadBoolean(gDzCompatHoverPending, id, 0) then
                // LEAVE + ENTER of the same frame: not a real hover change, drop both
                call SaveBoolean(gDzCompatHoverPending, id, 0, false)
            else
                // the cursor is on a different frame now: every other pending LEAVE is real
                call DzCompat_HoverFlushLeaves()
                call DzCompat_HoverDispatch(id, 2)
                if DZCOMPAT_HOVER_ONESHOT then
                    set gDzCompatHoverDisarmId[gDzCompatHoverDisarmCount] = id
                    set gDzCompatHoverDisarmCount = gDzCompatHoverDisarmCount + 1
                    if gDzCompatHoverDisarmCount == 1 then
                        if gDzCompatHoverDisarmTimer == null then
                            set gDzCompatHoverDisarmTimer = CreateTimer()
                        endif
                        call TimerStart(gDzCompatHoverDisarmTimer, 0., false, function DzCompat_HoverDisarmFlush)
                    endif
                endif
            endif
        else
            call SaveReal(gDzCompatHoverPending, id, 1, DzCompat_HoverNow())
            if not LoadBoolean(gDzCompatHoverPending, id, 0) then
                call SaveBoolean(gDzCompatHoverPending, id, 0, true)
                if gDzCompatHoverPendingCount >= 500 then
                    call DzCompat_HoverFlushLeaves()
                endif
                set gDzCompatHoverPendingId[gDzCompatHoverPendingCount] = id
                set gDzCompatHoverPendingCount = gDzCompatHoverPendingCount + 1
                if gDzCompatHoverPendingCount == 1 then
                    if gDzCompatHoverFlushTimer == null then
                        set gDzCompatHoverFlushTimer = CreateTimer()
                    endif
                    call TimerStart(gDzCompatHoverFlushTimer, 0.05, true, function DzCompat_HoverLeaveTick)
                endif
            endif
        endif
    endfunction

    function DzFrameSetScriptByCode takes integer frame, integer eventId, code funcHandle, boolean sync returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        local trigger trig
        local trigger user
        if f == null or funcHandle == null or eventId < 1 then
            return
        endif
        set trig = LoadTriggerHandle(gDzCompatFrameEvt, frame, eventId)
        if trig != null then
            call DestroyTrigger(trig)
        endif
        set user = LoadTriggerHandle(gDzCompatFrameEvt, frame, eventId + 20)
        if user != null then
            call DestroyTrigger(user)
            call RemoveSavedHandle(gDzCompatFrameEvt, frame, eventId + 20)
        endif
        if DZCOMPAT_HOVER_VIA_TOOLTIP and (eventId == 2 or eventId == 3) then
            set user = CreateTrigger()
            call TriggerAddAction(user, funcHandle)
            call SaveTriggerHandle(gDzCompatFrameEvt, frame, eventId + 20, user)
            call DzCompat_HoverEnroll(frame)
            set user = null
            set f = null
            return
        endif
        set trig = CreateTrigger()
        call DzCompat_RegisterFrameEvents(trig, f, eventId)
        if DzCompat_IsClickEvent(eventId) then
            call DzCompat_ClickClockEnsure()
            call TriggerAddCondition(trig, gDzCompatClickCond)
            call TriggerAddAction(trig, function DzCompat_ClickFix)
        endif
        if eventId == 2 or eventId == 3 then
            // hover events go through a relay that swallows same-tick LEAVE+ENTER flaps
            set user = CreateTrigger()
            call TriggerAddAction(user, funcHandle)
            call SaveTriggerHandle(gDzCompatFrameEvt, frame, eventId + 20, user)
            call TriggerAddAction(trig, function DzCompat_HoverRelay)
            set gDzCompatHoverRelayCode = function DzCompat_HoverRelay
            set gDzCompatHoverEnterCode = function DzCompat_MouseFocusEnter
        else
            call TriggerAddAction(trig, funcHandle)
        endif
        set user = null
        call SaveTriggerHandle(gDzCompatFrameEvt, frame, eventId, trig)
        set trig = null
    endfunction

    function DzFrameSetScriptBlock takes integer frame, integer eventId, code funcHandle, boolean sync returns nothing
        call DzFrameSetScriptByCode(frame, eventId, funcHandle, sync)
    endfunction

    function DzFrameSetScriptByCodeAsync takes integer frame, integer eventId, code func returns nothing
        call DzFrameSetScriptByCode(frame, eventId, func, false)
    endfunction

    function DzFrameSetScriptBlockAsync takes integer frame, integer eventId, code func returns nothing
        call DzFrameSetScriptByCode(frame, eventId, func, false)
    endfunction

    // ---- string-name variants ---------------------------------------------
    // A function can be registered once (anywhere in your init code, before
    // it's referenced) via:
    //   call DzCompat_RegisterFuncName("MyHandler", function MyHandler)
    // After that, DzFrameSetScript("MyHandler") resolves to the same
    // registered code and behaves like the ByCode variant. A name that was
    // not registered is run by name (ExecuteFunc), see DzCompat_ResolveFuncByName.
    function DzCompat_RegisterFuncName takes string name, code func returns nothing
        local trigger trig = CreateTrigger()
        call TriggerAddAction(trig, func)
        call SaveTriggerHandle(gDzCompatFuncTriggers, StringHash(name), 0, trig)
    endfunction

    // Action of the trigger DzCompat_ResolveFuncByName makes for a name nobody registered.
    function DzCompat_RunNamedFunc takes nothing returns nothing
        local string name = LoadStr(gDzCompatFuncTriggers, GetHandleId(GetTriggeringTrigger()), 1)
        if name != null and name != "" then
            call ExecuteFunc(name)
        endif
    endfunction

    // A name passed to DzCompat_RegisterFuncName uses that registration. Any other name is run the way the
    // real client runs it, by NAME (dzclient_api.dll 0x1000cbb0 calls the function by name; the synced frame
    // event does ExecuteFunc(name), 0x10017c70): a shared trigger per name whose action is ExecuteFunc.
    // Before, an unregistered name only printed a debug message and the frame did nothing - and maps build
    // many of these names at run time ("tianfutisdj" + I2S(i)), which no list made in advance can hold.
    // The name must be a function of the script, as it had to be in the original game.
    function DzCompat_ResolveFuncByName takes string name returns trigger
        local trigger trig
        if name == null or name == "" then
            return null
        endif
        if HaveSavedHandle(gDzCompatFuncTriggers, StringHash(name), 0) then
            return LoadTriggerHandle(gDzCompatFuncTriggers, StringHash(name), 0)
        endif
        set trig = CreateTrigger()
        call TriggerAddAction(trig, function DzCompat_RunNamedFunc)
        call SaveStr(gDzCompatFuncTriggers, GetHandleId(trig), 1, name)
        call SaveTriggerHandle(gDzCompatFuncTriggers, StringHash(name), 0, trig)
        return trig
    endfunction

    function DzFrameSetScript takes integer frame, integer eventId, string func, boolean sync returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        local trigger trig = DzCompat_ResolveFuncByName(func)
        if trig != null and f != null then
            call DzCompat_RegisterFrameEvents(trig, f, eventId)
            if DzCompat_IsClickEvent(eventId) then
                // the same click gate as DzFrameSetScriptByCode; the named trigger is shared,
                // so the gate is attached once per trigger (it tells frames apart itself)
                call DzCompat_ClickClockEnsure()
                if not HaveSavedBoolean(gDzCompatFrameEvt, GetHandleId(trig), 0) then
                    call SaveBoolean(gDzCompatFrameEvt, GetHandleId(trig), 0, true)
                    call TriggerAddCondition(trig, gDzCompatClickCond)
                endif
            endif
        endif
    endfunction

    function DzFrameSetScriptAsync takes integer frame, integer eventId, string funcName returns nothing
        call DzFrameSetScript(frame, eventId, funcName, false)
    endfunction

    // ---- Trigger-context accessors ---------------------------------------
    function DzGetTriggerUIEventPlayer takes nothing returns player
        return GetTriggerPlayer()
    endfunction

    function DzGetTriggerUIEventFrame takes nothing returns integer
        local framehandle f = BlzGetTriggerFrame()
        if gDzCompatHoverOverride then
            return gDzCompatHoverOverrideId
        endif
        if f == null or not HaveSavedInteger(gDzCompatReverseLookup, GetHandleId(f), 0) then
            return 0
        endif
        return LoadInteger(gDzCompatReverseLookup, GetHandleId(f), 0)
    endfunction

    // Frame id 0 is the "no frame" sentinel (matches Dz's convention of
    // 0/-1 for null) - no init needed for this, JASS arrays already default
    // every element to null/0 automatically.

    // ---- Child traversal --------------------------------------------
    function DzFrameGetChildrenCount takes integer whichframe returns integer
        local framehandle f = DzCompat_GetFrame(whichframe)
        if f == null then
            return 0
        endif
        return BlzFrameGetChildrenCount(f)
    endfunction

    function DzFrameGetChild takes integer whichframe, integer index returns integer
        local framehandle parent = DzCompat_GetFrame(whichframe)
        local framehandle child = null
        if parent == null or index < 0 then
            return 0
        endif
        set child = BlzFrameGetChild(parent, index)
        if child == null then
            return 0
        endif
        return DzCompat_RegisterFrame(child)
    endfunction

    function DzFrameGetWidth takes integer frame returns real
        local framehandle f = DzCompat_GetFrame(frame)
        if f == null then
            return 0.
        endif
        return BlzFrameGetWidth(f)
    endfunction

    // [APPROX] no separate "real" (i.e. post-scale?) width/height native
    // exists - treating these as aliases of the plain width/height getters.
    // If your map actually needs the pre-scale vs. post-scale distinction
    // Dz seems to imply by having both, this won't capture that difference.
    function DzFrameGetRealWidth takes integer frame returns real
        return DzFrameGetWidth(frame)
    endfunction

    function DzFrameGetRealHeight takes integer frame returns real
        return DzFrameGetHeight(frame)
    endfunction

    // ---- Client / window resolution ---------------------------------------------
    function DzGetClientWidth takes nothing returns integer
        return BlzGetLocalClientWidth()
    endfunction

    function DzGetClientHeight takes nothing returns integer
        return BlzGetLocalClientHeight()
    endfunction

    function DzGetWindowWidth takes nothing returns integer
        return BlzGetLocalClientWidth()
    endfunction

    function DzGetWindowHeight takes nothing returns integer
        return BlzGetLocalClientHeight()
    endfunction

    // [PORT LIMITATION] Reforged has no equivalent 4:3/16:9-style UI scale
    function DzEnableWideScreen takes boolean enable returns nothing
    endfunction

    // [REAL] Swaps a unit's displayed model/stats-appearance to another unit type via
    // BlzSetUnitSkin and updates the displayed name to match,
	// since a skin change alone leaves the old name showing.
    function DzSetUnitID takes unit whichUnit, integer id returns nothing
        call BlzSetUnitSkin(whichUnit, id)
        call BlzSetUnitName(whichUnit, GetObjectName(id))
    endfunction

    // Whether the game window has focus (local). The neutral stub would answer "never active".
    function DzIsWindowActive takes nothing returns boolean
        return BlzIsLocalClientActive()
    endfunction

    // ---- [APPROX] checkbox state --------------------------------------------------
    // No dedicated checkbox native exists - Blizzard's own UI reuses the
    // generic Value field (0.0/1.0) for checkbox state, which is the standard
    // community technique for this.
    function DzFrameSetCheckBoxState takes integer check_box_frame, boolean checked returns nothing
        local framehandle f = DzCompat_GetFrame(check_box_frame)
        if f == null then
            return
        endif
        if checked then
            call BlzFrameSetValue(f, 1.0)
        else
            call BlzFrameSetValue(f, 0.0)
        endif
    endfunction

    function DzFrameGetCheckBoxState takes integer check_box_frame returns boolean
        local framehandle f = DzCompat_GetFrame(check_box_frame)
        if f == null then
            return false
        endif
        return BlzFrameGetValue(f) >= 0.5
    endfunction

    // ---- [LOCAL] name/context tagging ----------------------------------------------
    // Dz's GetContext/SetNameContext look like user-defined metadata tagging
    // rather than a reflection of any real engine attribute, so this is
    // implemented as our own bookkeeping via the same reverse-lookup
    // hashtable pattern used elsewhere in this file. Only frames tagged
    // through this function will return a context - it does not inspect
    // real frame state.
    function DzFrameSetNameContext takes integer frame, string name, integer context returns nothing
        call SaveInteger(gDzCompatReverseLookup, GetHandleId(DzCompat_GetFrame(frame)), 1, context)
        call SaveStr(gDzCompatReverseLookup, GetHandleId(DzCompat_GetFrame(frame)), 2, name)
    endfunction

    function DzFrameGetContext takes integer frame returns integer
        if not HaveSavedInteger(gDzCompatReverseLookup, GetHandleId(DzCompat_GetFrame(frame)), 1) then
            return 0
        endif
        return LoadInteger(gDzCompatReverseLookup, GetHandleId(DzCompat_GetFrame(frame)), 1)
    endfunction

    // ---- [LOCAL, APPROX] focus tracking ----------------------------------------
    // BlzFrameSetFocus is real (used above) but there's no getter native at
    // all. This tracks only calls made through DzFrameSetFocus itself.
    function DzFrameIsFocus takes integer frame returns boolean
        if not HaveSavedBoolean(gDzCompatFocusTrack, frame, 0) then
            return false
        endif
        return LoadBoolean(gDzCompatFocusTrack, frame, 0)
    endfunction
