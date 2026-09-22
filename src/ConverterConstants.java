import java.util.Arrays;
import java.util.LinkedHashSet;
import java.util.Set;

/**
 * Static lookup tables shared by the forward and reverse converters.
 */
final class ConverterConstants {

    private ConverterConstants() {}

    // -------------------------------------------------------------------------
    // Implemented natives (exact list from the original R script)
    // -------------------------------------------------------------------------
    static final Set<String> IMPLEMENTED_NATIVES = new LinkedHashSet<>(Arrays.asList(
        // DzCompat_Frame.j
        "DzCreateFrame", "DzCreateSimpleFrame", "DzCreateFrameByTagName", "DzDestroyFrame",
        "DzFrameFindByName", "DzSimpleFrameFindByName", "DzGetGameUI", "DzFrameSetPoint",
        "DzFrameSetAbsolutePoint", "DzFrameSetAllPoints", "DzFrameClearAllPoints", "DzFrameSetSize",
        "DzFrameSetParent", "DzFrameGetParent", "DzFrameGetHeight", "DzFrameSetPriority", "DzFrameShow",
        "DzSimpleFrameShow", "DzFrameIsVisible", "DzFrameSetEnable", "DzFrameGetEnable", "DzFrameSetFocus",
        "DzFrameSetAlpha", "DzFrameGetAlpha", "DzFrameSetScale", "DzFrameSetTexture", "DzFrameSetModel",
        "DzFrameSetVertexColor", "DzFrameSetAnimate", "DzGetColor", "DzFrameSetText", "DzFrameGetText",
        "DzFrameAddText", "DzFrameSetTextColor", "DzFrameSetTextSizeLimit", "DzFrameGetTextSizeLimit",
        "DzFrameSetTextAlignment", "DzFrameSetFont", "DzFrameGetName", "DzFrameGetValue", "DzFrameSetValue",
        "DzFrameSetMinMaxValue", "DzFrameSetStepValue", "DzFrameSetTooltip", "DzLoadToc", "DzFrameHideInterface",
        "DzOriginalUIAutoResetPoint", "DzClickFrame", "DzFrameSetScriptByCode", "DzFrameSetScriptBlock",
        "DzFrameSetScriptByCodeAsync", "DzFrameSetScriptBlockAsync", "DzFrameSetScript", "DzFrameSetScriptAsync",
        "DzGetTriggerUIEventPlayer", "DzGetTriggerUIEventFrame", "DzFrameCageMouse",
        "DzSimpleFontStringFindByName", "DzSimpleTextureFindByName", "KKSimpleFrameIsVisible",
        "DzFrameGetChildrenCount", "DzFrameGetChild", "DzFrameGetWidth", "DzFrameGetRealWidth",
        "DzFrameGetRealHeight", "DzGetClientWidth", "DzGetClientHeight", "DzFrameSetCheckBoxState",
        "DzFrameGetCheckBoxState", "DzFrameSetNameContext", "DzFrameGetContext", "DzFrameIsFocus",
        // DzCompat_Frame.j - origin-frame sub-handle lookups (BlzGetOriginFrame)
        "DzFrameGetCommandBarButton", "DzFrameGetHeroBarButton", "DzFrameGetHeroHPBar",
        "DzFrameGetHeroManaBar", "DzFrameGetItemBarButton", "DzFrameGetMinimap",
        "DzFrameGetMinimapButton", "DzFrameGetTooltip", "DzFrameGetTopMessage",
        "DzFrameGetUnitMessage", "DzFrameGetChatMessage", "DzFrameGetPortrait",
        "DzFrameGetWorldFrameMessage", "DzFrameGetInfoPanelBuffButton",
		"DzGetWindowWidth", "DzGetWindowHeight",
        // UnitEffect / Sync
        "DzSyncData", "DzSyncDataImmediately", "DzSyncBuffer", "DzTriggerRegisterSyncData",
        "DzGetTriggerSyncPrefix", "DzGetTriggerSyncData", "DzGetTriggerSyncPlayer", "DzExecuteFunc",
        "DzGetMouseTerrainX", "DzGetMouseTerrainY",
        "DzUnitChangeAlpha", "DzUnitDisableAttack", "DzUnitSilence", "DzUnitSetCanSelect", "DzUnitSetTargetable",
        "DzUnitSetMoveType",
        "DzGetItemAbility", "DzSetUnitName", "DzGetUnitCollisionSize", "DzGetUnitZ", "DzKillUnit",
        "DzSetMousePos", "DzSetUnitPosition", "DzSetUnitXY", "DzGetLocale",
        "DzSetUnitMissileSpeed", "DzSetUnitMissileArc", "DzSetUnitMissileHoming", "DzSetUnitMissileModel",
        "DzSetUnitProperName", "DzWidgetSetMinimapIcon",
        "DzSetEffectPos", "DzSetEffectScale", "DzSetEffectVertexAlpha", "DzSetEffectVertexColor",
        "DzReviveUnit", "DzSetUnitDataCacheInteger",
        "DzUnitOrdersClear", "DzUnitOrdersCount", "DzUnitOrdersForceStop",
        "DzGroupGetCount", "DzGroupGetUnitAt", "DzRemoveEffect", "DzRemoveEffectTimed", "DzDieEffectTimed",
        "DzSaveHandleId", "DzLoadHandleId", "DzSaveHandleIdEx",
        "DzQueueIssueImmediateOrderById", "DzQueueIssuePointOrderById", "DzQueueIssueTargetOrderById",
        "DzQueueIssueInstantPointOrderById", "DzQueueIssueInstantTargetOrderById", "DzQueueIssueBuildOrderById",
        "DzQueueIssueNeutralImmediateOrderById", "DzQueueIssueNeutralPointOrderById", "DzQueueIssueNeutralTargetOrderById",
        "DzQueueGroupImmediateOrderById", "DzQueueGroupPointOrderById", "DzQueueGroupTargetOrderById",
        "DzGetMouseX", "DzGetMouseY", "DzGetMouseXRelative", "DzGetMouseYRelative",
        "DzAttackAbilityEndCooldown",
        // DzCompat_Stats.j
        "DzSetUnitDescription", "DzSetUnitPortrait", "DzSetUnitCollisionSize", "DzSetUnitSelectScale",
        "DzSetUnitHitIgnore", "DzGetUnitOverheadOffset", "DzGetTerrainZ", "DzUnitCanPlaceAround", "DzPositionCanPlaceAround",
        "DzSetUnitLifeRegen", "DzGetUnitLifeRegen", "DzSetUnitManaRegen", "DzGetUnitManaRegen",
        "DzSetUnitMinSpeed", "DzGetUnitMinSpeed", "DzSetUnitMaxSpeed", "DzGetUnitMaxSpeed",
        "DzSetUnitCastPoint", "DzGetUnitCastPoint", "DzSetUnitBackSwing", "DzGetUnitBackSwing",
        "DzSetUnitAttackTargetCount", "DzGetUnitAttackTargetCount",
        "DzSetHeroPrimaryAttributeType", "DzGetHeroPrimaryAttributeType",
        "DzSetHeroPrimaryAttribute", "DzGetHeroPrimaryAttribute",
        "DzSetHeroPrimaryAttributePlus", "DzGetHeroPrimaryAttributePlus",
        "DzSetUnitAbilityCastTime", "DzGetUnitAbilityCastTime",
        "DzSetUnitAbilityOrderId", "DzGetUnitAbilityOrderId",
        "DzItemSetVertexColor", "DzItemGetVertexColor", "DzItemSetAlpha", "DzItemSetSize", "DzItemGetSize",
        "DzSetItemCollisionSize", "DzGetItemCollisionSize",
        "DzTextTagSetStartAlpha", "DzTextTagSetShadowColor", "DzTextTagGetShadowColor",
        "DzTextTagSetFont", "DzTextTagGetFont",
        "DzUnitHasAbility",
        "DzSetUnitAbilityRange", "DzGetUnitAbilityRange",
        "DzSetUnitAbilityArea", "DzGetUnitAbilityArea",
        "DzSetUnitAbilityCool", "DzGetUnitAbilityCool",
        "DzSetUnitAbilityCost", "DzGetUnitAbilityCost",
        "DzSetUnitAbilityTip", "DzGetUnitAbilityTip",
        "DzSetUnitAbilityUberTip", "DzGetUnitAbilityUberTip",
        "DzSetUnitAbilityEnable", "DzSetUnitAbilityDisable",
        "DzSetUnitAbilityCastPoint", "DzGetUnitAbilityCastPoint",
        "DzSetUnitAbilityBackSwing", "DzGetUnitAbilityBackSwing",
        "DzSetUnitAbilityMissileSpeed", "DzGetUnitAbilityMissileSpeed",
        "DzSetUnitAbilityMissileArc", "DzGetUnitAbilityMissileArc",
        "DzSetUnitAbilityMissileArt", "DzGetUnitAbilityMissileArt",
        "DzSetUnitAbilityReqLevel", "DzGetUnitAbilityReqLevel",
        "DzSetUnitAbilityDuration", "DzGetUnitAbilityDuration",
        "DzSetUnitAbilityHeroDuration", "DzGetUnitAbilityHeroDuration",
        "DzSetUnitAbilityArt", "DzGetUnitAbilityArt", "DzSetUnitAbilityButtonPos", "DzAbilitySetStringData",
        "DzAbilitySetEnable",
        // DzCompat_StringBit.j
        "DzBitAnd", "DzBitOr", "DzBitXor", "DzBitNot", "DzBitShiftLeft", "DzBitShiftRight",
        "DzBitGetByte", "DzBitSetByte", "DzBitGet", "DzBitSet", "DzBitToInt",
        "DzStringFind", "DzStringContains", "DzStringFindFirstOf", "DzStringFindFirstNotOf",
        "DzStringFindLastOf", "DzStringFindLastNotOf",
        "DzStringTrimLeft", "DzStringTrimRight", "DzStringTrim", "DzStringReverse",
        "DzStringReplace", "DzStringInsert",
        // DzCompat_YDWE_EX.j - YDWE / yd_jass_api "EX*" extended natives
        "EXGetUnitAbility", "EXGetUnitAbilityByIndex", "EXGetAbilityId",
        "EXGetAbilityState", "EXSetAbilityState",
        "EXGetAbilityDataReal", "EXSetAbilityDataReal",
        "EXGetAbilityDataInteger", "EXSetAbilityDataInteger",
        "EXGetAbilityDataString", "EXSetAbilityDataString",
        "EXGetAbilityString", "EXSetAbilityString",
        "EXSetAbilityAEmeDataA",
        "EXGetBuffDataString", "EXSetBuffDataString",
        "EXGetEffectX", "EXGetEffectY", "EXGetEffectZ",
        "EXSetEffectXY", "EXSetEffectZ", "EXGetEffectSize", "EXSetEffectSize",
        "EXEffectMatRotateX", "EXEffectMatRotateY", "EXEffectMatRotateZ",
        "EXEffectMatScale", "EXEffectMatReset", "EXSetEffectSpeed",
        "EXGetItemDataString", "EXSetItemDataString",
        "EXGetEventDamageData", "EXSetEventDamage",
        "EXSetUnitFacing", "EXPauseUnit", "EXSetUnitCollisionType", "EXSetUnitMoveType",
        "EXGetUnitString", "EXSetUnitString", "EXGetUnitReal", "EXSetUnitReal",
        "EXGetUnitInteger", "EXSetUnitInteger",
        "EXGetUnitArrayString", "EXSetUnitArrayString",
        "EXDisplayChat",
        // DzCompat_Lua.j - EXExecuteScript (jass.slk object-data reads only)
        "EXExecuteScript",
        // RequestExtra
        "RequestExtraIntegerDataa", "RequestExtraBooleanDataa",
        "RequestExtraStringDataa", "RequestExtraRealDataa",
        // mouse-button / key-getters
        "DzTriggerRegisterKeyEventByCode", "DzTriggerRegisterKeyEvent",
        "DzTriggerRegisterMouseEvent", "DzGetTriggerKeyPlayer", "DzGetTriggerKey",
        "DzTriggerRegisterMouseMoveEvent", "DzTriggerRegisterMouseMoveEventByCode",
        "DzTriggerRegisterMouseWheelEventByCode", "DzTriggerRegisterMouseWheelEvent",
        "DzGetWheelDelta", "DzSetUnitModel", "DzGetMouseFocus", "DzTriggerRegisterMouseEventByCode", 
        "DzFrameSetUpdateCallbackByCode", "DzFrameSetUpdateCallback", "DzGetUnitUnderMouse",
		"DzCompat_MouseLMBCondition", "DzCompat_MouseRMBCondition", "DzGetMouseX", "DzGetMouseY",
		"DzGetMouseXRelative", "DzGetMouseYRelative",
        // Trivial helpers + OSKEY conversion 
        "DzTriggerRegisterKeyEventTrg", "DzTriggerRegisterMouseWheelEventTrg",
        // DzCompat_Archive.j direct Map API entry points
        "DzAPI_Map_SaveServerValue", "DzAPI_Map_GetServerValue",
        "DzAPI_Map_GetServerValueErrorCode",
        "DzAPI_Map_StoreString", "DzAPI_Map_StoreInteger", "DzAPI_Map_StoreReal", "DzAPI_Map_StoreBoolean",
        "DzAPI_Map_GetStoredString", "DzAPI_Map_GetStoredInteger", "DzAPI_Map_GetStoredReal", "DzAPI_Map_GetStoredBoolean",
		// DzCompat_Core.j - a native that some environments (YDWE / AI script natives) provide
        "UnitAlive"
    ));

