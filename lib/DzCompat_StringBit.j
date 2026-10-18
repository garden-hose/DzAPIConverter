// ============================================================================
// DzCompat_StringBit.j
//
// These are pure algorithms with no engine dependency, so unlike the other
// batches this one is implemented outright rather than wrapping a Blz native
// (except the three bitwise ops that Reforged already provides natively).
// ============================================================================


    // ============================================================
    // BITWISE
    // ============================================================

    // real natives since patch 1.31 - simple passthrough
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

    // [IMPLEMENTED] shifts. The dll (kkapi_local_plugin.dll 0x10070630 / 0x10070640) takes the count
    // modulo 32 ("n & 0x1f", so 32 -> 0 and 33 -> 1, never a no-op for >= 32), and DzBitShiftRight is
    // a LOGICAL shift (the dll declares the value as uint): zero bits come in from the left, so
    // DzBitShiftRight(-1, 1) == 2147483647 and DzBitShiftRight(-1, 24) == 255. A plain "/ 2" loop is an
    // arithmetic shift that truncates toward zero and gets every negative input wrong (colors with
    // alpha >= 128, hashes and packed bitfields are negative integers).
    function DzBitShiftLeft takes integer i, integer bitsToShift returns integer
        local integer n = BlzBitAnd(bitsToShift, 31)
        local integer k = 0
        loop
            exitwhen k >= n
            set i = i * 2 // JASS integers wrap on overflow, same as the C shift
            set k = k + 1
        endloop
        return i
    endfunction

    function DzBitShiftRight takes integer i, integer bitsToShift returns integer
        local integer n = BlzBitAnd(bitsToShift, 31)
        local integer k = 0
        local integer sign = 1
        if n == 0 then
            return i
        endif
        if i < 0 then
            // drop the sign bit, shift the 31 remaining bits, then put the sign bit back at bit (31 - n)
            set i = BlzBitAnd(i, 0x7FFFFFFF)
            set k = 31 - n
            loop
                exitwhen k <= 0
                set sign = sign * 2
                set k = k - 1
            endloop
        else
            set sign = 0
        endif
        set k = 0
        loop
            exitwhen k >= n
            set i = i / 2
            set k = k + 1
        endloop
        return i + sign
    endfunction

    // [IMPLEMENTED] byteIndex wraps modulo 4 (the dll computes "(byteIndex * 8) & 0x1f"), byte 0 = least
    // significant. DzBitSetByte does NOT mask the value to 8 bits in the dll (0x10070600), so a value above
    // 255 spills into the next byte, and that is kept here.
    function DzBitGetByte takes integer i, integer byteIndex returns integer
        return DzBitAnd(DzBitShiftRight(i, BlzBitAnd(byteIndex, 3) * 8), 255)
    endfunction

    function DzBitSetByte takes integer i, integer byteIndex, integer byteValue returns integer
        local integer shift = BlzBitAnd(byteIndex, 3) * 8
        local integer mask = DzBitNot(DzBitShiftLeft(255, shift))
        return DzBitOr(DzBitAnd(i, mask), DzBitShiftLeft(byteValue, shift))
    endfunction

    // [IMPLEMENTED] DzBitGet/DzBitSet work on a single BIT: the index is a bit number 0..31 taken modulo 32
    // (dll 0x10070590 "(i >> (idx & 0x1f)) & 1"). DzBitSet (0x100705e0) is "(byte)value << idx | i & ~(1 << idx)":
    // the value is a byte, not a flag, so only 0 and 1 are "normal" inputs; other values are or-ed in as-is.
    function DzBitGet takes integer i, integer byteIndex returns integer
        return DzBitAnd(DzBitShiftRight(i, byteIndex), 1)
    endfunction

    function DzBitSet takes integer i, integer byteIndex, integer byteValue returns integer
        local integer shift = BlzBitAnd(byteIndex, 31)
        local integer mask = DzBitNot(DzBitShiftLeft(1, shift))
        return DzBitOr(DzBitAnd(i, mask), DzBitShiftLeft(BlzBitAnd(byteValue, 255), shift))
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
        local string charSet = DzCompat_Fold(whichString, caseSensitive)
        local integer hayLen = StringLength(hay)
        local integer setLen = StringLength(charSet)
        local integer i = off
        local integer j
        loop
            exitwhen i == hayLen
            set j = 0
            loop
                exitwhen j == setLen
                if SubString(hay, i, i + 1) == SubString(charSet, j, j + 1) then
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
        local string charSet = DzCompat_Fold(whichString, caseSensitive)
        local integer hayLen = StringLength(hay)
        local integer setLen = StringLength(charSet)
        local integer i = off
        local integer j
        local boolean found
        loop
            exitwhen i == hayLen
            set found = false
            set j = 0
            loop
                exitwhen j == setLen
                if SubString(hay, i, i + 1) == SubString(charSet, j, j + 1) then
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
        local string charSet = DzCompat_Fold(whichString, caseSensitive)
        local integer hayLen = StringLength(hay)
        local integer setLen = StringLength(charSet)
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
                if SubString(hay, i, i + 1) == SubString(charSet, j, j + 1) then
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
        local string charSet = DzCompat_Fold(whichString, caseSensitive)
        local integer hayLen = StringLength(hay)
        local integer setLen = StringLength(charSet)
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
                if SubString(hay, i, i + 1) == SubString(charSet, j, j + 1) then
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

    // Non-overlapping count of whichString inside s. Empty needle returns 0.
    function DzStringCount takes string s, string whichString returns integer
        local integer step = StringLength(whichString)
        local integer hayLen = StringLength(s)
        local integer p = 0
        local integer count = 0
        local integer q
        if step <= 0 then
            return 0
        endif
        loop
            exitwhen p + step > hayLen
            set q = DzStringFind(s, whichString, p, true)
            exitwhen q < 0
            set count = count + 1
            set p = q + step
        endloop
        return count
    endfunction

    // Returns the 0-based index-th token of s split by delimiter whichString.
    // Empty delimiter returns s for index 0 and "" otherwise. Out-of-range
    // index returns "".
    function DzStringSplit takes string s, string whichString, integer index returns string
        local integer step = StringLength(whichString)
        local integer hayLen = StringLength(s)
        local integer p = 0
        local integer k = 0
        local integer q
        if step <= 0 then
            if index == 0 then
                return s
            endif
            return ""
        endif
        loop
            set q = DzStringFind(s, whichString, p, true)
            if k == index then
                if q < 0 then
                    return SubString(s, p, hayLen)
                endif
                return SubString(s, p, q)
            endif
            if q < 0 then
                return ""
            endif
            set p = q + step
            set k = k + 1
        endloop
        return ""
    endfunction

    // ============================================================
    // BIT ALIASES
    // ============================================================

    // Plain-name forms of the Dz bit natives (some KK environments declare these instead of / next to DzBit*).
    function BitAnd takes integer x, integer y returns integer
        return DzBitAnd(x, y)
    endfunction

    function BitOr takes integer x, integer y returns integer
        return DzBitOr(x, y)
    endfunction

    function BitXor takes integer x, integer y returns integer
        return DzBitXor(x, y)
    endfunction

    function BitShiftL takes integer x, integer y returns integer
        return DzBitShiftLeft(x, y)
    endfunction

    // Arithmetic shift right: the sign is kept and the result rounds toward negative infinity
    // (-5 >> 1 == -3), unlike DzBitShiftRight, whose "/ 2" truncates toward zero. The shift count is taken
    // modulo 32.
    function BitShiftR takes integer x, integer y returns integer
        local integer count = ModuloInteger(y, 32)
        local integer n = 0
        loop
            exitwhen n >= count
            if x >= 0 then
                set x = x / 2
            else
                set x = (x - 1) / 2
            endif
            set n = n + 1
        endloop
        return x
    endfunction
