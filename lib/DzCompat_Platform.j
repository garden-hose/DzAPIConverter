// ============================================================================
// DzCompat_Platform.j
// Local "server" emulation layer for DzAPI_Map_* / KKApi* platform APIs.
//
// Goal: completely emulate the remote server on the client using
// DzCompat_Archive.j (persistent text file) plus a few session defaults.
//
// Key namespaces inside the archive (per player unless noted):
//   STAT_<k>           map stats
//   LADDER_<k>         ladder stats
//   LADDERP_<k>        ladder player stats
//   MALL_<item>        owned flag ("1")
//   MALLC_<item>       mall item count
//   LEVEL              map level
//   LEVELRANK          map level rank
//   LADDERLV / LADDERRANK
//   PLAYED             games played
//   MAPS_PLAYED / MAPS_LEVEL / MAPS_GOLD / MAPS_LUMBER
//   ACH_<id>           achievement completed
//   VIP / REDVIP / BLUEVIP / PLATFORM_VIP
//   GUILD_NAME / GUILD_ROLE
//   EQUIP_<slot>       server archive equip (integer as string)
//   DROP_<k>           server archive drop string
//   MISSION_<k>        mission complete flag
//   CFG_<k>            map config strings (neutral player)
// ============================================================================

globals
    integer gDzServer_MatchType = 0
    boolean gDzServer_IsRPGLadder = false
    boolean gDzServer_IsRPGLobby = false
    boolean gDzServer_IsRPGQuickMatch = false
    boolean gDzServer_IsMapTest = false
    integer gDzServer_GameStartTime = 0
    string  gDzServer_DefaultGuildName = ""
    integer gDzServer_DefaultGuildRole = 0
    integer gDzServer_DefaultMapLevel = 0
    hashtable gDzServer_Batch = InitHashtable()
    integer gDzServer_BatchCount = 0
    boolean gDzServer_BatchOpen = false
endglobals

function DzServer_Set takes player p, string key, string value returns boolean
    return DzCompat_Archive_Save(p, key, value)
endfunction

function DzServer_Get takes player p, string key returns string
    return DzCompat_Archive_Load(p, key)
endfunction

function DzServer_GetInt takes player p, string key, integer defaultVal returns integer
    local string s = DzCompat_Archive_Load(p, key)
    if s == null or s == "" then
        return defaultVal
    endif
    return S2I(s)
endfunction

function DzServer_SetInt takes player p, string key, integer value returns nothing
    call DzCompat_Archive_Save(p, key, I2S(value))
endfunction

function DzServer_GetBool takes player p, string key returns boolean
    return DzCompat_Archive_Load(p, key) == "1"
endfunction

function DzServer_SetBool takes player p, string key, boolean value returns nothing
    if value then
        call DzCompat_Archive_Save(p, key, "1")
    else
        call DzCompat_Archive_Save(p, key, "0")
    endif
endfunction

function DzAPI_Map_GetMapLevel takes player whichPlayer returns integer
    return DzServer_GetInt(whichPlayer, "LEVEL", gDzServer_DefaultMapLevel)
endfunction

function DzAPI_Map_GetMapLevelRank takes player whichPlayer returns integer
    return DzServer_GetInt(whichPlayer, "LEVELRANK", 0)
endfunction

function DzAPI_Map_Stat_SetStat takes player whichPlayer, string key, string value returns nothing
    call DzServer_Set(whichPlayer, "STAT_" + key, value)
endfunction

function DzAPI_Map_Ladder_SetStat takes player whichPlayer, string key, string value returns nothing
    call DzServer_Set(whichPlayer, "LADDER_" + key, value)
endfunction

function DzAPI_Map_Ladder_SetPlayerStat takes player whichPlayer, string key, string value returns nothing
    call DzServer_Set(whichPlayer, "LADDERP_" + key, value)
endfunction

function DzAPI_Map_Ladder_SubmitIntegerData takes player whichPlayer, string key, integer value returns nothing
    call DzAPI_Map_Ladder_SetStat(whichPlayer, key, I2S(value))
endfunction

function DzAPI_Map_Ladder_SubmitTitle takes player whichPlayer, string value returns nothing
    call DzAPI_Map_Ladder_SetStat(whichPlayer, value, "1")
endfunction

function DzAPI_Map_Ladder_SubmitPlayerRank takes player whichPlayer, integer value returns nothing
    call DzAPI_Map_Ladder_SetPlayerStat(whichPlayer, "RankIndex", I2S(value))
endfunction

function DzAPI_Map_GetLadderLevel takes player whichPlayer returns integer
    return DzServer_GetInt(whichPlayer, "LADDERLV", 0)
endfunction

function DzAPI_Map_GetLadderRank takes player whichPlayer returns integer
    return DzServer_GetInt(whichPlayer, "LADDERRANK", 0)
endfunction

function DzAPI_Map_MissionComplete takes player whichPlayer, string key, string value returns nothing
    call DzServer_Set(whichPlayer, "MISSION_" + key, value)
endfunction

