// ============================================================================
// DzCompat_Archive.j
// Persistent local server-archive simulation for DzAPI_Map_SaveServerValue /
// GetServerValue (and the typed Store*/GetStored* wrappers that sit on top).
//
// HOW DATA GETS OUT OF AND BACK INTO THE GAME (why this file is built the way it is)
//   Plain JASS can write a text file (Preload / PreloadGen) and can ask the engine to
//   "run" one (Preloader), but it cannot read a file. Reforged only lets a run file do
//   a handful of things; one of them is setting an ability's tooltip text. So:
//     WRITE  each chunk of data is written as a Preload line that closes the Preload call
//            and injects  call BlzSetAbilityTooltip(<channel ability>,"@<data>",0)
//     READ   Preloader(<file>) runs that line, which leaves the data in the channel
//            ability's tooltip; BlzGetAbilityTooltip(<channel ability>,0) returns it.
//   (The earlier version of this file wrote "call DzCompat_Archive_LoadKV(...)" INSIDE the
//   Preload string. That is only text handed to Preload - nothing ever ran it, so
//   nothing was ever loaded.)
//
//   Engine facts this design follows (measured in-game by the converter that this
//   channel was taken from; not re-measured here):
//     - a line of a .pld file is limited to 259 characters, INCLUDING the
//       `call Preload( "` ... `" )` the engine writes around the injected text;
//     - only the tooltip slot of the channel ability works reliably, so ONE chunk goes
//       in ONE file (save_0.pld, save_1.pld, ...), each with a single Preload line;
//     - the engine runs each .pld PATH only once per game: running the same path a
//       second time hands back the first result. Every file is therefore read once per
//       game (at the first access), never again, and a save can only be loaded by
//       starting a new game;
//     - the channel ability must have tooltip text in the map's data: setting the
//       tooltip of an ability without one is ignored. The first ability that accepts text
//       is used (DZARCHIVE_CHANNEL_ABILITY first, then a few standard ones - see
//       DzCompat_Archive_Candidate). Only custom abilities of a map were measured by the
//       converter this channel comes from; a standard one is expected to work the same
//       way but has not been confirmed in-game.
//
// FILE LAYOUT (relative to CustomMapData):
//   DzCompat_Archive\<map>\u<hash of the player name>\save_<k>.pld   (one store per player)
//   DzCompat_Archive\<map>\shared\save_<k>.pld   (data saved for a non-player: neutral, computer)
//   ...\backups\b<slot>_<k>.pld   (rotating backups of the same files)
//   Text of the chunks: "#<parts>;" line, then per chunk a "#p<k>;" tag line and its records
//   "key=<flag><value>" (one per line; flag s = whole value, b/c = begin/continue of a value
//   that did not fit in one record), and a closing "#eof". Backslash and line breaks inside
//   keys and values are escaped, so any value is safe.
//
// LIMITATIONS (engine reality):
//   - Multiplayer: every client has its own disk and only ever reads and writes its OWN
//     player's files. A Load for another player's data is answered from memory only, so
//     clients can disagree about it - there is no cross-client sync.
//   - A .pld line is at most 259 characters, so a value is stored as several records when it
//     does not fit in one (transparently), and a save is limited to DZARCHIVE_PARTS_MAX files
//     (about 11 KB of data) and DZARCHIVE_KEYS_MAX keys per player.
//   - Keys are case-insensitive (StringHash), like the real server's.
//   - A carriage return inside a value is not escaped.
// ============================================================================

