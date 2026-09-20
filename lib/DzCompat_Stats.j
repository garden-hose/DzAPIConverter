// ============================================================================
// DzCompat_Stats.j
// Batch 6: Unit stats, item cosmetics, ability details, terrain queries
//
// These are the user's own best-effort/draft implementations - an attempt to
// architect something as close as possible to the real natives, NOT
// confirmed exact matches. This revision:
//   - removes functions that duplicated already-VERIFIED real implementations
//     living in DzCompat_Batch2.j / DzCompat_AbilityField.j (every duplicate
//     found was also a regression - fake bookkeeping replacing something
//     that actually worked; see conversation history for the full list)
//   - fixes several compile errors (undefined natives, and integer literals
//     passed where a typed *field constant is required - JASS enforces this
//     at compile time, it is not just a style issue)
//   - corrects a few confidently-stated native-existence claims that turned
//     out to be false when checked against this project's own common.j/
//     blizzard.j (BlzSetItemVertexColor, BlzSetUnitCollisionSize,
//     BlzSetHeroPortraitModel, SetTextTagFont - none of these exist here)
//   - deliberately KEEPS every function that doesn't correspond to a native
//     declared anywhere in DzAPI.j/KKAPI.j/BlizzardAPI.j (several Get*
//     counterparts to real Set* natives) - these are intentional additions
//     for interface symmetry, not something to strip out just because they
//     aren't part of the original surface.
//
// STATUS KEY:
//   [VERIFIED]   - Direct wrapper of confirmed Blz/stock native
//   [LOCAL]      - Hashtable-backed state tracking (cosmetic/UI-only, no
//                  gameplay sync, no effect on real engine state)
//   [APPROX]     - Mathematical approximation or best-effort technique
//   [NOT REAL]   - not a native declared in this project's own Dz/KK headers;
//                  kept intentionally for interface symmetry with a real
//                  Set*/Get* counterpart, but calling code should know
//                  there's no such thing on the original platform
//
// IMPORTANT LIMITATIONS:
//   - [LOCAL] natives store state only in this map's hashtable. They do NOT
//     persist across network sync and do NOT reflect real engine state -
//     bookkeeping only. Use for cosmetic/UI purposes.
//   - A few Set/Get pairs below are asymmetric on purpose: the Set is a real
//     native with no known real backing (so it's [LOCAL]), while the
//     matching Get is [NOT REAL] (invented for symmetry) or vice versa -
//     each such case is called out where it happens so the disconnect is
//     never a surprise.
// ============================================================================


    globals
        hashtable gDzCompatUnitStateTable = InitHashtable()  // unit -> property map
        hashtable gDzCompatItemStateTable = InitHashtable()  // item -> property map
        hashtable gDzCompatTextTagStateTable = InitHashtable() // texttag -> property map
    endglobals

    function DzCompat_AbilKey takes integer abilId, integer tag returns integer
        // Safe combination for the (ability, property-tag) childKey dimension:
        // ability rawcodes and these small tags are added, not multiplied by a
        // handle ID (the original draft computed GetHandleId(u) * 1000 +
        // abil_id as a single combined parentKey - handle IDs grow over a long
        // game and *1000 can overflow JASS's 32-bit signed integer and wrap
        // unpredictably, silently aliasing unrelated units' data together).
        // GetHandleId(u) is now used directly as parentKey (never multiplied,
        // so it can't overflow), and this childKey only ever combines an
        // ability rawcode with a tiny tag (0-99) - two different real ability
        // rawcodes would need to differ by less than 100 to collide, which is
        // vanishingly unlikely in practice.
        return abilId + tag
    endfunction

    // ========================================================================
    // UNIT NAME & DESCRIPTION
    // ========================================================================
    //
    // NOTE: the original draft's DzSetUnitName duplicated DzCompat_Batch2.j's
    // real, verified implementation (BlzSetUnitName - it actually renames the
    // unit) with a hashtable-only version that had no real effect at all.
    // Removed. DzGetUnitName below is [NOT REAL] (kept per instruction) and,
    // with no local setter left to feed it, now always falls through to the
    // real engine name - which is the correct, honest behavior, just worth
    // knowing it's no longer capable of returning anything custom.

    // [NOT REAL] no such native in DzAPI.j/KKAPI.j/BlizzardAPI.j. Kept for
    // symmetry. Always returns the real engine name now (see note above).
    function DzGetUnitName takes unit whichUnit returns string
        local string name = LoadStr(gDzCompatUnitStateTable, GetHandleId(whichUnit), 1)
        if name == "" then
            return GetUnitName(whichUnit)
        endif
        return name
    endfunction

    // [LOCAL] real native (DzSetUnitDescription is a genuine declared Dz
    // native), but no real Reforged native sets a unit's description/tooltip
    // text at runtime - checked, none exists. Bookkeeping only.
    function DzSetUnitDescription takes unit whichUnit, string value returns nothing
        call SaveStr(gDzCompatUnitStateTable, GetHandleId(whichUnit), 2, value)
    endfunction

    // [NOT REAL] no such native declared. Kept for symmetry with the (LOCAL)
    // setter above.
    function DzGetUnitDescription takes unit whichUnit returns string
        return LoadStr(gDzCompatUnitStateTable, GetHandleId(whichUnit), 2)
    endfunction

    // [LOCAL] real native, but no real setter exists for this either -
    // checked: neither BlzSetHeroPortraitModel nor any misspelled variant is
    // a real native in this project's common.j/blizzard.j. Bookkeeping only.
    function DzSetUnitPortrait takes unit whichUnit, string modelFile returns nothing
        call SaveStr(gDzCompatUnitStateTable, GetHandleId(whichUnit), 3, modelFile)
    endfunction

    // [NOT REAL] no such native declared. Kept for symmetry.
    function DzGetUnitPortrait takes unit whichUnit returns string
        return LoadStr(gDzCompatUnitStateTable, GetHandleId(whichUnit), 3)
    endfunction

    // ========================================================================
    // UNIT PROPERTIES - COLLISION, SELECTION, SCALING
    // ========================================================================

    // [LOCAL] real native, but BlzSetUnitCollisionSize does NOT exist in this
    // project's common.j (checked - the claim that Reforged 1.33+ added it
    // doesn't hold for this codebase). Bookkeeping only.
    //
    // IMPORTANT: DzCompat_Batch2.j already implements DzGetUnitCollisionSize
    // for real via the real BlzGetUnitCollisionSize getter (that one DOES
    // exist), reading live engine state - it has no idea this hashtable
    // exists and will never see what gets stored here. That means calling
    // this Set has NO visible effect at all, not even through DzGetUnitCollisionSize
    // - it's a fully inert write, kept only because DzSetUnitCollisionSize is
    // a real declared native and something has to stand in for it until a
    // real technique is found.
    function DzSetUnitCollisionSize takes unit Unit, real size returns nothing
        call SaveReal(gDzCompatUnitStateTable, GetHandleId(Unit), 10, size)
    endfunction

    // [LOCAL] [NOT REAL] no DzGetUnitSelectScale native is declared anywhere
    // in this project's headers - kept for symmetry with the setter below.
    function DzSetUnitSelectScale takes unit Unit, real scale returns nothing
        call SaveReal(gDzCompatUnitStateTable, GetHandleId(Unit), 11, scale)
    endfunction

    function DzGetUnitSelectScale takes unit Unit returns real
        local real scale = LoadReal(gDzCompatUnitStateTable, GetHandleId(Unit), 11)
        if scale <= 0.0 then
            return 1.0  // Default scale
        endif
        return scale
    endfunction

    // [LOCAL] real native, but there's no real Reforged technique that
    // ignores hits without much larger side effects: SetUnitInvulnerable
    // stops damage but doesn't affect targeting/selection, PauseUnit stops
    // far more than hit detection (orders, animation, everything). Neither
    // is a clean match for "ignore hits only", so this stays bookkeeping
    // only rather than picking one of those with unintended side effects.
    function DzSetUnitHitIgnore takes unit Unit, boolean ignore returns nothing
        call SaveBoolean(gDzCompatUnitStateTable, GetHandleId(Unit), 12, ignore)
    endfunction

    // [NOT REAL] no such native declared. Kept for symmetry.
    function DzGetUnitHitIgnore takes unit Unit returns boolean
        return LoadBoolean(gDzCompatUnitStateTable, GetHandleId(Unit), 12)
    endfunction

    // ========================================================================
    // TERRAIN & POSITION QUERIES
    // ========================================================================

    // [APPROX] real native (DzGetTerrainZ is genuinely declared), fixed from
    // the original draft's call to "BlzGetTerrainCliffLevel" - that native
    // does not exist at all (checked). The real native is GetTerrainCliffLevel
    // (no Blz prefix), and it returns a discrete CLIFF LEVEL INDEX (0, 1, 2...),
    // not a continuous world-Z height - a fundamentally different thing, not
    // just a naming slip. This converts the level to an approximate Z using
    // WC3's standard 128-units-per-cliff-level spacing with level 2 treated as
    // the baseline (the common default ground level) - real terrain smoothing,
    // ramps, and deformation between levels are NOT captured, so treat this as
    // a coarse estimate, not a precise height.
    function DzGetTerrainZ takes real x, real y returns real
        return (GetTerrainCliffLevel(x, y) - 2) * 128.0
    endfunction

    // [NOT REAL] no such native declared (DzSetUnitOverheadOffset doesn't
    // appear in DzAPI.j/KKAPI.j/BlizzardAPI.j either, so both halves of this
    // pair are additions kept for interface completeness, not real API).
    // [NOT REAL] DzSetUnitOverheadOffset is not declared anywhere in this
    // project's headers - kept for symmetry with the real getter below.
    function DzSetUnitOverheadOffset takes unit u, real offset returns nothing
        call SaveReal(gDzCompatUnitStateTable, GetHandleId(u), 13, offset)
    endfunction

    // [LOCAL] CORRECTION: this one IS a genuinely declared native (found in
    // KKAPI.j) - I initially mislabeled it [NOT REAL] without verifying.
    // Its real declared signature takes `widget`, not `unit` (fixed here to
    // match exactly - JASS requires the replacement function's signature to
    // match the native it's replacing). Since widget is a supertype of
    // unit, the unit-type-specific defaulting this used to do (hero/
    // structure/other) isn't safe here anymore - not every widget is a
    // unit, and there's no legal way to test "is this widget a unit" without
    // an illegal downcast. Simplified to a single flat default.
    function DzGetUnitOverheadOffset takes widget u returns real
        local real offset = LoadReal(gDzCompatUnitStateTable, GetHandleId(u), 13)
        if offset != 0.0 then
            return offset
        endif
        return 80.0
    endfunction

    // [APPROX] real native. Fixed a type-mismatch compile error: the
    // original called widget2unit(obj), which does not exist - JASS has no
    // legal way to downcast a widget to a unit (same category of problem as
    // sibling-type handle casting discussed elsewhere in this project). The
    // real declared signature genuinely takes `widget`, not `unit`, so this
    // uses a generic walkability check that works for any widget instead of
    // one that needs unit-specific move-type data. That means it does NOT
    // account for the specific object's actual movement type (a flying unit
    // and a ground unit get the same answer here) - a real limitation, not
    // just an unused parameter.
    function DzUnitCanPlaceAround takes widget obj, real x, real y returns boolean
        if GetWidgetLife(obj) <= 0.0 then
            return false
        endif
        return IsTerrainPathable(x, y, PATHING_TYPE_WALKABILITY)
    endfunction

    // [APPROX] real native. Fixed a second type-mismatch compile error: the
    // original passed MOVE_TYPE_FOOT (type movetype) where IsTerrainPathable
    // requires a pathingtype - a different, incompatible type despite the
    // similar name. collision_type is now mapped to the closest matching
    // pathingtype (0/1=ground, 2=air, 3=water, anything else defaults to
    // ground) - this mapping is a guess at what collision_type's values mean
    // since Dz's own numbering isn't documented anywhere available; still
    // does not account for nearby unit collision, only terrain.
    function DzPositionCanPlaceAround takes real x, real y, real collision_size, integer collision_type returns boolean
        if collision_type == 2 then
            return IsTerrainPathable(x, y, PATHING_TYPE_FLYABILITY)
        elseif collision_type == 3 then
            return IsTerrainPathable(x, y, PATHING_TYPE_AMPHIBIOUSPATHING)
        endif
        return IsTerrainPathable(x, y, PATHING_TYPE_WALKABILITY)
    endfunction

    // ========================================================================
    // UNIT REGEN & STAT MODIFICATIONS
    // ========================================================================
    // All four real natives below (LifeRegen/ManaRegen/MinSpeed/MaxSpeed) are
    // genuinely declared in KKAPI.j but have no known real Reforged technique
    // backing them (regen rate and min/max speed floors/ceilings aren't
    // exposed as writable fields anywhere in common.j/blizzard.j - checked).
    // [LOCAL] bookkeeping only, unchanged from the original draft.

    function DzSetUnitLifeRegen takes unit whichUnit, real regen returns boolean
        call SaveReal(gDzCompatUnitStateTable, GetHandleId(whichUnit), 20, regen)
        return true
    endfunction

    function DzGetUnitLifeRegen takes unit whichUnit returns real
        return LoadReal(gDzCompatUnitStateTable, GetHandleId(whichUnit), 20)
    endfunction

    function DzSetUnitManaRegen takes unit whichUnit, real regen returns boolean
        call SaveReal(gDzCompatUnitStateTable, GetHandleId(whichUnit), 21, regen)
        return true
    endfunction

    function DzGetUnitManaRegen takes unit whichUnit returns real
        return LoadReal(gDzCompatUnitStateTable, GetHandleId(whichUnit), 21)
    endfunction

    function DzSetUnitMinSpeed takes unit whichUnit, real speed, boolean ignore_polymorph returns boolean
        call SaveReal(gDzCompatUnitStateTable, GetHandleId(whichUnit), 22, speed)
        return true
    endfunction

    function DzGetUnitMinSpeed takes unit whichUnit returns real
        local real minSpeed = LoadReal(gDzCompatUnitStateTable, GetHandleId(whichUnit), 22)
        if minSpeed > 0.0 then
            return minSpeed
        endif
        return GetUnitDefaultMoveSpeed(whichUnit)
    endfunction

    function DzSetUnitMaxSpeed takes unit whichUnit, real speed, boolean ignore_polymorph returns boolean
        call SaveReal(gDzCompatUnitStateTable, GetHandleId(whichUnit), 23, speed)
        return true
    endfunction

    function DzGetUnitMaxSpeed takes unit whichUnit returns real
        local real maxSpeed = LoadReal(gDzCompatUnitStateTable, GetHandleId(whichUnit), 23)
        if maxSpeed > 0.0 then
            return maxSpeed
        endif
        return 522.0
    endfunction

    // [VERIFIED] real native, and this pair CAN be upgraded to a genuine
    // real implementation: DzSetUnitCastPoint/DzSetUnitBackSwing (no ability
    // parameter - distinct from DzSetUnitAbilityCastPoint/BackSwing in
    // DzCompat_AbilityField.j) match UNIT_RF_CAST_POINT/UNIT_RF_CAST_BACK_SWING
    // exactly - the same real per-unit fields already confirmed and used for
    // the ability-scoped versions, just without an unused abil_id parameter
    // this time since none was ever declared for these.
    function DzSetUnitCastPoint takes unit whichUnit, real cast_point returns boolean
        return BlzSetUnitRealField(whichUnit, UNIT_RF_CAST_POINT, cast_point)
    endfunction

    function DzGetUnitCastPoint takes unit whichUnit returns real
        return BlzGetUnitRealField(whichUnit, UNIT_RF_CAST_POINT)
    endfunction

    function DzSetUnitBackSwing takes unit whichUnit, real back_swing returns boolean
        return BlzSetUnitRealField(whichUnit, UNIT_RF_CAST_BACK_SWING, back_swing)
    endfunction

    function DzGetUnitBackSwing takes unit whichUnit returns real
        return BlzGetUnitRealField(whichUnit, UNIT_RF_CAST_BACK_SWING)
    endfunction

    // [LOCAL] real native, no known real backing (attack-target-count isn't
    // exposed as a writable field).
    function DzSetUnitAttackTargetCount takes unit whichUnit, integer index, integer target_count returns boolean
        call SaveInteger(gDzCompatUnitStateTable, GetHandleId(whichUnit), 26 + index, target_count)
        return true
    endfunction

    function DzGetUnitAttackTargetCount takes unit whichUnit, integer index returns integer
        return LoadInteger(gDzCompatUnitStateTable, GetHandleId(whichUnit), 26 + index)
    endfunction

    // ========================================================================
    // UNIT HERO ATTRIBUTES
    // ========================================================================
    // [LOCAL] bookkeeping only, unchanged from the original draft - no real
    // native backing found for any of these.

    function DzSetHeroPrimaryAttributeType takes unit whichUnit, integer attribute, boolean keep_primary_bonus returns boolean
        call SaveInteger(gDzCompatUnitStateTable, GetHandleId(whichUnit), 30, attribute)
        return true
    endfunction

    function DzGetHeroPrimaryAttributeType takes unit whichUnit returns integer
        return LoadInteger(gDzCompatUnitStateTable, GetHandleId(whichUnit), 30)
    endfunction

    function DzSetHeroPrimaryAttribute takes unit whichUnit, integer attribute returns boolean
        call SaveInteger(gDzCompatUnitStateTable, GetHandleId(whichUnit), 31, attribute)
        return true
    endfunction

    function DzGetHeroPrimaryAttribute takes unit whichUnit, boolean include_bonus returns integer
        return LoadInteger(gDzCompatUnitStateTable, GetHandleId(whichUnit), 31)
    endfunction

    function DzSetHeroPrimaryAttributePlus takes unit whichUnit, integer attribute, real value, boolean keep_current_bonus returns boolean
        call SaveReal(gDzCompatUnitStateTable, GetHandleId(whichUnit), 32 + attribute, value)
        return true
    endfunction

    function DzGetHeroPrimaryAttributePlus takes unit whichUnit, integer attribute returns real
        return LoadReal(gDzCompatUnitStateTable, GetHandleId(whichUnit), 32 + attribute)
    endfunction

    // ========================================================================
    // ABILITY DETAILS - CASTING & TIMING
    // ========================================================================

    // DzCompat_GetAbilityLevelIndex is defined once in DzCompat_AbilityField.j
    // and reused here - no need for a second copy (this file used to have its
    // own identical private copy, which is exactly the kind of duplicate-name
    // problem that surfaces once "private" no longer isolates it per-file).

    // [VERIFIED] real native. Fixed a compile error: the original passed the
    // raw integer literal 0x0E where BlzSetAbilityRealLevelField's 2nd
    // parameter requires a typed abilityreallevelfield value - JASS rejects
    // that at compile time, it isn't just an unverified guess, it's a type
    // mismatch. ABILITY_RLF_CASTING_TIME (rawcode 'acas') is a real, generic
    // field following the same short-lowercase-mnemonic pattern already
    // confirmed reliable for the other generic ability fields in this
    // project (aran/aare/acdn/amcs/adur/ahdu), so this is now a genuine
    // real-native implementation, not a fallback guess.
    function DzSetUnitAbilityCastTime takes unit u, integer abil_id, real value returns boolean
        local ability a = BlzGetUnitAbility(u, abil_id)
        if a == null then
            return false
        endif
        return BlzSetAbilityRealLevelField(a, ABILITY_RLF_CASTING_TIME, DzCompat_GetAbilityLevelIndex(u, abil_id), value)
    endfunction

    function DzGetUnitAbilityCastTime takes unit u, integer abil_id returns real
        local ability a = BlzGetUnitAbility(u, abil_id)
        if a == null then
            return 0.0
        endif
        return BlzGetAbilityRealLevelField(a, ABILITY_RLF_CASTING_TIME, DzCompat_GetAbilityLevelIndex(u, abil_id))
    endfunction

    // ========================================================================
    // ABILITY DISPLAY & METADATA
    // ========================================================================

    // [LOCAL] real native, no known generic writable field for an ability's
    // order ID - kept as bookkeeping. Fixed the same overflow-prone
    // GetHandleId(u)*1000+abil_id parentKey pattern used throughout the
    // original draft (see DzCompat_AbilKey's comment above for why).
    function DzSetUnitAbilityOrderId takes unit u, integer abil_id, integer order_id returns boolean
        call SaveInteger(gDzCompatUnitStateTable, GetHandleId(u), DzCompat_AbilKey(abil_id, 52), order_id)
        return true
    endfunction

    function DzGetUnitAbilityOrderId takes unit u, integer abil_id returns integer
        return LoadInteger(gDzCompatUnitStateTable, GetHandleId(u), DzCompat_AbilKey(abil_id, 52))
    endfunction

    // ========================================================================
    // ITEM COSMETICS
    // ========================================================================

    // [LOCAL] real native, but BlzSetItemVertexColor/BlzGetItemVertexColor do
    // NOT exist in this project's common.j (checked earlier in this
    // conversation and re-confirmed here) - no real vertex-color native
    // exists for items at all, only for units and special effects.
    // Bookkeeping only; corrected from the original's false "[VERIFIED]" tag.
    function DzItemSetVertexColor takes item Item, integer color returns nothing
        call SaveInteger(gDzCompatItemStateTable, GetHandleId(Item), 3, color)
    endfunction

    function DzItemGetVertexColor takes item Item returns integer
        return LoadInteger(gDzCompatItemStateTable, GetHandleId(Item), 3)
    endfunction

    // [LOCAL] same limitation as above - there's no real alpha channel to
    // write since there's no real item vertex-color native to begin with.
    // The original's bit-packing math (alpha in the top byte, RGB in the
    // lower 3 bytes) is a reasonable packing scheme to keep for internal
    // consistency, it just never reaches the engine either way.
    function DzItemSetAlpha takes item Item, integer alpha returns nothing
        local integer color = LoadInteger(gDzCompatItemStateTable, GetHandleId(Item), 3)
        local integer rgb = color - (color / 16777216) * 16777216
        call SaveInteger(gDzCompatItemStateTable, GetHandleId(Item), 3, (alpha * 16777216) + rgb)
    endfunction

    // [LOCAL] real native, no real BlzSetItemScale exists (checked) -
    // bookkeeping only.
    function DzItemSetSize takes item Item, real size returns nothing
        call SaveReal(gDzCompatItemStateTable, GetHandleId(Item), 1, size)
    endfunction

    function DzItemGetSize takes item Item returns real
        local real size = LoadReal(gDzCompatItemStateTable, GetHandleId(Item), 1)
        if size <= 0.0 then
            return 1.0
        endif
        return size
    endfunction

    // [LOCAL] real native, no real setter exists for item collision size
    // either (mirrors the same gap already documented for units).
    function DzSetItemCollisionSize takes item it, real size returns nothing
        call SaveReal(gDzCompatItemStateTable, GetHandleId(it), 2, size)
    endfunction

    function DzGetItemCollisionSize takes item it returns real
        return LoadReal(gDzCompatItemStateTable, GetHandleId(it), 2)
    endfunction

    // ========================================================================
    // TEXT TAG CUSTOMIZATION
    // ========================================================================

    // [LOCAL] CORRECTION: these ARE genuinely declared natives (found in
    // KKAPI.j) - I initially mislabeled them [NOT REAL] by trusting the
    // original draft's comment without independently verifying it myself.
    // The claimed real native (SetTextTagFont) still does not exist though
    // (checked and confirmed) - bookkeeping only, has no effect on any text
    // tag's rendered font.
    function DzTextTagSetFont takes string fileName returns nothing
        call SaveStr(gDzCompatTextTagStateTable, 0, 1, fileName)
    endfunction

    function DzTextTagGetFont takes nothing returns string
        return LoadStr(gDzCompatTextTagStateTable, 0, 1)
    endfunction

    // [LOCAL] [NOT REAL] this correction is now for something else - it
    // turns out DzTextTagSetStartAlpha/SetShadowColor/GetShadowColor below
    // are ALSO genuinely declared natives (also found in KKAPI.j on
    // independent verification), not additions either. Every text-tag
    // native in this section is real; none of them are [NOT REAL]. All are
    // [LOCAL] bookkeeping since no real native backs any of them.
    function DzTextTagSetStartAlpha takes texttag t, integer alpha returns nothing
        call SaveInteger(gDzCompatTextTagStateTable, GetHandleId(t), 1, alpha)
        call SetTextTagSuspended(t, false)
    endfunction

    function DzTextTagSetShadowColor takes texttag t, integer color returns nothing
        call SaveInteger(gDzCompatTextTagStateTable, GetHandleId(t), 2, color)
    endfunction

    function DzTextTagGetShadowColor takes texttag t returns integer
        return LoadInteger(gDzCompatTextTagStateTable, GetHandleId(t), 2)
    endfunction

