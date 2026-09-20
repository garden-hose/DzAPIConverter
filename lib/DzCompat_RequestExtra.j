// ============================================================================
// DzCompat_RequestExtra.j
// Real implementations for the DzAPI/KKAPI generic "extra data" natives.
//
// Every dataType that represents player/server state is routed through
// DzCompat_Archive.j / DzCompat_PlatformStubs.j (local server emulation).
// Session-only platform facts use the gDzServer_* globals.
// Payment / store UI APIs return explicit local failure.
// ============================================================================

function RequestExtraIntegerDataa takes integer dataType, player whichPlayer, string param1, string param2, boolean param3, integer param4, integer param5, integer param6 returns integer
        if dataType == 1 then // MissionComplete (write, return value unused by caller)
            call DzAPI_Map_MissionComplete(whichPlayer, param1, param2)
            return 0
		elseif dataType == 3 then // GetMapLevel
			return DzAPI_Map_GetMapLevel(whichPlayer)
        elseif dataType == 6 then // GetServerValueErrorCode - 0 = success/no-error
            return DzAPI_Map_GetServerValueErrorCode(whichPlayer)
        elseif dataType == 7 then // Stat_SetStat (write, return value unused by caller)
            call DzAPI_Map_Stat_SetStat(whichPlayer, param1, param2)
            return 0
        elseif dataType == 8 then // Ladder_SetStat (Write, return value unused by caller)
            call DzAPI_Map_Ladder_SetStat(whichPlayer, param1, param2)
            return 0
        elseif dataType == 9 then // Ladder_SetPlayerStat (Write, return value unused by caller)
            call DzAPI_Map_Ladder_SetPlayerStat(whichPlayer, param1, param2)
            return 0
        elseif dataType == 11 then // GetGameStartTime
            return DzAPI_Map_GetGameStartTime()
        elseif dataType == 13 then // GetMatchType
            return DzAPI_Map_GetMatchType()
        elseif dataType == 14 then // GetLadderLevel
            return DzAPI_Map_GetLadderLevel(whichPlayer)
        elseif dataType == 17 then // GetLadderRank
            return DzAPI_Map_GetLadderRank(whichPlayer)
        elseif dataType == 18 then // GetMapLevelRank
            return DzAPI_Map_GetMapLevelRank(whichPlayer)
        elseif dataType == 20 then // GetGuildRole (Member=10/Admin=20/Leader=30 in the real API - 0 reads as "no guild")
            return DzAPI_Map_GetGuildRole(whichPlayer)
        elseif dataType == 26 then // GetServerArchiveEquip
            return DzAPI_Map_GetServerArchiveEquip(whichPlayer, param1)
        elseif dataType == 29 then // GetUserID (per jassdoc's reforged-dzapi.j; GetPlayerId gives a stable per-match integer instead of 0, which would otherwise collide every player onto the same "user id"
            return DzAPI_Map_GetUserID(whichPlayer)
        elseif dataType == 28 then // OrpgTrigger (write, return value unused by caller - store flag)
            call DzServer_Set(whichPlayer, "ORPG_" + param1, param2)
            return 0
        elseif dataType == 30 then // GetPlatformVIP - 0 keeps DzAPI_Map_IsPlatformVIP(p) false too
            return DzAPI_Map_GetPlatformVIP(whichPlayer)
        elseif dataType == 33 then // UseConsumablesItem (write, return value unused by caller)
            if DzAPI_Map_ConsumeMallItem(whichPlayer, param1, 1) then
                return 1
            endif
            return 0
        elseif dataType == 41 then // GetMallItemCount
            return DzAPI_Map_GetMallItemCount(whichPlayer, param1)
        elseif dataType == 45 then // PlayedGames
            return DzAPI_Map_PlayedGames(whichPlayer)
        elseif dataType == 46 then // CommentCount
            return DzAPI_Map_CommentCount(whichPlayer)
        elseif dataType == 47 then // FriendCount
            return DzAPI_Map_FriendCount(whichPlayer)
        elseif dataType == 51 then // CommentTotalCount
            return DzServer_GetInt(whichPlayer, "COMMENT_TOTAL", 0)
        elseif dataType == 52 then // CommentTotalCount1
            return DzServer_GetInt(whichPlayer, "COMMENT_TOTAL1", 0)
        elseif dataType == 54 then // ContinuousCount
            return DzAPI_Map_ContinuousCount(whichPlayer)
        elseif dataType == 56 then // MapsTotalPlayed
            return DzAPI_Map_MapsTotalPlayed(whichPlayer)
        elseif dataType == 57 then // MapsLevel
            return DzAPI_Map_MapsLevel(whichPlayer)
        elseif dataType == 58 then // MapsConsumeGold
            return DzAPI_Map_MapsConsumeGold(whichPlayer)
        elseif dataType == 59 then // MapsConsumeLumber
            return DzAPI_Map_MapsConsumeLumber(whichPlayer)
        elseif dataType == 65 then // GetForumData
            return DzServer_GetInt(whichPlayer, "FORUM_" + param1, 0)
        elseif dataType == 68 then // GetLotteryUsedCountEx
            return DzServer_GetInt(whichPlayer, "LOTTERY", 0)
        elseif dataType == 69 then // GameResult_CommitData (write, return value unused by caller)
            call DzServer_Set(whichPlayer, "GAMERESULT_" + param1, param2)
		elseif dataType == 70 then // GetSinceLastPlayedSeconds
            return 0
        elseif dataType == 78 then // CustomRankCount
            return 0
        elseif dataType == 80 then // CustomRankValue
            return 0
        elseif dataType == 82 then // KKApiGetServerValueLimitLeft
            return DzServer_GetInt(whichPlayer, "SVLIMIT_" + param1, 999999)
		elseif dataType == 85 then // KKApiGetBackendLogicIntResult
            return 0
        elseif dataType == 87 then // KKApiGetBackendLogicUpdateTime
            return 0
        elseif dataType == 94 then // KKApiIsTaskInProgress compares this against taskstat with '==' ; -1 never matches a real status so the wrapper always reads as "not in progress"
            return -1
        elseif dataType == 95 then // KKApiQueryTaskCurrentProgress
            return 0
        elseif dataType == 96 then // KKApiQueryTaskTotalProgress
            return 0
        elseif dataType == 99 then // KKApiAchievementPoints
            return 0
        elseif dataType == 101 then // KKApiRandomSaveGameCount
            return 0
        elseif dataType == 106 then // KKApiGetGuildLevel
            return 0
        elseif dataType == 107 then // KKApiMapExplorationNum
            return 0
        elseif dataType == 108 then // KKApiMapExplorationTime
            return 0
        elseif dataType == 109 then // KKApiMapOrderNum
            return 0
        elseif dataType == 110 then // KKApiGetMallItemUpdateCount
            return 0
        elseif dataType == 113 then // KKApiDayRounds
            return 0
        elseif dataType == 115 then // KKApiConsumeLevel
            return 0
        elseif dataType == 120 then // KKApiBountyRank
            return 0
        elseif dataType == 121 then // KKApiBountyValue
            return 0
        else
            return 0
        endif