globals
    // In-memory store. parent = store id, child = StringHash(key) -> value string.
    // Store ids: 0 .. DZARCHIVE_SHARED-1 = the player with that id, DZARCHIVE_SHARED =
    // everything saved for a slot that is not a user player.
    hashtable gDzArchiveTable = InitHashtable()
    integer array gDzArchiveKeyCount                     // keys in each store
    string array gDzArchiveKeys                          // [store * DZARCHIVE_KEYS_MAX + i] -> key (exact spelling)
    boolean array gDzArchiveTried                        // the disk was already read (or skipped) for this store
    boolean array gDzArchiveDirty                        // changed since the last write to disk
    boolean array gDzArchiveStale                        // changed since the last backup

    boolean gDzArchiveInited = false                     // one-time per-session init
    string gDzArchiveFolder = ""                         // "DzCompat_Archive\\<map>\\"
    string gDzArchiveMapName = ""                        // sanitized, from GetMapName()

    // --- Channel --------------------------------------------------------------
    // The ability whose tooltip carries the data from the run file back to the script. It MUST
    // have tooltip text in the map's data (a standard hero ability such as Holy Light does; a
    // hidden one such as Aloc does not) and nothing else should use its tooltip while the
    // archive is read. Its original text is put back after every read.
    // It is the FIRST choice; when it cannot carry text the next candidates are tried.
    // If nothing loads, set DZCOMPAT_DEBUG_MESSAGES to true (DzCompat_Core.j) to have the
    // archive say which ability it uses and whether the channel works.
    constant integer DZARCHIVE_CHANNEL_ABILITY = 'AHhb'
    integer gDzArchiveChannel = 0                        // the ability actually in use (chosen at the first read)
    integer gDzArchiveChannelState = 0                   // 0 not chosen yet, 1 chosen, 2 none of the candidates works
    constant integer DZARCHIVE_LINE_MAX = 259            // engine limit of one .pld line
    constant integer DZARCHIVE_ENVELOPE = 19             // what the engine writes around the injected text
    constant integer DZARCHIVE_HEADER_SLACK = 12         // room kept for the "#<n>;" and "#p<k>;" lines
    constant integer DZARCHIVE_PART_MAX = 200            // design ceiling for the text of one chunk
    constant integer DZARCHIVE_PARTS_MAX = 64            // files of one store
    constant integer DZARCHIVE_KEYS_MAX = 256            // keys of one store
    constant integer DZARCHIVE_SHARED = 24               // store id of the non-player store
    constant string DZARCHIVE_SAVE_NAME = "save_"        // file name prefix of the live save
    constant string DZARCHIVE_EOF = "#eof"
    string gDzArchiveOrigTip = ""                        // the channel ability's own tooltip, put back after a read

    // --- Chunks being built by a write ----------------------------------------
    string array gDzArchiveChunk
    integer gDzArchiveChunkCount = 0
    string gDzArchiveCur = ""
    integer gDzArchiveCurLen = 0
    integer gDzArchiveUsable = 0                         // cached DzCompat_Archive_Capacity
    boolean gDzArchiveSawEof = false

    // --- Writing to disk: delayed and batched -----------------------------------
    // A map saves dozens of keys in a burst; rewriting the files for each one would be
    // dozens of file writes. The files are rewritten once, DZARCHIVE_FLUSH_DELAY game seconds
    // after the last change (0 = on every change).
    constant real DZARCHIVE_FLUSH_DELAY = 0.5
    timer gDzArchiveFlushTimer = null

    // --- Backup timer / rotation ------------------------------------------------
    timer gDzArchiveClockTimer = null
    constant real DZARCHIVE_TICK_SECONDS = 60.0
    constant integer DZARCHIVE_BACKUP_EVERY_TICKS = 10   // 10 * 60s
    integer gDzArchiveTickCount = 0
    constant integer DZARCHIVE_MAX_BACKUPS = 5
    integer gDzArchiveBackupSlot = 0                     // next slot to (re)write, cycles 0..DZARCHIVE_MAX_BACKUPS-1

    // --- Chat command registration ( -save / -load ) ----------------------------
    boolean gDzArchiveChatRegistered = false
endglobals

// ---------------------------------------------------------------------------
// Per-map name (filled in by the converter for this specific map)
// ---------------------------------------------------------------------------

function GetMapName takes nothing returns string
    return "__DZARCHIVE_MAP_NAME__"
endfunction

// ---------------------------------------------------------------------------
// Text helpers
// ---------------------------------------------------------------------------

// One printable ASCII character (code 32..126) as text.
function DzCompat_Archive_ByteChar takes integer b returns string
    local string table = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"
    if b < 32 or b > 126 then
        return "?"
    endif
    return SubString(table, b - 32, b - 31)
endfunction

// A rawcode as the text of a JASS rawcode literal: 'AHhb' -> "'AHhb'"
function DzCompat_Archive_Id4 takes integer id returns string
    return "'" + DzCompat_Archive_ByteChar(id / 16777216) + DzCompat_Archive_ByteChar(ModuloInteger(id / 65536, 256)) + DzCompat_Archive_ByteChar(ModuloInteger(id / 256, 256)) + DzCompat_Archive_ByteChar(ModuloInteger(id, 256)) + "'"
endfunction

// Position of the first line break of s at or after start, or -1.
function DzCompat_Archive_PosLF takes string s, integer start returns integer
    local integer n = StringLength(s)
    local integer i = start
    loop
        exitwhen i >= n
        if SubString(s, i, i + 1) == "\n" then
            return i
        endif
        set i = i + 1
    endloop
    return -1
endfunction

// Position of the first occurrence of one character in s, or -1.
function DzCompat_Archive_PosChar takes string s, string ch returns integer
    local integer n = StringLength(s)
    local integer i = 0
    loop
        exitwhen i >= n
        if SubString(s, i, i + 1) == ch then
            return i
        endif
        set i = i + 1
    endloop
    return -1
endfunction

// s as the inside of a JASS string literal: backslash and quote are escaped (this is what
// the Preload line needs so the engine reads the same text back).
function DzCompat_Archive_Esc takes string s returns string
    local integer n = StringLength(s)
    local integer i = 0
    local string r = ""
    local string ch
    loop
        exitwhen i >= n
        set ch = SubString(s, i, i + 1)
        if ch == "\\" then
            set r = r + "\\\\"
        elseif ch == "\"" then
            set r = r + "\\\""
        else
            set r = r + ch
        endif
        set i = i + 1
    endloop
    return r
