// ============================================================================
// DzCompat_Archive.j
// Persistent local server-archive simulation for DzAPI_Map_SaveServerValue /
// GetServerValue (and the typed Store*/GetStored* wrappers that sit on top).
//
// Design goals:
//   - Use a real text file via the Preload / PreloadGen system so the data
//     lives on disk under the Warcraft III directory tree.
//   - Keep an in-memory hashtable for fast reads within a session.
//   - On first access of a session, load the file into the hashtable.
//   - On every save, update the hashtable and rewrite the file.
//   - Give every map its own folder, named after the map itself, so
//     different maps installed on the same PC never share or overwrite
//     each other's archive.
//   - The live save file itself always uses one fixed name - the per-map
//     folder already guarantees uniqueness, so the file inside it doesn't
//     need to encode anything else.
//   - Automatically snapshot the archive into a rotating set of backups
//     so a corrupted/overwritten save can be recovered.
//   - Chat commands "-save" / "-load" (registered lazily on first archive
//     access) for manual flush and reload during testing or recovery.
//
// File layout (relative to the WC3 install / CustomMapData):
//   DzCompat_Archive\<GetMapName()>\save.pld                  (the live save)
//   DzCompat_Archive\<GetMapName()>\backups\backup_1.pld .. backup_5.pld
//
// <GetMapName()> is filled in by the converter for every map it produces
// (from the map's own "call SetMapName(...)" in its config() function, or
// from the input file name as a fallback), so this is a real per-map value,
// not a placeholder left over from the template.
//
// Backups: A 5-slot rotation system: backup_1.pld is written
//   first, then backup_2.pld, ... backup_5.pld, then back to backup_1.pld,
//   overwriting it. The slot pointer is session-local (not persisted across
//   restarts) to keep this simple - worst case a short session slightly
//   skews which slot gets reused next, which does not matter for a
//   disaster-recovery feature.
//
// Limitations (engine reality):
//   - Pure JASS cannot do arbitrary file I/O. PreloadGen is the only
//     supported way to write a text file that can later be executed.
//   - Multiplayer: each client has its own file; there is no cross-client
//     sync. Only a player's own client ever writes their save data to disk
//     (guarded by GetLocalPlayer(), the standard convention used by other
//     local WC3 save/archive systems) - the periodic backup snapshot is the
//     one exception, since it is a session-wide timer with no per-player
//     scope and mirrors the full known-key archive on every client.
//   - Very large archives may hit Preload line limits; keep keys short.
// ============================================================================

globals
    hashtable gDzArchiveTable = InitHashtable()          // parent = playerId+1, child = StringHash(key) -> value string
    boolean   gDzArchiveInited = false                   // one-time per-session init (folder, save path, backup timer)
    integer   gDzArchiveDirty = 0                        // number of writes since last flush
    constant integer DZARCHIVE_FLUSH_EVERY = 1           // rewrite file on every save (safest for persistence)

    // --- Per-map folder / save file -----------------------------------------
    string gDzArchiveMapName  = ""                       // sanitized, from GetMapName()
    string gDzArchiveFolder   = ""                       // "DzCompat_Archive\\<map>\\"
    constant string DZARCHIVE_SAVE_FILE_NAME = "save.pld"
    string gDzArchiveSavePath = ""                  // gDzArchiveFolder + DZARCHIVE_SAVE_FILE_NAME
	
    // --- Backup timer / rotation (5 slots, oldest is overwritten) -----------
    timer   gDzArchiveClockTimer = null                  // created lazily in DzCompat_Archive_EnsureLoaded
    constant real    DZARCHIVE_TICK_SECONDS = 60.0       // real-time tick, unaffected by game speed
    constant integer DZARCHIVE_BACKUP_EVERY_TICKS = 10   // 10 * 60s = every 10 real minutes
    integer gDzArchiveTickCount = 0
    constant integer DZARCHIVE_MAX_BACKUPS = 5
    integer gDzArchiveBackupSlot = 0                   // next slot to (re)write, cycles 0..DZARCHIVE_MAX_BACKUPS-1

    // --- Known-key list, so a full rewrite is possible without a hashtable
    //     iterator (JASS has none). Shared by the live save and backups.
    integer gDzArchiveKnownCount = 0
    constant integer DZARCHIVE_MAX_KNOWN = 256
    string array gDzArchiveKeyList

    // --- Chat command registration ( -save / -load ) -----------------------
    boolean gDzArchiveChatRegistered = false