endfunction

function RequestExtraBooleanDataa takes integer dataType, player whichPlayer, string param1, string param2, boolean param3, integer param4, integer param5, integer param6 returns boolean
        if dataType == 4 then // SaveServerValue - persist to local text file via DzCompat_Archive
            return DzCompat_Archive_Save(whichPlayer, param1, param2)
        elseif dataType == 10 then // IsRPGLobby
            return DzAPI_Map_IsRPGLobby()
        elseif dataType == 12 then // IsRPGLadder
            return DzAPI_Map_IsRPGLadder()
        elseif dataType == 31 then // SavePublicArchive - also route through local archive
            return DzCompat_Archive_Save(whichPlayer, "PUB_" + param1, param2)
        elseif dataType == 34 then // Statistics - fire-and-forget telemetry, report success
            call DzServer_Set(whichPlayer, "STATISTIC_" + param1, param2)
            return true
        elseif dataType == 37 then // Global_StoreString - route through local archive under a global namespace
            return DzCompat_Archive_Save(Player(PLAYER_NEUTRAL_PASSIVE), "G_" + param1, param2)
        elseif dataType == 39 then // SaveServerArchive / StoreIntegerEX / StoreStringEX - case-sensitive archive
            return DzCompat_Archive_Save(whichPlayer, "CS_" + param1, param2)
        elseif dataType == 40 then // IsRPGQuickMatch
            return DzAPI_Map_IsRPGQuickMatch()
        elseif dataType == 42 then // ConsumeMallItem - report success so consumable-gated logic doesn't stall on a purchase that will never happen
            return DzAPI_Map_ConsumeMallItem(whichPlayer, param1, param4)
        elseif dataType == 43 then // EnablePlatformSettings - report success, see note on dataType 42
            return DzAPI_Map_EnablePlatformSettings(whichPlayer, param4)
        elseif dataType == 48 then // IsConnoisseur (special platform badge) - false, don't hand out an unearned badge
            return DzAPI_Map_IsConnoisseur(whichPlayer)
        elseif dataType == 50 then // IsAuthor (map-author flag) - false, don't grant author-only powers to everyone
            return DzAPI_Map_IsAuthor(whichPlayer)
        elseif dataType == 53 then // PlayerFlags / Returns - bit-flag query, default "flag not set"
            return DzServer_GetBool(whichPlayer, "PFLAG_" + I2S(param4))
        elseif dataType == 55 then // IsPlayer
            return DzAPI_Map_IsPlayer(whichPlayer)
        elseif dataType == 60 then // MapsConsumeLv1
            return DzServer_GetBool(whichPlayer, "CONSUME_LV1")
        elseif dataType == 61 then // MapsConsumeLv2
            return DzServer_GetBool(whichPlayer, "CONSUME_LV2")
        elseif dataType == 62 then // MapsConsumeLv3
            return DzServer_GetBool(whichPlayer, "CONSUME_LV3")
        elseif dataType == 63 then // MapsConsumeLv4
            return DzServer_GetBool(whichPlayer, "CONSUME_LV4")
        elseif dataType == 64 then // IsPlayerUsingSkin - don't render a cosmetic nobody actually equipped
            return DzServer_GetBool(whichPlayer, "USING_SKIN_" + param1)
        elseif dataType == 66 then // OpenMall - fake
            return DzAPI_Map_OpenMall(whichPlayer)
        elseif dataType == 72 then // QuickBuy - fake
            return DzAPI_Map_QuickBuy(whichPlayer, param1)
        elseif dataType == 73 then // CancelQuickBuy - see note on dataType 72
            return DzAPI_Map_CancelQuickBuy(whichPlayer)
        elseif dataType == 74 then // IsMapTest
            return DzAPI_Map_IsMapTest()
        elseif dataType == 77 then // PlayerLoadedItems
            return DzServer_GetBool(whichPlayer, "ITEMS_LOADED")
        elseif dataType == 83 then // KKApiRequestBackendLogic
            call DzServer_Set(whichPlayer, "BACKEND_" + param1, param2)
            return true
        elseif dataType == 84 then // KKApiCheckBackendLogicExists
            return DzServer_Get(whichPlayer, "BACKEND_" + param1) != ""
        elseif dataType == 89 then // KKApiRemoveBackendLogicResult
            call DzServer_Set(whichPlayer, "BACKEND_" + param1, "")
            return true
        elseif dataType == 90 then // KKApiIsGameMode
            return DzServer_GetBool(Player(PLAYER_NEUTRAL_PASSIVE), "GAMEMODE_" + param1)
        elseif dataType == 91 then // KKApiInitializeGameKey
            call DzServer_Set(Player(PLAYER_NEUTRAL_PASSIVE), "GAMEKEY_" + param1, param2)
            return true
        elseif dataType == 92 then // KKApiPlayerIdentityType (VIP)
            if param4 == 4 then
                return DzAPI_Map_IsRedVIP(whichPlayer)
            elseif param4 == 3 then
                return DzAPI_Map_IsBlueVIP(whichPlayer)
            endif
            return DzAPI_Map_IsPlatformVIP(whichPlayer)
        elseif dataType == 98 then // KKApiIsAchievementCompleted
            return DzAPI_Map_IsAchievementCompleted(whichPlayer, param1)
        elseif dataType == 100 then // KKApiPlayedTime
            return DzServer_GetInt(whichPlayer, "PLAYED_TIME", 0) > 0
        elseif dataType == 102 then // KKApiBeginBatchSaveArchive
            return KKApiBeginBatchSaveArchive(whichPlayer)
        elseif dataType == 103 then // KKApiAddBatchSaveArchive
            return KKApiAddBatchSaveArchive(whichPlayer, param1, param2)
        elseif dataType == 104 then // KKApiEndBatchSaveArchive
            return KKApiEndBatchSaveArchive(whichPlayer)
        elseif dataType == 117 then // KKApiIsPinned
            return DzServer_GetBool(whichPlayer, "PINNED")
        elseif dataType == 1009 then // KKApiMlScriptEvent
            call DzServer_Set(whichPlayer, "ML_" + param1, param2)
            return true
        else
            return false
        endif