    static final String[] LIB_FILES = {
        "DzCompat_Core.j",
        "DzCompat_Frame.j",
        "DzCompat_Sync.j",
        "DzCompat_UnitEffect.j",
        "DzCompat_Input.j",
		"DzCompat_YDWE_EX.j",
        "DzCompat_Ability.j",
        "DzCompat_StringBit.j",
        "DzCompat_Stats.j",
		"DzCompat_Lua.j",
        "DzCompat_Archive.j",
        "DzCompat_Platform.j",
        "DzCompat_RequestExtra.j"
    };

    static final String[][] RENAME_PAIRS = {
        {"RequestExtraIntegerData", "RequestExtraIntegerDataa"},
        {"RequestExtraBooleanData", "RequestExtraBooleanDataa"},
        {"RequestExtraRealData", "RequestExtraRealDataa"},
        {"RequestExtraStringData", "RequestExtraStringDataa"}
    };

    /** Natives whose real implementations are gated behind the Unlock checkbox.
     *  When Unlock is off, these use the real archive-backed implementations in
     *  DzCompat_Platform.j; when on, they fall through to the UI stubs. */
    static final Set<String> UNLOCK_GATED_NATIVES = new LinkedHashSet<>(Arrays.asList(
        "DzAPI_Map_GetMapLevel",
        "DzAPI_Map_HasMallItem",
        "DzAPI_Map_GetGuildName"
    ));
}