endglobals

// ---------------------------------------------------------------------------
// Per-map name (filled in by the converter for this specific map)
// ---------------------------------------------------------------------------

function GetMapName takes nothing returns string
    return "__DZARCHIVE_MAP_NAME__"
endfunction

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

function DzCompat_Archive_PlayerKey takes player whichPlayer, string key returns string
    // Prefix with player slot so different players never collide.
    return "P" + I2S(GetPlayerId(whichPlayer)) + "_" + key
endfunction

function DzCompat_Archive_RememberKey takes string fullKey returns nothing
    local integer i = 0
    // Linear scan to avoid duplicates (archives are usually small)
    loop
        exitwhen i >= gDzArchiveKnownCount
        if gDzArchiveKeyList[i] == fullKey then
            return
        endif
        set i = i + 1
    endloop
    if gDzArchiveKnownCount < DZARCHIVE_MAX_KNOWN then
        set gDzArchiveKeyList[gDzArchiveKnownCount] = fullKey
        set gDzArchiveKnownCount = gDzArchiveKnownCount + 1
    endif
endfunction

function DzCompat_Archive_LoadKV takes string fullKey, string value returns nothing
    // Called from the Preload file on map start / first access.
    local integer pid
    local string key
    local integer uscore
    if fullKey == null or fullKey == "" then
        return
    endif
    // fullKey format: P<id>_<originalKey>
    set uscore = 1
    loop
        exitwhen uscore > StringLength(fullKey) or SubString(fullKey, uscore-1, uscore) == "_"
        set uscore = uscore + 1
    endloop
    if uscore > StringLength(fullKey) then
        return
    endif
    set pid = S2I(SubString(fullKey, 1, uscore-1))       // skip leading 'P'
    set key = SubString(fullKey, uscore, StringLength(fullKey))
    call SaveStr(gDzArchiveTable, pid + 1, StringHash(key), value)
    // Must track every key that comes from disk, otherwise the next WriteAll
    // only knows about keys that were saved *this* session and silently
    // drops everything that was preloaded.
    call DzCompat_Archive_RememberKey(fullKey)
endfunction


// Writes the full known-key archive contents (the live hashtable state) to
// an arbitrary target preload file. Used both for the live save and for
// each backup snapshot.
function DzCompat_Archive_WriteAllTo takes string targetPath returns nothing
    local integer i = 0
    local string fullKey
    local string value
    local integer pid
    local string key
    local integer uscore
    // PreloadGenStart does NOT clear any buffer left over from an earlier,
    // possibly-interrupted PreloadGen sequence (confirmed by the native's
    // own documentation) - clear it explicitly first so a stray leftover
    // line can never leak into this file.
    call PreloadGenClear()
    call PreloadGenStart()
    // Emit executable JASS lines. Preloader will run them on next load.
    // Assumption: keys and values do not contain double-quote characters.
    loop
        exitwhen i >= gDzArchiveKnownCount
        set fullKey = gDzArchiveKeyList[i]
        // Recover pid + original key to look up the current value
        set uscore = 1
        loop
            exitwhen uscore > StringLength(fullKey) or SubString(fullKey, uscore-1, uscore) == "_"
            set uscore = uscore + 1
        endloop
        if uscore <= StringLength(fullKey) then
            set pid = S2I(SubString(fullKey, 1, uscore-1))
            set key = SubString(fullKey, uscore, StringLength(fullKey))
            set value = LoadStr(gDzArchiveTable, pid + 1, StringHash(key))
            if value == null then
                set value = ""
            endif
            call Preload("call DzCompat_Archive_LoadKV(\"" + fullKey + "\", \"" + value + "\")")
        endif
        set i = i + 1
    endloop
    call PreloadGenEnd(targetPath)
endfunction

function DzCompat_Archive_WriteAll takes nothing returns nothing
    call DzCompat_Archive_WriteAllTo(gDzArchiveSavePath)
    set gDzArchiveDirty = 0
endfunction

// Rewrites the whole archive file from the in-memory table. Kept as a
// public alias (some callers, e.g. KKApiEndBatchSaveArchive, flush by name).
function DzCompat_Archive_Flush takes nothing returns nothing
    call DzCompat_Archive_WriteAll()
