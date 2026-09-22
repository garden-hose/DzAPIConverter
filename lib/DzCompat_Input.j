// ============================================================================
// DzCompat_Input.j
// Input / model / frame-callback natives.
//
// Combines:
//   - real implementations for key ByCode, mouse wheel stubs,
//     DzSetUnitModel, DzFrameSetUpdateCallback*, DzGetMouseFocus
//   - the full architected string-based key + mouse-button event path that
//     lived in the former DzCompat_InputEvents.j (DzTriggerRegisterKeyEvent,
//     DzTriggerRegisterMouseEvent, DzGetTriggerKey, DzGetTriggerKeyPlayer)
//
// STATUS:
//   [ARCHITECTED] DzTriggerRegisterKeyEvent / DzTriggerRegisterMouseEvent /
//                 DzGetTriggerKeyPlayer (built on real Blz* / EVENT_PLAYER_MOUSE_*)
//   [APPROX]    DzSetUnitModel via BlzSetUnitSkin (string -> skin/rawcode id)
//   [APPROX]    DzFrameSetUpdateCallbackByCode (30 Hz timer)
//   [PORT LIMITATION]   DzGetWheelDelta / DzTriggerRegisterMouseWheelEvent* /
//               DzGetMouseFocus (no full engine equivalent)
//   [HELPER]    DzTriggerRegister*Trg 
// ============================================================================

globals
    // ---- key-event registrations (string-func path) ----
    // Keyed by GetHandleId(trig). Each registration occupies 3 child slots
    // starting at (regIndex * 3):
    //   +0 integer - the raw Dz key code
    //   +1 integer - the raw Dz status code (0=up, 1=down)
    //   +2 string  - the callback function name, for ExecuteFunc
    hashtable gDzInputKeyReg             = InitHashtable()
    hashtable gDzInputKeyRegCount        = InitHashtable()
    hashtable gDzInputKeyDispatcherReady = InitHashtable()

    // ---- mouse-button-event registrations (same shape) ----
    hashtable gDzInputMouseReg             = InitHashtable()
    hashtable gDzInputMouseRegCount        = InitHashtable()
    hashtable gDzInputMouseDispatcherReady = InitHashtable()
	
	// ---- mouse-move-event registrations ----
    // tid, i -> func name; no key/btn filter needed (EVENT_PLAYER_MOUSE_MOVE
    // is already the exact event).
    hashtable gDzInputMouseMoveReg             = InitHashtable()
    hashtable gDzInputMouseMoveRegCount        = InitHashtable()
    hashtable gDzInputMouseMoveDispatcherReady = InitHashtable()
    hashtable gDzInputMouseMoveEventReady      = InitHashtable()
