// ============================================================================
// DzCompat_JN.j
// "JN" (JassNative) natives that can be emulated locally: string helpers, base64,
// stopwatch, integer/real casts and the login / connection answers.
//
// NOT covered here: everything that needs the M16 save channel - the JNObject*
// stores, score / rank / areasteal lists, mail, groups, daily checks, save codes, logging, memory
// access (JNMemory*, JNProcCall), time and push natives. A map that declares them still gets the
// converter's neutral-value stubs for them, which is what the original layer returns for them too.
//
// LIMITATIONS
//   - Strings are measured in BYTES (StringLength / SubString). Position, length and count results
//     match the originals for ASCII text; for multi-byte (UTF-8) text they count bytes, not characters.
//   - Base64 only handles ASCII (32..126). Anything else is returned unchanged, because JASS cannot
//     read the numeric value of a byte above 127.
//   - JNStringRegex is not emulated (JASS has no regular expressions) and stays a stub.
// ============================================================================

globals
    // Printable ASCII, code 32..126, in code order (DzCompat_JN_Ord / DzCompat_JN_Chr).
    constant string DZJN_ASCII = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"
    constant string DZJN_BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    // JNStopwatch*: one shared clock timer, ids 1 .. gDzJN_StopwatchCount.
    timer         gDzJN_Clock = null
    integer       gDzJN_StopwatchCount = 0
    real array    gDzJN_StopwatchStart
    real array    gDzJN_StopwatchTotal
    boolean array gDzJN_StopwatchRunning

    // JNGetMaxAttackSpeed / JNGetSyncDelay: what the map set, from the client's defaults (the attack speed
    // cap of Game.dll, 5.0, which the JassNative plugin restores at every map end; the Hera loader sets the
    // network delay to 100 ms). Reforged changes neither, so the value only reads back.
    real    gDzJN_MaxAttackSpeed = 5.0
    integer gDzJN_SyncDelay = 100

    // JNStringCalcLines: lines counted, width of the current line, width of the current word
    integer gDzJN_CLLines = 0
    integer gDzJN_CLLine = 0
    integer gDzJN_CLWord = 0
endglobals

// ---- ASCII helpers ---------------------------------------------------------
// Code (32..126) of a one-character string, -1 for anything else. The table is searched with ==,
// which is case-sensitive, so "a" and "A" give different codes.
function DzCompat_JN_Ord takes string c returns integer
    local integer i = 0
    if c == null then
        return -1
    endif
    loop
        exitwhen i >= 95
        if SubString(DZJN_ASCII, i, i + 1) == c then
            return i + 32
        endif
        set i = i + 1
    endloop
    return -1
endfunction

// One-character string for a character code in 32..126, "" for any other code.
function DzCompat_JN_Chr takes integer charCode returns string
    if charCode < 32 or charCode > 126 then
        return ""
    endif
    return SubString(DZJN_ASCII, charCode - 32, charCode - 31)
endfunction

function DzCompat_JN_IsSpace takes string c returns boolean
    return c == " " or c == "\t" or c == "\r" or c == "\n"
endfunction

// ---- strings ---------------------------------------------------------------
function JNStringLength takes string str returns integer
    if str == null then
        return 0
    endif
    return StringLength(str)
endfunction

// Index of the first occurrence of sub, -1 when there is none (an empty sub is never found).
function JNStringPos takes string str, string sub returns integer
    if str == null or sub == null or sub == "" then
        return -1
    endif
    return DzStringFind(str, sub, 0, true)
endfunction

function JNStringContains takes string str, string sub returns boolean
    return JNStringPos(str, sub) != -1
endfunction

// As the M16 client (Cirnix.JassNative.Common JassString.cs StringSub): a length of 0 or a start at or
// past the end gives ""; a negative start is eaten from the length (length += start, start = 0); a
// NEGATIVE length, or one past the end, gives the REST of the text (it used to give "" for length < 0).
// Proven in game in our layer (the M16 maps).
function JNStringSub takes string str, integer start, integer length returns string
    local integer n
    if str == null or length == 0 then
        return ""
    endif
    if start < 0 then
        set length = length + start
        set start = 0
    endif
    set n = StringLength(str)
    if start >= n then
        return ""
    endif
    if length < 0 or start + length > n then
        return SubString(str, start, n)
    endif
    return SubString(str, start, start + length)
endfunction

