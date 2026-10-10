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
		"DzGetWindowWidth", "DzGetWindowHeight", "DzIsWindowActive", "DzFrameGetUpperButtonBarButton",
        // UnitEffect / Sync
        "DzSyncData", "DzSyncDataImmediately", "DzSyncBuffer", "DzTriggerRegisterSyncData",
        "DzGetTriggerSyncPrefix", "DzGetTriggerSyncData", "DzGetTriggerSyncPlayer", "DzExecuteFunc",
        "DzGetMouseTerrainX", "DzGetMouseTerrainY", "DzGetMouseTerrainZ", 
        "DzUnitChangeAlpha", "DzUnitDisableAttack", "DzUnitSilence", "DzUnitSetCanSelect", "DzUnitSetTargetable",
        "DzUnitSetMoveType",
        "DzGetItemAbility", "DzSetUnitName", "DzGetUnitCollisionSize", "DzGetUnitZ", "DzKillUnit",
        "DzSetMousePos", "DzSetUnitPosition", "DzSetUnitXY", "DzGetLocale",
        "DzSetUnitMissileSpeed", "DzSetUnitMissileArc", "DzSetUnitMissileHoming", "DzSetUnitMissileModel",
        "DzSetUnitProperName", "DzWidgetSetMinimapIcon",
        "DzSetEffectPos", "DzSetEffectScale", "DzSetEffectVertexAlpha", "DzSetEffectVertexColor",
        "DzPlayEffectAnimation", "DzSetEffectVisible",
        "DzReviveUnit", "DzSetUnitDataCacheInteger",
        "DzUnitOrdersClear", "DzUnitOrdersCount", "DzUnitOrdersForceStop",
        "DzGroupGetCount", "DzGroupGetUnitAt", "DzRemoveEffect", "DzRemoveEffectTimed", "DzDieEffectTimed",
        "DzSaveHandleId", "DzLoadHandleId", "DzSaveHandleIdEx",
        "DzQueueIssueImmediateOrderById", "DzQueueIssuePointOrderById", "DzQueueIssueTargetOrderById",
        "DzQueueIssueInstantPointOrderById", "DzQueueIssueInstantTargetOrderById", "DzQueueIssueBuildOrderById",
        "DzQueueIssueNeutralImmediateOrderById", "DzQueueIssueNeutralPointOrderById", "DzQueueIssueNeutralTargetOrderById",
        "DzQueueGroupImmediateOrderById", "DzQueueGroupPointOrderById", "DzQueueGroupTargetOrderById",
        "DzAttackAbilityEndCooldown", "DzGetTriggerMallItem", "DzGetTriggerMallItemPlayer",
		"DzTriggerRegisterMallItemSyncData", "DzTriggerRegisterMallItemConsumeEvent", "DzTriggerRegisterMallItemRemoveEvent",
        // DzCompat_Stats.j
        "DzSetUnitDescription", "DzSetUnitPortrait", "DzSetUnitCollisionSize", "DzSetUnitSelectScale",
        "DzSetUnitHitIgnore", "DzGetUnitOverheadOffset", "DzGetTerrainZ", "DzUnitCanPlaceAround", "DzPositionCanPlaceAround",
        "DzSetUnitLifeRegen", "DzGetUnitLifeRegen", "DzSetUnitManaRegen", "DzGetUnitManaRegen",
        "DzSetUnitMinSpeed", "DzGetUnitMinSpeed", "DzSetUnitMaxSpeed", "DzGetUnitMaxSpeed",
        "DzSetUnitCastPoint", "DzGetUnitCastPoint", "DzSetUnitBackSwing", "DzGetUnitBackSwing",
        "DzSetUnitAttackTargetCount", "DzGetUnitAttackTargetCount",
        "DzSetHeroPrimaryAttributeType", "DzGetHeroPrimaryAttributeType",
        "DzSetHeroPrimaryAttribute", "DzGetHeroPrimaryAttribute",
        "DzSetHeroPrimaryAttributePlus", "DzGetHeroPrimaryAttributePlus", "DzGetUnitNeededXP",
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
        "EXGetUnitAbility", "EXGetUnitAbilityByIndex", "EXGetAbilityId", "DzUnitFindAbility",
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
        // DzCompat_YDWE_EX.j - effect color / visibility / animation, unit alias natives
        "EXSetEffectColor", "EXSetEffectVisible", "EXPlayEffectAnimation",
        "SetUnitName", "SetUnitModel", "SetUnitMissileModel",
        // DzCompat_UnitEffect.j / DzCompat_Frame.j
        "DzSetEffectAnimation", "DzSetWar3MapMap",
        // DzCompat_StringBit.j - plain-name bit operations
        "BitAnd", "BitOr", "BitXor", "BitShiftL", "BitShiftR",
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
		"DzGetMouseXRelative", "DzGetMouseYRelative", "DzIsKeyDown", 
		"DzTriggerRegisterMouseEventTrg", "DzTriggerRegisterMouseMoveEventTrg",
        // Trivial helpers + OSKEY conversion 
        "DzTriggerRegisterKeyEventTrg", "DzTriggerRegisterMouseWheelEventTrg",
        // DzCompat_Archive.j direct Map API entry points
        "DzAPI_Map_SaveServerValue", "DzAPI_Map_GetServerValue",
        "DzAPI_Map_GetServerValueErrorCode",
        "DzAPI_Map_StoreString", "DzAPI_Map_StoreInteger", "DzAPI_Map_StoreReal", "DzAPI_Map_StoreBoolean",
        "DzAPI_Map_GetStoredString", "DzAPI_Map_GetStoredInteger", "DzAPI_Map_GetStoredReal", "DzAPI_Map_GetStoredBoolean",
        // DzCompat_Platform.j - platform answers the real client registers as natives (lobby, VIP, public archive)
        "DzAPI_Map_IsRPGLobby", "DzAPI_Map_IsRedVIP", "DzAPI_Map_IsBlueVIP", "DzAPI_Map_GetPlatformVIP",
        "DzAPI_Map_SavePublicArchive", "DzAPI_Map_GetPublicArchive",
		// DzCompat_Core.j - a native that some environments (YDWE / AI script natives) provide
        "UnitAlive", "DzF2I", "DzI2F", "DzK2I", "DzI2K",
        // DzCompat_JN.j - JN (JassNative) strings, base64, stopwatch, casts, login answers
        "JNStringLength", "JNStringPos", "JNStringContains", "JNStringSub", "JNStringSplit",
        "JNStringCount", "JNStringReverse", "JNStringTrimStart", "JNStringTrimEnd", "JNStringTrim",
        "JNStringInsert", "JNStringReplace", "JNStringCalcLines",
        "JNStringToBase64", "JNStringFromBase64", "JNStringBase64Encoding",
        "JNStringEncrypt", "JNStringDecrypt",
        "JNStopwatchCreate", "JNStopwatchStart", "JNStopwatchPause", "JNStopwatchReset",
        "JNStopwatchDestroy", "JNStopwatchElapsedMS", "JNStopwatchElapsedSecond",
        "JNStopwatchElapsedMinute", "JNStopwatchElapsedHour",
        "JNI2R", "JNR2I", "JNOpenBrowser",
        "JNGetMaxAttackSpeed", "JNSetMaxAttackSpeed", "JNGetSyncDelay", "JNSetSyncDelay",
        "JNGetSettingLogin", "JNGetSettingLoginID", "JNLocalLogin", "JNLogin",
        "JNObjectCharacterServerConnectCheck", "JNGetConnectionState"
    ));

    /** Natives that read or write the local archive (DzCompat_Archive.j). With "Remove local
     *  save" on they are never given a real implementation: they are stubbed like any other
     *  unimplemented native, so nothing is saved and no file is written.
     *  (The UNLOCK_GATED_NATIVES below are archive-backed too and are stubbed as well.) */
    static final Set<String> LOCAL_SAVE_NATIVES = new LinkedHashSet<>(Arrays.asList(
        "DzAPI_Map_SaveServerValue", "DzAPI_Map_GetServerValue",
        "DzAPI_Map_GetServerValueErrorCode",
        "DzAPI_Map_StoreString", "DzAPI_Map_StoreInteger", "DzAPI_Map_StoreReal", "DzAPI_Map_StoreBoolean",
        "DzAPI_Map_GetStoredString", "DzAPI_Map_GetStoredInteger", "DzAPI_Map_GetStoredReal", "DzAPI_Map_GetStoredBoolean",
        "DzAPI_Map_SavePublicArchive", "DzAPI_Map_GetPublicArchive"
    ));

    /** With "Remove local save" on, these archive functions are replaced by empty bodies. They are
     *  the only doors into the archive (everything else - RequestExtra*Data save/load types,
     *  DzServer_* helpers - goes through them), so with them empty the rest of DzCompat_Archive.j
     *  is never pulled into the output. */
    static final String[][] LOCAL_SAVE_ENTRY_STUBS = {
        {"DzCompat_Archive_Save",  "function DzCompat_Archive_Save takes player whichPlayer, string key, string value returns boolean", "    return false"},
        {"DzCompat_Archive_Load",  "function DzCompat_Archive_Load takes player whichPlayer, string key returns string", "    return \"\""},
        {"DzCompat_Archive_Flush", "function DzCompat_Archive_Flush takes nothing returns nothing", null}
    };

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
        "DzCompat_ExtendedUnitState.j",
		"DzCompat_Lua.j",
        "DzCompat_Archive.j",
        "DzCompat_Platform.j",
        "DzCompat_RequestExtra.j",
        "DzCompat_JN.j"
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