endfunction

// Snapshots the current archive into the next backup slot (the oldest one,
// which is overwritten - see the "Backups" note at the top of this file).
// Snapshots the current archive into the next backup slot, cycling through
// backup_1.pld .. backup_5.pld (see the "Backups" note at the top of this
// file for why this is a fixed-slot rotation rather than unique file names).
function DzCompat_Archive_CreateBackup takes nothing returns nothing
    local string path = gDzArchiveFolder + "backups\\backup_" + I2S(gDzArchiveBackupSlot + 1) + ".pld"
    call DzCompat_Archive_WriteAllTo(path)
    set gDzArchiveBackupSlot = ModuloInteger(gDzArchiveBackupSlot + 1, DZARCHIVE_MAX_BACKUPS)
endfunction

// Real-time periodic tick (started once per session). Triggers a backup
// every 10 real minutes.
function DzCompat_Archive_OnTick takes nothing returns nothing
    set gDzArchiveTickCount = gDzArchiveTickCount + 1
    if gDzArchiveTickCount >= DZARCHIVE_BACKUP_EVERY_TICKS then
        set gDzArchiveTickCount = 0
        call DzCompat_Archive_CreateBackup()
    endif
endfunction

function DzCompat_Archive_EnsureLoaded takes nothing returns nothing
    if gDzArchiveInited then
        return
    endif
    set gDzArchiveInited = true

    // Every map gets its own folder, named after the map itself; the file
    // inside it always uses the same fixed name (see the header comment).
    set gDzArchiveMapName = GetMapName()
    if gDzArchiveMapName == null or gDzArchiveMapName == "" then
        set gDzArchiveMapName = "UnknownMap"
    endif
    if gDzArchiveFolder == "" then
        set gDzArchiveFolder = "DzCompat_Archive\\" + gDzArchiveMapName + "\\"
    endif
     set gDzArchiveSavePath = gDzArchiveFolder + DZARCHIVE_SAVE_FILE_NAME

    // Load the existing save's key/value pairs, if any (Preloader is a
    // silent no-op when the file doesn't exist yet - first time for this map).
    call Preloader(gDzArchiveSavePath)

    // Start the real-time (not game-speed-scaled) clock/backup ticker.
    set gDzArchiveClockTimer = CreateTimer()
    call TimerStart(gDzArchiveClockTimer, DZARCHIVE_TICK_SECONDS, true, function DzCompat_Archive_OnTick)
endfunction

// ---------------------------------------------------------------------------
// Manual archive control: chat commands "-save" and "-load"
// ---------------------------------------------------------------------------
// -save  : force a full rewrite of the live save.pld from the in-memory table
//          (only the issuing client's disk is written, matching the normal
//          GetLocalPlayer() convention used by DzCompat_Archive_Save).
// -load  : discard the in-memory table, re-run Preloader on the live save
//          file, and rebuild the known-key list. Intended for recovery /
//          testing; in multiplayer each client has its own file, so a full
//          table clear + Preloader is only performed on the local client.
// Registration is lazy: the first Save / Load / Cmd triggers
// DzCompat_Archive_RegisterChatCommands so definition order stays
// dependency-safe for plain JASS (callees before callers).
// ---------------------------------------------------------------------------

function DzCompat_Archive_Clear takes nothing returns nothing
    // Drop every key/value and the known-key list so a subsequent Preloader
    // starts from a clean slate.
    call FlushParentHashtable(gDzArchiveTable)
    set gDzArchiveKnownCount = 0
    set gDzArchiveDirty = 0
endfunction

function DzCompat_Archive_Reload takes nothing returns nothing
    // Ensure folder / path are known, then replace the in-memory state with
    // whatever is currently on disk.
	// Full clear + Preloader mutates the shared in-memory archive from a
    // per-client disk file. Safe only when every client would load the same
    // data (single-player). Callers that need this in multiplayer must use a
    // different design (e.g. sync the payload via BlzSendSyncData first).
    if not bj_isSinglePlayer then
        return
    endif
    call DzCompat_Archive_EnsureLoaded()
    call DzCompat_Archive_Clear()
    call Preloader(gDzArchiveSavePath)