// The index-th piece (0-based) of str cut at every sub; "" when there is no such piece.
function JNStringSplit takes string str, string sub, integer index returns string
    local integer n
    local integer m
    local integer start = 0
    local integer piece = 0
    local integer p
    if str == null or sub == null or index < 0 then
        return ""
    endif
    set n = StringLength(str)
    set m = StringLength(sub)
    if m <= 0 then
        if index == 0 then
            return str
        endif
        return ""
    endif
    loop
        set p = DzStringFind(str, sub, start, true)
        if p < 0 then
            if piece == index then
                return SubString(str, start, n)
            endif
            return ""
        endif
        if piece == index then
            return SubString(str, start, p)
        endif
        set piece = piece + 1
        set start = p + m
    endloop
    return ""
endfunction

// How many times sub occurs in str, without overlapping.
function JNStringCount takes string str, string sub returns integer
    local integer m
    local integer start = 0
    local integer total = 0
    local integer p
    if str == null or sub == null or sub == "" then
        return 0
    endif
    set m = StringLength(sub)
    loop
        set p = DzStringFind(str, sub, start, true)
        exitwhen p < 0
        set total = total + 1
        set start = p + m
    endloop
    return total
endfunction

function JNStringReverse takes string str returns string
    if str == null then
        return ""
    endif
    return DzStringReverse(str)
endfunction

// Trims space, tab, CR and LF (DzStringTrim* only trims spaces).
function JNStringTrimStart takes string str returns string
    local integer n
    local integer i = 0
    if str == null then
        return ""
    endif
    set n = StringLength(str)
    loop
        exitwhen i >= n
        exitwhen not DzCompat_JN_IsSpace(SubString(str, i, i + 1))
        set i = i + 1
    endloop
    return SubString(str, i, n)
endfunction

function JNStringTrimEnd takes string str returns string
    local integer i
    if str == null then
        return ""
    endif
    set i = StringLength(str)
    loop
        exitwhen i <= 0
        exitwhen not DzCompat_JN_IsSpace(SubString(str, i - 1, i))
        set i = i - 1
    endloop
    return SubString(str, 0, i)
endfunction

function JNStringTrim takes string str returns string
    return JNStringTrimEnd(JNStringTrimStart(str))
endfunction

// As the M16 client (JassString.cs StringInsert: str.PadRight(index).Insert(index, val)): a negative
// index is 0, and an index past the end first PADS the text with spaces up to it (it used to append
// at the end instead).
function JNStringInsert takes string str, integer index, string val returns string
    local integer n
    if str == null then
        set str = ""
    endif
    if val == null then
        set val = ""
    endif
    set n = StringLength(str)
    if index < 0 then
        set index = 0
    endif
    loop
        exitwhen n >= index
        set str = str + " "
        set n = n + 1
    endloop
    return DzStringInsert(str, index, val)
endfunction

// Replaces every occurrence of old (case-sensitive). An empty old leaves str as it is.
function JNStringReplace takes string str, string old, string newstr returns string
    if str == null or old == null or old == "" then
        return str
    endif
    if newstr == null then
        set newstr = ""
    endif
    return DzStringReplace(str, old, newstr, true)
endfunction

// A hexadecimal digit (for the |cAARRGGBB color codes of JNStringCalcLines).
function DzCompat_JN_IsHex takes string c returns boolean
    local integer v = DzCompat_JN_Ord(c)
    return (v >= 48 and v <= 57) or (v >= 65 and v <= 70) or (v >= 97 and v <= 102)
endfunction

// Adds one character of width w to the word being measured and breaks the line where the client does.
// gDzJN_CL* hold the state of the JNStringCalcLines call in progress.
function DzCompat_JN_CalcAdd takes integer w, integer length returns nothing
    set gDzJN_CLWord = gDzJN_CLWord + w
    if gDzJN_CLWord >= length then
        set gDzJN_CLWord = 0
        set gDzJN_CLLines = gDzJN_CLLines + 1
    elseif gDzJN_CLLine > 0 and gDzJN_CLWord + gDzJN_CLLine + 1 >= length then
        set gDzJN_CLLine = 0
        set gDzJN_CLLines = gDzJN_CLLines + 1
    endif
endfunction

