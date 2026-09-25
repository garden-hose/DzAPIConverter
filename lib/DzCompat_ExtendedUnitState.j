// ============================================================================
// DzCompat_ExtendedUnitState.j
//
// On kkapi/dzapi/YDWE platforms, UnitState.cpp hooks the stock natives
//     native GetUnitState takes unit whichUnit, unitstate whichUnitState returns real
//     native SetUnitState takes unit whichUnit, unitstate whichUnitState, real newVal returns nothing
// so that, in addition to the four stock unitstate values Reforged itself
// defines (UNIT_STATE_LIFE/MAX_LIFE/MANA/MAX_MANA = ConvertUnitState(0..3)),
// many extended index values become readable/writable - things like a unit's
// current attack-1 base damage, armor, or attack cooldown, passed as a raw
// integer through ConvertUnitState(N).
//
// Reforged's real GetUnitState/SetUnitState natives only understand indices
// 0-3. Calling them with anything else (as a converted script still will,
// verbatim, since these are stock native calls - not "native X" declarations
// ForwardConverter's normal pass can intercept) silently returns/writes 0.
// ExtendedUnitStateConverter.java rewrites every
//     GetUnitState(<u>, ConvertUnitState(<N>))      N not in {0,1,2,3}
//     SetUnitState(<u>, ConvertUnitState(<N>), <v>)
// call site in the map script to route through the two functions below
// instead, so each extended index gets a real (or best-effort) Reforged
// implementation in one place instead of silently returning 0 everywhere.
//
// STATUS KEY (see also DzCompat_Stats.j):
//   [REAL]       - real 1:1 Reforged native, exact behavior
//   [APPROX]     - real Reforged data, but WC3 has no matching field, so the
//                  value is derived (e.g. "max damage" from dice/sides/base)
//   [LOCAL]      - hashtable bookkeeping only; no engine field exists at all
//
// Extended index table (hex), from the platform's UnitState.cpp enum, for
// reference when adding a new case below:
//   0x10-0x16            Attack 1 dice, sides, base, bonus, min, max, range
//   0x20                 Armor
//   0x21-0x29, 0x56-0x58  Attack 1 extras (loss factor, weapon sound, attack
//                         type, max targets, interval, delays, back swing,
//                         range buffer, target types, spill, weapon type)
//   0x30-0x47, 0x59       Attack 2 equivalents of the above
//   0x50                  Armor type
//   0x51                  Rate of fire (global attack-rate multiplier)
//   0x52                  Acquisition range
//   0x53 / 0x54           Life regen / mana regen
//   0x55                  Min range
//   0x60 / 0x61           As-target type / Type
//
// Only the indices this converter's target maps are known to actually use
// are implemented below (decimal 18, 20, 21, 22, 32, 37, 81 = hex 0x12,
// 0x14, 0x15, 0x16, 0x20, 0x25, 0x51). Add a case for any other index a map
// turns out to need - unmapped indices fall through to a harmless 0 / no-op,
// exactly the same silent failure they'd have had without this file, so
// adding this library is always strictly an improvement, never a regression.
// ============================================================================

    globals
        // Lazily created the first time index 37 or 81 is ever touched - a map
        // that touches neither never pays for a trigger it doesn't need.
        trigger gDzCompatExtStateAttackSpeedTrigger = null
    endglobals

    // Returns the unit's TRUE, unmodified base attack cooldown, captured once
    // (the first time this unit's speed is ever touched by index 37 or 81) and
    // cached from then on. This - never the live field, which after the first
    // call is only ever written by BlzSetUnitAttackCooldown as a transient,
    // per-attack override - is the one fixed reference point both index 37's
    // delta and index 81's fractional bonus are computed against, which is
    // what makes the two additive/multiplicative effects combine correctly
    // instead of one of them re-dividing a value the other already modified.
    function DzCompat_ExtStateGetFrozenBaseCooldown takes unit whichUnit returns real
        local integer id = GetHandleId(whichUnit)
        local real cached
        if HaveSavedReal(gDzCompatUnitStateTable, id, 9083) then
            return LoadReal(gDzCompatUnitStateTable, id, 9083)
        endif
        set cached = BlzGetUnitWeaponRealField(whichUnit, UNIT_WEAPON_RF_ATTACK_BASE_COOLDOWN, 0)
        call SaveReal(gDzCompatUnitStateTable, id, 9083, cached)
        return cached
    endfunction

    // The one place a unit's live cooldown is ever computed. Combines index
    // 37's accumulated absolute delta (tag 9084, "+/-.05 nudges" from the
    // map's own threshold mechanic) with index 81's fractional bonus (tag
    // 9081; 0.15 means +15% attack speed, same confirmed semantics as the
    // AIs2 DataA field) against the SAME frozen baseline, in one formula:
    //     adjustedBase = frozenBaseline - delta37
    //     finalCooldown = adjustedBase / (1 + bonus81)
    // Always applies, even when both are back to 0, so that removing the last
    // active source correctly resets the unit to its true base cooldown
    // instead of leaving a stale override in place.
    function DzCompat_ExtStateApplyAttackSpeed takes unit whichUnit returns nothing
        local integer id = GetHandleId(whichUnit)
        local real frozenBase = DzCompat_ExtStateGetFrozenBaseCooldown(whichUnit)
        local real delta37 = LoadReal(gDzCompatUnitStateTable, id, 9084)
        local real bonus81 = LoadReal(gDzCompatUnitStateTable, id, 9081)
        local real adjustedBase = frozenBase - delta37
        if frozenBase <= 0 then
            return // no real weapon on this unit - nothing to scale
        endif
        if adjustedBase <= 0.01 then
            set adjustedBase = 0.01 // safety floor - never let index 37's own deltas reach/cross zero or negative
        endif
        if bonus81 < 0 then
            set bonus81 = 0. // floating-point drift guard; never speed a unit below its adjusted base
        endif
        call BlzSetUnitAttackCooldown(whichUnit, adjustedBase / (1.0 + bonus81), 0)
    endfunction

    // EVENT_PLAYER_UNIT_ATTACKED handler: Reforged resets a unit's cooldown to
    // its own base value on every attack, so the override has to be reapplied
    // here every time, not just once when either index is set.
    function DzCompat_ExtStateAttackSpeedHandler takes nothing returns nothing
        call DzCompat_ExtStateApplyAttackSpeed(GetAttacker())
    endfunction

    // Registers the attack-speed hook exactly once, on first use.
    function DzCompat_ExtStateEnsureAttackSpeedHook takes nothing returns nothing
        if gDzCompatExtStateAttackSpeedTrigger != null then
            return
        endif
        set gDzCompatExtStateAttackSpeedTrigger = CreateTrigger()
        call TriggerRegisterAnyUnitEventBJ(gDzCompatExtStateAttackSpeedTrigger, EVENT_PLAYER_UNIT_ATTACKED)
        call TriggerAddAction(gDzCompatExtStateAttackSpeedTrigger, function DzCompat_ExtStateAttackSpeedHandler)
    endfunction

    // Reforged's weapon-range setter has an index/delta quirk: writing index 0
    // alone does not reliably produce the requested weapon-1 range. Writing the
    // delta through index 1 (newRange - r0 + r1) does on current builds. Also
    // bumps acquisition range when the new attack range would otherwise exceed it.
    function DzCompat_ExtStateSetAttackRange takes unit whichUnit, real newRange returns nothing
        local real r0 = BlzGetUnitWeaponRealField(whichUnit, UNIT_WEAPON_RF_ATTACK_RANGE, 0)
        local real r1 = BlzGetUnitWeaponRealField(whichUnit, UNIT_WEAPON_RF_ATTACK_RANGE, 1)
        call BlzSetUnitWeaponRealField(whichUnit, UNIT_WEAPON_RF_ATTACK_RANGE, 1, newRange - r0 + r1)
        if BlzGetUnitRealField(whichUnit, UNIT_RF_ACQUISITION_RANGE) < newRange then
            call BlzSetUnitRealField(whichUnit, UNIT_RF_ACQUISITION_RANGE, newRange)
        endif
    endfunction

    function DzCompat_GetExtUnitState takes unit whichUnit, integer idx returns real
        if idx == 18 then
            // [REAL] 0x12 Attack 1 base damage
            return I2R(BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_BASE, 0))
        elseif idx == 20 then
            // [APPROX] 0x14 Attack 1 min damage - derived as base + dice
            // (one pip per die), matching the object editor formula.
            return I2R(BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_BASE, 0) + BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_NUMBER_OF_DICE, 0))
        elseif idx == 21 then
            // [APPROX] 0x15 Attack 1 max damage - WC3 has no direct "max damage"
            // field; the object editor derives it as base + dice * sides, so
            // that's what's reproduced here.
            return I2R(BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_BASE, 0) + (BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_NUMBER_OF_DICE, 0) * BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_SIDES_PER_DIE, 0)))
        elseif idx == 22 then
            // [REAL] 0x16 Attack 1 range (weapon 1). Matches the UnitState.cpp
            // table entry "range" - not dice*sides damage span.
            return BlzGetUnitWeaponRealField(whichUnit, UNIT_WEAPON_RF_ATTACK_RANGE, 0)
        elseif idx == 32 then
            // [REAL] 0x20 Armor
            return BlzGetUnitArmor(whichUnit)
        elseif idx == 37 then
            // [APPROX] 0x25 Attack 1 interval/cooldown - 
			// Returns frozenBaseline - accumulatedDelta, so
            // the map's own read-modify-write (GetUnitState(...) - .05, then
            // SetUnitState(..., newVal)) round-trips consistently: this is a
            // computed value now, not a raw field read, specifically so it
            // never drifts out of sync with what index 81's bonus is applied
            // against.
            return DzCompat_ExtStateGetFrozenBaseCooldown(whichUnit) - LoadReal(gDzCompatUnitStateTable, GetHandleId(whichUnit), 9084)
        elseif idx == 81 then
            // [APPROX] 0x51 Rate of fire.
            // Returns the raw accumulated bonus (0.15 means +15% attack speed) -
            // the map's own >=3. threshold check reads this directly.
            return LoadReal(gDzCompatUnitStateTable, GetHandleId(whichUnit), 9081)
        else
            // Unmapped extended index - see the hex table above. Falls back to 0,
            // same as an unconverted call would have returned in Reforged.
            return 0.
        endif
    endfunction

    function DzCompat_SetExtUnitState takes unit whichUnit, integer idx, real value returns nothing
        local integer dice
        local integer sides
        if idx == 18 then
            // [REAL] 0x12 Attack 1 base damage
            call BlzSetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_BASE, 0, R2I(value))
        elseif idx == 20 then
            // [APPROX] 0x14 Attack 1 min damage - write by adjusting base so
            // base + dice equals the requested minimum.
            set dice = BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_NUMBER_OF_DICE, 0)
            call BlzSetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_BASE, 0, R2I(value) - dice)
        elseif idx == 21 then
            // [APPROX] 0x15 Attack 1 max damage - write by adjusting base so
            // base + dice * sides equals the requested maximum.
            set dice = BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_NUMBER_OF_DICE, 0)
            set sides = BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_SIDES_PER_DIE, 0)
            call BlzSetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_BASE, 0, R2I(value) - (dice * sides))
        elseif idx == 22 then
            // [REAL] 0x16 Attack 1 range - see DzCompat_ExtStateSetAttackRange
            call DzCompat_ExtStateSetAttackRange(whichUnit, value)
        elseif idx == 32 then
            // [REAL] 0x20 Armor
            call BlzSetUnitArmor(whichUnit, value)
        elseif idx == 37 then
            // [REAL, unified with index 81 - see header] 0x25 Attack 1
            // interval/cooldown. Derives the accumulated delta directly from
            // the new absolute value (delta = frozenBaseline - value) rather
            // than tracking it separately, so Get/Set stay consistent by
            // construction, then lets DzCompat_ExtStateApplyAttackSpeed - the
            // one place cooldown is ever actually computed - combine it with
            // index 81's bonus and apply the result.
            call SaveReal(gDzCompatUnitStateTable, GetHandleId(whichUnit), 9084, DzCompat_ExtStateGetFrozenBaseCooldown(whichUnit) - value)
            call DzCompat_ExtStateEnsureAttackSpeedHook()
            call DzCompat_ExtStateApplyAttackSpeed(whichUnit)
        elseif idx == 81 then
            // [REAL, unified with index 37 - see header, enabled by default]
            // 0x51 Rate of fire. Stores the bonus, then lets
            // DzCompat_ExtStateApplyAttackSpeed combine it with index 37's
            // delta (both anchored on the same frozen baseline) and apply the
            // single, non-double-counted result.
            call SaveReal(gDzCompatUnitStateTable, GetHandleId(whichUnit), 9081, value)
            call DzCompat_ExtStateEnsureAttackSpeedHook()
            call DzCompat_ExtStateApplyAttackSpeed(whichUnit)
        else
            // Any other index is unmapped - writes are silently dropped here,
            // same as an unconverted SetUnitState call would have done nothing
            // useful in Reforged. Add a case above if a map needs one to stick.
        endif
    endfunction