endfunction

// Record text of a key or a value: backslash -> \\, line break -> \n, and (keys only) the
// "=" that separates key from value -> \e. Whatever the text holds, the record stays one line.
function DzCompat_Archive_Enc takes string s, boolean isKey returns string
    local integer n = StringLength(s)
    local integer i = 0
    local string r = ""
    local string ch
    loop
        exitwhen i >= n
        set ch = SubString(s, i, i + 1)
        if ch == "\\" then
            set r = r + "\\\\"
        elseif ch == "\n" then
            set r = r + "\\n"
        elseif isKey and ch == "=" then
            set r = r + "\\e"
        else
            set r = r + ch
        endif
        set i = i + 1
    endloop
    return r
endfunction

// The reverse of DzCompat_Archive_Enc.
function DzCompat_Archive_Dec takes string s returns string
    local integer n = StringLength(s)
    local integer i = 0
    local string r = ""
    local string ch
    local string nx
    loop
        exitwhen i >= n
        set ch = SubString(s, i, i + 1)
        if ch == "\\" and i + 1 < n then
            set nx = SubString(s, i + 1, i + 2)
            if nx == "n" then
                set r = r + "\n"
            elseif nx == "e" then
                set r = r + "="
            else
                set r = r + nx
            endif
            set i = i + 2
        else
            set r = r + ch
            set i = i + 1
        endif
    endloop
    return r
endfunction

// How many characters of v, starting at start, fit in budget characters once encoded
// (Enc) and escaped (Esc): a backslash costs 4, a quote 2, a line break 3, any other 1.
// Always at least 1, so a caller that loops over a value always moves forward.
function DzCompat_Archive_PieceLen takes string v, integer start, integer budget returns integer
    local integer n = StringLength(v)
    local integer i = start
    local integer used = 0
    local integer c
    local string ch
    loop
        exitwhen i >= n
        set ch = SubString(v, i, i + 1)
        set c = 1
        if ch == "\\" then
            set c = 4
        elseif ch == "\"" then
            set c = 2
        elseif ch == "\n" then
            set c = 3
        endif
        exitwhen used + c > budget
        set used = used + c
        set i = i + 1
    endloop
    if i == start and start < n then
        return 1
    endif
    return i - start
endfunction

// ---------------------------------------------------------------------------
// Which store, and where on disk
// ---------------------------------------------------------------------------

// A user player has its own store. Anything else (the neutral player some maps use for
// "global" data, computer players) shares the store DZARCHIVE_SHARED.
function DzCompat_Archive_StoreOf takes player p returns integer
    local integer pid = GetPlayerId(p)
    if pid >= 0 and pid < DZARCHIVE_SHARED and GetPlayerController(p) == MAP_CONTROL_USER then
        return pid
    endif
    return DZARCHIVE_SHARED
endfunction

// Is this store's data on THIS machine? The shared store is per machine; a player's store
// lives on that player's own machine only.
function DzCompat_Archive_IsLocalStore takes integer sid returns boolean
    if sid == DZARCHIVE_SHARED then
        return true
    endif
    return Player(sid) == GetLocalPlayer()
endfunction

function DzCompat_Archive_Dir takes integer sid returns string
    if sid == DZARCHIVE_SHARED then
        return gDzArchiveFolder + "shared\\"
    endif
    return gDzArchiveFolder + "u" + I2S(StringHash(StringCase(GetPlayerName(Player(sid)), false))) + "\\"
endfunction

function DzCompat_Archive_Path takes integer sid, string prefix, integer part returns string
    return DzCompat_Archive_Dir(sid) + prefix + I2S(part) + ".pld"
endfunction

// ---------------------------------------------------------------------------
// In-memory store
// ---------------------------------------------------------------------------

// Sets a key (or removes it when the value is empty - the server has no empty values).
function DzCompat_Archive_Mem takes integer sid, string key, string value returns nothing
    local integer h = StringHash(key)
    local integer n = gDzArchiveKeyCount[sid]
    local integer i = 0
    if value == null or value == "" then
        if HaveSavedString(gDzArchiveTable, sid, h) then
            call RemoveSavedString(gDzArchiveTable, sid, h)
            loop
                exitwhen i >= n
                if StringHash(gDzArchiveKeys[sid * DZARCHIVE_KEYS_MAX + i]) == h then
                    set gDzArchiveKeys[sid * DZARCHIVE_KEYS_MAX + i] = gDzArchiveKeys[sid * DZARCHIVE_KEYS_MAX + n - 1]
                    set gDzArchiveKeyCount[sid] = n - 1
                    set i = n
                else
                    set i = i + 1
                endif
            endloop
        endif
        return
    endif
    if not HaveSavedString(gDzArchiveTable, sid, h) then
        if n >= DZARCHIVE_KEYS_MAX then
            call DzCompat_Warn("archive: more than " + I2S(DZARCHIVE_KEYS_MAX) + " keys for one player - key " + key + " was not kept")
            return
        endif
        set gDzArchiveKeys[sid * DZARCHIVE_KEYS_MAX + n] = key
        set gDzArchiveKeyCount[sid] = n + 1
    endif
    call SaveStr(gDzArchiveTable, sid, h, value)
