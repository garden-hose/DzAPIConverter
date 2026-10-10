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
// are implemented below (decimal 18, 19, 20, 21, 22, 32, 37, 81 = hex 0x12,
// 0x13, 0x14, 0x15, 0x16, 0x20, 0x25, 0x51; and, read from the KKWE 2026
// yd_jass_api.dll GetUnitState/SetUnitState hooks at 0x10020980/0x10020DC0,
// 0x10, 0x11, 0x21-0x24, 0x26, 0x28, 0x29, 0x40, 0x50, 0x52-0x54, 0x56, 0x57,
// 0x60). In the japi the weapon states of a unit without an attack read 0 and
// ignore writes, and a real written to an integer field is TRUNCATED (R2I).
// Add a case for any other index a
// map turns out to need - unmapped indices fall through to a harmless 0 /
// no-op, exactly the same silent failure they'd have had without this file, so
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
    //
    // [FIXED] This trigger is registered with TriggerRegisterAnyUnitEventBJ, so it
    // fires for every attack by every unit in the game - including units that never
    // had index 37 or 81 touched at all. It used to call ApplyAttackSpeed
    // unconditionally, which calls BlzSetUnitAttackCooldown on every one of those
    // attacks too: harmless arithmetically (delta37/bonus81 default to 0, so the
    // cooldown is written back to what it already was), but it stomps any OTHER
    // source of that unit's cooldown - a real attack-speed aura or item using
    // BlzSetUnitAttackCooldown itself gets silently reverted on the unit's very next
    // attack. Only a unit index 37/81 has actually touched (marked at tag 9082 in
    // DzCompat_SetExtUnitState) is re-applied here now.
    function DzCompat_ExtStateAttackSpeedHandler takes nothing returns nothing
        local unit u = GetAttacker()
        if u == null or not HaveSavedBoolean(gDzCompatUnitStateTable, GetHandleId(u), 9082) then
            return
        endif
        call DzCompat_ExtStateApplyAttackSpeed(u)
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

    // [FIXED] [APPROX] The "green" attack bonus (items/auras such as Claws of
    // Attack) is not part of the weapon's base/dice/sides fields at all - it comes from
    // whatever ability granted it, most commonly one of Blizzard's stock "Item Attack
    // Bonus" abilities, which all expose the bonus through the same real field,
    // ABILITY_ILF_ATTACK_BONUS ('Iatt'). Index 21 (max damage) used to derive its value
    // from base + dice*sides alone, silently dropping this bonus whenever a map read
    // it and wrote it back (the round trip baked the wrong number into base, losing the
    // bonus on the next attack-bonus change). Summing 'Iatt' across the unit's current
    // abilities recovers the common case; a bonus applied by some other, non-field means
    // (e.g. a fully custom buff system) is still outside what this can see.
    // Index 19 (0x13) exposes this value as a unit-state via DzCompat_ExtStateGetBonus19.
    function DzCompat_ExtStateGetAttackBonus takes unit whichUnit returns integer
        local integer i = 0
        local integer total = 0
        local ability a
        loop
            set a = BlzGetUnitAbilityByIndex(whichUnit, i)
            exitwhen a == null
            set total = total + BlzGetAbilityIntegerLevelField(a, ABILITY_ILF_ATTACK_BONUS, GetUnitAbilityLevel(whichUnit, BlzGetAbilityId(a)) - 1)
            set i = i + 1
        endloop
        return total
    endfunction

    // Effective index-19 value: local override if the map wrote one (Set of
    // 0x13 stores tag 9085 and flags 9086), else the live 'Iatt' ability sum.
    // Set never changes combat on its own - Reforged has no single field for
    // green bonus - it only stores the value for Get read-back.
    function DzCompat_ExtStateGetBonus19 takes unit whichUnit returns real
        local integer id = GetHandleId(whichUnit)
        if HaveSavedBoolean(gDzCompatUnitStateTable, id, 9086) then
            return LoadReal(gDzCompatUnitStateTable, id, 9085)
        endif
        return I2R(DzCompat_ExtStateGetAttackBonus(whichUnit))
    endfunction

    // The japi's weapon states read the unit's attack object; a unit without one reads 0 and ignores
    // writes (yd_jass_api.dll, the [U+0x1E8] check in 0x10020980). Proven in game in our layer.
    function DzCompat_ExtStateHasAttack takes unit whichUnit returns boolean
        return IsUnitType(whichUnit, UNIT_TYPE_MELEE_ATTACKER) or IsUnitType(whichUnit, UNIT_TYPE_RANGED_ATTACKER)
    endfunction

    // States of the unit itself (0x50 armor type, 0x52 acquisition range, 0x53/0x54 life/mana
    // regeneration, 0x60 targeted as) and the other weapon-1 fields, all with a Reforged field.
    // Returns 0. for an index it does not know.
    function DzCompat_GetExtUnitStateMore takes unit whichUnit, integer idx returns real
        if idx == 80 then
            // [REAL] 0x50 armor (defense) type
            return I2R(BlzGetUnitIntegerField(whichUnit, UNIT_IF_DEFENSE_TYPE))
        elseif idx == 82 then
            // [REAL] 0x52 acquisition range
            return BlzGetUnitRealField(whichUnit, UNIT_RF_ACQUISITION_RANGE)
        elseif idx == 83 then
            // [REAL] 0x53 life regeneration
            return BlzGetUnitRealField(whichUnit, UNIT_RF_HIT_POINTS_REGENERATION_RATE)
        elseif idx == 84 then
            // [REAL] 0x54 mana regeneration
            return BlzGetUnitRealField(whichUnit, UNIT_RF_MANA_REGENERATION)
        elseif idx == 96 then
            // [REAL] 0x60 targeted as
            return I2R(BlzGetUnitIntegerField(whichUnit, UNIT_IF_TARGETED_AS))
        elseif not DzCompat_ExtStateHasAttack(whichUnit) then
            return 0.
        elseif idx == 16 then
            // [REAL] 0x10 attack 1 number of dice
            return I2R(BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_NUMBER_OF_DICE, 0))
        elseif idx == 17 then
            // [REAL] 0x11 attack 1 sides per die
            return I2R(BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_SIDES_PER_DIE, 0))
        elseif idx == 33 then
            // [REAL] 0x21 attack 1 damage loss factor
            return BlzGetUnitWeaponRealField(whichUnit, UNIT_WEAPON_RF_ATTACK_DAMAGE_LOSS_FACTOR, 0)
        elseif idx == 34 then
            // [REAL] 0x22 attack 1 weapon sound
            return I2R(BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_WEAPON_SOUND, 0))
        elseif idx == 35 then
            // [REAL] 0x23 attack 1 attack type
            return I2R(BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_ATTACK_TYPE, 0))
        elseif idx == 36 then
            // [REAL] 0x24 attack 1 maximum number of targets
            return I2R(BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_MAXIMUM_NUMBER_OF_TARGETS, 0))
        elseif idx == 38 then
            // [REAL] 0x26 attack 1 damage point
            return BlzGetUnitWeaponRealField(whichUnit, UNIT_WEAPON_RF_ATTACK_DAMAGE_POINT, 0)
        elseif idx == 40 then
            // [REAL] 0x28 attack 1 backswing point
            return BlzGetUnitWeaponRealField(whichUnit, UNIT_WEAPON_RF_ATTACK_BACKSWING_POINT, 0)
        elseif idx == 41 then
            // [REAL] 0x29 attack 1 targets allowed (the japi itself reads the 0x56 field here, a bug not copied)
            return I2R(BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_TARGETS_ALLOWED, 0))
        elseif idx == 64 then
            // [REAL] 0x40 attack 2 range (read only here)
            return BlzGetUnitWeaponRealField(whichUnit, UNIT_WEAPON_RF_ATTACK_RANGE, 1)
        elseif idx == 86 then
            // [REAL] 0x56 attack 1 spill distance
            return BlzGetUnitWeaponRealField(whichUnit, UNIT_WEAPON_RF_ATTACK_DAMAGE_SPILL_DISTANCE, 0)
        elseif idx == 87 then
            // [REAL] 0x57 attack 1 spill radius
            return BlzGetUnitWeaponRealField(whichUnit, UNIT_WEAPON_RF_ATTACK_DAMAGE_SPILL_RADIUS, 0)
        endif
        return 0.
    endfunction

    // The writes of DzCompat_GetExtUnitStateMore's indices (0x40 is read only here). Weapon fields
    // through index 0 [UNVERIFIED in game: the weapon-1 range needed the index quirk above].
    function DzCompat_SetExtUnitStateMore takes unit whichUnit, integer idx, real value returns nothing
        if idx == 80 then
            call BlzSetUnitIntegerField(whichUnit, UNIT_IF_DEFENSE_TYPE, R2I(value))
        elseif idx == 82 then
            call BlzSetUnitRealField(whichUnit, UNIT_RF_ACQUISITION_RANGE, value)
        elseif idx == 83 then
            call BlzSetUnitRealField(whichUnit, UNIT_RF_HIT_POINTS_REGENERATION_RATE, value)
        elseif idx == 84 then
            call BlzSetUnitRealField(whichUnit, UNIT_RF_MANA_REGENERATION, value)
        elseif idx == 96 then
            call BlzSetUnitIntegerField(whichUnit, UNIT_IF_TARGETED_AS, R2I(value))
        elseif not DzCompat_ExtStateHasAttack(whichUnit) then
            return
        elseif idx == 16 then
            call BlzSetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_NUMBER_OF_DICE, 0, R2I(value))
        elseif idx == 17 then
            call BlzSetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_SIDES_PER_DIE, 0, R2I(value))
        elseif idx == 33 then
            call BlzSetUnitWeaponRealField(whichUnit, UNIT_WEAPON_RF_ATTACK_DAMAGE_LOSS_FACTOR, 0, value)
        elseif idx == 34 then
            call BlzSetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_WEAPON_SOUND, 0, R2I(value))
        elseif idx == 35 then
            call BlzSetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_ATTACK_TYPE, 0, R2I(value))
        elseif idx == 36 then
            call BlzSetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_MAXIMUM_NUMBER_OF_TARGETS, 0, R2I(value))
        elseif idx == 38 then
            call BlzSetUnitWeaponRealField(whichUnit, UNIT_WEAPON_RF_ATTACK_DAMAGE_POINT, 0, value)
        elseif idx == 40 then
            call BlzSetUnitWeaponRealField(whichUnit, UNIT_WEAPON_RF_ATTACK_BACKSWING_POINT, 0, value)
        elseif idx == 41 then
            call BlzSetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_TARGETS_ALLOWED, 0, R2I(value))
        elseif idx == 86 then
            call BlzSetUnitWeaponRealField(whichUnit, UNIT_WEAPON_RF_ATTACK_DAMAGE_SPILL_DISTANCE, 0, value)
        elseif idx == 87 then
            call BlzSetUnitWeaponRealField(whichUnit, UNIT_WEAPON_RF_ATTACK_DAMAGE_SPILL_RADIUS, 0, value)
        endif
    endfunction

    function DzCompat_GetExtUnitState takes unit whichUnit, integer idx returns real
        if idx == 18 then
            // [REAL] 0x12 Attack 1 base damage
            return I2R(BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_BASE, 0))
        elseif idx == 19 then
            // [APPROX on Get / LOCAL on Set] 0x13 Attack 1 green damage bonus
            return DzCompat_ExtStateGetBonus19(whichUnit)
        elseif idx == 20 then
            // [APPROX] 0x14 Attack 1 min damage - derived as base + dice
            // (one pip per die), matching the object editor formula, plus the
            // effective green bonus (see DzCompat_ExtStateGetBonus19).
            return I2R(BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_BASE, 0) + BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_NUMBER_OF_DICE, 0)) + DzCompat_ExtStateGetBonus19(whichUnit)
        elseif idx == 21 then
            // [APPROX] 0x15 Attack 1 max damage - WC3 has no direct "max damage"
            // field; the object editor derives it as base + dice * sides, so
            // that's what's reproduced here, plus the effective green bonus
            // (see DzCompat_ExtStateGetBonus19) so an active attack bonus is
            // reflected instead of silently dropped.
            return I2R(BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_BASE, 0) + (BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_NUMBER_OF_DICE, 0) * BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_SIDES_PER_DIE, 0))) + DzCompat_ExtStateGetBonus19(whichUnit)
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
            // The other indices with a Reforged field (DzCompat_GetExtUnitStateMore); any other
            // unmapped extended index - see the hex table above - falls back to 0, same as an
            // unconverted call would have returned in Reforged.
            return DzCompat_GetExtUnitStateMore(whichUnit, idx)
        endif
    endfunction

    function DzCompat_SetExtUnitState takes unit whichUnit, integer idx, real value returns nothing
        local integer id
        if idx == 18 then
            // [REAL] 0x12 Attack 1 base damage
            call BlzSetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_BASE, 0, R2I(value))
        elseif idx == 19 then
            // [LOCAL] 0x13 Attack 1 green damage bonus - no Reforged field to
            // write; store for Get read-back only (see DzCompat_ExtStateGetBonus19).
            set id = GetHandleId(whichUnit)
            call SaveReal(gDzCompatUnitStateTable, id, 9085, value)
            call SaveBoolean(gDzCompatUnitStateTable, id, 9086, true)
        elseif idx == 20 or idx == 21 then
            // 0x14 / 0x15 Attack 1 min / max damage are READ ONLY: the japi's SetUnitState
            // swallows the write (yd_jass_api.dll 0x10020E2C: no field written, the original
            // native not called). This used to rewrite the base damage from the requested value.
            return
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
            call SaveBoolean(gDzCompatUnitStateTable, GetHandleId(whichUnit), 9082, true)
            call DzCompat_ExtStateEnsureAttackSpeedHook()
            call DzCompat_ExtStateApplyAttackSpeed(whichUnit)
        elseif idx == 81 then
            // [REAL, unified with index 37 - see header, enabled by default]
            // 0x51 Rate of fire. Stores the bonus, then lets
            // DzCompat_ExtStateApplyAttackSpeed combine it with index 37's
            // delta (both anchored on the same frozen baseline) and apply the
            // single, non-double-counted result.
            call SaveReal(gDzCompatUnitStateTable, GetHandleId(whichUnit), 9081, value)
            call SaveBoolean(gDzCompatUnitStateTable, GetHandleId(whichUnit), 9082, true)
            call DzCompat_ExtStateEnsureAttackSpeedHook()
            call DzCompat_ExtStateApplyAttackSpeed(whichUnit)
        else
            // The other indices with a Reforged field (DzCompat_SetExtUnitStateMore). Any other index
            // is unmapped - writes are silently dropped there, same as an unconverted SetUnitState call
            // would have done nothing useful in Reforged. Add a case if a map needs one to stick.
            call DzCompat_SetExtUnitStateMore(whichUnit, idx, value)
        endif
    endfunction