endfunction

function RequestExtraStringDataa takes integer dataType, player whichPlayer, string param1, string param2, boolean param3, integer param4, integer param5, integer param6 returns string
        if dataType == 2 then // GetActivityData
            return ""
        elseif dataType == 5 then // GetServerValue
            return DzCompat_Archive_Load(whichPlayer, param1)
        elseif dataType == 19 then // GetGuildName
            return DzAPI_Map_GetGuildName(whichPlayer)
        elseif dataType == 21 then // GetMapConfig
            return DzAPI_Map_GetMapConfig(param1)
        elseif dataType == 27 then // GetServerArchiveDrop
            return DzAPI_Map_GetServerArchiveDrop(whichPlayer, param1)
        elseif dataType == 32 then // GetPublicArchive
            return DzCompat_Archive_Load(whichPlayer, "PUB_" + param1)
        elseif dataType == 35 then // SystemArchive
            return DzCompat_Archive_Load(Player(PLAYER_NEUTRAL_PASSIVE), "SYS_" + param1)
        elseif dataType == 36 then // Global_GetStoreString
            return DzCompat_Archive_Load(Player(PLAYER_NEUTRAL_PASSIVE), "G_" + param1)
        elseif dataType == 38 then // case-sensitive archive get
            return DzCompat_Archive_Load(whichPlayer, "CS_" + param1)
        elseif dataType == 79 then // CustomRankPlayerName
            return DzServer_Get(whichPlayer, "RANKNAME_" + param1)
        elseif dataType == 81 then // GetPlayerUserName
            return DzAPI_Map_GetPlayerUserName(whichPlayer)
        elseif dataType == 86 then // KKApiGetBackendLogicStrResult
            return DzServer_Get(whichPlayer, "BACKEND_" + param1)
        elseif dataType == 88 then // KKApiGetBackendLogicGroup
            return DzServer_Get(whichPlayer, "BACKEND_GRP_" + param1)
        elseif dataType == 93 then // KKApiPlayerGUID
            return I2S(DzAPI_Map_GetUserID(whichPlayer))
        elseif dataType == 111 then // KKApiGetMapVersion
            return DzServer_Get(Player(PLAYER_NEUTRAL_PASSIVE), "MAP_VERSION")
        elseif dataType == 112 then // KKApiGetCompetitionGameMode
            return DzServer_Get(Player(PLAYER_NEUTRAL_PASSIVE), "COMP_MODE")
        else
            return ""
        endif
endfunction

function RequestExtraRealDataa takes integer dataType, player whichPlayer, string param1, string param2, boolean param3, integer param4, integer param5, integer param6 returns real
        // No DzAPI.j dataTypes currently use RealData for server state; archive-backed slot reserved
        if dataType == 0 then
            return S2R(DzCompat_Archive_Load(whichPlayer, "REAL_" + param1))
        endif
        return 0.00
endfunction