endfunction

// ---------------------------------------------------------------------------
// The channel: what goes into a .pld file and how it comes back
// ---------------------------------------------------------------------------

// The abilities tried as the channel, in order; 0 ends the list. They are standard hero
// abilities, which always have tooltip text.
function DzCompat_Archive_Candidate takes integer i returns integer
    if i == 0 then
        return DZARCHIVE_CHANNEL_ABILITY
    elseif i == 1 then
        return 'AHds'
    elseif i == 2 then
        return 'AHtb'
    elseif i == 3 then
        return 'AHfs'
    elseif i == 4 then
        return 'AOsh'
    elseif i == 5 then
        return 'AUav'
    endif
    return 0
endfunction

// The ability in use (the first choice until one was chosen).
function DzCompat_Archive_Channel takes nothing returns integer
    if gDzArchiveChannel != 0 then
        return gDzArchiveChannel
    endif
    return DZARCHIVE_CHANNEL_ABILITY
endfunction

// Characters of chunk text (escaped, without the "#" lines) one file can carry. Measured
// from the real line the writer builds, so it follows the channel ability's spelling.
function DzCompat_Archive_Capacity takes nothing returns integer
    local string head = "\")\ncall BlzSetAbilityTooltip(" + DzCompat_Archive_Id4(DzCompat_Archive_Channel()) + ",\"@"
    local string tail = "\",0)\n//"
    if gDzArchiveUsable > 0 then
        return gDzArchiveUsable
    endif
    set gDzArchiveUsable = DZARCHIVE_LINE_MAX - StringLength(head) - StringLength(tail) - DZARCHIVE_ENVELOPE - DZARCHIVE_HEADER_SLACK
    if gDzArchiveUsable > DZARCHIVE_PART_MAX then
        set gDzArchiveUsable = DZARCHIVE_PART_MAX
    endif
    if gDzArchiveUsable < 48 then
        set gDzArchiveUsable = 48
    endif
    return gDzArchiveUsable
endfunction

// Writes one chunk as the whole content of one file. Returns false (and writes nothing)
// when the line would not fit the 259 characters a .pld line may have.
function DzCompat_Archive_WriteChunkFile takes string path, string chunk returns boolean
    local string line = "\")\ncall BlzSetAbilityTooltip(" + DzCompat_Archive_Id4(DzCompat_Archive_Channel()) + ",\"@" + DzCompat_Archive_Esc(chunk) + "\",0)\n//"
    if gDzArchiveChannelState == 2 then
        return false
    endif
    if StringLength(line) + DZARCHIVE_ENVELOPE > DZARCHIVE_LINE_MAX then
        call DzCompat_Warn("archive: a chunk does not fit a .pld line (" + I2S(StringLength(line) + DZARCHIVE_ENVELOPE) + " > " + I2S(DZARCHIVE_LINE_MAX) + ") - " + path + " was not written")
        return false
    endif
    // PreloadGenStart does not clear what an earlier, interrupted sequence left behind
    call PreloadGenClear()
    call PreloadGenStart()
    call Preload(line)
    call PreloadGenEnd(path)
    return true
endfunction

// Chooses the channel ability the first time (the first candidate that can carry text),
// puts its own tooltip aside and sets the read marker. Returns false when no candidate can
// carry text - the archive then cannot read or write files at all.
function DzCompat_Archive_TipBegin takes nothing returns boolean
    local integer i = 0
    local integer c
    local string orig
    if gDzArchiveChannelState == 2 then
        return false
    endif
    if gDzArchiveChannelState == 1 then
        call BlzSetAbilityTooltip(gDzArchiveChannel, "@", 0)
        return true
    endif
    loop
        set c = DzCompat_Archive_Candidate(i)
        exitwhen c == 0
        set orig = BlzGetAbilityTooltip(c, 0)
        call BlzSetAbilityTooltip(c, "@", 0)
        if BlzGetAbilityTooltip(c, 0) == "@" then
            set gDzArchiveChannel = c
            set gDzArchiveOrigTip = orig
            if gDzArchiveOrigTip == null then
                set gDzArchiveOrigTip = ""
            endif
            set gDzArchiveChannelState = 1
            if i > 0 then
                call DzCompat_Warn("archive: " + DzCompat_Archive_Id4(DZARCHIVE_CHANNEL_ABILITY) + " cannot carry text - using " + DzCompat_Archive_Id4(c) + " as the channel ability")
            endif
            return true
        endif
        set i = i + 1
    endloop
    set gDzArchiveChannelState = 2
    call DzCompat_Warn("archive: no ability can carry text (tried " + DzCompat_Archive_Id4(DZARCHIVE_CHANNEL_ABILITY) + " and others) - saves cannot be written or read. Set DZARCHIVE_CHANNEL_ABILITY in DzCompat_Archive.j to an ability that has tooltip text in the map's data")
    return false
