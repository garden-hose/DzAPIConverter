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

function JNStringSub takes string str, integer start, integer length returns string
    local integer n
    if str == null or length <= 0 then
        return ""
    endif
    if start < 0 then
        set start = 0
    endif
    set n = StringLength(str)
    if start >= n then
        return ""
    endif
    if start + length > n then
        set length = n - start
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

// index is clamped into 0 .. length, so an out-of-range index appends instead of failing.
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
    elseif index > n then
        set index = n
    endif
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

// Number of lines str needs when `length` characters fit on one line.
function JNStringCalcLines takes string str, integer length returns integer
    if str == null or length <= 0 then
        return 1
    endif
    return 1 + StringLength(str) / length
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
function JNI2R takes integer i returns real
    return I2R(i)
endfunction

function JNR2I takes real r returns integer
    return R2I(r)
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
