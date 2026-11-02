// ============================================================================
// DzCompat_Morph.j
// DzSetUnitID: a real change of the unit's type that keeps its abilities.
//
// The KK native changes the type id of the unit. Reforged has no native for that; the
// stock way is a Chaos ability (code 'Acha') whose "Data - Unit Type" is the target.
// The converter writes one such ability per target id the script can pass to DzSetUnitID
// (UnitTypeMorphRegistry -> ability_patched.ini, imported into the map by hand) and bakes
// target -> ability into DzCompat_MorphChaosPut calls. A target without an ability (no map
// table folder, or an id the script analysis cannot see) falls back to the skin change.
//
// Adding the Chaos ability does not change the type at once: the unit changes on the
// next game tick, so the unit is watched until it has the new type, its abilities,
// life, mana, invulnerability and pause state are put back, and the Chaos ability goes.
// ============================================================================

globals
    // Parent key 0: target unit type id (child key) -> its Chaos ability id.
    // Parent key = a morphing unit's handle id: its state, see the DZCOMPAT_MORPH_* keys.
    hashtable gDzCompatMorph = InitHashtable()
    unit      array gDzCompatMorphUnit
    integer   gDzCompatMorphCount = 0
    timer     gDzCompatMorphTick = CreateTimer()
    timer     gDzCompatMorphStart = CreateTimer()
    // True while DzSetUnitID runs: every ability the unit has is kept, not only the ones it
    // gained since the call
    boolean   gDzCompatMorphKeepAll = false
    // Units that morph at the same time; one more is changed by skin only
    constant integer DZCOMPAT_MORPH_MAX = 32
    // Abilities kept per unit
    constant integer DZCOMPAT_MORPH_SLOTS = 120
    // Seconds between two checks of the waiting units
    constant real    DZCOMPAT_MORPH_PERIOD = 0.01
    // Checks (not counting those while the unit is paused) / checks in all before the unit
    // is let go with its old type and changed by skin
    constant integer DZCOMPAT_MORPH_TICKS = 200
    constant integer DZCOMPAT_MORPH_TOTAL = 3000
    // Child keys of a morphing unit
    constant integer DZCOMPAT_MORPH_TARGET = 1
    constant integer DZCOMPAT_MORPH_OLD = 2
    constant integer DZCOMPAT_MORPH_CHAOS = 3
    constant integer DZCOMPAT_MORPH_TICKS_LEFT = 4
    constant integer DZCOMPAT_MORPH_TOTAL_LEFT = 5
    constant integer DZCOMPAT_MORPH_UNPAUSED = 6
    constant integer DZCOMPAT_MORPH_LIFE = 7
    constant integer DZCOMPAT_MORPH_MANA = 8
    constant integer DZCOMPAT_MORPH_INVULNERABLE = 9
    constant integer DZCOMPAT_MORPH_SNAPSHOT = 10
    constant integer DZCOMPAT_MORPH_KEPT = 11
    constant integer DZCOMPAT_MORPH_KEEP_ALL = 12
    // 100 + 2k = id and 101 + 2k = level of the k-th kept ability (ability ids are far above)
    constant integer DZCOMPAT_MORPH_KEPT_LIST = 100