endfunction

// Puts the channel ability's own tooltip back.
function DzCompat_Archive_TipEnd takes nothing returns nothing
    if gDzArchiveChannelState == 1 then
        call BlzSetAbilityTooltip(gDzArchiveChannel, gDzArchiveOrigTip, 0)
    endif
endfunction

// Runs one file and returns the data it left in the channel ("" when the file is missing,
// was not run, or carried nothing). Needs DzCompat_Archive_TipBegin first.
function DzCompat_Archive_ReadChunkFile takes string path returns string
    local string s
    call BlzSetAbilityTooltip(gDzArchiveChannel, "@", 0)
    call Preloader(path)
    set s = BlzGetAbilityTooltip(gDzArchiveChannel, 0)
    if s == null or SubString(s, 0, 1) != "@" then
        return ""
    endif
    return SubString(s, 1, StringLength(s))
endfunction

// ---------------------------------------------------------------------------
// Building the chunks of a store
// ---------------------------------------------------------------------------

// Adds one finished record to the chunk being built, starting a new chunk when it would
// not fit. recLen is the record's length after Esc.
function DzCompat_Archive_AddRecord takes string rec, integer recLen, integer usable returns nothing
    if gDzArchiveCurLen + recLen > usable then
        set gDzArchiveChunk[gDzArchiveChunkCount] = gDzArchiveCur
        set gDzArchiveChunkCount = gDzArchiveChunkCount + 1
        set gDzArchiveCur = ""
        set gDzArchiveCurLen = 0
    endif
    set gDzArchiveCur = gDzArchiveCur + rec
    set gDzArchiveCurLen = gDzArchiveCurLen + recLen
endfunction

// Builds the chunks that hold the whole store into gDzArchiveChunk. Every chunk is made
// so its escaped text plus the "#" lines fits one line. Returns the number of chunks (files),
// or 0 when the store is empty or does not fit DZARCHIVE_PARTS_MAX files.
function DzCompat_Archive_BuildChunks takes integer sid returns integer
    local integer usable = DzCompat_Archive_Capacity()
    local integer i = 0
    local integer n = gDzArchiveKeyCount[sid]
    local string key
    local string val
    local string keyEnc
    local string pieceEnc
    local string flag
    local integer keyLen
    local integer overhead
    local integer pos
    local integer take
    local integer valLen
    set gDzArchiveChunkCount = 0
    set gDzArchiveCur = ""
    set gDzArchiveCurLen = 0
    loop
        exitwhen i >= n
        set key = gDzArchiveKeys[sid * DZARCHIVE_KEYS_MAX + i]
        set val = LoadStr(gDzArchiveTable, sid, StringHash(key))
        if val != null and val != "" then
            set keyEnc = DzCompat_Archive_Enc(key, true)
            set keyLen = StringLength(DzCompat_Archive_Esc(keyEnc))
            set overhead = keyLen + 3                    // "=" + flag + line break
            if overhead >= usable - 8 then
                call DzCompat_Warn("archive: key " + key + " is too long to store - skipped")
            else
                set pos = 0
                set valLen = StringLength(val)
                loop
                    set take = DzCompat_Archive_PieceLen(val, pos, usable - overhead)
                    set pieceEnc = DzCompat_Archive_Enc(SubString(val, pos, pos + take), false)
                    if pos == 0 and pos + take >= valLen then
                        set flag = "s"
                    elseif pos == 0 then
                        set flag = "b"
                    else
                        set flag = "c"
                    endif
                    call DzCompat_Archive_AddRecord(keyEnc + "=" + flag + pieceEnc + "\n", keyLen + 2 + StringLength(DzCompat_Archive_Esc(pieceEnc)) + 1, usable)
                    set pos = pos + take
                    exitwhen pos >= valLen
                endloop
            endif
        endif
        set i = i + 1
    endloop
    if gDzArchiveChunkCount == 0 and gDzArchiveCur == "" then
        return 0
    endif
    // the closing marker: a file that was cut short cannot then pass for a complete save
    if gDzArchiveCurLen + StringLength(DZARCHIVE_EOF) > usable then
        set gDzArchiveChunk[gDzArchiveChunkCount] = gDzArchiveCur
        set gDzArchiveChunkCount = gDzArchiveChunkCount + 1
        set gDzArchiveCur = ""
    endif
    set gDzArchiveChunk[gDzArchiveChunkCount] = gDzArchiveCur + DZARCHIVE_EOF
    set gDzArchiveChunkCount = gDzArchiveChunkCount + 1
    if gDzArchiveChunkCount > DZARCHIVE_PARTS_MAX then
        call DzCompat_Warn("archive: the save needs " + I2S(gDzArchiveChunkCount) + " files, more than " + I2S(DZARCHIVE_PARTS_MAX) + " - nothing was written")
        return 0
    endif
    // identity tag of every file (checked when reading) and the file count in the first one
    set i = 0
    loop
        exitwhen i >= gDzArchiveChunkCount
        set gDzArchiveChunk[i] = "#p" + I2S(i) + ";\n" + gDzArchiveChunk[i]
        set i = i + 1
    endloop
    set gDzArchiveChunk[0] = "#" + I2S(gDzArchiveChunkCount) + ";\n" + gDzArchiveChunk[0]
    return gDzArchiveChunkCount
