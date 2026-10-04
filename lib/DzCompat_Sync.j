// ============================================================================
// DzCompat_Sync.j
// Sync-data natives (DzSyncData family + trigger registration).
//
// BlzSendSyncData carries only a short string, so a longer value is cut into slices that travel under
// one shared prefix (DZSYNC_SLICE_PREFIX), are put back together on every client, and are then handed to
// the triggers registered for the original prefix. Short values are sent directly, untouched.
//
// LIMITATIONS
//   - A sliced value reaches its triggers through TriggerExecute, so the trigger's CONDITIONS are
//     evaluated first and its actions run only if they return true.
//   - Slices of one player arrive in order; if one is lost, the whole value is dropped.
// ============================================================================

globals
    // Longest value sent as it is; anything longer is sliced.
    constant integer DZSYNC_DIRECT_MAX = 200
    // Characters of data carried by one slice.
    constant integer DZSYNC_SLICE_LEN = 160
    constant string  DZSYNC_SLICE_PREFIX = "DzSL"

    // original prefix hash -> [-1] count, [i] trigger i, [-2 - i] its prefix
    hashtable gDzSyncSlices = null
    trigger   gDzSyncSliceTrig = null
    // set while a reassembled value is handed to the registered triggers
    boolean   gDzSyncDispatching = false
    string    gDzSyncDispatchPrefix = ""
    string    gDzSyncDispatchData = ""
    player    gDzSyncDispatchPlayer = null
    // per player: data received so far, and the number of the slice expected next
    string array  gDzSyncPending
    integer array gDzSyncNextPart
