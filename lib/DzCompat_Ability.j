// ============================================================================
// Reforged's real BlzGetUnitAbility(unit, abilId) returns the
// unit's own instance of that ability, and BlzSet/GetAbility*(Level)Field lets
// you read/write specific documented fields on it.
//
// LIMITATION: This only works for abilities the unit currently HAS.
// If the ability hasn't been added yet, BlzGetUnitAbility
// returns null and every wrapper below is a no-op that returns a default
// value. That matches how the real engine's per-unit ability instances work.
//
// STATUS KEY:
//   [APPROX]     - closest available native; behavior may differ in edge cases
//   [UNVERIFIED] - plausible constant name following Blizzard's naming pattern
//   [PORT LIMITATION] - function has limitations that have no known solution
// ============================================================================


    globals
        hashtable gDzCompatAbilityStringData = InitHashtable()
    endglobals

    function DzCompat_GetAbilityLevelIndex takes unit whichUnit, integer abilId returns integer
        local integer lvl = GetUnitAbilityLevel(whichUnit, abilId)
        if lvl <= 0 then
            return 0
        endif
        return lvl - 1 // Blz level fields are 0-indexed, Dz/GUI ability levels are 1-indexed
    endfunction

    // Trivial - no field lookup needed at all, the real stock native already
    // answers this directly.
    function DzUnitHasAbility takes unit whichUnit, integer abil_code returns boolean
        return GetUnitAbilityLevel(whichUnit, abil_code) > 0
    endfunction

    function DzSetUnitAbilityRange takes unit whichUnit, integer abil_code, real value returns boolean
        local ability a = BlzGetUnitAbility(whichUnit, abil_code)
        if a == null then
            return false
        endif
        return BlzSetAbilityRealLevelField(a, ABILITY_RLF_CAST_RANGE, DzCompat_GetAbilityLevelIndex(whichUnit, abil_code), value)
    endfunction

    function DzGetUnitAbilityRange takes unit whichUnit, integer abil_code returns real
        local ability a = BlzGetUnitAbility(whichUnit, abil_code)
        if a == null then
            return 0.0
        endif
        return BlzGetAbilityRealLevelField(a, ABILITY_RLF_CAST_RANGE, DzCompat_GetAbilityLevelIndex(whichUnit, abil_code))
    endfunction

    function DzSetUnitAbilityArea takes unit whichUnit, integer abil_code, real value returns boolean
        local ability a = BlzGetUnitAbility(whichUnit, abil_code)
        if a == null then
            return false
        endif
        return BlzSetAbilityRealLevelField(a, ABILITY_RLF_AREA_OF_EFFECT, DzCompat_GetAbilityLevelIndex(whichUnit, abil_code), value)
    endfunction

    function DzGetUnitAbilityArea takes unit whichUnit, integer abil_code returns real
        local ability a = BlzGetUnitAbility(whichUnit, abil_code)
        if a == null then
            return 0.0
        endif
        return BlzGetAbilityRealLevelField(a, ABILITY_RLF_AREA_OF_EFFECT, DzCompat_GetAbilityLevelIndex(whichUnit, abil_code))
    endfunction

    // ---- [APPROX] Cooldown ------------------------------------
    // ABILITY_RLF_COOLDOWN is the *base* cooldown value for that level, not
    // necessarily "seconds remaining right now" - community reports are mixed
    // on whether writing it also affects an in-progress cooldown countdown.
    // If your Dz GetUnitAbilityCool call is being used to read remaining
    // cooldown mid-fight rather than the configured base value, this will not
    // behave the same - look at using BlzEndUnitAbilityCooldown / 
	// BlzGetUnitAbilityCooldown instead.
    function DzSetUnitAbilityCool takes unit whichUnit, integer abil_code, real cool, real max_cool returns boolean
        local ability a = BlzGetUnitAbility(whichUnit, abil_code)
        if a == null then
            return false
        endif
        return BlzSetAbilityRealLevelField(a, ABILITY_RLF_COOLDOWN, DzCompat_GetAbilityLevelIndex(whichUnit, abil_code), cool)
    endfunction

    function DzGetUnitAbilityCool takes unit whichUnit, integer abil_code returns real
        local ability a = BlzGetUnitAbility(whichUnit, abil_code)
        if a == null then
            return 0.0
        endif
        return BlzGetAbilityRealLevelField(a, ABILITY_RLF_COOLDOWN, DzCompat_GetAbilityLevelIndex(whichUnit, abil_code))
    endfunction

    function DzSetUnitAbilityCost takes unit whichUnit, integer abil_code, integer value returns boolean
        local ability a = BlzGetUnitAbility(whichUnit, abil_code)
        if a == null then
            return false
        endif
        return BlzSetAbilityIntegerLevelField(a, ABILITY_ILF_MANA_COST, DzCompat_GetAbilityLevelIndex(whichUnit, abil_code), value)
    endfunction

    function DzGetUnitAbilityCost takes unit whichUnit, integer abil_code returns integer
        local ability a = BlzGetUnitAbility(whichUnit, abil_code)
        if a == null then
            return 0
        endif
        return BlzGetAbilityIntegerLevelField(a, ABILITY_ILF_MANA_COST, DzCompat_GetAbilityLevelIndex(whichUnit, abil_code))
    endfunction

    function DzSetUnitAbilityTip takes unit whichUnit, integer abil_id, string tip returns boolean
        local ability a = BlzGetUnitAbility(whichUnit, abil_id)
        if a == null then
            return false
        endif
        return BlzSetAbilityStringLevelField(a, ABILITY_SLF_TOOLTIP_NORMAL, DzCompat_GetAbilityLevelIndex(whichUnit, abil_id), tip)
    endfunction

    function DzGetUnitAbilityTip takes unit whichUnit, integer abil_id returns string
        local ability a = BlzGetUnitAbility(whichUnit, abil_id)
        if a == null then
            return ""
        endif
        return BlzGetAbilityStringLevelField(a, ABILITY_SLF_TOOLTIP_NORMAL, DzCompat_GetAbilityLevelIndex(whichUnit, abil_id))
    endfunction

    function DzSetUnitAbilityUberTip takes unit whichUnit, integer abil_id, string ubertip returns boolean
        local ability a = BlzGetUnitAbility(whichUnit, abil_id)
        if a == null then
            return false
        endif
        return BlzSetAbilityStringLevelField(a, ABILITY_SLF_TOOLTIP_NORMAL_EXTENDED, DzCompat_GetAbilityLevelIndex(whichUnit, abil_id), ubertip)
    endfunction

    function DzGetUnitAbilityUberTip takes unit whichUnit, integer abil_id returns string
        local ability a = BlzGetUnitAbility(whichUnit, abil_id)
        if a == null then
            return ""
        endif
        return BlzGetAbilityStringLevelField(a, ABILITY_SLF_TOOLTIP_NORMAL_EXTENDED, DzCompat_GetAbilityLevelIndex(whichUnit, abil_id))
    endfunction

    // ---- [APPROX] generic enable/disable (unit+abilcode form) ----------------
    // Balanced enable/disable calls applies.
    function DzSetUnitAbilityEnable takes unit u, integer abil_id returns boolean
        call BlzUnitDisableAbility(u, abil_id, false, false)
        return true
    endfunction

    function DzSetUnitAbilityDisable takes unit u, integer abil_id returns boolean
        call BlzUnitDisableAbility(u, abil_id, true, false)
        return true
    endfunction

    // ============================================================================
	// Two near-misses, worth mentioning:
    //   - ABILITY_RLF_DURATION looks like the generic "Duration" field by name,
    //     but its rawcode is 'Uin2' - a narrow, single-ability-family code, NOT
    //     one of Blizzard's shared mnemonic codes. Using it here would silently
    //     return/write garbage for every ability except whichever one actually
    //     owns 'Uin2'. The real generic field is ABILITY_RLF_DURATION_NORMAL
    //     (rawcode 'adur') - used below instead.
    //   - ABILITY_ILF_MISSILE_COUNT has the same problem (rawcode 'Ncs3', a
    //     narrow per-ability code) with no generic alternative available in
    //     common.j at all - DzGetUnitAbilityMissileCount/Set are therefore NOT
    //     implemented here
    // The fields used below (ucpt, ucbs, amsp, amac, arlv, amat, adur, ahdu)
    // all follow Blizzard's short-lowercase-mnemonic pattern shared by the
    // already-verified aran/aare/acdn/amcs fields, which is the actual signal
    // of "genuinely reused across many stock abilities" - not the constant
    // name's readability.
    // ============================================================================

    // ---- Cast Point / Backswing --------------------------------------
    // These are real per-UNIT fields (UNIT_RF_CAST_POINT / UNIT_RF_CAST_BACK_SWING),
    // not per-ability ones, despite Dz naming them "UnitAbility*" - matches how
    // WC3 actually works: a unit has one cast point/backswing shared by every
    // spell it casts. abil_id is accepted for signature compatibility but has
    // no effect on the result, same as the real engine.
    function DzSetUnitAbilityCastPoint takes unit u, integer abil_id, real value returns boolean
        return BlzSetUnitRealField(u, UNIT_RF_CAST_POINT, value)
    endfunction

    function DzGetUnitAbilityCastPoint takes unit u, integer abil_id returns real
        return BlzGetUnitRealField(u, UNIT_RF_CAST_POINT)
    endfunction

    function DzSetUnitAbilityBackSwing takes unit u, integer abil_id, real value returns boolean
        return BlzSetUnitRealField(u, UNIT_RF_CAST_BACK_SWING, value)
    endfunction

    function DzGetUnitAbilityBackSwing takes unit u, integer abil_id returns real
        return BlzGetUnitRealField(u, UNIT_RF_CAST_BACK_SWING)
    endfunction

    // ---- [APPROX] Missile speed ------------------------------------------------
    // The real field (ABILITY_IF_MISSILE_SPEED) is an INTEGER field -
    // Dz's native is typed `real`. This is not a shim precision loss: WC3's
    // missile speed genuinely only ever stores a whole number, so any
    // fractional value was already going to be truncated by the game itself.
    // R2I/I2R just make that explicit at the boundary.
    function DzSetUnitAbilityMissileSpeed takes unit u, integer abil_id, real missile_speed returns boolean
        local ability a = BlzGetUnitAbility(u, abil_id)
        if a == null then
            return false
        endif
        return BlzSetAbilityIntegerField(a, ABILITY_IF_MISSILE_SPEED, R2I(missile_speed))
    endfunction

    function DzGetUnitAbilityMissileSpeed takes unit u, integer abil_id returns real
        local ability a = BlzGetUnitAbility(u, abil_id)
        if a == null then
            return 0.0
        endif
        return I2R(BlzGetAbilityIntegerField(a, ABILITY_IF_MISSILE_SPEED))
    endfunction

    function DzSetUnitAbilityMissileArc takes unit u, integer abil_id, real missile_arc returns boolean
        local ability a = BlzGetUnitAbility(u, abil_id)
        if a == null then
            return false
        endif
        return BlzSetAbilityRealField(a, ABILITY_RF_ARF_MISSILE_ARC, missile_arc)
    endfunction

    function DzGetUnitAbilityMissileArc takes unit u, integer abil_id returns real
        local ability a = BlzGetUnitAbility(u, abil_id)
        if a == null then
            return 0.0
        endif
        return BlzGetAbilityRealField(a, ABILITY_RF_ARF_MISSILE_ARC)
    endfunction

    // ---- Missile art (model path) - level field ----------------------
    function DzSetUnitAbilityMissileArt takes unit u, integer abil_id, string missile_art returns boolean
        local ability a = BlzGetUnitAbility(u, abil_id)
        if a == null then
            return false
        endif
        return BlzSetAbilityStringLevelField(a, ABILITY_SLF_MISSILE_ART, DzCompat_GetAbilityLevelIndex(u, abil_id), missile_art)
    endfunction

    function DzGetUnitAbilityMissileArt takes unit u, integer abil_id returns string
        local ability a = BlzGetUnitAbility(u, abil_id)
        if a == null then
            return ""
        endif
        return BlzGetAbilityStringLevelField(a, ABILITY_SLF_MISSILE_ART, DzCompat_GetAbilityLevelIndex(u, abil_id))
    endfunction

    // ---- Required level (non-level integer field) --------------------
    function DzSetUnitAbilityReqLevel takes unit Unit, integer abil_code, integer value returns boolean
        local ability a = BlzGetUnitAbility(Unit, abil_code)
        if a == null then
            return false
        endif
        return BlzSetAbilityIntegerField(a, ABILITY_IF_REQUIRED_LEVEL, value)
    endfunction

    function DzGetUnitAbilityReqLevel takes unit Unit, integer abil_code returns integer
        local ability a = BlzGetUnitAbility(Unit, abil_code)
        if a == null then
            return 0
        endif
        return BlzGetAbilityIntegerField(a, ABILITY_IF_REQUIRED_LEVEL)
    endfunction

    // ---- Duration (normal) ---------------
    // Uses ABILITY_RLF_DURATION_NORMAL ('adur'), NOT ABILITY_RLF_DURATION
    // ('Uin2').
    function DzSetUnitAbilityDuration takes unit u, integer abil_id, real value returns boolean
        local ability a = BlzGetUnitAbility(u, abil_id)
        if a == null then
            return false
        endif
        return BlzSetAbilityRealLevelField(a, ABILITY_RLF_DURATION_NORMAL, DzCompat_GetAbilityLevelIndex(u, abil_id), value)
    endfunction

    function DzGetUnitAbilityDuration takes unit u, integer abil_id returns real
        local ability a = BlzGetUnitAbility(u, abil_id)
        if a == null then
            return 0.0
        endif
        return BlzGetAbilityRealLevelField(a, ABILITY_RLF_DURATION_NORMAL, DzCompat_GetAbilityLevelIndex(u, abil_id))
    endfunction

    // ---- Duration (hero targets) --------------------------------------
    function DzSetUnitAbilityHeroDuration takes unit u, integer abil_id, real value returns boolean
        local ability a = BlzGetUnitAbility(u, abil_id)
        if a == null then
            return false
        endif
        return BlzSetAbilityRealLevelField(a, ABILITY_RLF_DURATION_HERO, DzCompat_GetAbilityLevelIndex(u, abil_id), value)
    endfunction

    function DzGetUnitAbilityHeroDuration takes unit u, integer abil_id returns real
        local ability a = BlzGetUnitAbility(u, abil_id)
        if a == null then
            return 0.0
        endif
        return BlzGetAbilityRealLevelField(a, ABILITY_RLF_DURATION_HERO, DzCompat_GetAbilityLevelIndex(u, abil_id))
    endfunction

    // ---- Icon art - level field, rawcode 'aart' follows the same
    // reliable short-lowercase-mnemonic pattern as the other generic fields
    function DzSetUnitAbilityArt takes unit u, integer abil_id, string art_path returns boolean
        local ability a = BlzGetUnitAbility(u, abil_id)
        if a == null then
            return false
        endif
        return BlzSetAbilityStringLevelField(a, ABILITY_SLF_ICON_NORMAL, DzCompat_GetAbilityLevelIndex(u, abil_id), art_path)
    endfunction

    function DzGetUnitAbilityArt takes unit u, integer abil_id returns string
        local ability a = BlzGetUnitAbility(u, abil_id)
        if a == null then
            return ""
        endif
        return BlzGetAbilityStringLevelField(a, ABILITY_SLF_ICON_NORMAL, DzCompat_GetAbilityLevelIndex(u, abil_id))
    endfunction

    // ---- [APPROX] button position - non-level integer fields ----------------------
    // Reforged actually has THREE separate button-position pairs (normal/
    // activated/research icon states) where Dz's single native only has one
    // concept of "the" button position - mapped to the "normal" state pair
    // (ABILITY_IF_BUTTON_POSITION_NORMAL_X/Y) as the most common context.
    // If a mapper actually needs the activated/research icon repositioned
    // too, this alone won't cover that - there's no way to know which one(s)
    // they meant from a single (x, y) call.
    function DzSetUnitAbilityButtonPos takes unit Unit, integer abil_code, integer x, integer y returns boolean
        local ability a = BlzGetUnitAbility(Unit, abil_code)
        local boolean okX
        local boolean okY
        if a == null then
            return false
        endif
        set okX = BlzSetAbilityIntegerField(a, ABILITY_IF_BUTTON_POSITION_NORMAL_X, x)
        set okY = BlzSetAbilityIntegerField(a, ABILITY_IF_BUTTON_POSITION_NORMAL_Y, y)
        return okX and okY
    endfunction

    // ---- [APPROX] no matching real native for arbitrary key/value string
    // tagging on an ability handle - bookkeeping only. The string key is
    // hashed to an integer via the real StringHash native since hashtable
    // childKeys must be integers.
    function DzAbilitySetStringData takes ability whichAbility, string key, string value returns nothing
        call SaveStr(gDzCompatAbilityStringData, GetHandleId(whichAbility), StringHash(key), value)
    endfunction


    // ---- Enable/disable an ability handle on its owning unit ----
    // Uses EXGetAbilityId + YDWEEX_GetAbilityOwner (from DzCompat_YDWE_EX.j)
    // and BlzUnitDisableAbility. hideUI mirrors the Blz native's second flag.
    function DzAbilitySetEnable takes ability whichAbility, boolean enable, boolean hideUI returns nothing
        local unit owner = YDWEEX_GetAbilityOwner(whichAbility)
        if owner == null then
            return
        endif
        call BlzUnitDisableAbility(owner, EXGetAbilityId(whichAbility), not enable, hideUI)
    endfunction
