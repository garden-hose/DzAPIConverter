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
// are implemented below (decimal 18, 21, 22, 32, 37, 81 = hex 0x12, 0x15,
// 0x16, 0x20, 0x25, 0x51). Add a case for any other index a map turns out to
// need - unmapped indices fall through to a harmless 0 / no-op, exactly the
// same silent failure they'd have had without this file, so adding this
// library is always strictly an improvement, never a regression.
// ============================================================================

    function DzCompat_GetExtUnitState takes unit whichUnit, integer idx returns real
        if idx == 18 then
            // [REAL] 0x12 Attack 1 base damage
            return I2R(BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_BASE, 0))
        elseif idx == 21 then
            // [APPROX] 0x15 Attack 1 max damage - WC3 has no direct "max damage"
            // field; the object editor derives it as base + dice * sides, so
            // that's what's reproduced here.
            return I2R(BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_BASE, 0) + (BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_NUMBER_OF_DICE, 0) * BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_SIDES_PER_DIE, 0)))
        elseif idx == 22 then
            // [APPROX] 0x16 Attack 1 damage range (max - base), same caveat as 21
            return I2R(BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_NUMBER_OF_DICE, 0) * BlzGetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_SIDES_PER_DIE, 0))
        elseif idx == 32 then
            // [REAL] 0x20 Armor
            return BlzGetUnitArmor(whichUnit)
        elseif idx == 37 then
            // [APPROX] 0x25 Attack 1 interval/cooldown - this returns the *live*
            // cooldown (post agility/item bonuses). If the source map meant the
            // static design-time base cooldown instead, swap this for
            // BlzGetUnitWeaponRealField(whichUnit, UNIT_WEAPON_RF_ATTACK_BASE_COOLDOWN, 0).
            return BlzGetUnitAttackCooldown(whichUnit, 0)
        elseif idx == 81 then
            // [LOCAL] 0x51 Rate of fire / global attack-rate multiplier - Reforged
            // has no engine field for this at all; kkapi tracked it as a bonus
            // layered on top of cooldown. Bookkeeping only: whatever wrote this
            // value (DzCompat_SetExtUnitState below, or the map's own attack-speed
            // system) is the only thing that can make it non-zero.
            return LoadReal(gDzCompatUnitStateTable, GetHandleId(whichUnit), 9081)
        else
            // Unmapped extended index - see the hex table above. Falls back to 0,
            // same as an unconverted call would have returned in Reforged.
            return 0.
        endif
    endfunction

    function DzCompat_SetExtUnitState takes unit whichUnit, integer idx, real value returns nothing
        if idx == 18 then
            // [REAL] 0x12 Attack 1 base damage
            call BlzSetUnitWeaponIntegerField(whichUnit, UNIT_WEAPON_IF_ATTACK_DAMAGE_BASE, 0, R2I(value))
        elseif idx == 32 then
            // [REAL] 0x20 Armor
            call BlzSetUnitArmor(whichUnit, value)
        elseif idx == 81 then
            // [LOCAL] 0x51 Rate of fire - see the Get side above
            call SaveReal(gDzCompatUnitStateTable, GetHandleId(whichUnit), 9081, value)
        else
            // 21 (max damage), 22 (damage range) and 37 (cooldown) are derived/live
            // reads on the Get side with no single field to write back to, and any
            // other index is unmapped - writes to them are silently dropped here,
            // same as an unconverted SetUnitState call would have done nothing
            // useful in Reforged. Add a case above if a map needs one of these to
            // actually stick.
        endif
    endfunction