function DzAPI_Map_HasMallItem takes player whichPlayer, string key returns boolean
    if DzServer_GetBool(whichPlayer, "MALL_" + key) then
        return true
    endif
    if DzServer_GetInt(whichPlayer, "MALLC_" + key, 0) > 0 then
        return true
    endif
    return false
endfunction

function DzAPI_Map_GetMallItemCount takes player whichPlayer, string key returns integer
    return DzServer_GetInt(whichPlayer, "MALLC_" + key, 0)
endfunction

function DzAPI_Map_ConsumeMallItem takes player whichPlayer, string key, integer count returns boolean
    local integer have = DzServer_GetInt(whichPlayer, "MALLC_" + key, 0)
    if have < count then
        return false
    endif
    set have = have - count
    call DzServer_SetInt(whichPlayer, "MALLC_" + key, have)
    if have <= 0 then
        call DzServer_SetBool(whichPlayer, "MALL_" + key, false)
    endif
    return true
endfunction

function DzAPI_Map_LocalGrantMallItem takes player whichPlayer, string key, integer count returns nothing
    local integer have = DzServer_GetInt(whichPlayer, "MALLC_" + key, 0)
    call DzServer_SetInt(whichPlayer, "MALLC_" + key, have + count)
    call DzServer_SetBool(whichPlayer, "MALL_" + key, true)
endfunction

function DzAPI_Map_PlayedGames takes player whichPlayer returns integer
    return DzServer_GetInt(whichPlayer, "PLAYED", 0)
endfunction

function DzAPI_Map_CommentCount takes player whichPlayer returns integer
    return DzServer_GetInt(whichPlayer, "COMMENT", 0)
endfunction

function DzAPI_Map_FriendCount takes player whichPlayer returns integer
    return DzServer_GetInt(whichPlayer, "FRIENDS", 0)
endfunction

function DzAPI_Map_ContinuousCount takes player whichPlayer returns integer
    return DzServer_GetInt(whichPlayer, "CONTINUOUS", 0)
endfunction

function DzAPI_Map_MapsTotalPlayed takes player whichPlayer returns integer
    return DzServer_GetInt(whichPlayer, "MAPS_PLAYED", 0)
endfunction

function DzAPI_Map_MapsLevel takes player whichPlayer returns integer
    return DzServer_GetInt(whichPlayer, "MAPS_LEVEL", 0)
endfunction

function DzAPI_Map_MapsConsumeGold takes player whichPlayer returns integer
    return DzServer_GetInt(whichPlayer, "MAPS_GOLD", 0)
endfunction

function DzAPI_Map_MapsConsumeLumber takes player whichPlayer returns integer
    return DzServer_GetInt(whichPlayer, "MAPS_LUMBER", 0)
endfunction

function DzAPI_Map_GetGuildName takes player whichPlayer returns string
    local string s = DzServer_Get(whichPlayer, "GUILD_NAME")
    if s == null or s == "" then
        return gDzServer_DefaultGuildName
    endif
    return s
endfunction

function DzAPI_Map_GetGuildRole takes player whichPlayer returns integer
    return DzServer_GetInt(whichPlayer, "GUILD_ROLE", gDzServer_DefaultGuildRole)
endfunction

function DzAPI_Map_LocalSetGuild takes player whichPlayer, string name, integer role returns nothing
    call DzServer_Set(whichPlayer, "GUILD_NAME", name)
    call DzServer_SetInt(whichPlayer, "GUILD_ROLE", role)
endfunction

function DzAPI_Map_GetPlatformVIP takes player whichPlayer returns integer
    return DzServer_GetInt(whichPlayer, "PLATFORM_VIP", 0)
endfunction

function DzAPI_Map_IsPlatformVIP takes player whichPlayer returns boolean
    return DzAPI_Map_GetPlatformVIP(whichPlayer) > 0
endfunction

function DzAPI_Map_IsRedVIP takes player whichPlayer returns boolean
    return DzServer_GetBool(whichPlayer, "REDVIP")
endfunction

function DzAPI_Map_IsBlueVIP takes player whichPlayer returns boolean
    return DzServer_GetBool(whichPlayer, "BLUEVIP")
endfunction

function DzAPI_Map_LocalSetVIP takes player whichPlayer, boolean red, boolean blue, integer platformVip returns nothing
    call DzServer_SetBool(whichPlayer, "REDVIP", red)
    call DzServer_SetBool(whichPlayer, "BLUEVIP", blue)
    call DzServer_SetInt(whichPlayer, "PLATFORM_VIP", platformVip)
endfunction

function DzAPI_Map_IsAchievementCompleted takes player whichPlayer, string key returns boolean
    return DzServer_GetBool(whichPlayer, "ACH_" + key)
endfunction

function DzAPI_Map_LocalCompleteAchievement takes player whichPlayer, string key returns nothing
    call DzServer_SetBool(whichPlayer, "ACH_" + key, true)
endfunction

function DzAPI_Map_GetServerArchiveEquip takes player whichPlayer, string key returns integer
    return DzServer_GetInt(whichPlayer, "EQUIP_" + key, 0)
endfunction

