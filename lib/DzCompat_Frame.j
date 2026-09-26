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

        // Cached GameUI origin frame (see DzCompat_GetGameUI).
        framehandle gDzCompatGameUI = null

    	framehandle gDzStableParent = null

        // (frame id, event id) -> the trigger DzFrameSetScriptByCode built for it.
        // DzAPI keeps ONE script per frame and event, so setting it again must replace
        // the earlier one instead of stacking a second callback on top of it.
        hashtable gDzCompatFrameEvt = InitHashtable()

        // ---- click handling ------------------------------------------------
        // In Reforged a click on a frame is reported as CONTROL_CLICK (1), as MOUSE_UP (4),
        // or as both in the same instant, depending on the frame's type and template. Dz
        // maps use 1 or 4 for "the frame was clicked". So both are registered, and the
        // gate below lets the first one through and drops its twin.
        boolexpr gDzCompatClickCond = null
        // [FIXED] was a single (frame, time) pair shared by every player - see
        // DzCompat_ClickGate. Keyed fid -> playerId -> last-accepted-click time, so two
        // different players clicking the same shared frame within the window are told
        // apart instead of the second player's real click being dropped as if it were
        // the first player's CONTROL_CLICK/MOUSE_UP twin.
        hashtable gDzCompatClickTimes = InitHashtable()
        timer gDzCompatClickClock = null
        // Two click events for the same frame closer together than this are one click.
        constant real DZCOMPAT_CLICK_WINDOW = 0.20

        // A frame of type BUTTON that inherits no template does not report clicks in
        // Reforged (it still reports mouse enter/leave); GLUETEXTBUTTON does. When true,
        // DzCreateFrameByTagName falls back to GLUETEXTBUTTON for such a BUTTON.
        constant boolean DZCOMPAT_BUTTON_AS_GLUE_BUTTON = true

		// ---- [FIXED] deferred hover registration -----------------------------------
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

    // The frame that should own a new frame. A parent id that is 0 or does not name a
    // frame (for example one that was already destroyed) falls back to the GameUI, so a
    // frame is never created with a null owner.
    function DzCompat_GetOwnerFrame takes integer parent returns framehandle
        local framehandle f = DzCompat_GetFrame(parent)
        if f == null then
            return DzCompat_GetGameUI()
        endif
        return f
    endfunction

    function DzCreateFrame takes string frame, integer parent, integer id returns integer
        return DzCompat_RegisterFrameNamed(BlzCreateFrame(frame, DzCompat_GetOwnerFrame(parent), 0, id), frame, id)
    endfunction

    function DzCreateSimpleFrame takes string frame, integer parent, integer id returns integer
        return DzCompat_RegisterFrameNamed(BlzCreateSimpleFrame(frame, DzCompat_GetOwnerFrame(parent), id), frame, id)
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
        if regName == null or regName == "" then
            set regName = "__FrameGen_" + I2S(GetRandomInt(1, 100000))
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
        return DzCompat_RegisterFrameNamed(f, regName, id)
    endfunction

    function DzDestroyFrame takes integer frame returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        if f == null then
            return
        endif
        call BlzDestroyFrame(f)
        set gDzCompatFrame[frame] = null
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
    
    // Return a proxy frame that is a child of a STABLE parent.
    local framehandle proxy = BlzCreateFrameByType("BACKDROP", "DzHeroProxy" + I2S(buttonId), DzCompat_GetStableParent(), "", 0)
    
    // Make it invisible
    call BlzFrameSetAlpha(proxy, 0)
    
    // Give it the same size as the real button
    if realBtn != null then
        call BlzFrameSetSize(proxy, BlzFrameGetWidth(realBtn), BlzFrameGetHeight(realBtn))
    else
        call BlzFrameSetSize(proxy, 0.03, 0.03) // fallback size
    endif
    
    // Position it using ABSOLUTE coordinates in the 4:3 UI space.
    // The hero buttons are at the LEFT side of the screen.
    // Coordinates: TOPLEFT (0.0, 0.55) is the typical hero bar position.
    call BlzFrameSetAbsPoint(proxy, FRAMEPOINT_TOPLEFT, 0.0, 0.55 - (buttonId * 0.04))
    
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
        return DzCompat_RegisterFrame(BlzGetOriginFrame(ORIGIN_FRAME_MINIMAP, 0))
    endfunction

    // buttonId: 0=Signal, 1=Terrain, 2=Ally filter, 3=Creep filter, 4=Formation
    function DzFrameGetMinimapButton takes integer buttonId returns integer
        return DzCompat_RegisterFrame(BlzGetOriginFrame(ORIGIN_FRAME_MINIMAP_BUTTON, buttonId))
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

    function DzFrameSetPoint takes integer frame, integer point, integer relativeFrame, integer relativePoint, real x, real y returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        local framehandle r = DzCompat_GetFrame(relativeFrame)
        if f == null or r == null or point < 0 or point > 8 or relativePoint < 0 or relativePoint > 8 then
            return
        endif
        call BlzFrameSetPoint(f, ConvertFramePointType(point), r, ConvertFramePointType(relativePoint), x, y)
    endfunction

    function DzFrameSetAbsolutePoint takes integer frame, integer point, real x, real y returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        if f == null or point < 0 or point > 8 then
            return
        endif
        call BlzFrameSetAbsPoint(f, ConvertFramePointType(point), x, y)
    endfunction

    function DzFrameSetAllPoints takes integer frame, integer relativeFrame returns boolean
        local framehandle f = DzCompat_GetFrame(frame)
        local framehandle r = DzCompat_GetFrame(relativeFrame)
        if f == null or r == null then
            return false
        endif
        call BlzFrameSetAllPoints(f, r)
        return true
    endfunction

    function DzFrameClearAllPoints takes integer frame returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        if f != null then
            call BlzFrameClearAllPoints(f)
        endif
    endfunction

    function DzFrameSetSize takes integer frame, real w, real h returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        if f != null then
            call BlzFrameSetSize(f, w, h)
        endif
    endfunction

    function DzFrameSetParent takes integer frame, integer parent returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        local framehandle p = DzCompat_GetFrame(parent)
        if f != null and p != null then
            call BlzFrameSetParent(f, p)
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
        if f != null then
            call BlzFrameSetTexture(f, texture, flag, true)
        endif
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
        if f != null and modelFile != null then
            call BlzFrameSetModel(f, modelFile, modelType)
        endif
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

    function DzGetColor takes integer r, integer g, integer b, integer a returns integer
        return BlzConvertColor(a, r, g, b)
    endfunction

    function DzFrameSetText takes integer frame, string text returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        if f != null then
            call BlzFrameSetText(f, text)
        endif
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
        if f != null then
            call BlzFrameAddText(f, text)
        endif
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

    // [FIXED] The previous version treated align as ConvertTextAlignType's own two index
    // sets (0-2 vertical, 3-5 horizontal) - a reasonable-looking guess, but wrong: a real
    // converted map's own align values include 0, 6, 7 and 50, all outside that 0-5
    // range, so most calls were silently dropped by the old bounds check. A comparison
    // tool that ships a working DzFrameSetTextAlignment treats 0 and 100 as LEFT/RIGHT
    // with vertical always MIDDLE - i.e. align is a 0-100 horizontal position, not a
    // vertical/horizontal selector - which is also consistent with the same real map's
    // own 0/50 pairs (used to flip a tab label between left-aligned and centered to show
    // which tab is selected). Bucketing 0-100 into thirds additionally covers 6 and 7
    // (both round down to LEFT, which fits their real use on left-justified tooltip
    // text) without needing an exact 0/50/100 match.
    function DzFrameSetTextAlignment takes integer frame, integer align returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        local integer horz
        if f == null or align < 0 then
            return
        endif
        if align <= 33 then
            set horz = 3 // TEXT_JUSTIFY_LEFT
        elseif align >= 67 then
            set horz = 5 // TEXT_JUSTIFY_RIGHT
        else
            set horz = 4 // TEXT_JUSTIFY_CENTER
        endif
        call BlzFrameSetTextAlignment(f, ConvertTextAlignType(1), ConvertTextAlignType(horz)) // vertical always MIDDLE
    endfunction

    function DzFrameSetFont takes integer frame, string fileName, real height, integer flag returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        if f != null then
            call BlzFrameSetFont(f, fileName, height, flag)
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

    // ---- [ASSUMPTION] frame event registration ---------------------------------
    // Dz's eventId integers are assumed to reuse Reforged's own FRAMEEVENT_
    // numbering (CONTROL_CLICK=1, MOUSE_ENTER=2, MOUSE_LEAVE=3, MOUSE_UP=4,
    // MOUSE_DOWN=5, MOUSE_WHEEL=6, CHECKBOX_CHECKED=7, CHECKBOX_UNCHECKED=8,
    // EDITBOX_TEXT_CHANGED=9, POPUPMENU_ITEM_CHANGED=10, MOUSE_DOUBLECLICK=11,
    // SPRITE_ANIM_UPDATE=12, SLIDER_VALUE_CHANGED=13, DIALOG_CANCEL=14,
    // DIALOG_ACCEPT=15, EDITBOX_ENTER=16), since Dz's frame system sits on
    // top of the same underlying engine. [UNVERIFIED] - if clicks fire
    // as "mouse enter" or nothing fires at all, this numbering is wrong for
    // your Dz build.
    //
    // "sync" isn't reproducible as a separate mode - it's not a choice: a frame click's
    // trigger condition/action already runs on every client for every registrant (see
    // DzCompat_ClickGate and DzCompat_ClickFix below for what that actually implies -
    // code here must not branch on anything that can read differently per client, e.g. a
    // frame's local enabled/visible state). Every variant below (sync, async, block)
    // behaves identically as a result.

    // [APPROX] Dz/Bz frame-event id quirk adopted from maxou:
    // event ids above 10 are stored one higher than ConvertFrameEventType
    // expects, so subtract 1 before converting. Ids 0..10 pass through.
    // If a specific event never fires after conversion, this is the first
    // place to re-check against your map's Dz build.
    function DzCompat_ConvertFrameEvent takes integer eventId returns frameeventtype
        if eventId > 10 then
            return ConvertFrameEventType(eventId - 1)
        endif
        return ConvertFrameEventType(eventId)
    endfunction

    // Trigger condition for click registrations: passes the first click event of a frame
    // and rejects the twin event of the same click (see DZCOMPAT_CLICK_WINDOW).
    //
    // [FIXED] Click events fire (and this condition runs) identically for every client,
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
    // [FIXED] Keyboard focus is a per-client UI concern - restoring it is only
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
    function DzCompat_ClickFix takes nothing returns nothing
        local framehandle f = BlzGetTriggerFrame()
        if f != null and GetLocalPlayer() == GetTriggerPlayer() then
            call BlzFrameSetEnable(f, false)
            call BlzFrameSetEnable(f, true)
        endif
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
        if DzCompat_IsClickEvent(eventId) then
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
    function DzFrameSetScriptByCode takes integer frame, integer eventId, code funcHandle, boolean sync returns nothing
        local framehandle f = DzCompat_GetFrame(frame)
        local trigger trig
        if f == null or funcHandle == null or eventId < 1 then
            return
        endif
        set trig = LoadTriggerHandle(gDzCompatFrameEvt, frame, eventId)
        if trig != null then
            call DestroyTrigger(trig)
        endif
        set trig = CreateTrigger()
        call DzCompat_RegisterFrameEvents(trig, f, eventId)
        if DzCompat_IsClickEvent(eventId) then
            call DzCompat_ClickClockEnsure()
            call TriggerAddCondition(trig, gDzCompatClickCond)
            call TriggerAddAction(trig, function DzCompat_ClickFix)
        endif
        call TriggerAddAction(trig, funcHandle)
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
    // JASS cannot resolve "call the function named by this string" the way
    // Dz's engine could - you must register each function once (anywhere in
    // your init code, before it's referenced) via:
    //   call DzCompat_RegisterFuncName("MyHandler", function MyHandler)
    // After that, DzFrameSetScript("MyHandler") resolves to the same
    // registered code and behaves like the ByCode variant.
    function DzCompat_RegisterFuncName takes string name, code func returns nothing
        local trigger trig = CreateTrigger()
        call TriggerAddAction(trig, func)
        call SaveTriggerHandle(gDzCompatFuncTriggers, StringHash(name), 0, trig)
    endfunction

    function DzCompat_ResolveFuncByName takes string name returns trigger
        if not HaveSavedHandle(gDzCompatFuncTriggers, StringHash(name), 0) then
            call BJDebugMsg("DzCompat: no function registered for name \"" + name + "\" - call DzCompat_RegisterFuncName first")
            return null
        endif
        return LoadTriggerHandle(gDzCompatFuncTriggers, StringHash(name), 0)
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
