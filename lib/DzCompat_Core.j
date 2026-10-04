// ============================================================================
// DzCompat_Core.j
// Shared globals and tiny helpers used by multiple DzCompat modules.
// Injected early so later libs can rely on these symbols.
// ============================================================================

globals
    // Shared unit/effect bookkeeping.
    hashtable gDzCompatUnitDataCache = InitHashtable()
    hashtable gDzCompatEffectTimers = InitHashtable()
    hashtable gDzCompatMouseTrack = InitHashtable()
    boolean   gDzCompatMouseTrackReady = false
    constant integer SILENCE_ABILITY_ID = 'ACsi'
    // model path string -> skin rawcode (DzSetUnitModel registry)
    hashtable gDzCompatModelPathTable = InitHashtable()
    // Diagnostics are silent by default: a warning is a message for the map author, and players
    // should not see it in the chat. Set to true in a test build to see them on screen.
    constant boolean DZCOMPAT_DEBUG_MESSAGES = false
endglobals

// Shows a diagnostic message to the local player when DZCOMPAT_DEBUG_MESSAGES is true.
function DzCompat_Warn takes string msg returns nothing
    if DZCOMPAT_DEBUG_MESSAGES then
        call DisplayTimedTextToPlayer(GetLocalPlayer(), 0., 0., 20., "|cffffcc00[DzCompat]|r " + msg)
    endif
endfunction

// Identity type-cast helpers
// Some maps call these (frame/handle “casts”). They are no-ops on Reforged but prevent missing-native errors.
function DzF2I takes integer i returns integer
    return i
endfunction
function DzI2F takes integer i returns integer
    return i
endfunction
function DzK2I takes integer i returns integer
    return i
endfunction
function DzI2K takes integer i returns integer
    return i
endfunction

// UnitAlive is declared as a native by some map environments (YDWE, AI scripts) but Reforged's
// common.j does not have it, so a map that declares it needs a real body. "Alive" means the unit
// exists AND is not dead: null and removed units (type id 0) are not alive, and neither is a
// corpse. Callers such as damage filters may pass null (an emptied group), so null must be false.
function UnitAlive takes unit id returns boolean
    if id == null then
        return false
    endif
    if GetUnitTypeId(id) == 0 then
        return false
    endif
    return not IsUnitType(id, UNIT_TYPE_DEAD)
endfunction