endfunction

// Writes the store's files under the given name prefix ("save_" for the live save).
// Returns true when every file was written.
function DzCompat_Archive_WriteStoreAs takes integer sid, string prefix returns boolean
    local integer parts = DzCompat_Archive_BuildChunks(sid)
    local integer i = 0
    if parts < 1 then
        return false
    endif
    loop
        exitwhen i >= parts
        if not DzCompat_Archive_WriteChunkFile(DzCompat_Archive_Path(sid, prefix, i), gDzArchiveChunk[i]) then
            return false
        endif
        set i = i + 1
    endloop
    return true
endfunction

// ---------------------------------------------------------------------------
// Reading a store
// ---------------------------------------------------------------------------

// Is the tag line of a part at the given position of s?
function DzCompat_Archive_TagAt takes string s, integer part, integer pos returns boolean
    local string tag = "#p" + I2S(part) + ";\n"
    return SubString(s, pos, pos + StringLength(tag)) == tag
endfunction

// One record of the file text: key=<flag><value>. Lines without "=" (tags, the closing
// marker) carry no data.
function DzCompat_Archive_ParseRecord takes integer sid, string rec returns nothing
    local integer e
    local string key
    local string v
    local string flag
    local string data
    if rec == DZARCHIVE_EOF then
        set gDzArchiveSawEof = true
        return
    endif
    set e = DzCompat_Archive_PosChar(rec, "=")
    if e <= 0 then
        return
    endif
    set key = DzCompat_Archive_Dec(SubString(rec, 0, e))
    set v = SubString(rec, e + 1, StringLength(rec))
    set flag = SubString(v, 0, 1)
    set data = DzCompat_Archive_Dec(SubString(v, 1, StringLength(v)))
    if flag == "s" or flag == "b" then
        call DzCompat_Archive_Mem(sid, key, data)
    elseif flag == "c" then
        call DzCompat_Archive_Mem(sid, key, LoadStr(gDzArchiveTable, sid, StringHash(key)) + data)
    endif
endfunction

// Reads the store from disk into memory (this machine's own files only; see the header).
function DzCompat_Archive_LoadStore takes integer sid returns nothing
    local string s
    local string rec
    local integer e
    local integer parts
    local integer i
    local integer n
    local integer j
    local integer k
    if not DzCompat_Archive_TipBegin() then
        call DzCompat_Archive_TipEnd()
        return
    endif
    set s = DzCompat_Archive_ReadChunkFile(DzCompat_Archive_Path(sid, DZARCHIVE_SAVE_NAME, 0))
    if s == "" then
        call DzCompat_Warn("archive: no save read from " + DzCompat_Archive_Path(sid, DZARCHIVE_SAVE_NAME, 0) + " (first run, or the file could not be read back)")
        call DzCompat_Archive_TipEnd()
        return
    endif
    set e = DzCompat_Archive_PosChar(s, ";")
    if SubString(s, 0, 1) != "#" or e < 2 or not DzCompat_Archive_TagAt(s, 0, e + 2) then
        call DzCompat_Warn("archive: the first file is not a save of this format - not loaded: " + SubString(s, 0, 40))
        call DzCompat_Archive_TipEnd()
        return
    endif
    set parts = S2I(SubString(s, 1, e))
    if parts < 1 then
        set parts = 1
    endif
    if parts > DZARCHIVE_PARTS_MAX then
        set parts = DZARCHIVE_PARTS_MAX
    endif
    // the rest of the files; each must be the part it claims to be, because the engine
    // hands back an old result when a path is run twice
    set i = 1
    loop
        exitwhen i >= parts
        set rec = DzCompat_Archive_ReadChunkFile(DzCompat_Archive_Path(sid, DZARCHIVE_SAVE_NAME, i))
        if not DzCompat_Archive_TagAt(rec, i, 0) then
            call DzCompat_Warn("archive: file " + I2S(i) + " of " + I2S(parts) + " is missing or is not part " + I2S(i) + " - the save was not loaded")
            call DzCompat_Archive_TipEnd()
            return
        endif
        set s = s + rec
        set i = i + 1
    endloop
    call DzCompat_Archive_TipEnd()
    // the records, one per line
    set gDzArchiveSawEof = false
    set n = StringLength(s)
    set j = e + 2
    loop
        exitwhen j >= n
        set k = DzCompat_Archive_PosLF(s, j)
        if k < 0 then
            set k = n
        endif
        call DzCompat_Archive_ParseRecord(sid, SubString(s, j, k))
        set j = k + 1
        exitwhen gDzArchiveSawEof
    endloop
    if not gDzArchiveSawEof then
        call DzCompat_Warn("archive: the save has no closing marker - it was cut short; what could be read was loaded")
    endif
    call DzCompat_Warn("archive: loaded " + I2S(gDzArchiveKeyCount[sid]) + " key(s) from " + I2S(parts) + " file(s) in " + DzCompat_Archive_Dir(sid))