endglobals

    // ========================================================================
    // Key events - ByCode
    // ========================================================================

    // BlzTriggerRegisterPlayerKeyEvent
    // status: 1 = key down, 0 = key up (status==1 -> keyDown true)
    // sync: when true, register for every player so the event can be used in
    // shared trigger logic; when false, only the local player (UI-local keys).
    // trig may be null - Dz maps do that when they only want the callback ("call the
    // function when the key goes down") and have no trigger of their own; a private
    // trigger is created for it then.
    function DzTriggerRegisterKeyEventByCode takes trigger trig, integer key, integer status, boolean sync, code funcHandle returns nothing
        local integer i = 0
        local boolean keyDown = (status == 1)
        if trig == null then
            set trig = CreateTrigger()
        endif
        if sync then
            loop
                exitwhen i >= bj_MAX_PLAYER_SLOTS
                call BlzTriggerRegisterPlayerKeyEvent(trig, Player(i), ConvertOsKeyType(key), 0, keyDown)
                set i = i + 1
            endloop
        else
            call BlzTriggerRegisterPlayerKeyEvent(trig, GetLocalPlayer(), ConvertOsKeyType(key), 0, keyDown)
        endif
        call TriggerAddAction(trig, funcHandle)
    endfunction

    // ========================================================================
    // Key events - string func path (restored from DzCompat_InputEvents.j)
    // ========================================================================

    // Design note: Dz's key/mouse register natives take no `player` parameter.
    // Both registration functions therefore loop over every player slot so a
    // single call fires for any player; DzGetTriggerKeyPlayer recovers who.

    function DzCompat_KeyEventDispatch takes nothing returns nothing
        local integer tid = GetHandleId(GetTriggeringTrigger())
        local integer count = LoadInteger(gDzInputKeyRegCount, tid, 0)
        local integer i = 0
        local oskeytype curKey = BlzGetTriggerPlayerKey()
        local boolean curDown = BlzGetTriggerPlayerIsKeyDown()
        local boolean keyMatch
        local boolean statusMatch
		local string funcName
        loop
            exitwhen i >= count
            set keyMatch = (curKey == ConvertOsKeyType(LoadInteger(gDzInputKeyReg, tid, i * 3)))
            // status assumption: 0 = up/released, 1 = down/pressed
            set statusMatch = (curDown == (LoadInteger(gDzInputKeyReg, tid, i * 3 + 1) != 0))
			if keyMatch and statusMatch then
				set funcName = LoadStr(gDzInputKeyReg, tid, i * 3 + 2)
				if funcName != null and funcName != "" then
					call ExecuteFunc(funcName)
				endif
			endif
            set i = i + 1
        endloop
    endfunction

    // [ARCHITECTED] String-name key registration with multi-reg-per-trigger
    // support and ExecuteFunc dispatch. Prefer ByCode when the map already
    // has a code handle; this path is for maps that only ever used the
    // string form.
    function DzTriggerRegisterKeyEvent takes trigger trig, integer key, integer status, boolean sync, string func returns nothing
        local integer tid
        local integer count
        local integer i = 0
        if trig == null then
            set trig = CreateTrigger()
        endif
        set tid = GetHandleId(trig)
        set count = LoadInteger(gDzInputKeyRegCount, tid, 0)
        // Always register for all players so DzGetTriggerKeyPlayer is meaningful
        // (sync is accepted for signature compatibility; Blz key events are
        // already networked).
        loop
            exitwhen i >= bj_MAX_PLAYER_SLOTS
            call BlzTriggerRegisterPlayerKeyEvent(trig, Player(i), ConvertOsKeyType(key), 0, status != 0)
            set i = i + 1
        endloop
        call SaveInteger(gDzInputKeyReg, tid, count * 3, key)
        call SaveInteger(gDzInputKeyReg, tid, count * 3 + 1, status)
        call SaveStr(gDzInputKeyReg, tid, count * 3 + 2, func)
        call SaveInteger(gDzInputKeyRegCount, tid, 0, count + 1)
        if not LoadBoolean(gDzInputKeyDispatcherReady, tid, 0) then
            call SaveBoolean(gDzInputKeyDispatcherReady, tid, 0, true)
            call TriggerAddAction(trig, function DzCompat_KeyEventDispatch)
        endif
    endfunction

    // ========================================================================
    // OSKEY -> Dz/Windows VK conversion adopted from maxou
    // Dz key codes are Windows VK_* integers. Reforged key events yield
    // oskeytype; this table maps them so DzGetTriggerKey returns values that
    // match the integer codes maps register with.
    // ========================================================================

    function DzCompat_OsKeyToVk takes oskeytype key returns integer
        if key == OSKEY_BACKSPACE then
            return $08
        endif
        if key == OSKEY_TAB then
            return $09
        endif
        if key == OSKEY_CLEAR then
            return $0C
        endif
        if key == OSKEY_RETURN then
            return $0D
        endif
        if key == OSKEY_SHIFT then
            return $10
        endif
        if key == OSKEY_CONTROL then
            return $11
        endif
        if key == OSKEY_ALT then
            return $12
        endif
        if key == OSKEY_PAUSE then
            return $13
        endif
        if key == OSKEY_CAPSLOCK then
            return $14
        endif
        if key == OSKEY_KANA then
            return $15
        endif
        if key == OSKEY_HANGUL then
            return $15
        endif
        if key == OSKEY_JUNJA then
            return $17
        endif
        if key == OSKEY_FINAL then
            return $18
        endif
        if key == OSKEY_HANJA then
            return $19
        endif
        if key == OSKEY_KANJI then
            return $19
        endif
        if key == OSKEY_ESCAPE then
            return $1B
        endif
        if key == OSKEY_CONVERT then
            return $1C
        endif
        if key == OSKEY_NONCONVERT then
            return $1D
        endif
        if key == OSKEY_ACCEPT then
            return $1E
        endif
        if key == OSKEY_MODECHANGE then
            return $1F
        endif
        if key == OSKEY_SPACE then
            return $20
        endif
        if key == OSKEY_PAGEUP then
            return $21
        endif
        if key == OSKEY_PAGEDOWN then
            return $22
        endif
        if key == OSKEY_END then
            return $23
        endif
        if key == OSKEY_HOME then
            return $24
        endif
        if key == OSKEY_LEFT then
            return $25
        endif
        if key == OSKEY_UP then
            return $26
        endif
        if key == OSKEY_RIGHT then
            return $27
        endif
        if key == OSKEY_DOWN then
            return $28
        endif
        if key == OSKEY_SELECT then
            return $29
        endif
        if key == OSKEY_PRINT then
            return $2A
        endif
        if key == OSKEY_EXECUTE then
            return $2B
        endif
        if key == OSKEY_PRINTSCREEN then
            return $2C
        endif
        if key == OSKEY_INSERT then
            return $2D
        endif
        if key == OSKEY_DELETE then
            return $2E
        endif
        if key == OSKEY_HELP then
            return $2F
        endif
        if key == OSKEY_0 then
            return $30
        endif
        if key == OSKEY_1 then
            return $31
        endif
        if key == OSKEY_2 then
            return $32
        endif
        if key == OSKEY_3 then
            return $33
        endif
        if key == OSKEY_4 then
            return $34
        endif
        if key == OSKEY_5 then
            return $35
        endif
        if key == OSKEY_6 then
            return $36
        endif
        if key == OSKEY_7 then
            return $37
        endif
        if key == OSKEY_8 then
            return $38
        endif
        if key == OSKEY_9 then
            return $39
        endif
        if key == OSKEY_A then
            return $41
        endif
        if key == OSKEY_B then
            return $42
        endif
        if key == OSKEY_C then
            return $43
        endif
        if key == OSKEY_D then
            return $44
        endif
        if key == OSKEY_E then
            return $45
        endif
        if key == OSKEY_F then
            return $46
        endif
        if key == OSKEY_G then
            return $47
        endif
        if key == OSKEY_H then
            return $48
        endif
        if key == OSKEY_I then
            return $49
        endif
        if key == OSKEY_J then
            return $4A
        endif
        if key == OSKEY_K then
            return $4B
        endif
        if key == OSKEY_L then
            return $4C
        endif
        if key == OSKEY_M then
            return $4D
        endif
        if key == OSKEY_N then
            return $4E
        endif
        if key == OSKEY_O then
            return $4F
        endif
        if key == OSKEY_P then
            return $50
        endif
        if key == OSKEY_Q then
            return $51
        endif
        if key == OSKEY_R then
            return $52
        endif
        if key == OSKEY_S then
            return $53
        endif
        if key == OSKEY_T then
            return $54
        endif
        if key == OSKEY_U then
            return $55
        endif
        if key == OSKEY_V then
            return $56
        endif
        if key == OSKEY_W then
            return $57
        endif
        if key == OSKEY_X then
            return $58
        endif
        if key == OSKEY_Y then
            return $59
        endif
        if key == OSKEY_Z then
            return $5A
        endif
        if key == OSKEY_LMETA then
            return $5B
        endif
        if key == OSKEY_RMETA then
            return $5C
        endif
        if key == OSKEY_APPS then
            return $5D
        endif
        if key == OSKEY_SLEEP then
            return $5F
        endif
        if key == OSKEY_NUMPAD0 then
            return $60
        endif
        if key == OSKEY_NUMPAD1 then
            return $61
        endif
        if key == OSKEY_NUMPAD2 then
            return $62
        endif
        if key == OSKEY_NUMPAD3 then
            return $63
        endif
        if key == OSKEY_NUMPAD4 then
            return $64
        endif
        if key == OSKEY_NUMPAD5 then
            return $65
        endif
        if key == OSKEY_NUMPAD6 then
            return $66
        endif
        if key == OSKEY_NUMPAD7 then
            return $67
        endif
        if key == OSKEY_NUMPAD8 then
            return $68
        endif
        if key == OSKEY_NUMPAD9 then
            return $69
        endif
        if key == OSKEY_MULTIPLY then
            return $6A
        endif
        if key == OSKEY_ADD then
            return $6B
        endif
        if key == OSKEY_SEPARATOR then
            return $6C
        endif
        if key == OSKEY_SUBTRACT then
            return $6D
        endif
        if key == OSKEY_DECIMAL then
            return $6E
        endif
        if key == OSKEY_DIVIDE then
            return $6F
        endif
        if key == OSKEY_F1 then
            return $70
        endif
        if key == OSKEY_F2 then
            return $71
        endif
        if key == OSKEY_F3 then
            return $72
        endif
        if key == OSKEY_F4 then
            return $73
        endif
        if key == OSKEY_F5 then
            return $74
        endif
        if key == OSKEY_F6 then
            return $75
        endif
        if key == OSKEY_F7 then
            return $76
        endif
        if key == OSKEY_F8 then
            return $77
        endif
        if key == OSKEY_F9 then
            return $78
        endif
        if key == OSKEY_F10 then
            return $79
        endif
        if key == OSKEY_F11 then
            return $7A
        endif
        if key == OSKEY_F12 then
            return $7B
        endif
        if key == OSKEY_F13 then
            return $7C
        endif
        if key == OSKEY_F14 then
            return $7D
        endif
        if key == OSKEY_F15 then
            return $7E
        endif
        if key == OSKEY_F16 then
            return $7F
        endif
        if key == OSKEY_F17 then
            return $80
        endif
        if key == OSKEY_F18 then
            return $81
        endif
        if key == OSKEY_F19 then
            return $82
        endif
        if key == OSKEY_F20 then
            return $83
        endif
        if key == OSKEY_F21 then
            return $84
        endif
        if key == OSKEY_F22 then
            return $85
        endif
        if key == OSKEY_F23 then
            return $86
        endif
        if key == OSKEY_F24 then
            return $87
        endif
        if key == OSKEY_NUMLOCK then
            return $90
        endif
        if key == OSKEY_SCROLLLOCK then
            return $91
        endif
        if key == OSKEY_OEM_NEC_EQUAL then
            return $92
        endif
        if key == OSKEY_OEM_FJ_JISHO then
            return $92
        endif
        if key == OSKEY_OEM_FJ_MASSHOU then
            return $93
        endif
        if key == OSKEY_OEM_FJ_TOUROKU then
            return $94
        endif
        if key == OSKEY_OEM_FJ_LOYA then
            return $95
        endif
        if key == OSKEY_OEM_FJ_ROYA then
            return $96
        endif
        if key == OSKEY_LSHIFT then
            return $A0
        endif
        if key == OSKEY_RSHIFT then
            return $A1
        endif
        if key == OSKEY_LCONTROL then
            return $A2
        endif
        if key == OSKEY_RCONTROL then
            return $A3
        endif
        if key == OSKEY_LALT then
            return $A4
        endif
        if key == OSKEY_RALT then
            return $A5
        endif
        if key == OSKEY_BROWSER_BACK then
            return $A6
        endif
        if key == OSKEY_BROWSER_FORWARD then
            return $A7
        endif
        if key == OSKEY_BROWSER_REFRESH then
            return $A8
        endif
        if key == OSKEY_BROWSER_STOP then
            return $A9
        endif
        if key == OSKEY_BROWSER_SEARCH then
            return $AA
        endif
        if key == OSKEY_BROWSER_FAVORITES then
            return $AB
        endif
        if key == OSKEY_BROWSER_HOME then
            return $AC
        endif
        if key == OSKEY_VOLUME_MUTE then
            return $AD
        endif
        if key == OSKEY_VOLUME_DOWN then
            return $AE
        endif
        if key == OSKEY_VOLUME_UP then
            return $AF
        endif
        if key == OSKEY_MEDIA_NEXT_TRACK then
            return $B0
        endif
        if key == OSKEY_MEDIA_PREV_TRACK then
            return $B1
        endif
        if key == OSKEY_MEDIA_STOP then
            return $B2
        endif
        if key == OSKEY_MEDIA_PLAY_PAUSE then
            return $B3
        endif
        if key == OSKEY_LAUNCH_MAIL then
            return $B4
        endif
        if key == OSKEY_LAUNCH_MEDIA_SELECT then
            return $B5
        endif
        if key == OSKEY_LAUNCH_APP1 then
            return $B6
        endif
        if key == OSKEY_LAUNCH_APP2 then
            return $B7
        endif
        if key == OSKEY_OEM_1 then
            return $BA
        endif
        if key == OSKEY_OEM_PLUS then
            return $BB
        endif
        if key == OSKEY_OEM_COMMA then
            return $BC
        endif
        if key == OSKEY_OEM_MINUS then
            return $BD
        endif
        if key == OSKEY_OEM_PERIOD then
            return $BE
        endif
        if key == OSKEY_OEM_2 then
            return $BF
        endif
        if key == OSKEY_OEM_3 then
            return $C0
        endif
        if key == OSKEY_OEM_4 then
            return $DB
        endif
        if key == OSKEY_OEM_5 then
            return $DC
        endif
        if key == OSKEY_OEM_6 then
            return $DD
        endif
        if key == OSKEY_OEM_7 then
            return $DE
        endif
        if key == OSKEY_OEM_8 then
            return $DF
        endif
        if key == OSKEY_OEM_AX then
            return $E1
        endif
        if key == OSKEY_OEM_102 then
            return $E2
        endif
        if key == OSKEY_ICO_HELP then
            return $E3
        endif
        if key == OSKEY_ICO_00 then
            return $E4
        endif
        if key == OSKEY_PROCESSKEY then
            return $E5
        endif
        if key == OSKEY_ICO_CLEAR then
            return $E6
        endif
        if key == OSKEY_PACKET then
            return $E7
        endif
        if key == OSKEY_OEM_RESET then
            return $E9
        endif
        if key == OSKEY_OEM_JUMP then
            return $EA
        endif
        if key == OSKEY_OEM_PA1 then
            return $EB
        endif
        if key == OSKEY_OEM_PA2 then
            return $EC
        endif
        if key == OSKEY_OEM_PA3 then
            return $ED
        endif
        if key == OSKEY_OEM_WSCTRL then
            return $EE
        endif
        if key == OSKEY_OEM_CUSEL then
            return $EF
        endif
        if key == OSKEY_OEM_ATTN then
            return $F0
        endif
        if key == OSKEY_OEM_FINISH then
            return $F1
        endif
        if key == OSKEY_OEM_COPY then
            return $F2
        endif
        if key == OSKEY_OEM_AUTO then
            return $F3
        endif
        if key == OSKEY_OEM_ENLW then
            return $F4
        endif
        if key == OSKEY_OEM_BACKTAB then
            return $F5
        endif
        if key == OSKEY_ATTN then
            return $F6
        endif
        if key == OSKEY_CRSEL then
            return $F7
        endif
        if key == OSKEY_EXSEL then
            return $F8
        endif
        if key == OSKEY_EREOF then
            return $F9
        endif
        if key == OSKEY_PLAY then
            return $FA
        endif
        if key == OSKEY_ZOOM then
            return $FB
        endif
        if key == OSKEY_NONAME then
            return $FC
        endif
        if key == OSKEY_PA1 then
            return $FD
        endif
        if key == OSKEY_OEM_CLEAR then
            return $FE
        endif
            return 0
    endfunction

    // [ARCHITECTED] Who pressed the key (GetTriggerPlayer from the Blz event).
    function DzGetTriggerKeyPlayer takes nothing returns player
        return GetTriggerPlayer()
    endfunction

    //// [ARCHITECTED] Which key was pressed. Relies on ConvertOsKeyType /
    //// GetHandleId identity (community-standard technique).
    //function DzGetTriggerKey takes nothing returns integer
    //    return GetHandleId(BlzGetTriggerPlayerKey())
    //endfunction

    // Which key was pressed, returned as a Dz/Windows VK code.
    // Uses the full OSKEY -> VK table comparisons
    // against the integer key codes maps register with actually match.
    function DzGetTriggerKey takes nothing returns integer
        return DzCompat_OsKeyToVk(BlzGetTriggerPlayerKey())
    endfunction

    // ========================================================================
    // Mouse-button events (restored from DzCompat_InputEvents.j)
    // ========================================================================

    // Unlike keys, Blizzard's mouse events have no per-button registration;
    // EVENT_PLAYER_MOUSE_DOWN/UP fire for any button. The dispatcher filter
    // is therefore load-bearing even for a single registration.
    function DzCompat_MouseEventDispatch takes nothing returns nothing
        local integer tid = GetHandleId(GetTriggeringTrigger())
        local integer count = LoadInteger(gDzInputMouseRegCount, tid, 0)
        local integer i = 0
        local mousebuttontype curBtn = BlzGetTriggerPlayerMouseButton()
        local mousebuttontype checkBtn
        local boolean curDown
        local boolean btnMatch
        local boolean statusMatch
        loop
            exitwhen i >= count
            set checkBtn = ConvertMouseButtonType(LoadInteger(gDzInputMouseReg, tid, i * 3))
            set btnMatch = (curBtn == checkBtn)
            set curDown = BlzIsMouseButtonPressed(checkBtn)
            // same 0=up / 1=down assumption as the key dispatcher
            set statusMatch = (curDown == (LoadInteger(gDzInputMouseReg, tid, i * 3 + 1) != 0))
            if btnMatch and statusMatch then
                // Empty name = ByCode registration (action already on the trigger);
                // only ExecuteFunc when a real string callback was stored.
                if LoadStr(gDzInputMouseReg, tid, i * 3 + 2) != null and LoadStr(gDzInputMouseReg, tid, i * 3 + 2) != "" then
                    call ExecuteFunc(LoadStr(gDzInputMouseReg, tid, i * 3 + 2))
                endif
            endif
            set i = i + 1
        endloop
    endfunction

    function DzCompat_EnsureMouseButtonEvents takes trigger trig returns nothing
        local integer tid = GetHandleId(trig)
        local integer i = 0
        if LoadBoolean(gDzInputMouseDispatcherReady, tid, 0) then
            return
        endif
        call SaveBoolean(gDzInputMouseDispatcherReady, tid, 0, true)
        loop
            exitwhen i >= bj_MAX_PLAYER_SLOTS
            call TriggerRegisterPlayerEvent(trig, Player(i), EVENT_PLAYER_MOUSE_DOWN)
            call TriggerRegisterPlayerEvent(trig, Player(i), EVENT_PLAYER_MOUSE_UP)
            set i = i + 1
        endloop
        call TriggerAddAction(trig, function DzCompat_MouseEventDispatch)
    endfunction

    // [ARCHITECTED] btn: assumed to match Blizzard MOUSE_BUTTON_TYPE_* (1/2/3).
    // status, sync: same assumptions as DzTriggerRegisterKeyEvent.
    // NOTE: common.j warns that mouse events crash if registered during map
    // init — delay until after gameplay starts.
    function DzTriggerRegisterMouseEvent takes trigger trig, integer btn, integer status, boolean sync, string func returns nothing
        local integer tid
        local integer count
        if trig == null then
            set trig = CreateTrigger()
        endif
        set tid = GetHandleId(trig)
        set count = LoadInteger(gDzInputMouseRegCount, tid, 0)
        call DzCompat_EnsureMouseButtonEvents(trig)
        call SaveInteger(gDzInputMouseReg, tid, count * 3, btn)
        call SaveInteger(gDzInputMouseReg, tid, count * 3 + 1, status)
        call SaveStr(gDzInputMouseReg, tid, count * 3 + 2, func)
        call SaveInteger(gDzInputMouseRegCount, tid, 0, count + 1)
    endfunction

    // [ARCHITECTED] code-handle variant
    // registered the mouse event and filtered LMB/RMB via conditions but
    // never attached `funcHandle` as an action. We attach the action and also
    // install a button filter condition (left vs non-left), so one call is enough.
    //
    // btn: Dz mouse button codes — 1 (or 0x1) = left, anything else =
    //      treated as right for the condition filter (mapped 0x2 -> right).
    // status: 1 = down (bj_MOUSEEVENTTYPE_DOWN), 0 = up (bj_MOUSEEVENTTYPE_UP).
    // sync: signature compatibility only; events are registered for the local
    //       player. Prefer a dedicated trigger per button.
    function DzCompat_MouseLMBCondition takes nothing returns boolean
        if GetLocalPlayer() != GetTriggerPlayer() then
            return false
        endif
        return BlzGetTriggerPlayerMouseButton() == MOUSE_BUTTON_TYPE_LEFT
    endfunction

    function DzCompat_MouseRMBCondition takes nothing returns boolean
        if GetLocalPlayer() != GetTriggerPlayer() then
            return false
        endif
        return BlzGetTriggerPlayerMouseButton() == MOUSE_BUTTON_TYPE_RIGHT
    endfunction

    function DzTriggerRegisterMouseEventByCode takes trigger trig, integer btn, integer status, boolean sync, code funcHandle returns nothing
        local integer eventType
        if trig == null then
            set trig = CreateTrigger()
        endif
        if status == 1 then
            set eventType = bj_MOUSEEVENTTYPE_DOWN
        else
            set eventType = bj_MOUSEEVENTTYPE_UP
        endif
        call TriggerRegisterPlayerMouseEventBJ(trig, GetLocalPlayer(), eventType)
        // btn 0x1 / 1 -> left; otherwise right. Middle is not distinguished.
        if btn == 1 or btn == 0x1 then
            call TriggerAddCondition(trig, Condition(function DzCompat_MouseLMBCondition))
        else
            call TriggerAddCondition(trig, Condition(function DzCompat_MouseRMBCondition))
        endif
        if funcHandle != null then
            call TriggerAddAction(trig, funcHandle)
        endif
    endfunction

    // ========================================================================
	// Mouse move events (restored from DzCompat_InputEvents.j)
    // ========================================================================
    // EVENT_PLAYER_MOUSE_MOVE is real and synced between players (same event
    // used by DzCompat_EnsureMouseTracking for DzGetMouseTerrainX/Y).
    // Subject to the same "don't register during map init" engine bug.
    // sync is accepted for signature compatibility only.

    function DzCompat_EnsureMouseMoveEvent takes trigger trig returns nothing
        local integer tid = GetHandleId(trig)
        local integer i = 0
        if LoadBoolean(gDzInputMouseMoveEventReady, tid, 0) then
            return
        endif
        call SaveBoolean(gDzInputMouseMoveEventReady, tid, 0, true)
        loop
            exitwhen i >= bj_MAX_PLAYER_SLOTS
            call TriggerRegisterPlayerEvent(trig, Player(i), EVENT_PLAYER_MOUSE_MOVE)
            set i = i + 1
        endloop
    endfunction

    function DzCompat_MouseMoveDispatch takes nothing returns nothing
        local integer tid = GetHandleId(GetTriggeringTrigger())
        local integer count = LoadInteger(gDzInputMouseMoveRegCount, tid, 0)
        local integer i = 0
        loop
            exitwhen i >= count
            call ExecuteFunc(LoadStr(gDzInputMouseMoveReg, tid, i))
            set i = i + 1
        endloop
    endfunction

    function DzTriggerRegisterMouseMoveEvent takes trigger trig, boolean sync, string func returns nothing
        local integer tid
        local integer count
        if trig == null then
            set trig = CreateTrigger()
        endif
        set tid = GetHandleId(trig)
        set count = LoadInteger(gDzInputMouseMoveRegCount, tid, 0)
        call DzCompat_EnsureMouseMoveEvent(trig)
        call SaveStr(gDzInputMouseMoveReg, tid, count, func)
        call SaveInteger(gDzInputMouseMoveRegCount, tid, 0, count + 1)
        if not LoadBoolean(gDzInputMouseMoveDispatcherReady, tid, 0) then
            call SaveBoolean(gDzInputMouseMoveDispatcherReady, tid, 0, true)
            call TriggerAddAction(trig, function DzCompat_MouseMoveDispatch)
        endif
    endfunction

    // ByCode variant is straightforward: no shared filter needed, each
    // registration is just its own TriggerAddAction.
    function DzTriggerRegisterMouseMoveEventByCode takes trigger trig, boolean sync, code funcHandle returns nothing
        if trig == null then
            set trig = CreateTrigger()
        endif
        call DzCompat_EnsureMouseMoveEvent(trig)
        call TriggerAddAction(trig, funcHandle)
    endfunction
	
	// ---- mouse cursor position (Reforged 3.0+) --------------------
	// BlzGetMouseScreenPosX/Y are new in 3.0 and return the mouse's absolute
	// screen position in pixels - same shape and units as Dz's originals.
	// There's no separate "relative" native in 3.0 (no second reference point
	// is exposed), so the *Relative variants use the same call. Do NOT route
	// them through BlzGetTriggerPlayerMouseX/Y or gDzCompatMouseTrack - those
	// store world/terrain coordinates (see DzGetMouseTerrainX/Y).
	// If a map needs a value relative to a frame origin, that has to be done
	// by the caller (screen pos minus frame screen pos).

	function DzGetMouseX takes nothing returns integer
		return BlzGetMouseScreenPosX()
	endfunction

	function DzGetMouseY takes nothing returns integer
		return BlzGetMouseScreenPosY()
	endfunction

	function DzGetMouseXRelative takes nothing returns integer
		return BlzGetMouseScreenPosX()
	endfunction

	function DzGetMouseYRelative takes nothing returns integer
		return BlzGetMouseScreenPosY()
	endfunction

    // ========================================================================
    // Mouse wheel (limited)
    // ========================================================================


    // [PORT LIMITATION] No portable mouse-wheel event registration in stock Reforged
    // that matches Dz's signature. Kept as a defined no-op so maps compile.
    function DzTriggerRegisterMouseWheelEventByCode takes trigger whichTrigger, boolean sync, code funcHandle returns nothing
    endfunction

    function DzTriggerRegisterMouseWheelEvent takes trigger whichTrigger, boolean sync, string funcName returns nothing
    endfunction

    // [PORT LIMITATION] Wheel delta is only valid inside a real wheel event; without
    // registration support this always returns 0.
    function DzGetWheelDelta takes nothing returns integer
        return 0
    endfunction

    // ========================================================================
    // Model path / skin helpers (DzSetUnitModel)
    // ========================================================================

    // Pack a 4-character object id string (e.g. "hfoo", "Hamg") into the
    // integer rawcode form BlzSetUnitSkin expects. Longer strings (model file
    // paths) cannot be represented as a skin id; those yield 0 and the skin
    // call becomes a no-op.
    function DzCompat_StringToRawcode takes string s returns integer
        local integer i = 0
        local integer n
        local integer result = 0
        local integer len
        local string c
        if s == null then
            return 0
        endif
        set len = StringLength(s)
        if len != 4 then
            return 0
        endif
        loop
            exitwhen i >= 4
            set c = SubString(s, i, i + 1)
            // ASCII code points for a-z / A-Z / 0-9 cover normal rawcodes
            if c == "a" then
                set n = 97
            elseif c == "b" then
                set n = 98
            elseif c == "c" then
                set n = 99
            elseif c == "d" then
                set n = 100
            elseif c == "e" then
                set n = 101
            elseif c == "f" then
                set n = 102
            elseif c == "g" then
                set n = 103
            elseif c == "h" then
                set n = 104
            elseif c == "i" then
                set n = 105
            elseif c == "j" then
                set n = 106
            elseif c == "k" then
                set n = 107
            elseif c == "l" then
                set n = 108
            elseif c == "m" then
                set n = 109
            elseif c == "n" then
                set n = 110
            elseif c == "o" then
                set n = 111
            elseif c == "p" then
                set n = 112
            elseif c == "q" then
                set n = 113
            elseif c == "r" then
                set n = 114
            elseif c == "s" then
                set n = 115
            elseif c == "t" then
                set n = 116
            elseif c == "u" then
                set n = 117
            elseif c == "v" then
                set n = 118
            elseif c == "w" then
                set n = 119
            elseif c == "x" then
                set n = 120
            elseif c == "y" then
                set n = 121
            elseif c == "z" then
                set n = 122
            elseif c == "A" then
                set n = 65
            elseif c == "B" then
                set n = 66
            elseif c == "C" then
                set n = 67
            elseif c == "D" then
                set n = 68
            elseif c == "E" then
                set n = 69
            elseif c == "F" then
                set n = 70
            elseif c == "G" then
                set n = 71
            elseif c == "H" then
                set n = 72
            elseif c == "I" then
                set n = 73
            elseif c == "J" then
                set n = 74
            elseif c == "K" then
                set n = 75
            elseif c == "L" then
                set n = 76
            elseif c == "M" then
                set n = 77
            elseif c == "N" then
                set n = 78
            elseif c == "O" then
                set n = 79
            elseif c == "P" then
                set n = 80
            elseif c == "Q" then
                set n = 81
            elseif c == "R" then
                set n = 82
            elseif c == "S" then
                set n = 83
            elseif c == "T" then
                set n = 84
            elseif c == "U" then
                set n = 85
            elseif c == "V" then
                set n = 86
            elseif c == "W" then
                set n = 87
            elseif c == "X" then
                set n = 88
            elseif c == "Y" then
                set n = 89
            elseif c == "Z" then
                set n = 90
            elseif c == "0" then
                set n = 48
            elseif c == "1" then
                set n = 49
            elseif c == "2" then
                set n = 50
            elseif c == "3" then
                set n = 51
            elseif c == "4" then
                set n = 52
            elseif c == "5" then
                set n = 53
            elseif c == "6" then
                set n = 54
            elseif c == "7" then
                set n = 55
            elseif c == "8" then
                set n = 56
            elseif c == "9" then
                set n = 57
            else
                set n = 0
            endif
            set result = result * 256 + n
            set i = i + 1
        endloop
        return result
    endfunction

    // Path string -> skin/rawcode registry for DzSetUnitModel when the map
    // passes a model file path instead of a 4-char object id. Populated by
    // DzCompat_RegisterModelPath (generated by the converter from unit.ini /
    // UnitStrings-style data, or left with skinId 0 when the user declines).
    // Hashtable lives in DzCompat_Core.j (gDzCompatModelPathTable).

    function DzCompat_RegisterModelPath takes string modelPath, integer skinId returns nothing
        if modelPath == null or modelPath == "" then
            return
        endif
        call SaveInteger(gDzCompatModelPathTable, StringHash(modelPath), 0, skinId)
    endfunction

    // [APPROX] DzSetUnitModel -> BlzSetUnitSkin
    // Resolution order:
    //   1) path is a 4-char object id -> pack to rawcode
    //   2) path is registered via DzCompat_RegisterModelPath -> use that skin id
    //   3) otherwise no-op (skin id 0)
    function DzSetUnitModel takes unit whichUnit, string path returns nothing
        local integer skinId
        if path == null or path == "" then
            return
        endif
        set skinId = DzCompat_StringToRawcode(path)
        if skinId == 0 then
            set skinId = LoadInteger(gDzCompatModelPathTable, StringHash(path), 0)
        endif
        if skinId != 0 then
            call BlzSetUnitSkin(whichUnit, skinId)
        endif
    endfunction

    // [APPROX] DzFrameSetUpdateCallbackByCode — callback on a repeating 1/30s timer
    function DzFrameSetUpdateCallbackByCode takes code funcHandle returns nothing
        call TimerStart(CreateTimer(), 1.0 / 30.0, true, funcHandle)
    endfunction

    function DzFrameSetUpdateCallback takes string funcName returns nothing
        // String form cannot be resolved to code in plain JASS.
    endfunction

    // ========================================================================
    // Convenience helpers 
    // ========================================================================
	
	function MoveDzFrame takes integer frameId, real posX, real posY returns nothing
		// DzFrameSetAbsolutePoint takes the point as an integer: 7 is FRAMEPOINT_BOTTOM
		// Function DzFrameSetAbsolutePoint lives in DzCompat_Frame.j
		call DzFrameSetAbsolutePoint(frameId, 7, posX, posY)
	endfunction

    // Null-safe wrappers used by some maps instead of the full signatures.
    function DzTriggerRegisterKeyEventTrg takes trigger whichTrigger, integer status, integer key returns nothing
        if whichTrigger == null then
            return
        endif
        call DzTriggerRegisterKeyEvent(whichTrigger, key, status, true, null)
    endfunction

    function DzTriggerRegisterMouseWheelEventTrg takes trigger whichTrigger returns nothing
        if whichTrigger == null then
            return
        endif
        call DzTriggerRegisterMouseWheelEvent(whichTrigger, true, null)
    endfunction
	
	function DzTriggerRegisterMouseEventTrg takes trigger whichTrigger, integer status, integer btn returns nothing
        local integer eventType
        if whichTrigger == null then
            return
        endif
        if status == 1 then
            set eventType = bj_MOUSEEVENTTYPE_DOWN
        else
            set eventType = bj_MOUSEEVENTTYPE_UP
        endif
        // Local player only (same as ByCode). Map owns TriggerAddAction.
        call TriggerRegisterPlayerMouseEventBJ(whichTrigger, GetLocalPlayer(), eventType)
        if btn == 1 or btn == 0x1 then
            call TriggerAddCondition(whichTrigger, Condition(function DzCompat_MouseLMBCondition))
        else
            call TriggerAddCondition(whichTrigger, Condition(function DzCompat_MouseRMBCondition))
        endif
    endfunction
	
	function DzTriggerRegisterMouseMoveEventTrg takes trigger whichTrigger returns nothing
        if whichTrigger == null then
            return
        endif
        // Registers EVENT_PLAYER_MOUSE_MOVE for all slots; no dispatcher action.
        call DzCompat_EnsureMouseMoveEvent(whichTrigger)
    endfunction
	