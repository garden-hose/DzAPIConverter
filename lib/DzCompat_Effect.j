// ============================================================================
// DzCompat_Effect.j
// Effect model tracking and the natives that need an effect's model path:
// DzSetEffectModel, DzBindEffect, DzUnbindEffect, DzSetEffectAttachedModelScale.
//
// Reforged cannot attach an existing effect to a unit and has no getter for an
// effect's model path. The map's AddSpecialEffect* / DestroyEffect calls are
// rewritten (EffectModelConverter, only for a map that calls one of these natives)
// to the DzCompat_ wrappers below, which remember the path. DzBindEffect then
// hides the original effect and shows a copy attached to the parent widget.
// ============================================================================

globals
    // Per effect handle id: child 1 = the model path the effect was created with,
    // child 2 = the path set by DzSetEffectModel. Filled by the wrappers below.
    hashtable gDzCompatEffectModel = InitHashtable()
    // Per effect handle id: child 0 = the attached copy (effect), 1 = the parent (widget),
    // string child 2 = the attachment point.
    hashtable gDzCompatEffectBind = InitHashtable()
    // The effect the last wrapper made (the wrappers return it, so no local keeps a reference)
    effect    gDzCompatEffectLast = null
endglobals

    // Takes the attached copy of a bound effect away again and shows the effect itself.
    function DzUnbindEffect takes effect whichEffect returns nothing
        local integer id
        local effect bound
        local integer alpha = 255
        if whichEffect == null then
            return
        endif
        set id = GetHandleId(whichEffect)
        set bound = LoadEffectHandle(gDzCompatEffectBind, id, 0)
        if bound != null then
            call DestroyEffect(bound)
            call FlushChildHashtable(gDzCompatEffectBind, id)
            // the alpha DzSetEffectVertexAlpha last wrote (255 when it never did)
            if HaveSavedInteger(gDzCompatEffectVertex, id, 0) then
                set alpha = LoadInteger(gDzCompatEffectVertex, id, 0)
            endif
            call BlzSetSpecialEffectAlpha(whichEffect, alpha)
        endif
        set bound = null
    endfunction

    function DzCompat_AddSpecialEffect takes string modelName, real x, real y returns effect
        set gDzCompatEffectLast = AddSpecialEffect(modelName, x, y)
        if gDzCompatEffectLast != null then
            call SaveStr(gDzCompatEffectModel, GetHandleId(gDzCompatEffectLast), 1, modelName)
        endif
        return gDzCompatEffectLast
    endfunction

    function DzCompat_AddSpecialEffectLoc takes string modelName, location where returns effect
        set gDzCompatEffectLast = AddSpecialEffectLoc(modelName, where)
        if gDzCompatEffectLast != null then
            call SaveStr(gDzCompatEffectModel, GetHandleId(gDzCompatEffectLast), 1, modelName)
        endif
        return gDzCompatEffectLast
    endfunction

    function DzCompat_AddSpecialEffectTarget takes string modelName, widget targetWidget, string attachPointName returns effect
        set gDzCompatEffectLast = AddSpecialEffectTarget(modelName, targetWidget, attachPointName)
        if gDzCompatEffectLast != null then
            call SaveStr(gDzCompatEffectModel, GetHandleId(gDzCompatEffectLast), 1, modelName)
        endif
        return gDzCompatEffectLast
    endfunction

    // The BJ versions keep Blizzard.j's own behaviour (bj_lastCreatedEffect is set by them).
    function DzCompat_AddSpecialEffectLocBJ takes location where, string modelName returns effect
        set gDzCompatEffectLast = AddSpecialEffectLocBJ(where, modelName)
        if gDzCompatEffectLast != null then
            call SaveStr(gDzCompatEffectModel, GetHandleId(gDzCompatEffectLast), 1, modelName)
        endif
        return gDzCompatEffectLast
    endfunction

    function DzCompat_AddSpecialEffectTargetUnitBJ takes string attachPointName, widget targetWidget, string modelName returns effect
        set gDzCompatEffectLast = AddSpecialEffectTargetUnitBJ(attachPointName, targetWidget, modelName)
        if gDzCompatEffectLast != null then
            call SaveStr(gDzCompatEffectModel, GetHandleId(gDzCompatEffectLast), 1, modelName)
        endif
        return gDzCompatEffectLast
    endfunction

    // An effect that is bound has an attached copy: destroying the effect has to take the
    // copy with it, and its model entry goes so a recycled handle id does not inherit it.
    function DzCompat_DestroyEffect takes effect whichEffect returns nothing
        local integer id
        if whichEffect == null then
            return
        endif
        set id = GetHandleId(whichEffect)
        call DzUnbindEffect(whichEffect)
        call FlushChildHashtable(gDzCompatEffectModel, id)
        call DestroyEffect(whichEffect)
    endfunction

    // [APPROX] The effect keeps existing but is hidden (alpha 0); a copy of its model is
    // attached to the parent at the attachment point. The copy takes the effect's scale at
    // the time of the call (EXSetEffectSize before the bind carries over; after it, use
    // DzSetEffectAttachedModelScale). The model is the one DzSetEffectModel set, else the one
    // the effect was created with; with no recorded path (an effect made by a call that was
    // not rewritten) nothing is bound.
    function DzBindEffect takes widget parent, string attachPoint, effect whichEffect returns nothing
        local integer id
        local string model
        local effect bound
        if whichEffect == null or parent == null then
            return
        endif
        call DzUnbindEffect(whichEffect)
        set id = GetHandleId(whichEffect)
        set model = LoadStr(gDzCompatEffectModel, id, 2)
        if model == null or model == "" then
            set model = LoadStr(gDzCompatEffectModel, id, 1)
        endif
        if model == null or model == "" then
            return
        endif
        set bound = AddSpecialEffectTarget(model, parent, attachPoint)
        if bound == null then
            return
        endif
        call BlzSetSpecialEffectScale(bound, BlzGetSpecialEffectScale(whichEffect))
        call BlzSetSpecialEffectAlpha(whichEffect, 0)
        call SaveEffectHandle(gDzCompatEffectBind, id, 0, bound)
        call SaveWidgetHandle(gDzCompatEffectBind, id, 1, parent)
        call SaveStr(gDzCompatEffectBind, id, 2, attachPoint)
        set bound = null
    endfunction

    // [APPROX] An existing effect cannot change its model on Reforged. The path is kept for
    // the next DzBindEffect; when the effect is bound already, the attached copy is rebuilt
    // with the new model.
    function DzSetEffectModel takes effect whichEffect, string model returns nothing
        local integer id
        local widget parent
        local string attachPoint
        if whichEffect == null or model == null or model == "" then
            return
        endif
        set id = GetHandleId(whichEffect)
        call SaveStr(gDzCompatEffectModel, id, 2, model)
        if LoadEffectHandle(gDzCompatEffectBind, id, 0) != null then
            set parent = LoadWidgetHandle(gDzCompatEffectBind, id, 1)
            set attachPoint = LoadStr(gDzCompatEffectBind, id, 2)
            call DzBindEffect(parent, attachPoint, whichEffect)
            set parent = null
        endif
    endfunction

    // Scales the attached copy of a bound effect; false when the effect is not bound.
    function DzSetEffectAttachedModelScale takes effect whichEffect, real scaleX, real scaleY, real scaleZ returns boolean
        local effect bound
        if whichEffect == null then
            return false
        endif
        set bound = LoadEffectHandle(gDzCompatEffectBind, GetHandleId(whichEffect), 0)
        if bound == null then
            return false
        endif
        call BlzSetSpecialEffectMatrixScale(bound, scaleX, scaleY, scaleZ)
        set bound = null
        return true
    endfunction
