// ============================================================================
// DzCompat_StringBit.j
// Batch 4: string utility + bitwise natives from KKAPI.j
//
// These are pure algorithms with no engine dependency, so unlike the other
// batches this one is implemented outright rather than wrapping a Blz native
// (except the three bitwise ops that Reforged already provides natively).
// ============================================================================


    // ============================================================
    // BITWISE
    // ============================================================

    // [VERIFIED] real natives since patch 1.31 - simple passthrough
    function DzBitAnd takes integer a, integer b returns integer
        return BlzBitAnd(a, b)
    endfunction

    function DzBitOr takes integer a, integer b returns integer
        return BlzBitOr(a, b)
    endfunction

    function DzBitXor takes integer a, integer b returns integer
        return BlzBitXor(a, b)
    endfunction

    // [IMPLEMENTED] no native equivalent, but trivial given BlzBitXor:
    // NOT x == x XOR -1 (all bits set) in two's-complement 32-bit integers.
    function DzBitNot takes integer i returns integer
        return BlzBitXor(i, -1)
    endfunction

    // [IMPLEMENTED] shifts via arithmetic. JASS integers are 32-bit signed;
    // left shift overflow behavior matches native bitwise shifting for
    // shift amounts 0-31. Shifting by 32+ or negative amounts is undefined
    // here same as it would be at the engine level - guard your inputs.
    function DzBitShiftLeft takes integer i, integer bitsToShift returns integer
        local integer result = i
        local integer n = 0
        loop
            exitwhen n == bitsToShift
            set result = result * 2
            set n = n + 1
        endloop
        return result
    endfunction

    function DzBitShiftRight takes integer i, integer bitsToShift returns integer
        local integer result = i
        local integer n = 0
        loop
            exitwhen n == bitsToShift
            set result = result / 2
            set n = n + 1
        endloop
        return result
    endfunction

    // [IMPLEMENTED] byteIndex 0-3, byte 0 = least significant.
    function DzBitGetByte takes integer i, integer byteIndex returns integer
        return DzBitAnd(DzBitShiftRight(i, byteIndex * 8), 255)
    endfunction

    function DzBitSetByte takes integer i, integer byteIndex, integer byteValue returns integer
        local integer mask = DzBitNot(DzBitShiftLeft(255, byteIndex * 8))
        local integer cleared = DzBitAnd(i, mask)
        return DzBitOr(cleared, DzBitShiftLeft(DzBitAnd(byteValue, 255), byteIndex * 8))
    endfunction

    // [IMPLEMENTED] single-bit get/set within a byte. byteIndex here follows
    // Dz's own naming (it takes a byteIndex param but operates at bit
    // granularity per the original signature) - if your actual usage treats
    // this as a raw bit index 0-31 instead of "bit within byteIndex", tell me
    // and I'll adjust; the original native's exact indexing convention isn't
    // fully clear from the signature alone.
    function DzBitGet takes integer i, integer byteIndex returns integer
        return DzBitAnd(DzBitShiftRight(i, byteIndex), 1)
    endfunction

    function DzBitSet takes integer i, integer byteIndex, integer byteValue returns integer
        local integer mask = DzBitNot(DzBitShiftLeft(1, byteIndex))
        local integer cleared = DzBitAnd(i, mask)
        if byteValue != 0 then
            return DzBitOr(cleared, DzBitShiftLeft(1, byteIndex))
        endif
        return cleared
    endfunction

    // [IMPLEMENTED] pack 4 bytes (b1 = least significant) into one integer.
    function DzBitToInt takes integer b1, integer b2, integer b3, integer b4 returns integer
        local integer result = DzBitAnd(b1, 255)
        set result = DzBitOr(result, DzBitShiftLeft(DzBitAnd(b2, 255), 8))
        set result = DzBitOr(result, DzBitShiftLeft(DzBitAnd(b3, 255), 16))
        set result = DzBitOr(result, DzBitShiftLeft(DzBitAnd(b4, 255), 24))
        return result
    endfunction

    // ============================================================
    // STRING
    // ============================================================

    // [IMPLEMENTED] case-folding helper - JASS has no built-in lower(), so
    // this hand-rolls ASCII A-Z -> a-z. Only handles ASCII; if your map's
    // strings need non-ASCII case-insensitive matching this won't cover it.
    function DzCompat_CharIndexUpper takes string c returns integer
        local string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        local integer i = 0
        loop
            exitwhen i == 26
            if SubString(alphabet, i, i + 1) == c then
                return i
            endif
            set i = i + 1
        endloop
        return -1
    endfunction

    function DzCompat_ToLowerAscii takes string s returns string
        local string lower = "abcdefghijklmnopqrstuvwxyz"
        local integer len = StringLength(s)
        local integer i = 0
        local integer idx
        local string result = ""
        local string c
        loop
            exitwhen i == len
            set c = SubString(s, i, i + 1)
            set idx = DzCompat_CharIndexUpper(c)
            if idx >= 0 then
                set result = result + SubString(lower, idx, idx + 1)
            else
                set result = result + c
            endif
            set i = i + 1
        endloop
        return result
    endfunction

    function DzCompat_Fold takes string s, boolean caseSensitive returns string
        if caseSensitive then
            return s
        endif
        return DzCompat_ToLowerAscii(s)
    endfunction

    // [IMPLEMENTED] returns -1 if not found, matching typical Dz/C++ find()
    // convention (confirm against your actual usage - if the original
    // returns 0 for "not found" instead, tell me and I'll adjust the
    // sentinel value).
    function DzStringFind takes string s, string whichString, integer off, boolean caseSensitive returns integer
        local string hay = DzCompat_Fold(s, caseSensitive)
        local string needle = DzCompat_Fold(whichString, caseSensitive)
        local integer hayLen = StringLength(hay)
        local integer needleLen = StringLength(needle)
        local integer i = off
        if needleLen == 0 then
            return off
        endif
        loop
            exitwhen i + needleLen > hayLen
            if SubString(hay, i, i + needleLen) == needle then
                return i
            endif
            set i = i + 1
        endloop
        return -1
    endfunction

    function DzStringContains takes string s, string whichString, boolean caseSensitive returns boolean
        return DzStringFind(s, whichString, 0, caseSensitive) != -1
    endfunction

    function DzStringFindFirstOf takes string s, string whichString, integer off, boolean caseSensitive returns integer
        local string hay = DzCompat_Fold(s, caseSensitive)
        local string set_ = DzCompat_Fold(whichString, caseSensitive)
        local integer hayLen = StringLength(hay)
        local integer setLen = StringLength(set_)
        local integer i = off
        local integer j
        loop
            exitwhen i == hayLen
            set j = 0
            loop
                exitwhen j == setLen
                if SubString(hay, i, i + 1) == SubString(set_, j, j + 1) then
                    return i
                endif
                set j = j + 1
            endloop
            set i = i + 1
        endloop
        return -1
    endfunction

    function DzStringFindFirstNotOf takes string s, string whichString, integer off, boolean caseSensitive returns integer
        local string hay = DzCompat_Fold(s, caseSensitive)
        local string set_ = DzCompat_Fold(whichString, caseSensitive)
        local integer hayLen = StringLength(hay)
        local integer setLen = StringLength(set_)
        local integer i = off
        local integer j
        local boolean found
        loop
            exitwhen i == hayLen
            set found = false
            set j = 0
            loop
                exitwhen j == setLen
                if SubString(hay, i, i + 1) == SubString(set_, j, j + 1) then
                    set found = true
                endif
                set j = j + 1
            endloop
            if not found then
                return i
            endif
            set i = i + 1
        endloop
        return -1
    endfunction

    function DzStringFindLastOf takes string s, string whichString, integer off, boolean caseSensitive returns integer
        local string hay = DzCompat_Fold(s, caseSensitive)
        local string set_ = DzCompat_Fold(whichString, caseSensitive)
        local integer hayLen = StringLength(hay)
        local integer setLen = StringLength(set_)
        local integer i = hayLen - 1
        local integer j
        if off < hayLen - 1 and off >= 0 then
            set i = off
        endif
        loop
            exitwhen i < 0
            set j = 0
            loop
                exitwhen j == setLen
                if SubString(hay, i, i + 1) == SubString(set_, j, j + 1) then
                    return i
                endif
                set j = j + 1
            endloop
            set i = i - 1
        endloop
        return -1
    endfunction

    function DzStringFindLastNotOf takes string s, string whichString, integer off, boolean caseSensitive returns integer
        local string hay = DzCompat_Fold(s, caseSensitive)
        local string set_ = DzCompat_Fold(whichString, caseSensitive)
        local integer hayLen = StringLength(hay)
        local integer setLen = StringLength(set_)
        local integer i = hayLen - 1
        local integer j
        local boolean found
        if off < hayLen - 1 and off >= 0 then
            set i = off
        endif
        loop
            exitwhen i < 0
            set found = false
            set j = 0
            loop
                exitwhen j == setLen
                if SubString(hay, i, i + 1) == SubString(set_, j, j + 1) then
                    set found = true
                endif
                set j = j + 1
            endloop
            if not found then
                return i
            endif
            set i = i - 1
        endloop
        return -1
    endfunction

    function DzStringTrimLeft takes string s returns string
        local integer len = StringLength(s)
        local integer i = 0
        loop
            exitwhen i == len
            if SubString(s, i, i + 1) != " " then
                exitwhen true
            endif
            set i = i + 1
        endloop
        return SubString(s, i, len)
    endfunction

    function DzStringTrimRight takes string s returns string
        local integer len = StringLength(s)
        local integer i = len
        loop
            exitwhen i == 0
            if SubString(s, i - 1, i) != " " then
                exitwhen true
            endif
            set i = i - 1
        endloop
        return SubString(s, 0, i)
    endfunction

    function DzStringTrim takes string s returns string
        return DzStringTrimLeft(DzStringTrimRight(s))
    endfunction

    function DzStringReverse takes string s returns string
        local integer len = StringLength(s)
        local integer i = len - 1
        local string result = ""
        loop
            exitwhen i < 0
            set result = result + SubString(s, i, i + 1)
            set i = i - 1
        endloop
        return result
    endfunction

    function DzStringReplace takes string s, string whichString, string replaceWith, boolean caseSensitive returns string
        local string hay = DzCompat_Fold(s, caseSensitive)
        local string needle = DzCompat_Fold(whichString, caseSensitive)
        local integer needleLen = StringLength(needle)
        local integer hayLen = StringLength(s)
        local integer i = 0
        local string result = ""
        if needleLen == 0 then
            return s
        endif
        loop
            exitwhen i >= hayLen
            if i + needleLen <= hayLen and SubString(hay, i, i + needleLen) == needle then
                set result = result + replaceWith
                set i = i + needleLen
            else
                set result = result + SubString(s, i, i + 1) // pulled from original (unfolded) string to preserve case in output
                set i = i + 1
            endif
        endloop
        return result
    endfunction

    function DzStringInsert takes string s, integer whichPosition, string whichString returns string
        return SubString(s, 0, whichPosition) + whichString + SubString(s, whichPosition, StringLength(s))
    endfunction

