// ============================================================================
// DzCompat_Sync.j
// Sync-data natives (DzSyncData family + trigger registration).
//
// ============================================================================

    // ---- sync data ------------------------------------------------
    function DzSyncData takes string prefix, string data returns nothing
        call BlzSendSyncData(prefix, data)
    endfunction

    function DzSyncDataImmediately takes string prefix, string data returns nothing
        call BlzSendSyncData(prefix, data)
    endfunction

    function DzSyncBuffer takes string prefix, string data, integer dataLen returns nothing
        // dataLen is unused - JASS strings are self-terminating; no raw buffer native exists
        call BlzSendSyncData(prefix, data)
    endfunction

    // Blizzard docs say fromServer should always be false. Register for every
    // player slot so "any player sends, everyone receives" works.
    function DzTriggerRegisterSyncData takes trigger trig, string prefix, boolean server returns nothing
        local integer i = 0
        loop
            exitwhen i == bj_MAX_PLAYER_SLOTS
            call BlzTriggerRegisterPlayerSyncEvent(trig, Player(i), prefix, false)
            set i = i + 1
        endloop
    endfunction

    function DzGetTriggerSyncPrefix takes nothing returns string
        return BlzGetTriggerSyncPrefix()
    endfunction

    function DzGetTriggerSyncData takes nothing returns string
        return BlzGetTriggerSyncData()
    endfunction

    function DzGetTriggerSyncPlayer takes nothing returns player
        return GetTriggerPlayer()
    endfunction