// The M16 client's line count (JassString.cs StringCalcLines; maps use it to size a tooltip box): the
// text without trailing spaces is cut into words at spaces; a character below U+0100 is 1 wide and any
// other (hangul, CJK) 2; |cAARRGGBB and |r have no width; |n and a line feed break the line; a line breaks
// when a word alone reaches `length`, or when the word plus what the line already holds passes it. null or
// a length <= 0 gives 0. It used to be 1 + characters / length, which gave half the lines of a Korean
// tooltip. Proven in game in our layer.
// [APPROX] Strings are bytes here: a run of non-ASCII bytes is read as 3-byte UTF-8 characters (all of
// hangul and CJK), so a 2-byte character (Latin-1, Cyrillic) is measured wrong.
function JNStringCalcLines takes string str, integer length returns integer
    local integer n
    local integer i = 0
    local integer k
    local string c
    local string d
    if str == null or length <= 0 then
        return 0
    endif
    set str = JNStringTrimEnd(str)
    set n = StringLength(str)
    set gDzJN_CLLines = 1
    set gDzJN_CLLine = 0
    set gDzJN_CLWord = 0
    loop
        exitwhen i >= n
        set c = SubString(str, i, i + 1)
        set d = SubString(str, i + 1, i + 2)
        if c == " " then
            // the end of a word (an empty one, between two spaces, counts 1 as well)
            set gDzJN_CLLine = gDzJN_CLLine + gDzJN_CLWord + 1
            set gDzJN_CLWord = 0
            set i = i + 1
        elseif c == "\n" or (c == "|" and (d == "n" or d == "N")) then
            if c == "|" then
                set i = i + 1
            endif
            set i = i + 1
            set gDzJN_CLLine = 0
            set gDzJN_CLWord = 0
            set gDzJN_CLLines = gDzJN_CLLines + 1
            if i >= n or SubString(str, i, i + 1) == " " then
                set gDzJN_CLWord = 1
            endif
        elseif c == "\r" then
            set i = i + 1
        elseif c == "|" and (d == "r" or d == "R") then
            set i = i + 2
        elseif c == "|" and (d == "c" or d == "C") then
            // a whole |cAARRGGBB has no width; an incomplete one counts its "|"
            set k = 0
            loop
                exitwhen k >= 8 or not DzCompat_JN_IsHex(SubString(str, i + 2 + k, i + 3 + k))
                set k = k + 1
            endloop
            if k >= 8 then
                set i = i + 10
            else
                call DzCompat_JN_CalcAdd(1, length)
                set i = i + 1
            endif
        elseif DzCompat_JN_Ord(c) >= 0 or c == "\t" then
            call DzCompat_JN_CalcAdd(1, length)
            set i = i + 1
        else
            call DzCompat_JN_CalcAdd(2, length)
            set i = i + 3
        endif
    endloop
    return gDzJN_CLLines
endfunction

// ---- base64 ----------------------------------------------------------------
function DzCompat_JN_B64Value takes string c returns integer
    local integer i = 0
    loop
        exitwhen i >= 64
        if SubString(DZJN_BASE64, i, i + 1) == c then
            return i
        endif
        set i = i + 1
    endloop
    return -1
endfunction

function DzCompat_JN_B64Char takes integer v returns string
    return SubString(DZJN_BASE64, v, v + 1)
endfunction

// [PORT LIMITATION] ASCII text only: a string with any other byte is returned unchanged.
function JNStringToBase64 takes string str returns string
    local integer n
    local integer i = 0
    local integer a
    local integer b
    local integer c
    local string result = ""
    if str == null or str == "" then
        return ""
    endif
    set n = StringLength(str)
    loop
        exitwhen i >= n
        set a = DzCompat_JN_Ord(SubString(str, i, i + 1))
        set b = -1
        set c = -1
        if a < 0 then
            return str
        endif
        if i + 1 < n then
            set b = DzCompat_JN_Ord(SubString(str, i + 1, i + 2))
            if b < 0 then
                return str
            endif
        endif
        if i + 2 < n then
            set c = DzCompat_JN_Ord(SubString(str, i + 2, i + 3))
            if c < 0 then
                return str
            endif
        endif
        set result = result + DzCompat_JN_B64Char(a / 4)
        if b < 0 then
            set result = result + DzCompat_JN_B64Char(ModuloInteger(a, 4) * 16) + "=="
        elseif c < 0 then
            set result = result + DzCompat_JN_B64Char(ModuloInteger(a, 4) * 16 + b / 16) + DzCompat_JN_B64Char(ModuloInteger(b, 16) * 4) + "="
        else
            set result = result + DzCompat_JN_B64Char(ModuloInteger(a, 4) * 16 + b / 16) + DzCompat_JN_B64Char(ModuloInteger(b, 16) * 4 + c / 64) + DzCompat_JN_B64Char(ModuloInteger(c, 64))
        endif
        set i = i + 3
    endloop
    return result
endfunction