endfunction

function DzCompat_Archive_CmdSave takes nothing returns nothing
    local player p = GetTriggerPlayer()
    call DzCompat_Archive_EnsureLoaded()
    // All clients keep the same in-memory table (lockstep). Only the
    // issuing player's client writes the file, identical to the normal
    // save path.
    if GetLocalPlayer() == p then
        call DzCompat_Archive_WriteAll()
        call DisplayTimedTextToPlayer(p, 0, 0, 8.0, "|cff00ff00[DzCompat Archive] Saved to disk.|r")
    endif
endfunction

function DzCompat_Archive_CmdLoad takes nothing returns nothing
    local player p = GetTriggerPlayer()
    call DzCompat_Archive_EnsureLoaded()
    // -load rewrites the shared hashtable from disk. Each client has its own
    // save.pld, so:
    //   - doing Clear+Preloader only under GetLocalPlayer() desyncs
    //   - doing it on every client still loads different files and desyncs
    // Restrict to single-player (the intended testing/recovery use case).
    if not bj_isSinglePlayer then
        call DisplayTimedTextToPlayer(p, 0, 0, 8.0, "|cffffcc00[DzCompat Archive] -load is single-player only (would desync in multiplayer). This cmd is just for testing, main save system is automatic|r")
        return
    endif
    call DzCompat_Archive_Clear()
    call Preloader(gDzArchiveSavePath)
    call DisplayTimedTextToPlayer(p, 0, 0, 8.0, "|cff00ff00[DzCompat Archive] Reloaded from disk.|r")
endfunction

function DzCompat_Archive_RegisterChatCommands takes nothing returns nothing
    local trigger tSave
    local trigger tLoad
    local integer i
    if gDzArchiveChatRegistered then
        return
    endif
    set gDzArchiveChatRegistered = true

    set tSave = CreateTrigger()
    set tLoad = CreateTrigger()
    set i = 0
    loop
        exitwhen i >= bj_MAX_PLAYERS
        call TriggerRegisterPlayerChatEvent(tSave, Player(i), "-save", true)
        call TriggerRegisterPlayerChatEvent(tLoad, Player(i), "-load", true)
        set i = i + 1
    endloop
    call TriggerAddAction(tSave, function DzCompat_Archive_CmdSave)
    call TriggerAddAction(tLoad, function DzCompat_Archive_CmdLoad)
endfunction


// ---------------------------------------------------------------------------
// Public API used by RequestExtraData and direct DzAPI_Map_* wrappers
// ---------------------------------------------------------------------------

function DzCompat_Archive_SetPath takes string path returns nothing
    // Optional: maps can call this BEFORE the first Save/Load of the session
    // to override the auto-detected per-map folder (must end with "\\").
    // Has no effect once the archive has already been initialized.
    if gDzArchiveInited then
        return
    endif
    if path != null and path != "" then
        set gDzArchiveFolder = path
    endif
endfunction

function DzCompat_Archive_Save takes player whichPlayer, string key, string value returns boolean
    local string fullKey
    if whichPlayer == null or key == null then
        return false
    endif
    call DzCompat_Archive_EnsureLoaded()
    call DzCompat_Archive_RegisterChatCommands()
    set fullKey = DzCompat_Archive_PlayerKey(whichPlayer, key)
    call SaveStr(gDzArchiveTable, GetPlayerId(whichPlayer) + 1, StringHash(key), value)
    call DzCompat_Archive_RememberKey(fullKey)
    set gDzArchiveDirty = gDzArchiveDirty + 1
    // Every client executes this call identically (WC3's simulation is
    // lockstep-synchronized), so without this check every client would
    // write a local disk copy of every OTHER player's data too, every
    // time anyone saves. Only the file's actual owner should persist it
    // to their own machine - the same convention used by every other
    // local WC3 save/archive system (compare any PreloadGen-based
    // FileIO/SaveFile library's writer functions).
    if gDzArchiveDirty >= DZARCHIVE_FLUSH_EVERY and GetLocalPlayer() == whichPlayer then
        call DzCompat_Archive_WriteAll()
    endif
    return true
endfunction

