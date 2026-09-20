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

	function DzCreateFrame takes string frame, integer parent, integer id returns integer
       return DzCompat_RegisterFrameNamed(BlzCreateFrame(frame, DzCompat_GetFrame(parent), 0, id), frame, id)
	endfunction

	function DzCreateSimpleFrame takes string frame, integer parent, integer id returns integer
        return DzCompat_RegisterFrameNamed(BlzCreateSimpleFrame(frame, DzCompat_GetFrame(parent), id), frame, id)
	endfunction

	function DzCreateFrameByTagName takes string frameType, string name, integer parent, string template, integer id returns integer
		local string regName = name
		if regName == null or regName == "" then
			set regName = "__FrameGen_" + I2S(GetRandomInt(1, 100000))
		endif
        return DzCompat_RegisterFrameNamed(BlzCreateFrameByType(frameType, regName, DzCompat_GetFrame(parent), template, id), regName, id)
	endfunction

    function DzDestroyFrame takes integer frame returns nothing
        call BlzDestroyFrame(DzCompat_GetFrame(frame))
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
    function KKSimpleFrameIsVisible takes integer simple_frame returns boolean
        return DzFrameIsVisible(simple_frame)
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

    function DzFrameGetHeroBarButton takes integer buttonId returns integer
        return DzCompat_RegisterFrame(BlzGetOriginFrame(ORIGIN_FRAME_HERO_BUTTON, buttonId))
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
    // index 0 returns it, higher indices walk children via DzFrameGetChild.
    function DzFrameGetInfoPanelBuffButton takes integer index returns integer
        local integer container = DzCompat_RegisterFrame(BlzGetOriginFrame(ORIGIN_FRAME_UNIT_PANEL_BUFF_BAR, 0))
        if index <= 0 then
            return container
        endif
        return DzFrameGetChild(container, index - 1)
    endfunction

	function DzFrameSetPoint takes integer frame, integer point, integer relativeFrame, integer relativePoint, real x, real y returns nothing
        call BlzFrameSetPoint(DzCompat_GetFrame(frame), ConvertFramePointType(point), DzCompat_GetFrame(relativeFrame), ConvertFramePointType(relativePoint), x, y)
	endfunction
	
	function DzFrameSetAbsolutePoint takes integer frame, integer point, real x, real y returns nothing
        call BlzFrameSetAbsPoint(DzCompat_GetFrame(frame), ConvertFramePointType(point), x, y)
	endfunction

    function DzFrameSetAllPoints takes integer frame, integer relativeFrame returns boolean
        call BlzFrameSetAllPoints(DzCompat_GetFrame(frame), DzCompat_GetFrame(relativeFrame))
        return true
    endfunction

    function DzFrameClearAllPoints takes integer frame returns nothing
        call BlzFrameClearAllPoints(DzCompat_GetFrame(frame))
    endfunction

    function DzFrameSetSize takes integer frame, real w, real h returns nothing
        call BlzFrameSetSize(DzCompat_GetFrame(frame), w, h)
    endfunction

    function DzFrameSetParent takes integer frame, integer parent returns nothing
        call BlzFrameSetParent(DzCompat_GetFrame(frame), DzCompat_GetFrame(parent))
    endfunction

    function DzFrameGetParent takes integer frame returns integer
        return DzCompat_RegisterFrame(BlzFrameGetParent(DzCompat_GetFrame(frame)))
    endfunction

    function DzFrameGetHeight takes integer frame returns real
        return BlzFrameGetHeight(DzCompat_GetFrame(frame))
    endfunction

    // [APPROX] Dz's "priority" (set at creation) is treated here as frame
    // Level, which controls sibling draw/click order post-creation. Close in
    // effect, not identical semantics.
    function DzFrameSetPriority takes integer frame, integer priority returns nothing
        call BlzFrameSetLevel(DzCompat_GetFrame(frame), priority)
    endfunction

    // ---- Visibility / enable state -------------------------------
    function DzFrameShow takes integer frame, boolean enable returns nothing
        call BlzFrameSetVisible(DzCompat_GetFrame(frame), enable)
    endfunction

    function DzSimpleFrameShow takes integer frame, boolean enable returns nothing
        call BlzFrameSetVisible(DzCompat_GetFrame(frame), enable)
    endfunction

    function DzFrameIsVisible takes integer frame returns boolean
        return BlzFrameIsVisible(DzCompat_GetFrame(frame))
    endfunction

    function DzFrameSetEnable takes integer name, boolean enable returns nothing
        call BlzFrameSetEnable(DzCompat_GetFrame(name), enable)
    endfunction

    function DzFrameGetEnable takes integer frame returns boolean
        return BlzFrameGetEnable(DzCompat_GetFrame(frame))
    endfunction

    function DzFrameSetFocus takes integer frame, boolean enable returns boolean
        call BlzFrameSetFocus(DzCompat_GetFrame(frame), enable)
        call DzCompat_TrackFocus(frame, enable)
        return true
    endfunction

    function DzFrameSetAlpha takes integer frame, integer alpha returns nothing
        call BlzFrameSetAlpha(DzCompat_GetFrame(frame), alpha)
    endfunction

    function DzFrameGetAlpha takes integer frame returns integer
        return BlzFrameGetAlpha(DzCompat_GetFrame(frame))
    endfunction

    function DzFrameSetScale takes integer frame, real scale returns nothing
        call BlzFrameSetScale(DzCompat_GetFrame(frame), scale)
    endfunction

    function DzFrameSetTexture takes integer frame, string texture, integer flag returns nothing
        call BlzFrameSetTexture(DzCompat_GetFrame(frame), texture, flag, true)
    endfunction

    // [APPROX] Dz's 4th param ("flag") has nowhere to go: the real native is
    // BlzFrameSetModel(framehandle frame, string modelFile, integer cameraIndex)
    // - exactly 3 args, no room for a 4th. modelType maps to cameraIndex
    // (both select which camera/portrait slot the model uses). flag is
    // dropped on the floor with no engine equivalent - this is a hard
    // engine limitation. If your Dz maps pass anything other than 0 for flag
	// and rely on it doing something, that will probably not work properly
    function DzFrameSetModel takes integer frame, string modelFile, integer modelType, integer flag returns nothing
        call BlzFrameSetModel(DzCompat_GetFrame(frame), modelFile, modelType)
    endfunction

    function DzFrameSetVertexColor takes integer frame, integer color returns nothing
        call BlzFrameSetVertexColor(DzCompat_GetFrame(frame), color)
    endfunction

    // [UNVERIFIED] Dz's "autocast" boolean is best-effort mapped onto
    // BlzFrameSetSpriteAnimate's flags param as bit 0 (1 = flag set, 0 =
    // clear). If animations play differently than expected (e.g.
    // looping/blending looks wrong), that's the first place to look - try
    // flipping this to 0/nonzero and compare, or drop it back to a
    // hardcoded 0 if it makes things worse.
    function DzFrameSetAnimate takes integer frame, integer animId, boolean autocast returns nothing
        local integer flags = 0
        if autocast then
            set flags = 1
        endif
        call BlzFrameSetSpriteAnimate(DzCompat_GetFrame(frame), animId, flags)
    endfunction

    function DzGetColor takes integer r, integer g, integer b, integer a returns integer
        return BlzConvertColor(a, r, g, b)
    endfunction

    function DzFrameSetText takes integer frame, string text returns nothing
        call BlzFrameSetText(DzCompat_GetFrame(frame), text)
    endfunction

    function DzFrameGetText takes integer frame returns string
        return BlzFrameGetText(DzCompat_GetFrame(frame))
    endfunction

    function DzFrameAddText takes integer frame, string text returns nothing
        call BlzFrameAddText(DzCompat_GetFrame(frame), text)
    endfunction

    function DzFrameSetTextColor takes integer frame, integer color returns nothing
        call BlzFrameSetTextColor(DzCompat_GetFrame(frame), color)
    endfunction
	
    function DzFrameSetTextSizeLimit takes integer frame, integer size returns nothing
        call BlzFrameSetTextSizeLimit(DzCompat_GetFrame(frame), size) 
    endfunction
	
    function DzFrameGetTextSizeLimit takes integer frame returns integer
        return BlzFrameGetTextSizeLimit(DzCompat_GetFrame(frame)) 
    endfunction

    function DzFrameSetTextAlignment takes integer frame, integer align returns nothing
        // Dz packs vertical+horizontal into one int; if your Dz constants file
        // defines the packing scheme, split it into two
        // BlzFrameSetTextAlignment(frame, textaligntype vert, textaligntype horz)
        // arguments properly instead of this placeholder.
        call BlzFrameSetTextAlignment(DzCompat_GetFrame(frame), ConvertTextAlignType(align), ConvertTextAlignType(align))
    endfunction

    function DzFrameSetFont takes integer frame, string fileName, real height, integer flag returns nothing
        call BlzFrameSetFont(DzCompat_GetFrame(frame), fileName, height, flag)
    endfunction

    function DzFrameGetName takes integer frame returns string
        return BlzFrameGetName(DzCompat_GetFrame(frame))
    endfunction

    // ---- Slider/value controls --------------------------------------
    function DzFrameGetValue takes integer frame returns real
        return BlzFrameGetValue(DzCompat_GetFrame(frame))
    endfunction

    function DzFrameSetValue takes integer frame, real value returns nothing
        call BlzFrameSetValue(DzCompat_GetFrame(frame), value)
    endfunction

    function DzFrameSetMinMaxValue takes integer frame, real minValue, real maxValue returns nothing
        call BlzFrameSetMinMaxValue(DzCompat_GetFrame(frame), minValue, maxValue)
    endfunction

    function DzFrameSetStepValue takes integer frame, real step returns nothing
        call BlzFrameSetStepSize(DzCompat_GetFrame(frame), step) // corrected: real native is named "StepSize", not "StepValue"
    endfunction

    function DzFrameSetTooltip takes integer frame, integer tooltip returns nothing
        call BlzFrameSetTooltip(DzCompat_GetFrame(frame), DzCompat_GetFrame(tooltip))
    endfunction

    // ---- Misc global UI ------------------------------------------
    function DzLoadToc takes string fileName returns nothing
        call BlzLoadTOCFile(fileName)
    endfunction

    function DzFrameHideInterface takes nothing returns nothing
        call BlzHideOriginFrames(true)
    endfunction

    function DzOriginalUIAutoResetPoint takes boolean enable returns nothing
        call BlzEnableUIAutoPosition(enable)
    endfunction

    // ---- Click simulation ----------------------------------------
    function DzClickFrame takes integer frame returns nothing
        call BlzFrameClick(DzCompat_GetFrame(frame)) // confirmed against real common.j
    endfunction

    // ---- Mouse cage (confine cursor to frame bounds) ----------------
    function DzFrameCageMouse takes integer frame, boolean enable returns nothing
        call BlzFrameCageMouse(DzCompat_GetFrame(frame), enable)
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
    // "sync" isn't reproducible - Reforged frame events are inherently local/
    // client-side; there's no server-authoritative variant to opt into. Every
    // variant below (sync, async, block) behaves identically as a result.

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
    function DzFrameSetScriptByCode takes integer frame, integer eventId, code funcHandle, boolean sync returns nothing
        local trigger trig = CreateTrigger()
        // verification needed
        call BlzTriggerRegisterFrameEvent(trig, DzCompat_GetFrame(frame), DzCompat_ConvertFrameEvent(eventId))
		// call BlzTriggerRegisterFrameEvent(trig, DzCompat_GetFrame(frame), ConvertFrameEventType(eventId))
        call TriggerAddAction(trig, funcHandle)
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
        local trigger trig = DzCompat_ResolveFuncByName(func)
        if trig != null then
            // verification needed
			call BlzTriggerRegisterFrameEvent(trig, DzCompat_GetFrame(frame), DzCompat_ConvertFrameEvent(eventId))            call BlzTriggerRegisterFrameEvent(trig, DzCompat_GetFrame(frame), DzCompat_ConvertFrameEvent(eventId))
			//call BlzTriggerRegisterFrameEvent(trig, DzCompat_GetFrame(frame), ConvertFrameEventType(eventId))
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
        return BlzFrameGetChildrenCount(DzCompat_GetFrame(whichframe))
    endfunction

    function DzFrameGetChild takes integer whichframe, integer index returns integer
        local framehandle child = BlzFrameGetChild(DzCompat_GetFrame(whichframe), index)
        if child == null then
            return 0
        endif
        return DzCompat_RegisterFrame(child)
    endfunction

    function DzFrameGetWidth takes integer frame returns real
        return BlzFrameGetWidth(DzCompat_GetFrame(frame))
    endfunction

    // [APPROX] no separate "real" (i.e. post-scale?) width/height native
    // exists - treating these as aliases of the plain width/height getters.
    // If your map actually needs the pre-scale vs. post-scale distinction
    // Dz seems to imply by having both, this won't capture that difference.
    function DzFrameGetRealWidth takes integer frame returns real
        return BlzFrameGetWidth(DzCompat_GetFrame(frame))
    endfunction

    function DzFrameGetRealHeight takes integer frame returns real
        return BlzFrameGetHeight(DzCompat_GetFrame(frame))
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
        if checked then
            call BlzFrameSetValue(DzCompat_GetFrame(check_box_frame), 1.0)
        else
            call BlzFrameSetValue(DzCompat_GetFrame(check_box_frame), 0.0)
        endif
    endfunction

    function DzFrameGetCheckBoxState takes integer check_box_frame returns boolean
        return BlzFrameGetValue(DzCompat_GetFrame(check_box_frame)) >= 0.5
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
