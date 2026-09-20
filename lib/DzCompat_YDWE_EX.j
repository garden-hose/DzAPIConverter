// ============================================================================
// DzCompat_YDWE_EX.j
// Reforged-compatible implementations for the YDWE / yd_jass_api "EX*" extended
// natives (see YDWE_EX_Natives.j / YDWE-EX-Natives-Reference.md).
//
// NOTE ON CONSTANTS: an earlier version of this file referenced the ability/
// item/buff "data type" and "state type" selector values by their symbolic
// names (e.g. ABILITY_DATA_ART), assuming a map using these EX* natives would
// also carry YDWE_EX_Natives.j's constant block. In practice, YDWE's Trigger
// Editor only auto-inserts the bare `native` declarations a GUI action needs
// and generates calls with the raw numeric literal already inlined (e.g.
// `EXGetAbilityDataString(a, 1, 204)`), not the symbolic constant name - so
// that constants block is often simply absent from the map, causing an
// "Undeclared variable" error (and a cascading "different primitive types"
// error once the parser can't resolve the comparison's type). Every data_type/
// state_type value below is therefore a raw integer literal with the
// constant's name in a trailing comment for readability, matching what
// YDWE_EX_Natives.j itself defines them as - nothing here depends on the map
// declaring anything beyond the bare `native EX...` lines.
//
// RESEARCH NOTE: unlike the Dz batches, there is no runtime yd_jass_api plugin
// to fall back on - every function below is either a genuine Reforged
// (Blz-prefixed) native doing the same job, or an honest approximation. Where
// no real technique exists at all, the function is local bookkeeping only
// (matches whatever was last Set, has zero effect on the actual game) rather
// than a guess - see STATUS KEY.
//
// STATUS KEY:
//   [REAL]         - a genuine Reforged native does exactly this
//   [REAL, via X]  - genuine Reforged natives combined with a well-established
//                    community technique (dummy instance, turn-speed trick, etc.)
//   [APPROX]       - real natives used, but semantics differ from the original
//                    EX native in a documented way
//   [PORT LIMITATION] - no working technique found; local bookkeeping only, so
//                    reads-after-writes stay internally consistent but there is
//                    no actual in-game effect
//   [UNVERIFIED]   - plausible field/native name, not confirmed against a real
//                    build - check your World Editor's GUI field dropdowns or
//                    a jassdoc mirror before shipping
// ============================================================================

    globals
        // ability handle (from EXGetUnitAbility / EXGetUnitAbilityByIndex) -> the
        // unit it came from. Needed because EXGetAbilityState/EXSetAbilityState
        // only get an `ability`, but the real per-unit cooldown natives need the
        // owning unit too.
        hashtable gYDWEEXOwner = InitHashtable()
        // catch-all local bookkeeping table for every [PORT LIMITATION] / partial
        // fallback case below (effect rotation/scale accumulators, ability Data
        // A-I, unit-type field stand-ins, move-type storage, etc.). Parent/child
        // key schemes are chosen per-feature and are documented at each use site;
        // they don't need to be globally unique, just unique enough in practice.
        hashtable gYDWEEXLocal = InitHashtable()
        // persistent per-itemcode work-item cache (see YDWEEX_GetCachedWorkItem)
        // - kept separate from gYDWEEXOwner/gYDWEEXLocal because it deliberately
        // uses a fixed parent key with itemcode as the child key, and mixing a
        // fixed parent with those tables' dynamic GetHandleId()-based parents
        // used elsewhere risks an accidental collision.
        hashtable gYDWEEXItemCache = InitHashtable()
    endglobals

    // ---- internal helper: remember which unit an ability handle came from ------
    function YDWEEX_CacheAbilityOwner takes ability a, unit owner returns nothing
        if a == null then
            return
        endif
        call SaveUnitHandle(gYDWEEXOwner, GetHandleId(a), 0, owner)
    endfunction

    function YDWEEX_GetAbilityOwner takes ability a returns unit
        if a == null then
            return null
        endif
        if not HaveSavedHandle(gYDWEEXOwner, GetHandleId(a), 0) then
            return null
        endif
        return LoadUnitHandle(gYDWEEXOwner, GetHandleId(a), 0)
    endfunction

    // ---- internal helper: ability string data, shared by the by-handle and ----
    // by-raw-code natives, since Reforged's runtime-tooltip/icon natives are
    // themselves keyed by raw ability code, not by ability instance.
    // [REAL] NAME/ART/TIP/UBERTIP/RESEARCH_TIP/RESEARCH_UBERTIP.
    // [REAL, reasoned mapping] UNTIP/UNUBERTIP/UNART - mapped to Blizzard's
    // "Activated" tooltip/icon natives. Not directly confirmed by name, but
    // well-grounded: common.j's own doc describes these as "for abilities such
    // as defend which have an 'active' state", which is exactly the toggle-
    // ability concept (Defend/Patrol-style) that WC3's Object Editor exposes as
    // a separate "Un-" prefixed field set (shown once the ability is toggled
    // on, offering to turn it back off) - both independent naming schemes
    // point to the same thing. Verify in-game with a toggle ability if you
    // depend on this; if it turns out backwards, swap UNTIP/UNUBERTIP/UNART to
    // use the base Tooltip/ExtendedTooltip/Icon natives instead and vice versa.
    // [PORT LIMITATION] everything else (hotkeys, the per-slot art fields,
    // lightning effect) - no by-id native found for these.
    // [UNVERIFIED] level indexing: EX docs say level is 1-based; whether these
    // particular Blz natives expect 0- or 1-based level was not confirmed during
    // research - verify in-game and adjust by +/-1 here if tooltips land on the
    // wrong level.
    function YDWEEX_GetAbilityStringByCode takes integer abilcode, integer level, integer data_type returns string
        if data_type == 203 then //ABILITY_DATA_NAME
            return GetObjectName(abilcode)
        elseif data_type == 204 then //ABILITY_DATA_ART
            return BlzGetAbilityIcon(abilcode)
        elseif data_type == 215 then //ABILITY_DATA_TIP
            return BlzGetAbilityTooltip(abilcode, level)
        elseif data_type == 218 then //ABILITY_DATA_UBERTIP
            return BlzGetAbilityExtendedTooltip(abilcode, level)
        elseif data_type == 214 then //ABILITY_DATA_RESEARCH_TIP
            return BlzGetAbilityResearchTooltip(abilcode, level)
        elseif data_type == 217 then //ABILITY_DATA_RESEARCH_UBERTIP
            return BlzGetAbilityResearchExtendedTooltip(abilcode, level)
		elseif data_type == 216 then //ABILITY_DATA_UNTIP
            return BlzGetAbilityActivatedTooltip(abilcode, level)
        elseif data_type == 219 then //ABILITY_DATA_UNUBERTIP
            return BlzGetAbilityActivatedExtendedTooltip(abilcode, level)
        elseif data_type == 220 then //ABILITY_DATA_UNART
            return BlzGetAbilityActivatedIcon(abilcode)
        endif
        return LoadStr(gYDWEEXLocal, abilcode, data_type * 100 + level)
    endfunction

    function YDWEEX_SetAbilityStringByCode takes integer abilcode, integer level, integer data_type, string value returns boolean
        if data_type == 204 then //ABILITY_DATA_ART
            call BlzSetAbilityIcon(abilcode, value)
            return true
        elseif data_type == 215 then //ABILITY_DATA_TIP
            call BlzSetAbilityTooltip(abilcode, value, level)
            return true
        elseif data_type == 218 then //ABILITY_DATA_UBERTIP
            call BlzSetAbilityExtendedTooltip(abilcode, value, level)
            return true
        elseif data_type == 214 then //ABILITY_DATA_RESEARCH_TIP
            call BlzSetAbilityResearchTooltip(abilcode, value, level)
            return true
        elseif data_type == 217 then //ABILITY_DATA_RESEARCH_UBERTIP
            call BlzSetAbilityResearchExtendedTooltip(abilcode, value, level)
            return true
		elseif data_type == 216 then //ABILITY_DATA_UNTIP
            call BlzSetAbilityActivatedTooltip(abilcode, value, level)
            return true
        elseif data_type == 219 then //ABILITY_DATA_UNUBERTIP
            call BlzSetAbilityActivatedExtendedTooltip(abilcode, value, level)
            return true
        elseif data_type == 220 then //ABILITY_DATA_UNART
            call BlzSetAbilityActivatedIcon(abilcode, value)
            return true
        endif
        // NAME has no confirmed runtime setter either - local bookkeeping only.
        call SaveStr(gYDWEEXLocal, abilcode, data_type * 100 + level, value)
        return true
    endfunction

    // ============================================================================
    // Ability lookup
    // ============================================================================

    // ---- [REAL] --------------------------------------------------------------
    function EXGetUnitAbility takes unit u, integer abilcode returns ability
        local ability a = BlzGetUnitAbility(u, abilcode)
        call YDWEEX_CacheAbilityOwner(a, u)
        return a
    endfunction

    function EXGetUnitAbilityByIndex takes unit u, integer index returns ability
        local ability a = BlzGetUnitAbilityByIndex(u, index)
        call YDWEEX_CacheAbilityOwner(a, u)
        return a
    endfunction

    function EXGetAbilityId takes ability abil returns integer
        return BlzGetAbilityId(abil)
    endfunction

    // ============================================================================
    // Ability state (cooldown)
    // ============================================================================

    // ---- [REAL, via owner cache] ----------------------------------------------
    // BlzGetUnitAbilityCooldownRemaining/BlzStartUnitAbilityCooldown/
    // BlzEndUnitAbilityCooldown need (unit, abilcode), not an `ability` handle -
    // the owner cache above bridges that gap. Only works for abilities that were
    // actually obtained through EXGetUnitAbility/EXGetUnitAbilityByIndex in this
    // same game session (matches the reference doc's own warning that these
    // handles are internal pool references, not portable across long gaps).
    function EXGetAbilityState takes ability abil, integer state_type returns real
        local unit owner
        if state_type != 1 then //ABILITY_STATE_COOLDOWN
            return 0.00
        endif
        set owner = YDWEEX_GetAbilityOwner(abil)
        if owner == null then
            return 0.00
        endif
        return BlzGetUnitAbilityCooldownRemaining(owner, BlzGetAbilityId(abil))
    endfunction

    function EXSetAbilityState takes ability abil, integer state_type, real value returns boolean
        local unit owner
        local integer abilcode
        if state_type != 1 then //ABILITY_STATE_COOLDOWN
            return false
        endif
        set owner = YDWEEX_GetAbilityOwner(abil)
        if owner == null then
            return false
        endif
        set abilcode = BlzGetAbilityId(abil)
        if value <= 0.00 then
            call BlzEndUnitAbilityCooldown(owner, abilcode)
        else
            call BlzStartUnitAbilityCooldown(owner, abilcode, value)
        endif
        return true
    endfunction

    // ============================================================================
    // Ability level data - Real / Integer / String
    // ============================================================================

    // ---- [REAL] DUR/HERODUR/COOL/AREA/RNG, reusing the same field constants
    // already verified in DzCompat_AbilityField.j for the equivalent Dz natives.
    // [PORT LIMITATION] CAST (no generic cast-time field) and DATA_A..I (no confirmed
    // generic "Data A..I" level-field names in Reforged) - bookkeeping only.
    function EXGetAbilityDataReal takes ability abil, integer level, integer data_type returns real
        local integer idx = level - 1
        if idx < 0 then
            set idx = 0
        endif
        if data_type == 102 then //ABILITY_DATA_DUR
            return BlzGetAbilityRealLevelField(abil, ABILITY_RLF_DURATION_NORMAL, idx)
        elseif data_type == 103 then //ABILITY_DATA_HERODUR
            return BlzGetAbilityRealLevelField(abil, ABILITY_RLF_DURATION_HERO, idx)
        elseif data_type == 105 then //ABILITY_DATA_COOL
            return BlzGetAbilityRealLevelField(abil, ABILITY_RLF_COOLDOWN, idx)
        elseif data_type == 106 then //ABILITY_DATA_AREA
            return BlzGetAbilityRealLevelField(abil, ABILITY_RLF_AREA_OF_EFFECT, idx)
        elseif data_type == 107 then //ABILITY_DATA_RNG
            return BlzGetAbilityRealLevelField(abil, ABILITY_RLF_CAST_RANGE, idx)
        endif
        return LoadReal(gYDWEEXLocal, GetHandleId(abil), data_type * 100 + level)
    endfunction

    function EXSetAbilityDataReal takes ability abil, integer level, integer data_type, real value returns boolean
        local integer idx = level - 1
        if idx < 0 then
            set idx = 0
        endif
        if data_type == 102 then //ABILITY_DATA_DUR
            return BlzSetAbilityRealLevelField(abil, ABILITY_RLF_DURATION_NORMAL, idx, value)
        elseif data_type == 103 then //ABILITY_DATA_HERODUR
            return BlzSetAbilityRealLevelField(abil, ABILITY_RLF_DURATION_HERO, idx, value)
        elseif data_type == 105 then //ABILITY_DATA_COOL
            return BlzSetAbilityRealLevelField(abil, ABILITY_RLF_COOLDOWN, idx, value)
        elseif data_type == 106 then //ABILITY_DATA_AREA
            return BlzSetAbilityRealLevelField(abil, ABILITY_RLF_AREA_OF_EFFECT, idx, value)
        elseif data_type == 107 then //ABILITY_DATA_RNG
            return BlzSetAbilityRealLevelField(abil, ABILITY_RLF_CAST_RANGE, idx, value)
        endif
        call SaveReal(gYDWEEXLocal, GetHandleId(abil), data_type * 100 + level, value)
        return true
    endfunction

    // ---- [REAL] COST (mana cost). [PORT LIMITATION] TARGS/UNITID -----------------
    function EXGetAbilityDataInteger takes ability abil, integer level, integer data_type returns integer
        local integer idx = level - 1
        if idx < 0 then
            set idx = 0
        endif
        if data_type == 104 then //ABILITY_DATA_COST
            return BlzGetAbilityIntegerLevelField(abil, ABILITY_ILF_MANA_COST, idx)
        endif
        return LoadInteger(gYDWEEXLocal, GetHandleId(abil), data_type * 100 + level)
    endfunction

    function EXSetAbilityDataInteger takes ability abil, integer level, integer data_type, integer value returns boolean
        local integer idx = level - 1
        if idx < 0 then
            set idx = 0
        endif
        if data_type == 104 then //ABILITY_DATA_COST
            return BlzSetAbilityIntegerLevelField(abil, ABILITY_ILF_MANA_COST, idx, value)
        endif
        call SaveInteger(gYDWEEXLocal, GetHandleId(abil), data_type * 100 + level, value)
        return true
    endfunction

    // ---- see YDWEEX_Get/SetAbilityStringByCode above for status per field -----
    function EXGetAbilityDataString takes ability abil, integer level, integer data_type returns string
        return YDWEEX_GetAbilityStringByCode(BlzGetAbilityId(abil), level, data_type)
    endfunction

    function EXSetAbilityDataString takes ability abil, integer level, integer data_type, string value returns boolean
        return YDWEEX_SetAbilityStringByCode(BlzGetAbilityId(abil), level, data_type, value)
    endfunction

    // ============================================================================
    // Ability string by id (no unit/instance required)
    // ============================================================================

    // ---- see YDWEEX_Get/SetAbilityStringByCode above for status per field -----
    function EXGetAbilityString takes integer abilcode, integer level, integer data_type returns string
        return YDWEEX_GetAbilityStringByCode(abilcode, level, data_type)
    endfunction

    function EXSetAbilityString takes integer abilcode, integer level, integer data_type, string value returns boolean
        return YDWEEX_SetAbilityStringByCode(abilcode, level, data_type, value)
    endfunction

    // ============================================================================
    // Metamorphosis helper
    // ============================================================================

    // ---- [PORT LIMITATION] no confirmed field controls a Metamorphosis-style
    // ability's target unit id at runtime in Reforged. Bookkeeping only - this
    // will NOT actually change what a unit transforms into.
    function EXSetAbilityAEmeDataA takes ability abil, integer unitid returns boolean
        call SaveInteger(gYDWEEXLocal, GetHandleId(abil), 555001, unitid)
        return true
    endfunction

    // ============================================================================
    // Buff natives
    // ============================================================================

    // ---- [APPROX] buffs share the same rawcode-keyed object data as abilities,
    // and BlzGetAbilityTooltip's own doc says it "Supports Unit/Item/Ability/Tech
    // Codes" - reusing the same by-id natives on a buff code. Not confirmed
    // against a real buff id; test before shipping.
    function EXGetBuffDataString takes integer buffcode, integer data_type returns string
        if data_type == 1 then //BUFF_DATA_ART
            return BlzGetAbilityIcon(buffcode)
        elseif data_type == 2 then //BUFF_DATA_TIP
            return BlzGetAbilityTooltip(buffcode, 0)
        elseif data_type == 3 then //BUFF_DATA_UBERTIP
            return BlzGetAbilityExtendedTooltip(buffcode, 0)
        endif
        return ""
    endfunction

    function EXSetBuffDataString takes integer buffcode, integer data_type, string value returns boolean
        if data_type == 1 then //BUFF_DATA_ART
            call BlzSetAbilityIcon(buffcode, value)
            return true
        elseif data_type == 2 then //BUFF_DATA_TIP
            call BlzSetAbilityTooltip(buffcode, value, 0)
            return true
        elseif data_type == 3 then //BUFF_DATA_UBERTIP
            call BlzSetAbilityExtendedTooltip(buffcode, value, 0)
            return true
        endif
        return false
    endfunction

    // ============================================================================
    // Effect natives
    // ============================================================================

    // ---- [REAL] position/size/timescale - direct Blz equivalents --------------
    function EXGetEffectX takes effect e returns real
        // [APPROX] Blizzard restricts effect-position getters to LOCAL-only (each
        // client can read a different answer; never sync gameplay logic on it).
        // That's a real engine restriction, not a shim limitation.
        return BlzGetLocalSpecialEffectX(e)
    endfunction

    function EXGetEffectY takes effect e returns real
        return BlzGetLocalSpecialEffectY(e)
    endfunction

    function EXGetEffectZ takes effect e returns real
        return BlzGetLocalSpecialEffectZ(e)
    endfunction

    function EXSetEffectXY takes effect e, real x, real y returns nothing
        call BlzSetSpecialEffectX(e, x)
        call BlzSetSpecialEffectY(e, y)
    endfunction

    function EXSetEffectZ takes effect e, real z returns nothing
        call BlzSetSpecialEffectZ(e, z)
    endfunction

    // ---- [REAL set / APPROX get] no Blz getter for uniform scale exists, so the
    // getter just returns whatever was last Set here (default 1.0, matching the
    // real native's own documented default).
    function EXGetEffectSize takes effect e returns real
        if HaveSavedReal(gYDWEEXLocal, GetHandleId(e), 900001) then
            return LoadReal(gYDWEEXLocal, GetHandleId(e), 900001)
        endif
        return 1.00
    endfunction

    function EXSetEffectSize takes effect e, real size returns nothing
        call BlzSetSpecialEffectScale(e, size)
        call SaveReal(gYDWEEXLocal, GetHandleId(e), 900001, size)
    endfunction

    // ---- [REAL, via accumulator] Blz's Yaw/Pitch/Roll setters are absolute, but
    // EX's Mat* rotations are documented as cumulative (matrix multiply) - an
    // accumulator per effect reproduces that. Axis mapping (Z=yaw, X=pitch,
    // Y=roll) is taken directly from YDWE_EX_Natives.j's own EXEffectSetOrientation
    // wrapper, not guessed.
    function EXEffectMatRotateX takes effect e, real angle returns nothing
        local real cur = 0.00
        if HaveSavedReal(gYDWEEXLocal, GetHandleId(e), 900002) then
            set cur = LoadReal(gYDWEEXLocal, GetHandleId(e), 900002)
        endif
        set cur = cur + angle
        call SaveReal(gYDWEEXLocal, GetHandleId(e), 900002, cur)
        call BlzSetSpecialEffectPitch(e, cur * bj_DEGTORAD)
    endfunction

    function EXEffectMatRotateY takes effect e, real angle returns nothing
        local real cur = 0.00
        if HaveSavedReal(gYDWEEXLocal, GetHandleId(e), 900003) then
            set cur = LoadReal(gYDWEEXLocal, GetHandleId(e), 900003)
        endif
        set cur = cur + angle
        call SaveReal(gYDWEEXLocal, GetHandleId(e), 900003, cur)
        call BlzSetSpecialEffectRoll(e, cur * bj_DEGTORAD)
    endfunction

    function EXEffectMatRotateZ takes effect e, real angle returns nothing
        local real cur = 0.00
        if HaveSavedReal(gYDWEEXLocal, GetHandleId(e), 900004) then
            set cur = LoadReal(gYDWEEXLocal, GetHandleId(e), 900004)
        endif
        set cur = cur + angle
        call SaveReal(gYDWEEXLocal, GetHandleId(e), 900004, cur)
        call BlzSetSpecialEffectYaw(e, cur * bj_DEGTORAD)
    endfunction

    // ---- [APPROX] BlzSetSpecialEffectMatrixScale is a genuine non-uniform-scale
    // native (confirmed real), but it SETS the matrix rather than multiplying it -
    // EX's version is documented cumulative. Call EXEffectMatReset first if you
    // need a clean absolute scale rather than a running multiply.
    function EXEffectMatScale takes effect e, real x, real y, real z returns nothing
        call BlzSetSpecialEffectMatrixScale(e, x, y, z)
    endfunction

    function EXEffectMatReset takes effect e returns nothing
        call SaveReal(gYDWEEXLocal, GetHandleId(e), 900002, 0.00)
        call SaveReal(gYDWEEXLocal, GetHandleId(e), 900003, 0.00)
        call SaveReal(gYDWEEXLocal, GetHandleId(e), 900004, 0.00)
        call BlzSetSpecialEffectOrientation(e, 0.00, 0.00, 0.00)
        call BlzSetSpecialEffectMatrixScale(e, 1.00, 1.00, 1.00)
    endfunction

    function EXSetEffectSpeed takes effect e, real speed returns nothing
        call BlzSetSpecialEffectTimeScale(e, speed)
    endfunction

    // ============================================================================
    // Item natives
    // ============================================================================

    // ---- internal helper: a persistent, invisible item instance per item type,
    // reused (not recreated) so that a Set followed by a Get for the same
    // itemcode actually observes the change - reads/writes on Reforged's Blz
    // item field natives are instance-scoped, so a throwaway created-then-
    // destroyed instance would make any Set evaporate immediately. This
    // instance is intentionally never removed - it lives for the rest of the
    // game as a small, hidden bookkeeping object per distinct itemcode queried.
    function YDWEEX_GetCachedWorkItem takes integer itemcode returns item
        local item it
        if HaveSavedHandle(gYDWEEXItemCache, 1, itemcode) then
            return LoadItemHandle(gYDWEEXItemCache, 1, itemcode)
        endif
        set it = CreateItem(itemcode, 0, 0)
        call SetItemVisible(it, false)
        call SaveItemHandle(gYDWEEXItemCache, 1, itemcode, it)
        return it
    endfunction

    // ---- [REAL] NAME via GetObjectName (no instance needed). [REAL] TIP/
    // UBERTIP/ART/DESCRIPTION via genuine dedicated Blz natives (an earlier
    // pass guessed wrong generic itemstringfield constant names for these and
    // got "Undeclared variable" - verified this time against jassdoc's actual
    // common.j: BlzGet/SetItemTooltip, BlzGet/SetItemExtendedTooltip,
    // BlzGet/SetItemIconPath, BlzGet/SetItemDescription all genuinely exist).
    // [NOT PORTABLE, setter only] NAME/TIP: common.j's own doc marks
    // BlzSetItemName and BlzSetItemTooltip with "@bug Doesn't work" - so
    // those two setters fall back to local bookkeeping (the getters are still
    // real and used normally).
    // [APPROX, all setters] even where the native setter genuinely works
    // (DESCRIPTION/UBERTIP/ART), it only edits OUR cached instance above, not
    // the item TYPE template - EX's real semantics are type-wide (every
    // instance of that item id reflects the change), and Reforged's Blz item
    // field natives are instance-scoped, so a NEW item of that type created
    // elsewhere on the map afterward will NOT show the change. Reads/writes
    // through these EX natives for the same itemcode stay consistent with
    // each other, which is the most that's achievable here.
    function EXGetItemDataString takes integer itemcode, integer data_type returns string
        local item it
        if data_type == 4 then //ITEM_DATA_NAME
            return GetObjectName(itemcode)
        endif
        set it = YDWEEX_GetCachedWorkItem(itemcode)
        if data_type == 5 then //ITEM_DATA_DESCRIPTION
            return BlzGetItemDescription(it)
        elseif data_type == 2 then //ITEM_DATA_TIP
            return BlzGetItemTooltip(it)
        elseif data_type == 3 then //ITEM_DATA_UBERTIP
            return BlzGetItemExtendedTooltip(it)
        elseif data_type == 1 then //ITEM_DATA_ART
            return BlzGetItemIconPath(it)
        endif
        return ""
    endfunction

    function EXSetItemDataString takes integer itemcode, integer data_type, string value returns boolean
        local item it
        if data_type == 5 then //ITEM_DATA_DESCRIPTION
            set it = YDWEEX_GetCachedWorkItem(itemcode)
            call BlzSetItemDescription(it, value)
            return true
        elseif data_type == 3 then //ITEM_DATA_UBERTIP
            set it = YDWEEX_GetCachedWorkItem(itemcode)
            call BlzSetItemExtendedTooltip(it, value)
            return true
        elseif data_type == 1 then //ITEM_DATA_ART
            set it = YDWEEX_GetCachedWorkItem(itemcode)
            call BlzSetItemIconPath(it, value)
            return true
        endif
        // NAME/TIP - confirmed-broken native setters (see comment above),
        // local bookkeeping only.
        call SaveStr(gYDWEEXLocal, itemcode, data_type, value)
        return true
    endfunction

    // ============================================================================
    // Event Damage natives
    // ============================================================================

    // ---- internal helpers: attacktype/damagetype/weapontype are handle types
    // with no reverse-conversion native, so map each back to the SAME raw
    // internal id Blizzard's own ConvertAttackType/ConvertDamageType/
    // ConvertWeaponType constants use (confirmed via jassdoc's common.j) -
    // these are not an invented enumeration, they're the engine's actual ids.
    function YDWEEX_AttackTypeToInt takes attacktype t returns integer
        if t == ATTACK_TYPE_NORMAL then
            return 0
        elseif t == ATTACK_TYPE_MELEE then
            return 1
        elseif t == ATTACK_TYPE_PIERCE then
            return 2
        elseif t == ATTACK_TYPE_SIEGE then
            return 3
        elseif t == ATTACK_TYPE_MAGIC then
            return 4
        elseif t == ATTACK_TYPE_CHAOS then
            return 5
        elseif t == ATTACK_TYPE_HERO then
            return 6
        endif
        return -1
    endfunction

    function YDWEEX_DamageTypeToInt takes damagetype t returns integer
        if t == DAMAGE_TYPE_UNKNOWN then
            return 0
        elseif t == DAMAGE_TYPE_NORMAL then
            return 4
        elseif t == DAMAGE_TYPE_ENHANCED then
            return 5
        elseif t == DAMAGE_TYPE_FIRE then
            return 8
        elseif t == DAMAGE_TYPE_COLD then
            return 9
        elseif t == DAMAGE_TYPE_LIGHTNING then
            return 10
        elseif t == DAMAGE_TYPE_POISON then
            return 11
        elseif t == DAMAGE_TYPE_DISEASE then
            return 12
        elseif t == DAMAGE_TYPE_DIVINE then
            return 13
        elseif t == DAMAGE_TYPE_MAGIC then
            return 14
        elseif t == DAMAGE_TYPE_SONIC then
            return 15
        elseif t == DAMAGE_TYPE_ACID then
            return 16
        elseif t == DAMAGE_TYPE_FORCE then
            return 17
        elseif t == DAMAGE_TYPE_DEATH then
            return 18
        elseif t == DAMAGE_TYPE_MIND then
            return 19
        elseif t == DAMAGE_TYPE_PLANT then
            return 20
        elseif t == DAMAGE_TYPE_DEFENSIVE then
            return 21
        elseif t == DAMAGE_TYPE_DEMOLITION then
            return 22
        elseif t == DAMAGE_TYPE_SLOW_POISON then
            return 23
        elseif t == DAMAGE_TYPE_SPIRIT_LINK then
            return 24
        elseif t == DAMAGE_TYPE_SHADOW_STRIKE then
            return 25
        elseif t == DAMAGE_TYPE_UNIVERSAL then
            return 26
        endif
        return -1
    endfunction

    function YDWEEX_WeaponTypeToInt takes weapontype t returns integer
        if t == WEAPON_TYPE_WHOKNOWS then
            return 0
        elseif t == WEAPON_TYPE_METAL_LIGHT_CHOP then
            return 1
        elseif t == WEAPON_TYPE_METAL_MEDIUM_CHOP then
            return 2
        elseif t == WEAPON_TYPE_METAL_HEAVY_CHOP then
            return 3
        elseif t == WEAPON_TYPE_METAL_LIGHT_SLICE then
            return 4
        elseif t == WEAPON_TYPE_METAL_MEDIUM_SLICE then
            return 5
        elseif t == WEAPON_TYPE_METAL_HEAVY_SLICE then
            return 6
        elseif t == WEAPON_TYPE_METAL_MEDIUM_BASH then
            return 7
        elseif t == WEAPON_TYPE_METAL_HEAVY_BASH then
            return 8
        elseif t == WEAPON_TYPE_METAL_MEDIUM_STAB then
            return 9
        elseif t == WEAPON_TYPE_METAL_HEAVY_STAB then
            return 10
        elseif t == WEAPON_TYPE_WOOD_LIGHT_SLICE then
            return 11
        elseif t == WEAPON_TYPE_WOOD_MEDIUM_SLICE then
            return 12
        elseif t == WEAPON_TYPE_WOOD_HEAVY_SLICE then
            return 13
        elseif t == WEAPON_TYPE_WOOD_LIGHT_BASH then
            return 14
        elseif t == WEAPON_TYPE_WOOD_MEDIUM_BASH then
            return 15
        elseif t == WEAPON_TYPE_WOOD_HEAVY_BASH then
            return 16
        elseif t == WEAPON_TYPE_WOOD_LIGHT_STAB then
            return 17
        elseif t == WEAPON_TYPE_WOOD_MEDIUM_STAB then
            return 18
        elseif t == WEAPON_TYPE_CLAW_LIGHT_SLICE then
            return 19
        elseif t == WEAPON_TYPE_CLAW_MEDIUM_SLICE then
            return 20
        elseif t == WEAPON_TYPE_CLAW_HEAVY_SLICE then
            return 21
        elseif t == WEAPON_TYPE_AXE_MEDIUM_CHOP then
            return 22
        elseif t == WEAPON_TYPE_ROCK_HEAVY_BASH then
            return 23
        endif
        return -1
    endfunction

    // ---- [REAL] IS_ATTACK/DAMAGE_TYPE/WEAPON_TYPE/ATTACK_TYPE all use genuine
    // Reforged natives (BlzGetEventIsAttack/DamageType/WeaponType/AttackType -
    // verified against jassdoc's common.j). Only valid inside
    // EVENT_UNIT_DAMAGED / EVENT_PLAYER_UNIT_DAMAGED, same as the original EX
    // native.
    // [APPROX] PHYSICAL: maps DAMAGE_TYPE_NORMAL (engine id 4) to "physical",
    // matching the common JAPI / port convention that treats the stock attack
    // damage type as physical and everything else as spell/special. This is
    // more faithful than reusing BlzGetEventIsAttack (which answers a different
    // question and collapsed PHYSICAL into IS_ATTACK).
    // [APPROX] VALID: Reforged has no "is a damage event currently on the
    // stack" flag. Returning 1 matches the working assumption of every caller
    // (they only invoke this inside a damage handler) and the behaviour of
    // this native.
    // [APPROX] IS_RANGED: Reforged does not expose the event's ranged flag.
    // Approximate as "this is an attack AND the source unit is typed as a
    // ranged attacker". Wrong for melee units dealing triggered ranged-style
    // damage and for ranged units dealing pure spell damage, but it is the
    // best signal available without map-specific knowledge.
    function EXGetEventDamageData takes integer edd_type returns integer
        if edd_type == 0 then //EVENT_DAMAGE_DATA_VAILD
            return 1
        elseif edd_type == 1 then //EVENT_DAMAGE_DATA_PHYSICAL
            if BlzGetEventDamageType() == DAMAGE_TYPE_NORMAL then
                return 1
            endif
            return 0
        elseif edd_type == 2 then //EVENT_DAMAGE_DATA_IS_ATTACK
            if BlzGetEventIsAttack() then
                return 1
            endif
            return 0
        elseif edd_type == 3 then //EVENT_DAMAGE_DATA_IS_RANGED
            if BlzGetEventIsAttack() and IsUnitType(GetEventDamageSource(), UNIT_TYPE_RANGED_ATTACKER) then
                return 1
            endif
            return 0
        elseif edd_type == 4 then //EVENT_DAMAGE_DATA_DAMAGE_TYPE
            return YDWEEX_DamageTypeToInt(BlzGetEventDamageType())
        elseif edd_type == 5 then //EVENT_DAMAGE_DATA_WEAPON_TYPE
            return YDWEEX_WeaponTypeToInt(BlzGetEventWeaponType())
        elseif edd_type == 6 then //EVENT_DAMAGE_DATA_ATTACK_TYPE
            return YDWEEX_AttackTypeToInt(BlzGetEventAttackType())
        endif
        return 0
    endfunction

    // ---- [REAL] confirmed real, works inside EVENT_UNIT_DAMAGED / ------------
    // EVENT_PLAYER_UNIT_DAMAGED just like the original.
    function EXSetEventDamage takes real amount returns boolean
        call BlzSetEventDamage(amount)
        return true
    endfunction

    // ============================================================================
    // Unit natives
    // ============================================================================

    // ---- [APPROX, via turn-speed trick] Reforged has no native that snaps
    // facing while bypassing turn rate. Standard community technique: max out
    // turn speed, snap the facing, restore the old turn speed - converges within
    // about one game update, which reads as instant even though it is not a
    // single atomic native call the way the original EX native was.
    function EXSetUnitFacing takes unit u, real angle returns nothing
        local real oldTurn = GetUnitTurnSpeed(u)
        call SetUnitTurnSpeed(u, 999.00)
        call SetUnitFacing(u, angle)
        call SetUnitTurnSpeed(u, oldTurn)
    endfunction

    // ---- [REAL] BlzPauseUnitEx pauses a unit without the shift-order-queue-loss
    // and buff-suspension side effects of stock PauseUnit - matches the original
    // EX native's stated purpose exactly.
    function EXPauseUnit takes unit u, boolean flag returns nothing
        call BlzPauseUnitEx(u, flag)
    endfunction

    // ---- [APPROX] the original's per-bit collision toggle `(1 << t)` has no
    // confirmed granular Reforged equivalent - falls back to the stock
    // SetUnitPathing, which toggles ALL pathing collision on/off and ignores
    // which specific bit `t` was requested.
    function EXSetUnitCollisionType takes boolean enable, unit u, integer t returns nothing
        call SetUnitPathing(u, enable)
    endfunction

    // ---- [PORT LIMITATION] no known runtime technique changes a unit's
    // movement/pathing type (ground/air/amphibious/etc.) in Reforged short of
    // abilities like Crow Form. Bookkeeping only - has no in-game effect.
    function EXSetUnitMoveType takes unit u, integer t returns nothing
        call SaveInteger(gYDWEEXLocal, GetHandleId(u), 900101, t)
    endfunction

    // ============================================================================
    // Unit-type data (by unitcode, not instance)
    // ============================================================================

    // ---- [PORT LIMITATION] the reference doc, unlike its ability/item/buff
    // sections, does not define what the numeric `data_type` codes mean for
    // these four natives - there is nothing to safely map them onto, so this is
    // pure local bookkeeping (read back exactly what was last written, matching
    // no numeric scheme in particular). Wire real field mappings in here once
    // you have YDWE's actual unit-data constant list for these natives.
    function EXGetUnitString takes integer unitcode, integer data_type returns string
        return LoadStr(gYDWEEXLocal, unitcode, data_type)
    endfunction

    function EXSetUnitString takes integer unitcode, integer data_type, string value returns boolean
        call SaveStr(gYDWEEXLocal, unitcode, data_type, value)
        return true
    endfunction

    function EXGetUnitReal takes integer unitcode, integer data_type returns real
        return LoadReal(gYDWEEXLocal, unitcode, data_type)
    endfunction

    function EXSetUnitReal takes integer unitcode, integer data_type, real value returns boolean
        call SaveReal(gYDWEEXLocal, unitcode, data_type, value)
        return true
    endfunction

    function EXGetUnitInteger takes integer unitcode, integer data_type returns integer
        return LoadInteger(gYDWEEXLocal, unitcode, data_type)
    endfunction

    function EXSetUnitInteger takes integer unitcode, integer data_type, integer value returns boolean
        call SaveInteger(gYDWEEXLocal, unitcode, data_type, value)
        return true
    endfunction

    function EXGetUnitArrayString takes integer unitcode, integer data_type, integer index returns string
        return LoadStr(gYDWEEXLocal, unitcode, data_type * 100000 + index)
    endfunction

    function EXSetUnitArrayString takes integer unitcode, integer data_type, integer index, string value returns boolean
        call SaveStr(gYDWEEXLocal, unitcode, data_type * 100000 + index, value)
        return true
    endfunction

    // ============================================================================
    // Chat native
    // ============================================================================

    // ---- [APPROX] Manually-prefixed timed text player message simulation shown
    // to every currently-playing player; this is NOT routed through real chat/ally/
    // observer filtering, so chat_recipient's original meaning is not honored.
    function EXDisplayChat takes player p, integer chat_recipient, string message returns nothing
        local string line = "|cffffcc00" + GetPlayerName(p) + ":|r " + message
        local integer i = 0
        loop
            exitwhen i >= bj_MAX_PLAYERS
            if GetPlayerSlotState(Player(i)) == PLAYER_SLOT_STATE_PLAYING then
                call DisplayTimedTextToPlayer(Player(i), 0, 0, 10.00, line)
            endif
            set i = i + 1
        endloop
    endfunction
