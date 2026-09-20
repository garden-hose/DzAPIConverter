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