// [PORT LIMITATION] Returns str unchanged when it is not valid base64 or does not decode to printable ASCII.
function JNStringFromBase64 takes string str returns string
    local integer n
    local integer i = 0
    local integer a
    local integer b
    local integer c
    local integer d
    local integer v
    local string result = ""
    if str == null or str == "" then
        return ""
    endif
    set n = StringLength(str)
    if ModuloInteger(n, 4) != 0 then
        return str
    endif
    loop
        exitwhen i >= n
        set a = DzCompat_JN_B64Value(SubString(str, i, i + 1))
        set b = DzCompat_JN_B64Value(SubString(str, i + 1, i + 2))
        set c = -2
        set d = -2
        if SubString(str, i + 2, i + 3) != "=" then
            set c = DzCompat_JN_B64Value(SubString(str, i + 2, i + 3))
        endif
        if SubString(str, i + 3, i + 4) != "=" then
            set d = DzCompat_JN_B64Value(SubString(str, i + 3, i + 4))
        endif
        // -1 = not a base64 character, -2 = padding; padding is only valid in the last group
        if a < 0 or b < 0 or c == -1 or d == -1 or (c == -2 and d != -2) or ((c == -2 or d == -2) and i + 4 < n) then
            return str
        endif
        set v = a * 4 + b / 16
        if v < 32 or v > 126 then
            return str
        endif
        set result = result + DzCompat_JN_Chr(v)
        if c >= 0 then
            set v = ModuloInteger(b, 16) * 16 + c / 4
            if v < 32 or v > 126 then
                return str
            endif
            set result = result + DzCompat_JN_Chr(v)
            if d >= 0 then
                set v = ModuloInteger(c, 4) * 64 + d
                if v < 32 or v > 126 then
                    return str
                endif
                set result = result + DzCompat_JN_Chr(v)
            endif
        endif
        set i = i + 4
    endloop
    return result
endfunction

function JNStringBase64Encoding takes string str returns string
    return JNStringToBase64(str)
endfunction

// [APPROX] No key-based cipher is emulated: the text passes through unchanged in both directions,
// so a map that encrypts and later decrypts the same value still gets its own text back.
function JNStringEncrypt takes string plainText, string key returns string
    return plainText
endfunction

function JNStringDecrypt takes string cipherText, string key returns string
    return cipherText
endfunction

// ---- stopwatch -------------------------------------------------------------
function DzCompat_JN_Now takes nothing returns real
    if gDzJN_Clock == null then
        set gDzJN_Clock = CreateTimer()
        call TimerStart(gDzJN_Clock, 1000000., false, null)
    endif
    return TimerGetElapsed(gDzJN_Clock)
endfunction

// Seconds the stopwatch has counted so far (0 for an unknown id).
function DzCompat_JN_StopwatchSeconds takes integer id returns real
    if id < 1 or id > gDzJN_StopwatchCount then
        return 0.
    endif
    if gDzJN_StopwatchRunning[id] then
        return gDzJN_StopwatchTotal[id] + DzCompat_JN_Now() - gDzJN_StopwatchStart[id]
    endif
    return gDzJN_StopwatchTotal[id]
endfunction

// Returns the new id, 0 when the 8190 available ids are used up. A new stopwatch starts stopped.
function JNStopwatchCreate takes nothing returns integer
    if gDzJN_StopwatchCount >= 8190 then
        return 0
    endif
    set gDzJN_StopwatchCount = gDzJN_StopwatchCount + 1
    set gDzJN_StopwatchTotal[gDzJN_StopwatchCount] = 0.
    set gDzJN_StopwatchRunning[gDzJN_StopwatchCount] = false
    return gDzJN_StopwatchCount
endfunction

function JNStopwatchStart takes integer id returns nothing
    if id < 1 or id > gDzJN_StopwatchCount or gDzJN_StopwatchRunning[id] then
        return
    endif
    set gDzJN_StopwatchStart[id] = DzCompat_JN_Now()
    set gDzJN_StopwatchRunning[id] = true
endfunction

function JNStopwatchPause takes integer id returns nothing
    if id < 1 or id > gDzJN_StopwatchCount or not gDzJN_StopwatchRunning[id] then
        return
    endif
    set gDzJN_StopwatchTotal[id] = DzCompat_JN_StopwatchSeconds(id)
    set gDzJN_StopwatchRunning[id] = false
endfunction

// Back to 0; a running stopwatch keeps running from 0.
function JNStopwatchReset takes integer id returns nothing
    if id < 1 or id > gDzJN_StopwatchCount then
        return
    endif
    set gDzJN_StopwatchTotal[id] = 0.
    set gDzJN_StopwatchStart[id] = DzCompat_JN_Now()
endfunction