function DzCompat_Archive_Load takes player whichPlayer, string key returns string
    local string value
    if whichPlayer == null or key == null then
        return ""
    endif
    call DzCompat_Archive_EnsureLoaded()
    call DzCompat_Archive_RegisterChatCommands()
    set value = LoadStr(gDzArchiveTable, GetPlayerId(whichPlayer) + 1, StringHash(key))
    if value == null then
        return ""
    endif
    return value
endfunction

// Convenience typed wrappers that mirror the classic DzAPI_Map_Store*/GetStored*
// family (they add the type prefix letter before calling the string archive).

function DzCompat_Archive_StoreString takes player whichPlayer, string key, string value returns nothing
    call DzCompat_Archive_Save(whichPlayer, "S" + key, value)
endfunction

function DzCompat_Archive_StoreInteger takes player whichPlayer, string key, integer value returns nothing
    call DzCompat_Archive_Save(whichPlayer, "I" + key, I2S(value))
endfunction

function DzCompat_Archive_StoreReal takes player whichPlayer, string key, real value returns nothing
    call DzCompat_Archive_Save(whichPlayer, "R" + key, R2S(value))
endfunction

function DzCompat_Archive_StoreBoolean takes player whichPlayer, string key, boolean value returns nothing
    if value then
        call DzCompat_Archive_Save(whichPlayer, "B" + key, "1")
    else
        call DzCompat_Archive_Save(whichPlayer, "B" + key, "0")
    endif
endfunction

function DzCompat_Archive_GetStoredString takes player whichPlayer, string key returns string
    return DzCompat_Archive_Load(whichPlayer, "S" + key)
endfunction

function DzCompat_Archive_GetStoredInteger takes player whichPlayer, string key returns integer
    return S2I(DzCompat_Archive_Load(whichPlayer, "I" + key))
endfunction

function DzCompat_Archive_GetStoredReal takes player whichPlayer, string key returns real
    return S2R(DzCompat_Archive_Load(whichPlayer, "R" + key))
endfunction

function DzCompat_Archive_GetStoredBoolean takes player whichPlayer, string key returns boolean
    return DzCompat_Archive_Load(whichPlayer, "B" + key) == "1"
endfunction

// ---------------------------------------------------------------------------
// Direct DzAPI_Map_* entry points (classic DzAPI.j style).
// Many maps declare these as natives or call them without going through
// RequestExtra*Data. Route them to the same persistent archive.
// ---------------------------------------------------------------------------

function DzAPI_Map_SaveServerValue takes player whichPlayer, string key, string value returns boolean
    return DzCompat_Archive_Save(whichPlayer, key, value)
endfunction

function DzAPI_Map_GetServerValue takes player whichPlayer, string key returns string
    return DzCompat_Archive_Load(whichPlayer, key)
endfunction

function DzAPI_Map_GetServerValueErrorCode takes player whichPlayer returns integer
    // 0 = success / no error (matches typical Dz usage of GetPlayerServerValueSuccess)
    return 0
endfunction

function DzAPI_Map_StoreString takes player whichPlayer, string key, string value returns nothing
    call DzCompat_Archive_StoreString(whichPlayer, key, value)
endfunction

function DzAPI_Map_StoreInteger takes player whichPlayer, string key, integer value returns nothing
    call DzCompat_Archive_StoreInteger(whichPlayer, key, value)
endfunction

function DzAPI_Map_StoreReal takes player whichPlayer, string key, real value returns nothing
    call DzCompat_Archive_StoreReal(whichPlayer, key, value)
endfunction

function DzAPI_Map_StoreBoolean takes player whichPlayer, string key, boolean value returns nothing
    call DzCompat_Archive_StoreBoolean(whichPlayer, key, value)
endfunction

function DzAPI_Map_GetStoredString takes player whichPlayer, string key returns string
    return DzCompat_Archive_GetStoredString(whichPlayer, key)
endfunction

function DzAPI_Map_GetStoredInteger takes player whichPlayer, string key returns integer
    return DzCompat_Archive_GetStoredInteger(whichPlayer, key)
endfunction

function DzAPI_Map_GetStoredReal takes player whichPlayer, string key returns real
    return DzCompat_Archive_GetStoredReal(whichPlayer, key)
endfunction

function DzAPI_Map_GetStoredBoolean takes player whichPlayer, string key returns boolean
    return DzCompat_Archive_GetStoredBoolean(whichPlayer, key)
endfunction