endfunction

// A round trip through the channel with a file of its own: tells whether writing and
// reading work on this machine. Only run when diagnostics are on (DZCOMPAT_DEBUG_MESSAGES).
function DzCompat_Archive_SelfTest takes nothing returns nothing
    local string path = gDzArchiveFolder + "selftest.pld"
    local string back
    if not DzCompat_Archive_WriteChunkFile(path, "DZ-SELFTEST") then
        return
    endif
    if not DzCompat_Archive_TipBegin() then
        call DzCompat_Archive_TipEnd()
        return
    endif
    set back = DzCompat_Archive_ReadChunkFile(path)
    call DzCompat_Archive_TipEnd()
    if back == "DZ-SELFTEST" then
        call DzCompat_Warn("archive self-test: OK - the channel ability " + DzCompat_Archive_Id4(DzCompat_Archive_Channel()) + " carries data through a file")
    else
        call DzCompat_Warn("archive self-test: FAILED - the file was written but nothing came back through the tooltip of " + DzCompat_Archive_Id4(DzCompat_Archive_Channel()) + " (got: " + back + ")")
    endif
endfunction

// ---------------------------------------------------------------------------
// Flushing to disk and backups
// ---------------------------------------------------------------------------

// Writes one store now, if its files are on this machine. Returns true when written.
function DzCompat_Archive_FlushStore takes integer sid returns boolean
    if not DzCompat_Archive_IsLocalStore(sid) then
        set gDzArchiveDirty[sid] = false
        return false
    endif
    set gDzArchiveDirty[sid] = false
    return DzCompat_Archive_WriteStoreAs(sid, DZARCHIVE_SAVE_NAME)
endfunction

// Writes every changed store (public: KKApiEndBatchSaveArchive and "-save" flush by name).
function DzCompat_Archive_Flush takes nothing returns nothing
    local integer sid = 0
    loop
        exitwhen sid > DZARCHIVE_SHARED
        if gDzArchiveDirty[sid] then
            call DzCompat_Archive_FlushStore(sid)
        endif
        set sid = sid + 1
    endloop
endfunction

// One store per tick, so a burst of stores never adds up to one long-running thread.
function DzCompat_Archive_FlushTick takes nothing returns nothing
    local integer sid = 0
    local boolean more = false
    local boolean done = false
    loop
        exitwhen sid > DZARCHIVE_SHARED
        if gDzArchiveDirty[sid] then
            if done then
                set more = true
            else
                call DzCompat_Archive_FlushStore(sid)
                set done = true
            endif
        endif
        set sid = sid + 1
    endloop
    if more then
        call TimerStart(gDzArchiveFlushTimer, 0.05, false, function DzCompat_Archive_FlushTick)
    endif
endfunction

// Called after every change: writes now, or arms the delayed write.
function DzCompat_Archive_ScheduleFlush takes nothing returns nothing
    if DZARCHIVE_FLUSH_DELAY <= 0. then
        call DzCompat_Archive_Flush()
        return
    endif
    if gDzArchiveFlushTimer == null then
        set gDzArchiveFlushTimer = CreateTimer()
    endif
    call TimerStart(gDzArchiveFlushTimer, DZARCHIVE_FLUSH_DELAY, false, function DzCompat_Archive_FlushTick)
endfunction

// Snapshots every store this machine holds that changed since its last snapshot into the
// next backup slot (the oldest is overwritten - a fixed rotation, backups\b1_* .. b5_*).
function DzCompat_Archive_CreateBackup takes nothing returns nothing
    local integer sid = 0
    local string prefix = "backups\\b" + I2S(gDzArchiveBackupSlot + 1) + "_"
    local boolean any = false
    loop
        exitwhen sid > DZARCHIVE_SHARED
        if gDzArchiveStale[sid] and gDzArchiveKeyCount[sid] > 0 and DzCompat_Archive_IsLocalStore(sid) then
            call DzCompat_Archive_WriteStoreAs(sid, prefix)
            set any = true
        endif
        set gDzArchiveStale[sid] = false
        set sid = sid + 1
    endloop
    if any then
        set gDzArchiveBackupSlot = ModuloInteger(gDzArchiveBackupSlot + 1, DZARCHIVE_MAX_BACKUPS)
    endif