// Ids are not reused: the stopwatch is stopped and zeroed.
function JNStopwatchDestroy takes integer id returns nothing
    if id < 1 or id > gDzJN_StopwatchCount then
        return
    endif
    set gDzJN_StopwatchTotal[id] = 0.
    set gDzJN_StopwatchRunning[id] = false
endfunction

function JNStopwatchElapsedMS takes integer id returns integer
    return R2I(DzCompat_JN_StopwatchSeconds(id) * 1000.)
endfunction

function JNStopwatchElapsedSecond takes integer id returns integer
    return R2I(DzCompat_JN_StopwatchSeconds(id))
endfunction

function JNStopwatchElapsedMinute takes integer id returns integer
    return R2I(DzCompat_JN_StopwatchSeconds(id) / 60.)
endfunction

function JNStopwatchElapsedHour takes integer id returns integer
    return R2I(DzCompat_JN_StopwatchSeconds(id) / 3600.)
endfunction

// ---- casts / browser -------------------------------------------------------
// JNI2R / JNR2I are BIT casts in the M16 client (BitConverter: the 32 bits of the integer read as the
// game's 32-bit IEEE 754 real, and back), not value conversions: a map that stores XP as
// BitXor(JNR2I(xp), key) lost the fraction with R2I. Proven in game in our layer (the Blc1 M16 map).
// Inf/NaN (exponent 255) come out as the largest exponent.
function JNI2R takes integer i returns real
    local boolean neg = i < 0
    local integer e
    local integer m
    local real v
    if i == 0 or i == -2147483647 - 1 then
        return 0.
    endif
    if neg then
        set i = i + 2147483647 + 1
    endif
    set e = i / 8388608
    set m = i - e * 8388608
    if e == 0 then
        set v = I2R(m)
        set e = -149
    else
        set v = 1. + I2R(m) / 8388608.
        set e = e - 127
    endif
    loop
        exitwhen e <= 0
        set v = v * 2.
        set e = e - 1
    endloop
    loop
        exitwhen e >= 0
        set v = v * 0.5
        set e = e + 1
    endloop
    if neg then
        return -v
    endif
    return v
endfunction

// The inverse of JNI2R: sign, exponent with the 127 bias, 23 mantissa bits (exponent 0 for subnormals).
function JNR2I takes real r returns integer
    local integer e = 127
    local integer m
    local real a = r
    if r == 0. then
        return 0
    endif
    if r < 0. then
        set a = -r
    endif
    loop
        exitwhen a < 2. or e >= 254
        set a = a * 0.5
        set e = e + 1
    endloop
    loop
        exitwhen a >= 1. or e <= 1
        set a = a * 2.
        set e = e - 1
    endloop
    if a < 1. then
        set m = R2I(a * 8388608.)
        set e = 0
    else
        set m = R2I((a - 1.) * 8388608.)
    endif
    if r < 0. then
        return e * 8388608 + m - 2147483647 - 1
    endif
    return e * 8388608 + m
endfunction

function JNGetMaxAttackSpeed takes nothing returns real
    return gDzJN_MaxAttackSpeed
endfunction

function JNSetMaxAttackSpeed takes real speed returns nothing
    set gDzJN_MaxAttackSpeed = speed
endfunction

// The client clamps the delay into 10 .. 550 ms (JassMiscellaneous.cs SetSyncDelay).
function JNGetSyncDelay takes nothing returns integer
    return gDzJN_SyncDelay
endfunction

function JNSetSyncDelay takes integer delay returns nothing
    if delay <= 10 then
        set gDzJN_SyncDelay = 10
    elseif delay >= 550 then
        set gDzJN_SyncDelay = 550
    else
        set gDzJN_SyncDelay = delay
    endif
endfunction

// No browser can be opened from JASS: the address is shown to the local player instead.
function JNOpenBrowser takes string Address returns nothing
    if Address != null and Address != "" then
        call DisplayTimedTextToPlayer(GetLocalPlayer(), 0., 0., 30., Address)
    endif
endfunction

// ---- login / connection ----------------------------------------------------
// [APPROX] There is no account server: every login and connection check answers "success", and
// the login id is the local player's name.
function JNGetSettingLogin takes nothing returns boolean
    return true
endfunction

function JNGetSettingLoginID takes nothing returns string
    return GetPlayerName(GetLocalPlayer())
endfunction

function JNLocalLogin takes string id returns boolean
    return true
endfunction

function JNLogin takes string id, string password returns boolean
    return true
endfunction

function JNObjectCharacterServerConnectCheck takes nothing returns boolean
    return true
endfunction

// 'BNET' = connected through Battle.net.
function JNGetConnectionState takes nothing returns integer
    return 'BNET'
endfunction
