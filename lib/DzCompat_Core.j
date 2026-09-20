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
endglobals

// ---- [REAL, via stock checks] UnitAlive ------------------------------------
// Platform maps (KK/Dz and many YDWE scripts) declare
//   native UnitAlive takes unit id returns boolean
// Replace it with the standard community definition: 
// a unit is alive when it still has a type
// id (not removed) and is not flagged UNIT_TYPE_DEAD.
// Null-safe: GetUnitTypeId(null) is 0, so the combined check returns false for
// a null handle.
function UnitAlive takes unit whichUnit returns boolean
    return GetUnitTypeId(whichUnit) != 0 and not IsUnitType(whichUnit, UNIT_TYPE_DEAD)
endfunction