endfunction

// Periodic tick (started once per session): a backup every DZARCHIVE_BACKUP_EVERY_TICKS ticks.
function DzCompat_Archive_OnTick takes nothing returns nothing
    set gDzArchiveTickCount = gDzArchiveTickCount + 1
    if gDzArchiveTickCount >= DZARCHIVE_BACKUP_EVERY_TICKS then
        set gDzArchiveTickCount = 0
        call DzCompat_Archive_CreateBackup()
    endif
endfunction

// One-time set-up: the per-map folder and the backup clock. Safe to call any number of times.
function DzCompat_Archive_EnsureLoaded takes nothing returns nothing
    if gDzArchiveInited then
        return
    endif
    set gDzArchiveInited = true
    set gDzArchiveMapName = GetMapName()
    if gDzArchiveMapName == null or gDzArchiveMapName == "" then
        set gDzArchiveMapName = "UnknownMap"
    endif
    if gDzArchiveFolder == "" then
        set gDzArchiveFolder = "DzCompat_Archive\\" + gDzArchiveMapName + "\\"
    endif
    set gDzArchiveClockTimer = CreateTimer()
    call TimerStart(gDzArchiveClockTimer, DZARCHIVE_TICK_SECONDS, true, function DzCompat_Archive_OnTick)
    if DZCOMPAT_DEBUG_MESSAGES then
        call DzCompat_Archive_SelfTest()
    endif
endfunction

// Reads a store from disk the first time anything touches it (once per game: see the header).
function DzCompat_Archive_Ensure takes integer sid returns nothing
    call DzCompat_Archive_EnsureLoaded()
    if gDzArchiveTried[sid] then
        return
    endif
    set gDzArchiveTried[sid] = true
    if DzCompat_Archive_IsLocalStore(sid) then
        call DzCompat_Archive_LoadStore(sid)
    endif
endfunction

// ---------------------------------------------------------------------------
// Manual archive control: chat commands "-save" and "-load"
// ---------------------------------------------------------------------------
// -save  : write the changed stores to disk now (this machine's own files only).
// -load  : Warcraft runs each file once per game, so a save cannot be re-read while the
//          game runs; the command reports what was loaded at the start instead.
// Registration is lazy: the first Save / Load triggers DzCompat_Archive_RegisterChatCommands.
// ---------------------------------------------------------------------------

function DzCompat_Archive_CmdSave takes nothing returns nothing
    local player p = GetTriggerPlayer()
    call DzCompat_Archive_EnsureLoaded()
    call DzCompat_Archive_Flush()
    if GetLocalPlayer() == p then
        call DisplayTimedTextToPlayer(p, 0, 0, 8.0, "|cff00ff00[DzCompat Archive] Saved to disk.|r")
    endif
endfunction

function DzCompat_Archive_CmdLoad takes nothing returns nothing
    local player p = GetTriggerPlayer()
    local integer sid = DzCompat_Archive_StoreOf(p)
    call DzCompat_Archive_EnsureLoaded()
    if GetLocalPlayer() == p then
        call DisplayTimedTextToPlayer(p, 0, 0, 10.0, "|cff00ff00[DzCompat Archive]|r " + I2S(gDzArchiveKeyCount[sid]) + " key(s) in memory, loaded from " + DzCompat_Archive_Dir(sid) + ". A save is read once when the game starts; to load it again, start a new game.")
    endif
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
    local integer sid
    if whichPlayer == null or key == null or key == "" then
        return false
    endif
    set sid = DzCompat_Archive_StoreOf(whichPlayer)
    // read what is on disk BEFORE changing anything, so the files written later still hold
    // the keys this session never touched
    call DzCompat_Archive_Ensure(sid)
    call DzCompat_Archive_RegisterChatCommands()
    call DzCompat_Archive_Mem(sid, key, value)
    set gDzArchiveDirty[sid] = true
    set gDzArchiveStale[sid] = true
    call DzCompat_Archive_ScheduleFlush()
    return true
endfunction

function DzCompat_Archive_Load takes player whichPlayer, string key returns string
    local integer sid
    local string value
    if whichPlayer == null or key == null then
        return ""
    endif
    set sid = DzCompat_Archive_StoreOf(whichPlayer)
    call DzCompat_Archive_Ensure(sid)
    call DzCompat_Archive_RegisterChatCommands()
    set value = LoadStr(gDzArchiveTable, sid, StringHash(key))
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