endglobals

    // Called by the baked DzCompat_InitMorphChaos.
    function DzCompat_MorphChaosPut takes integer target, integer chaosAbility returns nothing
        call SaveInteger(gDzCompatMorph, 0, target, chaosAbility)
    endfunction

    // 0 when the script analysis found no Chaos ability for this target
    function DzCompat_MorphChaos takes integer target returns integer
        return LoadInteger(gDzCompatMorph, 0, target)
    endfunction

    // The skin change DzSetUnitID did before: the look of another unit type, not its stats.
    // A skin change alone leaves the old name showing.
    function DzCompat_MorphSkin takes unit u, integer target returns nothing
        call BlzSetUnitSkin(u, target)
        call BlzSetUnitName(u, GetObjectName(target))
    endfunction

    function DzCompat_MorphPending takes unit u returns boolean
        if u == null or gDzCompatMorphCount == 0 then
            return false
        endif
        return HaveSavedInteger(gDzCompatMorph, GetHandleId(u), DZCOMPAT_MORPH_TARGET)
    endfunction

    function DzCompat_MorphObserve takes unit u, integer h returns nothing
        call SaveReal(gDzCompatMorph, h, DZCOMPAT_MORPH_LIFE, GetUnitState(u, UNIT_STATE_LIFE))
        call SaveReal(gDzCompatMorph, h, DZCOMPAT_MORPH_MANA, GetUnitState(u, UNIT_STATE_MANA))
        call SaveBoolean(gDzCompatMorph, h, DZCOMPAT_MORPH_INVULNERABLE, BlzIsUnitInvulnerable(u))
    endfunction

    // mark = true: remembers which abilities the unit has now (child key = ability id).
    // mark = false: lists the abilities to put back after the change - every one when the
    // call came from DzSetUnitID, else only those the unit gained since it was marked.
    function DzCompat_MorphAbilities takes unit u, integer h, boolean mark returns nothing
        local integer i = 0
        local integer n = 0
        local integer id
        local integer chaos = LoadInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_CHAOS)
        local boolean keepAll = LoadBoolean(gDzCompatMorph, h, DZCOMPAT_MORPH_KEEP_ALL)
        local ability a
        loop
            set a = BlzGetUnitAbilityByIndex(u, i)
            exitwhen a == null or i >= 200
            set id = BlzGetAbilityId(a)
            if mark then
                call SaveBoolean(gDzCompatMorph, h, id, true)
            elseif id != chaos and id != 0 and n < DZCOMPAT_MORPH_SLOTS then
                if (keepAll and id != 'Amov' and id != 'Aatk' and id != 'AHer' and id != 'ARal') or not LoadBoolean(gDzCompatMorph, h, id) then
                    call SaveInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_KEPT_LIST + 2 * n, id)
                    call SaveInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_KEPT_LIST + 2 * n + 1, GetUnitAbilityLevel(u, id))
                    set n = n + 1
                endif
            endif
            set i = i + 1
        endloop
        if not mark then
            call SaveInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_KEPT, n)
        endif
        set a = null
    endfunction

    function DzCompat_MorphRemove takes integer i returns nothing
        set gDzCompatMorphCount = gDzCompatMorphCount - 1
        set gDzCompatMorphUnit[i] = gDzCompatMorphUnit[gDzCompatMorphCount]
        set gDzCompatMorphUnit[gDzCompatMorphCount] = null
        if gDzCompatMorphCount == 0 then
            call PauseTimer(gDzCompatMorphTick)
        endif
    endfunction

    function DzCompat_MorphIndex takes unit u returns integer
        local integer i = gDzCompatMorphCount - 1
        loop
            exitwhen i < 0
            if gDzCompatMorphUnit[i] == u then
                return i
            endif
            set i = i - 1
        endloop
        return -1
    endfunction

    // Life and mana back, clamped to what the new type allows.
    function DzCompat_MorphRestoreState takes unit u, real life, real mana returns nothing
        local real m = GetUnitState(u, UNIT_STATE_MAX_LIFE)
        if life > 0.405 then
            if life < m then
                call SetUnitState(u, UNIT_STATE_LIFE, life)
            else
                call SetUnitState(u, UNIT_STATE_LIFE, m)
            endif
        endif
        set m = GetUnitState(u, UNIT_STATE_MAX_MANA)
        if mana > 0.0 then
            if mana < m then
                call SetUnitState(u, UNIT_STATE_MANA, mana)
            else
                call SetUnitState(u, UNIT_STATE_MANA, m)
            endif
        endif
    endfunction

    // The unit has its new type: the Chaos ability goes, the abilities come back.
    function DzCompat_MorphApply takes unit u, integer h returns nothing
        local integer target = LoadInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_TARGET)
        local integer chaos = LoadInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_CHAOS)
        local integer n = LoadInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_KEPT)
        local integer k = 0
        local integer id
        local integer lv
        if GetUnitAbilityLevel(u, chaos) > 0 then
            call UnitRemoveAbility(u, chaos)
            // taking the Chaos ability away must not take the new type with it
            if GetUnitTypeId(u) != target then
                call UnitAddAbility(u, chaos)
            endif
        endif
        loop
            exitwhen k >= n
            set id = LoadInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_KEPT_LIST + 2 * k)
            set lv = LoadInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_KEPT_LIST + 2 * k + 1)
            if GetUnitAbilityLevel(u, id) == 0 then
                if UnitAddAbility(u, id) and lv > 1 then
                    call SetUnitAbilityLevel(u, id, lv)
                endif
            endif
            set k = k + 1
        endloop
        if LoadBoolean(gDzCompatMorph, h, DZCOMPAT_MORPH_INVULNERABLE) and not BlzIsUnitInvulnerable(u) then
            call SetUnitInvulnerable(u, true)
        endif
        call DzCompat_MorphRestoreState(u, LoadReal(gDzCompatMorph, h, DZCOMPAT_MORPH_LIFE), LoadReal(gDzCompatMorph, h, DZCOMPAT_MORPH_MANA))
        if LoadBoolean(gDzCompatMorph, h, DZCOMPAT_MORPH_UNPAUSED) then
            call PauseUnit(u, true)
        endif
        call FlushChildHashtable(gDzCompatMorph, h)
    endfunction

    // The change did not happen (or something else changed the unit's type): the Chaos
    // ability goes and the unit is left as it is.
    function DzCompat_MorphRelease takes unit u, integer h returns nothing
        local integer chaos = LoadInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_CHAOS)
        if GetUnitAbilityLevel(u, chaos) > 0 then
            call UnitRemoveAbility(u, chaos)
        endif
        if LoadBoolean(gDzCompatMorph, h, DZCOMPAT_MORPH_UNPAUSED) then
            call PauseUnit(u, true)
        endif
        call FlushChildHashtable(gDzCompatMorph, h)
    endfunction

    // Runs one game tick after DzSetUnitID: the unit still has its old type here, so this is
    // the moment its abilities, life and mana are written down for DzCompat_MorphApply.
    function DzCompat_MorphSnapshot takes nothing returns nothing
        local integer i = gDzCompatMorphCount - 1
        local unit u
        local integer h
        loop
            exitwhen i < 0
            set u = gDzCompatMorphUnit[i]
            set h = GetHandleId(u)
            if HaveSavedInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_TARGET) and not LoadBoolean(gDzCompatMorph, h, DZCOMPAT_MORPH_SNAPSHOT) then
                if GetUnitTypeId(u) == LoadInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_OLD) then
                    call SaveBoolean(gDzCompatMorph, h, DZCOMPAT_MORPH_SNAPSHOT, true)
                    call DzCompat_MorphAbilities(u, h, false)
                    call DzCompat_MorphObserve(u, h)
                endif
            endif
            set i = i - 1
        endloop
        set u = null
    endfunction

    function DzCompat_MorphWatch takes nothing returns nothing
        local integer i = gDzCompatMorphCount - 1
        local unit u
        local integer h
        local integer t
        local integer target
        loop
            exitwhen i < 0
            set u = gDzCompatMorphUnit[i]
            set h = GetHandleId(u)
            set t = GetUnitTypeId(u)
            if t == 0 or not HaveSavedInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_TARGET) then
                // the unit is gone, or its entry was taken away
                call FlushChildHashtable(gDzCompatMorph, h)
                call DzCompat_MorphRemove(i)
            else
                set target = LoadInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_TARGET)
                if t == target then
                    call DzCompat_MorphApply(u, h)
                    call DzCompat_MorphRemove(i)
                elseif t != LoadInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_OLD) then
                    call DzCompat_MorphRelease(u, h)
                    call DzCompat_MorphRemove(i)
                elseif LoadInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_TICKS_LEFT) <= 0 or LoadInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_TOTAL_LEFT) <= 0 then
                    // the change never came: give up and change the look only
                    call DzCompat_MorphRelease(u, h)
                    call DzCompat_MorphRemove(i)
                    call DzCompat_MorphSkin(u, target)
                else
                    call DzCompat_MorphObserve(u, h)
                    if not IsUnitPaused(u) then
                        call SaveInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_TICKS_LEFT, LoadInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_TICKS_LEFT) - 1)
                    endif
                    call SaveInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_TOTAL_LEFT, LoadInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_TOTAL_LEFT) - 1)
                endif
            endif
            set i = i - 1
        endloop
        set u = null
    endfunction

    function DzCompat_Morph takes unit u, integer target returns nothing
        local integer chaos
        local integer h
        local integer i
        local real life
        local real mana
        local boolean wasPaused
        if u == null or target == 0 then
            return
        endif
        set h = GetHandleId(u)
        if DzCompat_MorphPending(u) then
            set i = DzCompat_MorphIndex(u)
            if GetUnitTypeId(u) == LoadInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_TARGET) then
                call DzCompat_MorphApply(u, h)
            elseif target == LoadInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_TARGET) then
                return
            else
                call DzCompat_MorphRelease(u, h)
            endif
            if i >= 0 then
                call DzCompat_MorphRemove(i)
            endif
        endif
        if GetUnitTypeId(u) == target then
            if BlzGetUnitSkin(u) != target then
                call BlzSetUnitSkin(u, target)
            endif
            return
        endif
        set chaos = DzCompat_MorphChaos(target)
        if chaos != 0 and gDzCompatMorphCount >= DZCOMPAT_MORPH_MAX then
            set chaos = 0
        endif
        if chaos == 0 then
            call DzCompat_MorphSkin(u, target)
            return
        endif
        set life = GetUnitState(u, UNIT_STATE_LIFE)
        set mana = GetUnitState(u, UNIT_STATE_MANA)
        call FlushChildHashtable(gDzCompatMorph, h)
        call SaveInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_CHAOS, chaos)
        call SaveBoolean(gDzCompatMorph, h, DZCOMPAT_MORPH_KEEP_ALL, gDzCompatMorphKeepAll)
        call DzCompat_MorphAbilities(u, h, true)
        // a paused unit does not change; it is paused again when the change is done
        set wasPaused = false
        if IsUnitPaused(u) then
            call PauseUnit(u, false)
            set wasPaused = not IsUnitPaused(u)
        endif
        call UnitAddAbility(u, chaos)
        if GetUnitTypeId(u) == target then
            // changed at once
            call FlushChildHashtable(gDzCompatMorph, h)
            call UnitRemoveAbility(u, chaos)
            if GetUnitTypeId(u) != target then
                call UnitAddAbility(u, chaos)
            endif
            if wasPaused then
                call PauseUnit(u, true)
            endif
            call DzCompat_MorphRestoreState(u, life, mana)
            return
        endif
        call SaveInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_TARGET, target)
        call SaveInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_OLD, GetUnitTypeId(u))
        call SaveInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_TICKS_LEFT, DZCOMPAT_MORPH_TICKS)
        call SaveInteger(gDzCompatMorph, h, DZCOMPAT_MORPH_TOTAL_LEFT, DZCOMPAT_MORPH_TOTAL)
        call SaveBoolean(gDzCompatMorph, h, DZCOMPAT_MORPH_UNPAUSED, wasPaused)
        call DzCompat_MorphObserve(u, h)
        set gDzCompatMorphUnit[gDzCompatMorphCount] = u
        set gDzCompatMorphCount = gDzCompatMorphCount + 1
        if gDzCompatMorphCount == 1 then
            call TimerStart(gDzCompatMorphTick, DZCOMPAT_MORPH_PERIOD, true, function DzCompat_MorphWatch)
        endif
        call TimerStart(gDzCompatMorphStart, 0.0, false, function DzCompat_MorphSnapshot)
    endfunction

    // [REAL] Changes the unit's type and keeps its abilities. Where no Chaos ability was
    // baked for the target, the look of the target type only (BlzSetUnitSkin + name).
    function DzSetUnitID takes unit whichUnit, integer id returns nothing
        set gDzCompatMorphKeepAll = true
        call DzCompat_Morph(whichUnit, id)
        set gDzCompatMorphKeepAll = false
    endfunction