endglobals

    // ---- slicing ----------------------------------------------------

    // Position of the first "|" at or after start, -1 when there is none.
    function DzCompat_Sync_PosBar takes string s, integer start returns integer
        local integer n = StringLength(s)
        local integer i = start
        loop
            exitwhen i >= n
            if SubString(s, i, i + 1) == "|" then
                return i
            endif
            set i = i + 1
        endloop
        return -1
    endfunction

    // Runs every trigger registered for the prefix, with the value and the sender made visible to the
    // DzGetTrigger* natives. The previous values are put back afterwards, so a trigger that syncs
    // from inside its own action cannot disturb the outer dispatch.
    function DzCompat_Sync_Dispatch takes player whichPlayer, string prefix, string data returns nothing
        local integer key = StringHash(prefix)
        local integer count = LoadInteger(gDzSyncSlices, key, -1)
        local integer i = 0
        local trigger trig
        local boolean oldDispatching = gDzSyncDispatching
        local string oldPrefix = gDzSyncDispatchPrefix
        local string oldData = gDzSyncDispatchData
        local player oldPlayer = gDzSyncDispatchPlayer
        set gDzSyncDispatching = true
        set gDzSyncDispatchPrefix = prefix
        set gDzSyncDispatchData = data
        set gDzSyncDispatchPlayer = whichPlayer
        loop
            exitwhen i >= count
            if LoadStr(gDzSyncSlices, key, -2 - i) == prefix then
                set trig = LoadTriggerHandle(gDzSyncSlices, key, i)
                if trig != null and IsTriggerEnabled(trig) then
                    if TriggerEvaluate(trig) then
                        call TriggerExecute(trig)
                    endif
                endif
            endif
            set i = i + 1
        endloop
        set gDzSyncDispatching = oldDispatching
        set gDzSyncDispatchPrefix = oldPrefix
        set gDzSyncDispatchData = oldData
        set gDzSyncDispatchPlayer = oldPlayer
        set trig = null
        set oldPlayer = null
    endfunction

    // Receives one slice. Format: <part>|<parts>|<prefixLength>|<prefix><data>
    function DzCompat_Sync_OnSlice takes nothing returns nothing
        local string s = BlzGetTriggerSyncData()
        local player sender = GetTriggerPlayer()
        local integer id = GetPlayerId(sender)
        local integer bar1
        local integer bar2 = -1
        local integer bar3 = -1
        local integer part
        local integer parts
        local integer prefixLen
        local string prefix
        if s == null then
            set sender = null
            return
        endif
        set bar1 = DzCompat_Sync_PosBar(s, 0)
        if bar1 > 0 then
            set bar2 = DzCompat_Sync_PosBar(s, bar1 + 1)
        endif
        if bar2 > bar1 + 1 then
            set bar3 = DzCompat_Sync_PosBar(s, bar2 + 1)
        endif
        if bar3 <= bar2 + 1 then
            set sender = null
            return
        endif
        set part = S2I(SubString(s, 0, bar1))
        set parts = S2I(SubString(s, bar1 + 1, bar2))
        set prefixLen = S2I(SubString(s, bar2 + 1, bar3))
        set prefix = SubString(s, bar3 + 1, bar3 + 1 + prefixLen)
        if part == 0 then
            set gDzSyncPending[id] = ""
            set gDzSyncNextPart[id] = 0
        endif
        if part != gDzSyncNextPart[id] or parts < 1 then
            // out of order or malformed: drop what was collected
            set gDzSyncPending[id] = ""
            set gDzSyncNextPart[id] = -1
            set sender = null
            return
        endif
        set gDzSyncPending[id] = gDzSyncPending[id] + SubString(s, bar3 + 1 + prefixLen, StringLength(s))
        set gDzSyncNextPart[id] = part + 1
        if part >= parts - 1 then
            set s = gDzSyncPending[id]
            set gDzSyncPending[id] = ""
            set gDzSyncNextPart[id] = 0
            call DzCompat_Sync_Dispatch(sender, prefix, s)
        endif
        set sender = null
    endfunction

    // Remembers that trig wants the values synced under prefix; the first call also sets up the
    // slice receiver.
    function DzCompat_Sync_Register takes trigger trig, string prefix returns nothing
        local integer key = StringHash(prefix)
        local integer count
        local integer i = 0
        if gDzSyncSlices == null then
            set gDzSyncSlices = InitHashtable()
            set gDzSyncSliceTrig = CreateTrigger()
            loop
                exitwhen i >= bj_MAX_PLAYER_SLOTS
                call BlzTriggerRegisterPlayerSyncEvent(gDzSyncSliceTrig, Player(i), DZSYNC_SLICE_PREFIX, false)
                set i = i + 1
            endloop
            call TriggerAddAction(gDzSyncSliceTrig, function DzCompat_Sync_OnSlice)
        endif
        set count = LoadInteger(gDzSyncSlices, key, -1)
        call SaveTriggerHandle(gDzSyncSlices, key, count, trig)
        call SaveStr(gDzSyncSlices, key, -2 - count, prefix)
        call SaveInteger(gDzSyncSlices, key, -1, count + 1)
    endfunction

    // Sends data as slices.
    function DzCompat_Sync_SendSliced takes string prefix, string data returns nothing
        local integer n = StringLength(data)
        local integer prefixLen = StringLength(prefix)
        local integer sliceLen = DZSYNC_SLICE_LEN
        local integer parts
        local integer i = 0
        local string header
        // the header is up to 12 characters plus the prefix: keep header + slice within the direct limit
        if 12 + prefixLen + sliceLen > DZSYNC_DIRECT_MAX then
            set sliceLen = DZSYNC_DIRECT_MAX - 12 - prefixLen
            if sliceLen < 16 then
                set sliceLen = 16
            endif
        endif
        set parts = (n + sliceLen - 1) / sliceLen
        set header = "|" + I2S(parts) + "|" + I2S(prefixLen) + "|" + prefix
        loop
            exitwhen i >= parts
            call BlzSendSyncData(DZSYNC_SLICE_PREFIX, I2S(i) + header + SubString(data, i * sliceLen, (i + 1) * sliceLen))
            set i = i + 1
        endloop
    endfunction

    // ---- sync data ------------------------------------------------
    function DzSyncData takes string prefix, string data returns nothing
        if prefix == null then
            return
        endif
        if data == null then
            set data = ""
        endif
        if StringLength(data) > DZSYNC_DIRECT_MAX then
            call DzCompat_Sync_SendSliced(prefix, data)
            return
        endif
        call BlzSendSyncData(prefix, data)
    endfunction

    function DzSyncDataImmediately takes string prefix, string data returns nothing
        call DzSyncData(prefix, data)
    endfunction

    function DzSyncBuffer takes string prefix, string data, integer dataLen returns nothing
        // dataLen is unused - JASS strings are self-terminating; no raw buffer native exists
        call DzSyncData(prefix, data)
    endfunction

    // Blizzard docs say fromServer should always be false. Register for every
    // player slot so "any player sends, everyone receives" works.
    function DzTriggerRegisterSyncData takes trigger trig, string prefix, boolean server returns nothing
        local integer i = 0
        if trig == null or prefix == null then
            return
        endif
        loop
            exitwhen i == bj_MAX_PLAYER_SLOTS
            call BlzTriggerRegisterPlayerSyncEvent(trig, Player(i), prefix, false)
            set i = i + 1
        endloop
        call DzCompat_Sync_Register(trig, prefix)
    endfunction

    function DzGetTriggerSyncPrefix takes nothing returns string
        if gDzSyncDispatching then
            return gDzSyncDispatchPrefix
        endif
        return BlzGetTriggerSyncPrefix()
    endfunction

    function DzGetTriggerSyncData takes nothing returns string
        local string data
        if gDzSyncDispatching then
            return gDzSyncDispatchData
        endif
        set data = BlzGetTriggerSyncData()
        if data == null then
            return ""
        endif
        return data
    endfunction

    function DzGetTriggerSyncPlayer takes nothing returns player
        if gDzSyncDispatching then
            return gDzSyncDispatchPlayer
        endif
        return GetTriggerPlayer()
    endfunction

	function DzTriggerRegisterMallItemSyncData takes trigger trig returns nothing
		call DzTriggerRegisterSyncData(trig, "DZMIA", true)
	endfunction
	
	function DzTriggerRegisterMallItemConsumeEvent takes trigger trig returns nothing
		call DzTriggerRegisterSyncData(trig, "DZMIC", true)
	endfunction
	
	function DzTriggerRegisterMallItemRemoveEvent takes trigger trig returns nothing
		call DzTriggerRegisterSyncData(trig, "DZMID", true)
	endfunction
	
	function DzGetTriggerMallItemPlayer takes nothing returns player
		return DzGetTriggerSyncPlayer()
	endfunction
	
	function DzGetTriggerMallItem takes nothing returns string
		return DzGetTriggerSyncData()
	endfunction
