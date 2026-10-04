// ============================================================================
// DzCompat_UnitEffect.j
// Unit visual/state natives, mouse tracking, effect timers, queue orders.
// Globals live in DzCompat_Core.j / are duplicated here for standalone use.
// ============================================================================

globals
    hashtable gDzCompatUnitDataCache = InitHashtable()
    hashtable gDzCompatEffectTimers = InitHashtable()
    hashtable gDzCompatEffectHidden = InitHashtable()
    hashtable gDzCompatMouseTrack = InitHashtable()
    boolean   gDzCompatMouseTrackReady = false
    constant integer SILENCE_ABILITY_ID = 'ACsi'
endglobals

    function DzCompat_OnMouseMoveTrack takes nothing returns nothing
        local integer pid = GetPlayerId(GetTriggerPlayer())
        call SaveReal(gDzCompatMouseTrack, pid, 0, BlzGetTriggerPlayerMouseX())
        call SaveReal(gDzCompatMouseTrack, pid, 1, BlzGetTriggerPlayerMouseY())
    endfunction

    function DzCompat_EnsureMouseTracking takes nothing returns nothing
        local trigger trig
        local integer i = 0
        if gDzCompatMouseTrackReady then
            return
        endif
        set gDzCompatMouseTrackReady = true
        set trig = CreateTrigger()
        loop
            exitwhen i >= bj_MAX_PLAYER_SLOTS
            call TriggerRegisterPlayerEvent(trig, Player(i), EVENT_PLAYER_MOUSE_MOVE)
            set i = i + 1
        endloop
        call TriggerAddAction(trig, function DzCompat_OnMouseMoveTrack)
    endfunction

    function DzGetMouseTerrainX takes nothing returns real
        call DzCompat_EnsureMouseTracking()
        return LoadReal(gDzCompatMouseTrack, GetPlayerId(GetTriggerPlayer()), 0)
    endfunction

    function DzGetMouseTerrainY takes nothing returns real
        call DzCompat_EnsureMouseTracking()
        return LoadReal(gDzCompatMouseTrack, GetPlayerId(GetTriggerPlayer()), 1)
    endfunction
	
	// World Z under the local player's cursor. Built from the same tracked XY
    // as X/Y via GetLocationZ (no dedicated Blz terrain-Z-under-cursor native).
    function DzGetMouseTerrainZ takes nothing returns real
        local location loc
        local real z
        call DzCompat_EnsureMouseTracking()
        set loc = Location(LoadReal(gDzCompatMouseTrack, GetPlayerId(GetLocalPlayer()), 0), LoadReal(gDzCompatMouseTrack, GetPlayerId(GetLocalPlayer()), 1))
        set z = GetLocationZ(loc)
        call RemoveLocation(loc)
        set loc = null
        return z
    endfunction

    // ---- misc ------------------------------------------------------
    // DzExecuteFunc needs no wrapper at all - it's calling into the same slot
    // stock JASS already fills with the real native "ExecuteFunc". If your
    // war3map.j declares both, just delete the Dz declaration and rename call
    // sites, or keep this passthrough if renaming isn't convenient.
    function DzExecuteFunc takes string funcName returns nothing
        call ExecuteFunc(funcName)
    endfunction

    // ---- DzUnitChangeAlpha -----------------------------------------
    // Stock JASS has always had a real native for this - no Blz-era addition
    // needed. forceUpdate is dropped since SetUnitVertexColor applies
    // immediately; RGB channels default to full since Dz's native only
    // exposes alpha.
    function DzUnitChangeAlpha takes unit whichUnit, integer alpha, boolean forceUpdate returns nothing
        call SetUnitVertexColor(whichUnit, 255, 255, 255, alpha)
    endfunction

    // ---- DzUnitDisableAttack ----------------------------------------
    // Real native since 1.29: disabling the 'Aatk' (Attack) ability - rawcode
    // confirmed correct. Note this is a counter, not a flag (see
    // BlzUnitDisableAbility docs) - repeated enable/disable calls must stay
    // balanced or it'll get stuck.
    // Disabling also cuts off an attack already under way; the ability flag alone lets it finish.
    function DzUnitDisableAttack takes unit whichUnit, boolean disable returns nothing
        if whichUnit == null then
            return
        endif
        call BlzUnitDisableAbility(whichUnit, 'Aatk', disable, false)
        if disable then
            call BlzUnitInterruptAttack(whichUnit)
        endif
    endfunction

    // ---- DzUnitSilence -----------------------------------------------
    // No single "silence" native exists; applying the real Silence buff
    // ability so spellcasting is actually blocked by the engine (not just
    // cosmetically). SILENCE_ABILITY_ID confirmed as this map's Silence buff
    // rawcode - declared in the globals block above.

    function DzUnitSilence takes unit whichUnit, boolean disable returns nothing
        if disable then
            call UnitAddAbility(whichUnit, SILENCE_ABILITY_ID)
        else
            call UnitRemoveAbility(whichUnit, SILENCE_ABILITY_ID)
        endif
    endfunction

    // ---- DzUnitSetCanSelect / DzUnitSetTargetable --------------------
    // No native isolates "selectable" from "targetable" - the community
    // technique (Locust ability, rawcode confirmed correct) toggles both
    // together and also affects minimap visibility and some order behavior.
    // If your map needs these truly independent, that's not achievable
    // without engine changes; this is the closest available approximation
    // using only real natives.
    function DzUnitSetCanSelect takes unit whichUnit, boolean state returns nothing
        if state then
            call UnitRemoveAbility(whichUnit, 'Aloc')
        else
            call UnitAddAbility(whichUnit, 'Aloc')
        endif
    endfunction

    function DzUnitSetTargetable takes unit whichUnit, boolean state returns nothing
        if state then
            call UnitRemoveAbility(whichUnit, 'Aloc')
        else
            call UnitAddAbility(whichUnit, 'Aloc')
        endif
    endfunction

    // ---- unit move type (string name -> UNIT_IF_MOVE_TYPE) ----------
    function DzUnitSetMoveType takes unit whichUnit, string moveType returns nothing
        local integer v = 0
        if moveType == "foot" then
            set v = 1
        elseif moveType == "fly" then
            set v = 2
        elseif moveType == "horse" then
            set v = 4
        elseif moveType == "hover" then
            set v = 8
        elseif moveType == "float" then
            set v = 16
        elseif moveType == "amph" then
            set v = 32
        elseif moveType == "unbuildable" then
            set v = 64
        else
            return
        endif
        call BlzSetUnitIntegerField(whichUnit, UNIT_IF_MOVE_TYPE, v)
    endfunction

    // ---- unit order queue control (BlzUnit*Orders) -----------------
    function DzUnitOrdersClear takes unit u, boolean onlyQueued returns nothing
        call BlzUnitClearOrders(u, onlyQueued)
    endfunction

    function DzUnitOrdersCount takes unit u returns integer
        return BlzGetUnitOrderCount(u)
    endfunction

    function DzUnitOrdersForceStop takes unit u, boolean clearQueue returns nothing
        call BlzUnitForceStopOrder(u, clearQueue)
    endfunction

    // ---- DzUnitDisableInventory -------------------------------------------------
    // Held off on this one - I don't have a confirmed technique that disables
    // inventory interaction without side effects (removing the inventory
    // ability entirely also drops carried items). Tell me what "disable"
    // needs to mean in your map (can't use items? can't drop/pick up? both?)
    // and I'll find the right approach rather than guess.

    // ============================================================================
    // Batch 5 - misc unit/item/mouse natives with direct real-native equivalents
    // ============================================================================

    // ---- item ability lookup ------------------------------------------
    function DzGetItemAbility takes item whichEffect, integer index returns ability
        return BlzGetItemAbility(whichEffect, index)
    endfunction

    // ---- unit name ----------------------------------------------------
    function DzSetUnitName takes unit whichUnit, string name returns nothing
        if whichUnit == null or name == null or name == "" then
            return
        endif
        call BlzSetUnitName(whichUnit, name)
    endfunction

    // ---- unit collision size (read-only in real Reforged) -----------
    // BlzGetUnitCollisionSize exists; there is no BlzSetUnitCollisionSize or any
    // other real native that writes this value - collision size isn't exposed
    // as a settable field at all in common.j/blizzard.j. DzSetUnitCollisionSize
    // is therefore NOT implemented here and still falls back to the dummy stub;
    // flag it back to me if you find a technique (e.g. a specific ability field)
    // that actually changes it in-game and I'll wire it in.
    function DzGetUnitCollisionSize takes unit Unit returns real
        if Unit == null then
            return 0.
        endif
        return BlzGetUnitCollisionSize(Unit)
    endfunction

    // ---- [VERIFIED] unit Z (current height off the walkable surface) -----------
    function DzGetUnitZ takes unit u returns real
        return BlzGetUnitZ(u)
    endfunction

    // ---- [APPROX] kill unit -------------------------------------------------------
    // Real KillUnit takes no killer - kill credit/bounty attribution to a
    // specific "killer" unit cannot be reproduced with a single native call.
    // This drops the killer and performs an unconditional, unattributed kill
    // (matches KillUnit's own behavior - always kills regardless of magic
    // immunity/wards, same as the real native). If your map actually depends
    // on the kill being credited to `killer` (bounty gold, kill-count
    // triggers, etc.), switch to the lethal 
	// UnitDamageTarget(killer, whichUnit, ...) instead - that attributes the
    // kill properly but goes through the normal damage/death-trigger pipeline
    // instead of an instant kill, which is a different, larger behavior change.
    function DzKillUnit takes unit whichUnit, unit killer returns boolean
        call KillUnit(whichUnit)
        return true
    endfunction

    // ---- mouse position -------------------------------------------------
    function DzSetMousePos takes integer x, integer y returns nothing
        call BlzSetMousePos(x, y)
    endfunction

    // ---- unit position -------------------------------------------------
    function DzSetUnitPosition takes unit whichUnit, real x, real y returns nothing
        call SetUnitPosition(whichUnit, x, y)
    endfunction

    function DzSetUnitXY takes unit whichUnit, real x, real y returns boolean
        call SetUnitPosition(whichUnit, x, y)
        return true
    endfunction

    // ---- locale ----------------------------------------------------------
    function DzGetLocale takes nothing returns string
        return BlzGetLocale()
    endfunction

    // ============================================================================
    // These are DISTINCT from the ability-scoped DzSetUnitAbilityMissileSpeed/Arc 
	// in DzCompat_AbilityField.j - these apply to the unit's primary attack
    // (weapon index 0) directly, with no ability parameter at all.
    // ============================================================================

    function DzSetUnitMissileSpeed takes unit whichUnit, real speed returns nothing
        call BlzSetUnitWeaponRealField(whichUnit, UNIT_WEAPON_RF_ATTACK_PROJECTILE_SPEED, 0, speed)
    endfunction

    function DzSetUnitMissileArc takes unit whichUnit, real arc returns nothing
        call BlzSetUnitWeaponRealField(whichUnit, UNIT_WEAPON_RF_ATTACK_PROJECTILE_ARC, 0, arc)
    endfunction

    function DzSetUnitMissileHoming takes unit whichUnit, boolean enable returns nothing
        call BlzSetUnitWeaponBooleanField(whichUnit, UNIT_WEAPON_BF_ATTACK_PROJECTILE_HOMING_ENABLED, 0, enable)
    endfunction

    // Both weapon slots, so a unit whose second weapon is the one that attacks gets the model too.
    function DzSetUnitMissileModel takes unit whichUnit, string modelFile returns nothing
        if whichUnit == null or modelFile == null then
            return
        endif
        call BlzSetUnitWeaponStringField(whichUnit, UNIT_WEAPON_SF_ATTACK_PROJECTILE_ART, 0, modelFile)
        call BlzSetUnitWeaponStringField(whichUnit, UNIT_WEAPON_SF_ATTACK_PROJECTILE_ART, 1, modelFile)
    endfunction

    // ---- hero proper name -------------------------------------------
    function DzSetUnitProperName takes unit whichUnit, string name returns nothing
        if whichUnit == null or name == null or name == "" then
            return
        endif
        call BlzSetHeroProperName(whichUnit, name)
    endfunction

    // ---- [APPROX] minimap icon ---------------------------------------------------
    // Real CreateMinimapIconOnUnit needs an RGB color + fogstate that Dz's own
    // signature doesn't expose - defaulted to white/always-visible, matching
    // what a mapper would get from Dz if it also had no way to customize
    // those (can't confirm the original's exact default from the docs).
    //
    // IMPORTANT LIMITATION: minimapicon has no SaveMinimapIconHandle/
    // LoadMinimapIconHandle native (checked - it's simply not in the list of
    // handle types common.j supports for hashtable storage), so a created
    // icon's handle CANNOT be retrieved again in a later call. Two
    // consequences: (1) calling this repeatedly on the same unit stacks a
    // new icon on top instead of replacing the old one - there is no way to
    // destroy the previous one first; (2) DzWidgetSetMinimapIconEnable
    // cannot be implemented at all, since toggling requires retrieving the
    // handle this function created. It is intentionally left unimplemented
    // (falls back to the dummy stub) rather than silently doing nothing.
    function DzWidgetSetMinimapIcon takes unit whichunit, string path returns nothing
        call CreateMinimapIconOnUnit(whichunit, 255, 255, 255, path, FOG_OF_WAR_VISIBLE)
    endfunction

    // ============================================================================
    // Effects, revive, and a local-only data cache. 
    // ============================================================================

    // ---- effect position -----------------------------------------------
    function DzSetEffectPos takes effect whichEffect, real x, real y, real z returns nothing
        call BlzSetSpecialEffectPosition(whichEffect, x, y, z)
    endfunction

    // ---- effect scale ----------------------------------------------------
    function DzSetEffectScale takes effect whichHandle, real scale returns nothing
        if whichHandle == null then
            return
        endif
        call BlzSetSpecialEffectScale(whichHandle, scale)
    endfunction

    // Plays the named animation. The attachment ("link") argument has no Reforged equivalent.
    function DzPlayEffectAnimation takes effect whichEffect, string anim, string link returns nothing
        if whichEffect == null or anim == null then
            return
        endif
        call BlzSetSpecialEffectAnimation(whichEffect, anim)
    endfunction

    // [APPROX] Dz played an effect's sequence by its index in the model. Reforged only plays a special effect's
    // sequences by animtype (BlzPlaySpecialEffect), and the model's own sequence list is not readable from JASS, so the
    // index is mapped to the animtype the common KK effect models use for it: 1 = death, 2 = birth, 3 = attack,
    // 4 = walk, anything else (0 included) = stand. flag has no Reforged equivalent.
    function DzSetEffectAnimation takes effect whichEffect, integer index, integer flag returns nothing
        local integer animType
        if whichEffect == null then
            return
        endif
        if index == 1 then
            set animType = 1 // ANIM_TYPE_DEATH
        elseif index == 2 then
            set animType = 0 // ANIM_TYPE_BIRTH
        elseif index == 3 then
            set animType = 6 // ANIM_TYPE_ATTACK
        elseif index == 4 then
            set animType = 5 // ANIM_TYPE_WALK
        else
            set animType = 4 // ANIM_TYPE_STAND
        endif
        call BlzPlaySpecialEffect(whichEffect, ConvertAnimType(animType))
    endfunction

    // Reforged cannot hide a special effect. Alpha 0 alone leaves particles and additive layers on screen, so
    // hiding also zeroes the scale and the matrix scale; showing restores alpha 255 and the scale the effect had
    // when it was hidden. (Measured in game on ported KK maps.)
    function DzSetEffectVisible takes effect whichEffect, boolean enable returns nothing
        local integer h
        if whichEffect == null then
            return
        endif
        set h = GetHandleId(whichEffect)
        if enable then
            call BlzSetSpecialEffectAlpha(whichEffect, 255)
            if HaveSavedReal(gDzCompatEffectHidden, h, 0) then
                call BlzSetSpecialEffectScale(whichEffect, LoadReal(gDzCompatEffectHidden, h, 0))
                call RemoveSavedReal(gDzCompatEffectHidden, h, 0)
            else
                call BlzSetSpecialEffectScale(whichEffect, 1.0)
            endif
            call BlzResetSpecialEffectMatrix(whichEffect)
        else
            if not HaveSavedReal(gDzCompatEffectHidden, h, 0) then
                call SaveReal(gDzCompatEffectHidden, h, 0, BlzGetSpecialEffectScale(whichEffect))
            endif
            call BlzSetSpecialEffectAlpha(whichEffect, 0)
            call BlzSetSpecialEffectScale(whichEffect, 0.0)
            call BlzSetSpecialEffectMatrixScale(whichEffect, 0.0, 0.0, 0.0)
        endif
    endfunction

    // ---- effect alpha -----------------------------------------------------
    function DzSetEffectVertexAlpha takes effect whichEffect, integer alpha returns nothing
        call BlzSetSpecialEffectAlpha(whichEffect, alpha)
    endfunction

    // ---- effect color, unpacked from Dz's single packed integer ---------
    // Same ARGB packing convention as DzGetColor's BlzConvertColor output
    // (alpha in the top byte, then red, green, blue). BlzSetSpecialEffectColor wants the
    // three color channels as separate integers and BlzSetSpecialEffectAlpha the alpha, so
    // the packed value is unpacked with plain integer arithmetic (JASS has no bitwise
    // operators).
    //
    // JASS integers are signed 32-bit. Any color with alpha >= 128 - which is every fully
    // opaque one (alpha 255) - is a NEGATIVE number, and integer division truncates
    // towards zero, so the usual "color / 65536" arithmetic gives wrong channels for it.
    // The value is therefore first moved into the non-negative range by adding 2^31 (which
    // only clears the top bit; the lower 24 bits, the color channels, are unchanged), and
    // the alpha's top bit is added back separately.
    function DzCompat_ColorAlpha takes integer color returns integer
        if color < 0 then
            return 128 + (color + 2147483647 + 1) / 16777216
        endif
        return color / 16777216
    endfunction

    function DzSetEffectVertexColor takes effect whichEffect, integer color returns nothing
        local integer rest
        local integer red
        local integer green
        local integer blue
        if whichEffect == null then
            return
        endif
        if color < 0 then
            set rest = color + 2147483647 + 1
        else
            set rest = color
        endif
        set rest = ModuloInteger(rest, 16777216)
        set red = rest / 65536
        set green = (rest - red * 65536) / 256
        set blue = rest - red * 65536 - green * 256
        call BlzSetSpecialEffectColor(whichEffect, red, green, blue)
        call BlzSetSpecialEffectAlpha(whichEffect, DzCompat_ColorAlpha(color))
    endfunction

    // ---- [FIXED] revive unit ----------------------------------------------------
    // ReviveHero only works on UNIT_TYPE_HERO units - calling it on a regular
    // unit is a silent no-op in the real engine, so this used to do nothing at
    // all for non-hero callers (a real correctness gap, not just an
    // approximation). Non-heroes are now revived by recreating them, which is
    // the standard real-engine substitute (there is no ReviveUnit native).
    // whichPlayer is honored where it's cheap to: null means "keep current
    // owner"; for heroes, an explicit different player runs through
    // SetUnitOwner after the revive (still dropped as a same-instant part of
    // ReviveHero itself - see original note below). hp<=0 is treated as "not
    // specified" rather than as an instant re-kill, since 0 was almost
    // certainly a default/unset argument, not deliberate.
    function DzReviveUnit takes unit whichUnit, player whichPlayer, real hp, real mp, real x, real y returns nothing
        local unit newUnit
        if whichUnit == null then
            return
        endif
        if whichPlayer == null then
            set whichPlayer = GetOwningPlayer(whichUnit)
        endif
        if IsUnitType(whichUnit, UNIT_TYPE_HERO) then
            call ReviveHero(whichUnit, x, y, true)
            if hp > 0.00 then
                call SetWidgetLife(whichUnit, hp)
            endif
            call SetUnitState(whichUnit, UNIT_STATE_MANA, mp)
            if GetOwningPlayer(whichUnit) != whichPlayer then
                call SetUnitOwner(whichUnit, whichPlayer, true)
            endif
            return
        endif
        // Non-hero: no revive native exists, so recreate it in place.
        set newUnit = CreateUnit(whichPlayer, GetUnitTypeId(whichUnit), x, y, GetUnitFacing(whichUnit))
        if hp > 0.00 then
            call SetUnitState(newUnit, UNIT_STATE_LIFE, hp)
        endif
        call SetUnitState(newUnit, UNIT_STATE_MANA, mp)
        set newUnit = null
    endfunction

    // ---- [LOCAL] no known real native backs this at all (writes into an
    // arbitrary "unit data cache" keyed by a raw id integer, not a real unit
    // handle - this project has no visibility into what reads it back, no
    // DzGetUnitDataCacheInteger is declared anywhere in the project's
    // headers either). Bookkeeping only, kept so the native isn't silently
    // dummy-stubbed instead. id and index are added rather than multiplied
    // to combine them into one childKey - same overflow-avoidance reasoning
    // as DzCompat_AbilKey in DzCompat_Stats.j.
    function DzSetUnitDataCacheInteger takes integer uid, integer id, integer index, integer v returns nothing
        call SaveInteger(gDzCompatUnitDataCache, uid, id + index, v)
    endfunction

    // ============================================================================
    // Unit group accessors, delayed effect destruction 
    // ============================================================================

    // ---- unit group accessors -------------------------------------------
    function DzGroupGetCount takes group g returns integer
        return BlzGroupGetSize(g)
    endfunction

    function DzGroupGetUnitAt takes group g, integer index returns unit
        return BlzGroupUnitAt(g, index)
    endfunction

    // ---- immediate effect removal ---------------------------------------
    function DzRemoveEffect takes effect whichEffect returns boolean
        call DestroyEffect(whichEffect)
        return true
    endfunction

    // ---- delayed effect removal --------------------------------------------
    // DzRemoveEffectTimed and DzDieEffectTimed have identical signatures in
    // the original headers - special effects have no "death" state the way
    // units do, so there's nothing to differentiate between a plain removal
    // and a "die" removal for a generic effect handle. Both are implemented
    // identically: a one-shot timer holding the effect handle in a
    // per-timer hashtable slot, destroying it and cleaning up when the timer
    // expires. If Dz's originals actually differed (e.g. one played a
    // death animation first)
    function DzCompat_OnEffectTimerExpire takes nothing returns nothing
        local timer t = GetExpiredTimer()
        local integer id = GetHandleId(t)
        call DestroyEffect(LoadEffectHandle(gDzCompatEffectTimers, id, 0))
        call FlushChildHashtable(gDzCompatEffectTimers, id)
        call PauseTimer(t)
        call DestroyTimer(t)
    endfunction

    function DzCompat_ScheduleEffectRemoval takes effect whichEffect, real time returns boolean
        local timer t = CreateTimer()
        call SaveEffectHandle(gDzCompatEffectTimers, GetHandleId(t), 0, whichEffect)
        call TimerStart(t, time, false, function DzCompat_OnEffectTimerExpire)
        return true
    endfunction

    function DzRemoveEffectTimed takes effect whichEffect, real time returns boolean
        return DzCompat_ScheduleEffectRemoval(whichEffect, time)
    endfunction

    function DzDieEffectTimed takes effect whichEffect, real time returns boolean
        return DzCompat_ScheduleEffectRemoval(whichEffect, time)
    endfunction

    // ---- generic handle-ID storage - these just wrap the real
    // hashtable primitives (a handle ID is already a plain integer, so there
    // is nothing Dz-specific to reproduce here).
    // (SaveInteger returns nothing, so it cannot be returned as the boolean result)
    function DzSaveHandleId takes hashtable whichHashtable, integer parentKey, integer childKey, integer handleId returns boolean
        call SaveInteger(whichHashtable, parentKey, childKey, handleId)
        return true
    endfunction

    function DzLoadHandleId takes hashtable whichHashtable, integer parentKey, integer childKey returns integer
        return LoadInteger(whichHashtable, parentKey, childKey)
    endfunction

    // ---- [APPROX] same as above, but drops the handleType param - there's
    // nowhere for it to go: LoadHandleId (and this native's own signature)
    // only ever hands back a raw integer, never a typed handle, so knowing
    // what type it "should" be doesn't change how it's stored or retrieved.
    function DzSaveHandleIdEx takes hashtable whichHashtable, integer parentKey, integer childKey, integer handleId, integer handleType returns boolean
        call SaveInteger(whichHashtable, parentKey, childKey, handleId)
        return true
    endfunction

    // ============================================================================
    // Queued order issuing. Reforged has a complete, exact-matching
    // BlzQueue*OrderById native family - these are direct 1:1 wraps, not
    // approximations. The 3 group variants loop over BlzGroupGetSize/
    // BlzGroupUnitAt 
    // ============================================================================

    function DzQueueIssueImmediateOrderById takes unit whichUnit, integer order returns boolean
        return BlzQueueImmediateOrderById(whichUnit, order)
    endfunction

    function DzQueueIssuePointOrderById takes unit whichUnit, integer order, real x, real y returns boolean
        return BlzQueuePointOrderById(whichUnit, order, x, y)
    endfunction

    function DzQueueIssueTargetOrderById takes unit whichUnit, integer order, widget targetWidget returns boolean
        return BlzQueueTargetOrderById(whichUnit, order, targetWidget)
    endfunction

    function DzQueueIssueInstantPointOrderById takes unit whichUnit, integer order, real x, real y, widget instantTargetWidget returns boolean
        return BlzQueueInstantPointOrderById(whichUnit, order, x, y, instantTargetWidget)
    endfunction

    function DzQueueIssueInstantTargetOrderById takes unit whichUnit, integer order, widget targetWidget, widget instantTargetWidget returns boolean
        return BlzQueueInstantTargetOrderById(whichUnit, order, targetWidget, instantTargetWidget)
    endfunction

    function DzQueueIssueBuildOrderById takes unit whichPeon, integer unitId, real x, real y returns boolean
        return BlzQueueBuildOrderById(whichPeon, unitId, x, y)
    endfunction

    function DzQueueIssueNeutralImmediateOrderById takes player forWhichPlayer, unit neutralStructure, integer unitId returns boolean
        return BlzQueueNeutralImmediateOrderById(forWhichPlayer, neutralStructure, unitId)
    endfunction

    function DzQueueIssueNeutralPointOrderById takes player forWhichPlayer, unit neutralStructure, integer unitId, real x, real y returns boolean
        return BlzQueueNeutralPointOrderById(forWhichPlayer, neutralStructure, unitId, x, y)
    endfunction

    function DzQueueIssueNeutralTargetOrderById takes player forWhichPlayer, unit neutralStructure, integer unitId, widget target returns boolean
        return BlzQueueNeutralTargetOrderById(forWhichPlayer, neutralStructure, unitId, target)
    endfunction

    // ---- group variants - loop over the real per-unit natives above ----
    function DzQueueGroupImmediateOrderById takes group whichGroup, integer order returns boolean
        local integer i = 0
        local integer n = BlzGroupGetSize(whichGroup)
        local boolean allOk = true
        loop
            exitwhen i >= n
            if not BlzQueueImmediateOrderById(BlzGroupUnitAt(whichGroup, i), order) then
                set allOk = false
            endif
            set i = i + 1
        endloop
        return allOk
    endfunction

    function DzQueueGroupPointOrderById takes group whichGroup, integer order, real x, real y returns boolean
        local integer i = 0
        local integer n = BlzGroupGetSize(whichGroup)
        local boolean allOk = true
        loop
            exitwhen i >= n
            if not BlzQueuePointOrderById(BlzGroupUnitAt(whichGroup, i), order, x, y) then
                set allOk = false
            endif
            set i = i + 1
        endloop
        return allOk
    endfunction

    function DzQueueGroupTargetOrderById takes group whichGroup, integer order, widget targetWidget returns boolean
        local integer i = 0
        local integer n = BlzGroupGetSize(whichGroup)
        local boolean allOk = true
        loop
            exitwhen i >= n
            if not BlzQueueTargetOrderById(BlzGroupUnitAt(whichGroup, i), order, targetWidget) then
                set allOk = false
            endif
            set i = i + 1
        endloop
        return allOk
    endfunction

    // ---- Unit under mouse / local selection (KK-JAPI) ---

    // BlzGetMouseFocusUnit is the Reforged equivalent of
    // DzGetUnitUnderMouse 1:1.
    function DzGetUnitUnderMouse takes nothing returns unit
        return BlzGetMouseFocusUnit()
    endfunction

    // [APPROX] Local selection helpers built on GroupEnumUnitsSelected.
    // Dz/KK expose these as JAPI; Reforged has no dedicated native, but the
    // classic GroupEnumUnitsSelected path is correct for the local player.
    // Index is 0-based (first selected unit = 0), matching BlzGroupUnitAt style.
    // Callers that treated KK's index as 1-based should subtract 1.

    function DzGetLocalSelectUnitCount takes nothing returns integer
        local group g = CreateGroup()
        local integer n
        call GroupEnumUnitsSelected(g, GetLocalPlayer(), null)
        set n = CountUnitsInGroup(g)
        call DestroyGroup(g)
        set g = null
        return n
    endfunction

    function DzGetLocalSelectUnit takes integer index returns unit
        local group g = CreateGroup()
        local unit u = null
        local integer i = 0
        call GroupEnumUnitsSelected(g, GetLocalPlayer(), null)
        loop
            set u = FirstOfGroup(g)
            exitwhen u == null
            call GroupRemoveUnit(g, u)
            if i == index then
                call DestroyGroup(g)
                set g = null
                return u
            endif
            set i = i + 1
        endloop
        call DestroyGroup(g)
        set g = null
        set u = null
        return null
    endfunction

    // [APPROX] "Leader" of the local selection = first unit in the selection
    // group (same order GroupEnumUnitsSelected yields).
    function DzGetSelectedLeaderUnit takes nothing returns unit
        return DzGetLocalSelectUnit(0)
    endfunction

    // ---- [APPROX] attack-ability cooldown reset (Reforged 3.0+) --------------
    // DzAttackAbilityEndCooldown only receives an `ability` handle - but the
    // real native that can reset a cooldown, BlzSetUnitAbilityCooldownRemaining
    // (new in 3.0), needs the *unit* that owns the ability plus its raw
    // ability id. There is no native that goes handle -> owning unit, so this
    // does a one-time scan of every unit currently on the map (GroupEnumUnitsInRect
    // over GetWorldBounds(), so it covers the whole playable area regardless
    // of map size) and checks each unit's ability list for a matching handle.
    // BlzGetAbilityId() then supplies the rawcode BlzSetUnitAbilityCooldownRemaining
    // needs.
    //
    // Two caveats:
    // 1) Performance: this is an O(units x abilities-per-unit) scan. Fine to
    //    call occasionally (e.g. from a specific trigger/cast-response), but
    //    do not call it every frame/tick for many units.
    // 2) Semantics: WC3 has no real "attack ability" object for a unit's
    //    plain melee/ranged attack - basic attacks are driven by weapon
    //    fields, not an ability. This function will correctly reset the
    //    cooldown of *any* genuine ability handle it's given (orb effects,
    //    channel-based attacks, etc.), but if DzGetAttackAbility() elsewhere
    //    in your map is only a stub that returns null/0, there's nothing
    //    real for this to find. If you can tell me what DzGetAttackAbility()
    //    is actually meant to return for a given unit, I can implement that
    //    native too and confirm this pairing end-to-end.

    function DzAttackAbilityEndCooldown takes ability whichHandle returns nothing
        local rect worldBounds = GetWorldBounds()
        local group allUnits = CreateGroup()
        local unit u
        local ability a
        local integer i
        local unit foundUnit = null
        local integer foundAbilId = 0

        call GroupEnumUnitsInRect(allUnits, worldBounds, null)
        loop
            set u = FirstOfGroup(allUnits)
            exitwhen u == null or foundUnit != null
            call GroupRemoveUnit(allUnits, u)
            set i = 0
            loop
                set a = BlzGetUnitAbilityByIndex(u, i)
                exitwhen a == null or foundUnit != null
                if a == whichHandle then
                    set foundUnit = u
                    set foundAbilId = BlzGetAbilityId(a)
                endif
                set i = i + 1
            endloop
        endloop
        call DestroyGroup(allUnits)
        call RemoveRect(worldBounds)

        if foundUnit != null then
            call BlzSetUnitAbilityCooldownRemaining(foundUnit, foundAbilId, 0.0)
        endif
    endfunction