function DzAPI_Map_GetServerArchiveDrop takes player whichPlayer, string key returns string
    return DzServer_Get(whichPlayer, "DROP_" + key)
endfunction

function DzAPI_Map_LocalSetServerArchiveEquip takes player whichPlayer, string key, integer value returns nothing
    call DzServer_SetInt(whichPlayer, "EQUIP_" + key, value)
endfunction

function DzAPI_Map_GetMatchType takes nothing returns integer
    return gDzServer_MatchType
endfunction

function DzAPI_Map_IsRPGLadder takes nothing returns boolean
    return gDzServer_IsRPGLadder
endfunction

function DzAPI_Map_IsRPGLobby takes nothing returns boolean
    return gDzServer_IsRPGLobby
endfunction

function DzAPI_Map_IsRPGQuickMatch takes nothing returns boolean
    return gDzServer_IsRPGQuickMatch
endfunction

function DzAPI_Map_GetGameStartTime takes nothing returns integer
    return gDzServer_GameStartTime
endfunction

function DzAPI_Map_IsMapTest takes nothing returns boolean
    return gDzServer_IsMapTest
endfunction

function DzAPI_Map_LocalSetMatchContext takes integer matchType, boolean rpgLadder, boolean rpgLobby, boolean quickMatch, boolean mapTest returns nothing
    set gDzServer_MatchType = matchType
    set gDzServer_IsRPGLadder = rpgLadder
    set gDzServer_IsRPGLobby = rpgLobby
    set gDzServer_IsRPGQuickMatch = quickMatch
    set gDzServer_IsMapTest = mapTest
endfunction

function DzAPI_Map_GetMapConfig takes string key returns string
    return DzServer_Get(Player(PLAYER_NEUTRAL_PASSIVE), "CFG_" + key)
endfunction

function DzAPI_Map_LocalSetMapConfig takes string key, string value returns nothing
    call DzServer_Set(Player(PLAYER_NEUTRAL_PASSIVE), "CFG_" + key, value)
endfunction

function DzAPI_Map_GetUserID takes player whichPlayer returns integer
    local integer id = DzServer_GetInt(whichPlayer, "USERID", -1)
    if id < 0 then
        return GetPlayerId(whichPlayer)
    endif
    return id
endfunction

function DzAPI_Map_GetPlayerUserName takes player whichPlayer returns string
    local string s = DzServer_Get(whichPlayer, "USERNAME")
    if s == null or s == "" then
        return GetPlayerName(whichPlayer)
    endif
    return s
endfunction

function DzAPI_Map_OpenMall takes player whichPlayer returns boolean
    return false
endfunction

function DzAPI_Map_QuickBuy takes player whichPlayer, string key returns boolean
    return false
endfunction

function DzAPI_Map_CancelQuickBuy takes player whichPlayer returns boolean
    return false
endfunction

function DzAPI_Map_EnablePlatformSettings takes player whichPlayer, integer settings returns boolean
    call DzServer_SetInt(whichPlayer, "PLATFORM_SETTINGS", settings)
    return true
endfunction

function KKApiBeginBatchSaveArchive takes player whichPlayer returns boolean
    set gDzServer_BatchOpen = true
    set gDzServer_BatchCount = 0
    return true
endfunction

function KKApiAddBatchSaveArchive takes player whichPlayer, string key, string value returns boolean
    if not gDzServer_BatchOpen then
        return false
    endif
    call SaveStr(gDzServer_Batch, GetPlayerId(whichPlayer) + 1, gDzServer_BatchCount, key)
    call SaveStr(gDzServer_Batch, GetPlayerId(whichPlayer) + 101, gDzServer_BatchCount, value)
    set gDzServer_BatchCount = gDzServer_BatchCount + 1
    return true
endfunction

function KKApiEndBatchSaveArchive takes player whichPlayer returns boolean
    local integer i = 0
    local string k
    local string v
    if not gDzServer_BatchOpen then
        return false
    endif
    loop
        exitwhen i >= gDzServer_BatchCount
        set k = LoadStr(gDzServer_Batch, GetPlayerId(whichPlayer) + 1, i)
        set v = LoadStr(gDzServer_Batch, GetPlayerId(whichPlayer) + 101, i)
        call DzCompat_Archive_Save(whichPlayer, k, v)
        set i = i + 1
    endloop
    set gDzServer_BatchOpen = false
    set gDzServer_BatchCount = 0
    call DzCompat_Archive_Flush()
    return true
endfunction

function DzAPI_Map_IsAuthor takes player whichPlayer returns boolean
    return DzServer_GetBool(whichPlayer, "AUTHOR")
endfunction

function DzAPI_Map_IsConnoisseur takes player whichPlayer returns boolean
    return DzServer_GetBool(whichPlayer, "CONNOISSEUR")
endfunction

function DzAPI_Map_IsPlayer takes player whichPlayer returns boolean
    return GetPlayerController(whichPlayer) == MAP_CONTROL_USER
endfunction

function GetPlayerServerValueSuccess takes player whichPlayer returns boolean
    return DzAPI_Map_GetServerValueErrorCode(whichPlayer) == 0
endfunction
