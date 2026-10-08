// ============================================================================
// DzCompat_Lua.j
// Reforged-compatible EXExecuteScript (YDWE Lua engine entry point).
//
// The real native wraps its argument as `return (<script>)`, runs it in YDWE's
// Lua state and hands back the result as a string (null on any failure). A JASS
// map cannot run Lua, so this file supports exactly three idioms:
//
//   1. object-data reads through jass.slk
//        EXExecuteScript("(require'jass.slk').item[" + I2S(itemcode) + "].Name")
//      Grammar: <anything>jass.slk['")] . <table> [ <integer> ] . <field>
//
//   2. object-data reads through YDWE's Xwei module (same data, function syntax)
//        EXExecuteScript("(require'YDWEXweiObjectSlk').unit(" + I2S(id) + ", 'Name')")
//      Grammar: YDWEXweiObjectSlk['")] . <table> ( <integer> , '<field>' )
//
//   3. the Lua string library (pure computation, no object data needed)
//        string.pack / string.unpack ('>I4' and '<I4' only), string.reverse,
//        string.sub, string.find, string.match, string.gsub
//      find / match / gsub implement real Lua 5.3 patterns (a port of lstrlib's
//      matcher), including captures, %b, %f and back-references. Like the real
//      native, only the FIRST return value of a call is returned. Indices are
//      Lua's (1-based). Limits: strings up to 8000 bytes; bytes outside printable
//      ASCII cannot be told apart in character classes, and pack/unpack only
//      handle printable-ASCII bytes (enough for rawcodes), anything else gives null.
//
// The object-data values come from a table that ForwardConverter bakes into the
// map from the W3x2lni table\*.ini files (see SlkTableRegistry.java): it calls
// DzCompat_SlkDeclare / DzCompat_SlkPut from DzCompat_InitSlk at map init.
// Nothing is created at runtime (no work items), so calling this from a
// local-only callback (frame events, GetLocalPlayer blocks) is desync-safe.
//
// [STATUS] Anything that does not match one of the grammars, or is not baked,
// returns null - the same value YDWE returns when the Lua expression fails. The
// only runtime fallback for object data is the Name field of item/unit/ability,
// via GetObjectName (jassdoc: returns the literal "Default string" for an invalid
// id, and must not be called during global initialisation).
// ============================================================================

globals
    // parent key = object rawcode as integer, child key = field index
    hashtable gDzSlkData = InitHashtable()
    integer   gDzSlkFieldCount = 0
    string array gDzSlkFieldTable
    string array gDzSlkFieldName

    // ---- Lua string library ----
    // Printable ASCII, code 32..126, in code order.
    constant string DZLUA_ASCII = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"
    hashtable gDzLuaOrdTable = InitHashtable()
    boolean   gDzLuaOrdReady = false

    // parsed call: function name and arguments (kind 0 string, 1 integer, 2 boolean, 3 nil)
    string       gDzLuaFunc = ""
    integer      gDzLuaArgCount = 0
    string array gDzLuaArgText
    integer array gDzLuaArgKind

    // pattern matcher state (a port of lstrlib's MatchState)
    boolean      gDzLuaError = false
    string       gDzLuaSrcText = ""
    integer      gDzLuaSrcLen = 0
    string array gDzLuaSrcChar
    integer array gDzLuaSrcCode
    integer      gDzLuaPatLen = 0
    string array gDzLuaPatChar
    integer array gDzLuaPatCode
    integer      gDzLuaLevel = 0
    integer      gDzLuaDepth = 0
    integer array gDzLuaCapInit
    integer array gDzLuaCapLen      // -1 = capture still open, -2 = position capture "()"
endglobals
    // Index of the first occurrence of needle in s at or after start, else -1.
    function DzCompat_LuaFind takes string s, string needle, integer start returns integer
        local integer n = StringLength(s)
        local integer m = StringLength(needle)
        local integer i = start
        loop
            exitwhen i + m > n
            if SubString(s, i, i + m) == needle then
                return i
            endif
            set i = i + 1
        endloop
        return -1
    endfunction

    // s without leading/trailing spaces. Guards SubString's start>end quirk
    // (it returns the rest of the string instead of "").
    function DzCompat_LuaTrim takes string s returns string
        local integer a = 0
        local integer b = StringLength(s)
        loop
            exitwhen a >= b
            exitwhen SubString(s, a, a + 1) != " "
            set a = a + 1
        endloop
        loop
            exitwhen b <= a
            exitwhen SubString(s, b - 1, b) != " "
            set b = b - 1
        endloop
        if b <= a then
            return ""
        endif
        return SubString(s, a, b)
    endfunction

    // True when s is a canonical decimal integer that fits in 32 bits.
    function DzCompat_LuaIsInteger takes string s returns boolean
        return s != "" and I2S(S2I(s)) == s
    endfunction

    // Index registered for (table, field) by DzCompat_SlkDeclare, or -1.
    function DzCompat_SlkFindField takes string tbl, string field returns integer
        local integer i = 0
        loop
            exitwhen i >= gDzSlkFieldCount
            if gDzSlkFieldTable[i] == tbl and gDzSlkFieldName[i] == field then
                return i
            endif
            set i = i + 1
        endloop
        return -1
    endfunction

    // Called by the generated DzCompat_InitSlk_* functions.
    function DzCompat_SlkDeclare takes integer index, string tbl, string field returns nothing
        set gDzSlkFieldTable[index] = tbl
        set gDzSlkFieldName[index] = field
        if index >= gDzSlkFieldCount then
            set gDzSlkFieldCount = index + 1
        endif
    endfunction

    function DzCompat_SlkPut takes integer id, integer index, string value returns nothing
        call SaveStr(gDzSlkData, id, index, value)
    endfunction

    // ======================================================================
    // Object data lookup (shared by the jass.slk and the Xwei idioms)
    // ======================================================================
    function DzCompat_SlkLookup takes string tbl, integer id, string field returns string
        local integer f = DzCompat_SlkFindField(tbl, field)
        local string c
        if f >= 0 then
            if HaveSavedString(gDzSlkData, id, f) then
                return LoadStr(gDzSlkData, id, f)
            endif
        endif
        if field == "Name" and (tbl == "item" or tbl == "unit" or tbl == "ability") then
            set c = GetObjectName(id)
            if c != "Default string" then
                return c
            endif
        endif
        return null
    endfunction

    // s without leading blanks starting at p: index of the first non-blank.
    function DzCompat_LuaSkipBlanks takes string s, integer p returns integer
        local integer n = StringLength(s)
        loop
            exitwhen p >= n
            exitwhen SubString(s, p, p + 1) != " "
            set p = p + 1
        endloop
        return p
    endfunction

    // YDWEXweiObjectSlk['")] . <table> ( <integer> , '<field>' )   p = index of the module name
    function DzCompat_XweiRead takes string script, integer p returns string
        local integer n = StringLength(script)
        local integer q
        local integer r
        local string c
        local string tbl
        local string idText
        set p = p + 17
        loop
            exitwhen p >= n
            set c = SubString(script, p, p + 1)
            exitwhen c != "'" and c != "\"" and c != ")" and c != " "
            set p = p + 1
        endloop
        if p >= n or SubString(script, p, p + 1) != "." then
            return null
        endif
        set q = DzCompat_LuaFind(script, "(", p)
        if q < 0 then
            return null
        endif
        set r = DzCompat_LuaFind(script, ",", q + 1)
        if r < 0 then
            return null
        endif
        set tbl = DzCompat_LuaTrim(SubString(script, p + 1, q))
        set idText = DzCompat_LuaTrim(SubString(script, q + 1, r))
        if not DzCompat_LuaIsInteger(idText) then
            return null
        endif
        set p = DzCompat_LuaSkipBlanks(script, r + 1)
        if p >= n then
            return null
        endif
        set c = SubString(script, p, p + 1)
        if c != "'" and c != "\"" then
            return null
        endif
        set q = DzCompat_LuaFind(script, c, p + 1)
        if q < 0 then
            return null
        endif
        set c = SubString(script, p + 1, q)
        set p = DzCompat_LuaSkipBlanks(script, q + 1)
        if p >= n or SubString(script, p, p + 1) != ")" then
            return null
        endif
        return DzCompat_SlkLookup(tbl, S2I(idText), c)
    endfunction

    // ======================================================================
    // Lua string library
    // ======================================================================

    // Code of a one-character string: 32..126, tab/LF/CR, 128 for any other byte, -1 for null/"".
    function DzCompat_LuaOrd takes string c returns integer
        local integer i
        local integer k
        local string ch
        if c == null or c == "" then
            return -1
        endif
        if c == "\t" then
            return 9
        elseif c == "\n" then
            return 10
        elseif c == "\r" then
            return 13
        endif
        if not gDzLuaOrdReady then
            set gDzLuaOrdReady = true
            set i = 0
            loop
                exitwhen i >= 95
                set ch = SubString(DZLUA_ASCII, i, i + 1)
                if ch != StringCase(ch, false) then
                    call SaveInteger(gDzLuaOrdTable, StringHash(ch), 1, i + 32)
                else
                    call SaveInteger(gDzLuaOrdTable, StringHash(ch), 0, i + 32)
                endif
                set i = i + 1
            endloop
        endif
        // StringHash ignores case and may collide, so every hit is verified with ==
        set k = LoadInteger(gDzLuaOrdTable, StringHash(c), 0)
        if k >= 32 and SubString(DZLUA_ASCII, k - 32, k - 31) == c then
            return k
        endif
        set k = LoadInteger(gDzLuaOrdTable, StringHash(c), 1)
        if k >= 32 and SubString(DZLUA_ASCII, k - 32, k - 31) == c then
            return k
        endif
        set i = 0
        loop
            exitwhen i >= 95
            if SubString(DZLUA_ASCII, i, i + 1) == c then
                return i + 32
            endif
            set i = i + 1
        endloop
        return 128
    endfunction

    // One-character string for a code in 32..126, "" otherwise.
    function DzCompat_LuaChr takes integer charCode returns string
        if charCode < 32 or charCode > 126 then
            return ""
        endif
        return SubString(DZLUA_ASCII, charCode - 32, charCode - 31)
    endfunction

    // Lua's posrelat: negative positions count from the end, result 0 when out of range.
    function DzCompat_LuaPosRel takes integer pos, integer len returns integer
        if pos >= 0 then
            return pos
        elseif 0 - pos > len then
            return 0
        endif
        return len + pos + 1
    endfunction

    // Substring [a, b) of the matcher's source string.
    function DzCompat_LuaSlice takes integer a, integer b returns string
        if b <= a then
            return ""
        endif
        return SubString(gDzLuaSrcText, a, b)
    endfunction

    // Fills the matcher arrays; false when a string is too long.
    function DzCompat_LuaSetup takes string s, string pat returns boolean
        local integer i = 0
        set gDzLuaSrcText = s
        set gDzLuaSrcLen = StringLength(s)
        set gDzLuaPatLen = StringLength(pat)
        set gDzLuaError = false
        if gDzLuaSrcLen > 8000 or gDzLuaPatLen > 8000 then
            return false
        endif
        loop
            exitwhen i >= gDzLuaSrcLen
            set gDzLuaSrcChar[i] = SubString(s, i, i + 1)
            set gDzLuaSrcCode[i] = DzCompat_LuaOrd(gDzLuaSrcChar[i])
            set i = i + 1
        endloop
        set i = 0
        loop
            exitwhen i >= gDzLuaPatLen
            set gDzLuaPatChar[i] = SubString(pat, i, i + 1)
            set gDzLuaPatCode[i] = DzCompat_LuaOrd(gDzLuaPatChar[i])
            set i = i + 1
        endloop
        return true
    endfunction

    // Pattern byte code at i, 0 past the end (the C code reads the terminating NUL).
    function DzCompat_LuaPCode takes integer i returns integer
        if i >= gDzLuaPatLen then
            return 0
        endif
        return gDzLuaPatCode[i]
    endfunction

    // lstrlib match_class: does code c belong to class letter cl (%a, %d, ...)?
    function DzCompat_LuaMatchClass takes integer c, integer cl returns boolean
        local integer lo = cl
        local boolean res
        if cl >= 65 and cl <= 90 then
            set lo = cl + 32
        endif
        if lo == 97 then
            set res = (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
        elseif lo == 99 then
            set res = (c >= 0 and c < 32) or c == 127
        elseif lo == 100 then
            set res = c >= 48 and c <= 57
        elseif lo == 103 then
            set res = c >= 33 and c <= 126
        elseif lo == 108 then
            set res = c >= 97 and c <= 122
        elseif lo == 112 then
            set res = (c >= 33 and c <= 47) or (c >= 58 and c <= 64) or (c >= 91 and c <= 96) or (c >= 123 and c <= 126)
        elseif lo == 115 then
            set res = c == 32 or (c >= 9 and c <= 13)
        elseif lo == 117 then
            set res = c >= 65 and c <= 90
        elseif lo == 119 then
            set res = (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
        elseif lo == 120 then
            set res = (c >= 48 and c <= 57) or (c >= 65 and c <= 70) or (c >= 97 and c <= 102)
        else
            return cl == c
        endif
        if cl >= 65 and cl <= 90 then
            return not res
        endif
        return res
    endfunction

    // lstrlib matchbracketclass: p = '[' , ec = the closing ']'.
    function DzCompat_LuaBracket takes integer c, integer p, integer ec returns boolean
        local boolean sig = true
        if DzCompat_LuaPCode(p + 1) == 94 then
            set sig = false
            set p = p + 1
        endif
        loop
            set p = p + 1
            exitwhen p >= ec
            if gDzLuaPatCode[p] == 37 then
                set p = p + 1
                if DzCompat_LuaMatchClass(c, DzCompat_LuaPCode(p)) then
                    return sig
                endif
            elseif DzCompat_LuaPCode(p + 1) == 45 and p + 2 < ec then
                set p = p + 2
                if gDzLuaPatCode[p - 2] <= c and c <= gDzLuaPatCode[p] then
                    return sig
                endif
            elseif gDzLuaPatCode[p] == c then
                return sig
            endif
        endloop
        return not sig
    endfunction

    // lstrlib classEnd: index just past the single-char class starting at p.
    function DzCompat_LuaClassEnd takes integer p returns integer
        local integer pc = gDzLuaPatCode[p]
        set p = p + 1
        if pc == 37 then
            if p >= gDzLuaPatLen then
                set gDzLuaError = true
                return gDzLuaPatLen
            endif
            return p + 1
        elseif pc == 91 then
            if DzCompat_LuaPCode(p) == 94 then
                set p = p + 1
            endif
            loop
                if p >= gDzLuaPatLen then
                    set gDzLuaError = true
                    return gDzLuaPatLen
                endif
                set pc = gDzLuaPatCode[p]
                set p = p + 1
                if pc == 37 and p < gDzLuaPatLen then
                    set p = p + 1
                endif
                exitwhen p < gDzLuaPatLen and gDzLuaPatCode[p] == 93
            endloop
            return p + 1
        endif
        return p
    endfunction

    // lstrlib singlematch: does the source char at s match the class at p..ep?
    function DzCompat_LuaSingle takes integer s, integer p, integer ep returns boolean
        local integer pc
        if s >= gDzLuaSrcLen then
            return false
        endif
        set pc = gDzLuaPatCode[p]
        if pc == 46 then
            return true
        elseif pc == 37 then
            return DzCompat_LuaMatchClass(gDzLuaSrcCode[s], DzCompat_LuaPCode(p + 1))
        elseif pc == 91 then
            return DzCompat_LuaBracket(gDzLuaSrcCode[s], p, ep - 1)
        endif
        return gDzLuaSrcChar[s] == gDzLuaPatChar[p]
    endfunction

    // lstrlib match: end index of the match of pattern p at source s, or -1.
    // start_capture / end_capture / max_expand / min_expand are inlined because
    // JASS cannot call a function that is declared further down (no mutual recursion).
    function DzCompat_LuaMatch takes integer s, integer p returns integer
        local integer res = -1
        local integer ep
        local integer e
        local integer pc
        local integer nc
        local integer sc
        local integer lv
        local integer i
        local integer b
        local integer cont
        local integer len
        local boolean ok
        set gDzLuaDepth = gDzLuaDepth + 1
        if gDzLuaDepth > 200 then
            set gDzLuaError = true
            set gDzLuaDepth = gDzLuaDepth - 1
            return -1
        endif
        loop
            if gDzLuaError then
                set res = -1
                exitwhen true
            endif
            if p >= gDzLuaPatLen then
                set res = s
                exitwhen true
            endif
            set pc = gDzLuaPatCode[p]
            set nc = DzCompat_LuaPCode(p + 1)
            if pc == 40 then
                // start capture: "(" or position capture "()"
                set lv = gDzLuaLevel
                if lv >= 32 then
                    set gDzLuaError = true
                    exitwhen true
                endif
                set gDzLuaCapInit[lv] = s
                set gDzLuaLevel = lv + 1
                if nc == 41 then
                    set gDzLuaCapLen[lv] = -2
                    set e = DzCompat_LuaMatch(s, p + 2)
                else
                    set gDzLuaCapLen[lv] = -1
                    set e = DzCompat_LuaMatch(s, p + 1)
                endif
                if e == -1 then
                    set gDzLuaLevel = gDzLuaLevel - 1
                endif
                set res = e
                exitwhen true
            elseif pc == 41 then
                // end capture: close the innermost open capture
                set lv = gDzLuaLevel - 1
                loop
                    exitwhen lv < 0
                    exitwhen gDzLuaCapLen[lv] == -1
                    set lv = lv - 1
                endloop
                if lv < 0 then
                    set gDzLuaError = true
                    exitwhen true
                endif
                set gDzLuaCapLen[lv] = s - gDzLuaCapInit[lv]
                set e = DzCompat_LuaMatch(s, p + 1)
                if e == -1 then
                    set gDzLuaCapLen[lv] = -1
                endif
                set res = e
                exitwhen true
            elseif pc == 36 and p + 1 == gDzLuaPatLen then
                if s == gDzLuaSrcLen then
                    set res = s
                endif
                exitwhen true
            elseif pc == 37 and nc == 98 then
                // %bxy balanced
                if p + 3 >= gDzLuaPatLen then
                    set gDzLuaError = true
                    exitwhen true
                endif
                if s >= gDzLuaSrcLen or gDzLuaSrcChar[s] != gDzLuaPatChar[p + 2] then
                    exitwhen true
                endif
                set cont = 1
                set i = s + 1
                set e = -1
                loop
                    exitwhen i >= gDzLuaSrcLen
                    if gDzLuaSrcChar[i] == gDzLuaPatChar[p + 3] then
                        set cont = cont - 1
                        if cont == 0 then
                            set e = i + 1
                            exitwhen true
                        endif
                    elseif gDzLuaSrcChar[i] == gDzLuaPatChar[p + 2] then
                        set cont = cont + 1
                    endif
                    set i = i + 1
                endloop
                if e == -1 then
                    exitwhen true
                endif
                set s = e
                set p = p + 4
            elseif pc == 37 and nc == 102 then
                // %f[set] frontier
                set p = p + 2
                if DzCompat_LuaPCode(p) != 91 then
                    set gDzLuaError = true
                    exitwhen true
                endif
                set ep = DzCompat_LuaClassEnd(p)
                if gDzLuaError then
                    exitwhen true
                endif
                set sc = 0
                if s > 0 then
                    set sc = gDzLuaSrcCode[s - 1]
                endif
                set len = 0
                if s < gDzLuaSrcLen then
                    set len = gDzLuaSrcCode[s]
                endif
                if (not DzCompat_LuaBracket(sc, p, ep - 1)) and DzCompat_LuaBracket(len, p, ep - 1) then
                    set p = ep
                else
                    exitwhen true
                endif
            elseif pc == 37 and nc >= 48 and nc <= 57 then
                // %1 .. %9 back-reference
                set lv = nc - 49
                if lv < 0 or lv >= gDzLuaLevel or gDzLuaCapLen[lv] == -1 then
                    set gDzLuaError = true
                    exitwhen true
                endif
                set len = gDzLuaCapLen[lv]
                if len < 0 then
                    set len = 0
                endif
                set ok = gDzLuaSrcLen - s >= len
                set i = 0
                loop
                    exitwhen not ok or i >= len
                    if gDzLuaSrcChar[gDzLuaCapInit[lv] + i] != gDzLuaSrcChar[s + i] then
                        set ok = false
                    endif
                    set i = i + 1
                endloop
                if not ok then
                    exitwhen true
                endif
                set s = s + len
                set p = p + 2
            else
                // single char class with optional suffix
                set ep = DzCompat_LuaClassEnd(p)
                if gDzLuaError then
                    exitwhen true
                endif
                set sc = DzCompat_LuaPCode(ep)
                if not DzCompat_LuaSingle(s, p, ep) then
                    if sc == 42 or sc == 63 or sc == 45 then
                        set p = ep + 1
                    else
                        exitwhen true
                    endif
                else
                    if sc == 63 then
                        set e = DzCompat_LuaMatch(s + 1, ep + 1)
                        if e != -1 then
                            set res = e
                            exitwhen true
                        endif
                        set p = ep + 1
                    elseif sc == 43 or sc == 42 then
                        // max_expand
                        set i = 0
                        if sc == 43 then
                            set s = s + 1
                        endif
                        loop
                            exitwhen not DzCompat_LuaSingle(s + i, p, ep)
                            set i = i + 1
                        endloop
                        loop
                            exitwhen i < 0
                            set e = DzCompat_LuaMatch(s + i, ep + 1)
                            if e != -1 or gDzLuaError then
                                set res = e
                                exitwhen true
                            endif
                            set i = i - 1
                        endloop
                        exitwhen true
                    elseif sc == 45 then
                        // min_expand
                        loop
                            set e = DzCompat_LuaMatch(s, ep + 1)
                            if e != -1 or gDzLuaError then
                                set res = e
                                exitwhen true
                            endif
                            if DzCompat_LuaSingle(s, p, ep) then
                                set s = s + 1
                            else
                                exitwhen true
                            endif
                        endloop
                        exitwhen true
                    else
                        set s = s + 1
                        set p = ep
                    endif
                endif
            endif
        endloop
        set gDzLuaDepth = gDzLuaDepth - 1
        return res
    endfunction

    // Match at source start s1 with a fresh capture state.
    function DzCompat_LuaTryAt takes integer s1, integer p0 returns integer
        set gDzLuaLevel = 0
        set gDzLuaDepth = 0
        return DzCompat_LuaMatch(s1, p0)
    endfunction

    // lstrlib get_onecapture: capture l of the last match [s, e); null + error flag when invalid.
    function DzCompat_LuaCapture takes integer l, integer s, integer e returns string
        local integer ln
        if l >= gDzLuaLevel then
            if l != 0 then
                set gDzLuaError = true
                return null
            endif
            return DzCompat_LuaSlice(s, e)
        endif
        set ln = gDzLuaCapLen[l]
        if ln == -1 then
            set gDzLuaError = true
            return null
        endif
        if ln == -2 then
            return I2S(gDzLuaCapInit[l] + 1)
        endif
        return DzCompat_LuaSlice(gDzLuaCapInit[l], gDzLuaCapInit[l] + ln)
    endfunction

    // True when the pattern has none of the magic characters ^$*+?.([%-
    function DzCompat_LuaNoSpecials takes string pat returns boolean
        local integer i = 0
        local integer n = StringLength(pat)
        local string c
        loop
            exitwhen i >= n
            set c = SubString(pat, i, i + 1)
            if c == "^" or c == "$" or c == "*" or c == "+" or c == "?" or c == "." or c == "(" or c == "[" or c == "%" or c == "-" then
                return false
            endif
            set i = i + 1
        endloop
        return true
    endfunction

    // ---- call parsing: string.<fn>( arg, arg, ... ) ----------------------
    // 1 = parsed (gDzLuaFunc / gDzLuaArg*), 0 = not a string.* call, -1 = malformed.
    function DzCompat_LuaParseCall takes string script returns integer
        local integer n = StringLength(script)
        local integer p = 0
        local integer q
        local integer kind
        local string c
        local string quote
        local string text
        set gDzLuaArgCount = 0
        loop
            exitwhen p >= n
            set c = SubString(script, p, p + 1)
            exitwhen c != " " and c != "("
            set p = p + 1
        endloop
        if SubString(script, p, p + 7) != "string." then
            return 0
        endif
        set p = p + 7
        set q = DzCompat_LuaFind(script, "(", p)
        if q < 0 then
            return -1
        endif
        set gDzLuaFunc = DzCompat_LuaTrim(SubString(script, p, q))
        set p = q + 1
        loop
            set p = DzCompat_LuaSkipBlanks(script, p)
            if p >= n then
                return -1
            endif
            set c = SubString(script, p, p + 1)
            if c == ")" and gDzLuaArgCount == 0 then
                set p = p + 1
                exitwhen true
            endif
            if c == "'" or c == "\"" then
                set quote = c
                set text = ""
                set p = p + 1
                loop
                    if p >= n then
                        return -1
                    endif
                    set c = SubString(script, p, p + 1)
                    exitwhen c == quote
                    if c == "\\" and p + 1 < n then
                        set p = p + 1
                        set c = SubString(script, p, p + 1)
                        if c == "n" then
                            set c = "\n"
                        elseif c == "t" then
                            set c = "\t"
                        elseif c == "r" then
                            set c = "\r"
                        endif
                    endif
                    set text = text + c
                    set p = p + 1
                endloop
                set p = p + 1
                set kind = 0
            else
                set q = p
                loop
                    exitwhen q >= n
                    set c = SubString(script, q, q + 1)
                    exitwhen c == "," or c == ")"
                    set q = q + 1
                endloop
                set text = DzCompat_LuaTrim(SubString(script, p, q))
                set p = q
                if text == "true" or text == "false" then
                    set kind = 2
                elseif text == "nil" then
                    set kind = 3
                elseif DzCompat_LuaIsInteger(text) then
                    set kind = 1
                else
                    return -1
                endif
            endif
            if gDzLuaArgCount >= 8 then
                return -1
            endif
            set gDzLuaArgText[gDzLuaArgCount] = text
            set gDzLuaArgKind[gDzLuaArgCount] = kind
            set gDzLuaArgCount = gDzLuaArgCount + 1
            set p = DzCompat_LuaSkipBlanks(script, p)
            if p >= n then
                return -1
            endif
            set c = SubString(script, p, p + 1)
            set p = p + 1
            exitwhen c == ")"
            if c != "," then
                return -1
            endif
        endloop
        // only blanks may follow the closing parenthesis (the wrapper adds one more ")")
        loop
            exitwhen p >= n
            set c = SubString(script, p, p + 1)
            if c != " " and c != ")" then
                return -1
            endif
            set p = p + 1
        endloop
        return 1
    endfunction

    // Argument i as text (strings and integers), else null.
    function DzCompat_LuaArgString takes integer i returns string
        if i >= gDzLuaArgCount then
            return null
        endif
        if gDzLuaArgKind[i] == 0 or gDzLuaArgKind[i] == 1 then
            return gDzLuaArgText[i]
        endif
        return null
    endfunction

    // Argument i as integer, fallback when absent, nil or not a number.
    function DzCompat_LuaArgInt takes integer i, integer fallback returns integer
        if i >= gDzLuaArgCount then
            return fallback
        endif
        if gDzLuaArgKind[i] == 1 or (gDzLuaArgKind[i] == 0 and DzCompat_LuaIsInteger(gDzLuaArgText[i])) then
            return S2I(gDzLuaArgText[i])
        endif
        return fallback
    endfunction

    // string.reverse(s)
    function DzCompat_LuaFnReverse takes nothing returns string
        local string s = DzCompat_LuaArgString(0)
        local string r = ""
        local integer i
        if s == null then
            return null
        endif
        set i = StringLength(s)
        loop
            exitwhen i <= 0
            set r = r + SubString(s, i - 1, i)
            set i = i - 1
        endloop
        return r
    endfunction

    // string.sub(s, i [, j])
    function DzCompat_LuaFnSub takes nothing returns string
        local string s = DzCompat_LuaArgString(0)
        local integer l
        local integer a
        local integer b
        if s == null or gDzLuaArgCount < 2 then
            return null
        endif
        set l = StringLength(s)
        set a = DzCompat_LuaPosRel(DzCompat_LuaArgInt(1, 1), l)
        set b = DzCompat_LuaPosRel(DzCompat_LuaArgInt(2, -1), l)
        if a < 1 then
            set a = 1
        endif
        if b > l then
            set b = l
        endif
        if a > b then
            return ""
        endif
        return SubString(s, a - 1, b)
    endfunction

    // string.pack('>I4' | '<I4', n): 4 bytes of a non-negative integer, printable ASCII bytes only.
    function DzCompat_LuaFnPack takes nothing returns string
        local string f = DzCompat_LuaArgString(0)
        local integer v
        local string c0
        local string c1
        local string c2
        local string c3
        if (f != ">I4" and f != "<I4") or gDzLuaArgCount < 2 or gDzLuaArgKind[1] != 1 then
            return null
        endif
        set v = S2I(gDzLuaArgText[1])
        if v < 0 then
            return null
        endif
        set c3 = DzCompat_LuaChr(ModuloInteger(v, 256))
        set v = v / 256
        set c2 = DzCompat_LuaChr(ModuloInteger(v, 256))
        set v = v / 256
        set c1 = DzCompat_LuaChr(ModuloInteger(v, 256))
        set c0 = DzCompat_LuaChr(v / 256)
        if c0 == "" or c1 == "" or c2 == "" or c3 == "" then
            return null
        endif
        if f == ">I4" then
            return c0 + c1 + c2 + c3
        endif
        return c3 + c2 + c1 + c0
    endfunction

    // string.unpack('>I4' | '<I4', s [, pos]): first return value only.
    function DzCompat_LuaFnUnpack takes nothing returns string
        local string f = DzCompat_LuaArgString(0)
        local string s = DzCompat_LuaArgString(1)
        local integer pos = DzCompat_LuaArgInt(2, 1)
        local integer b0
        local integer b1
        local integer b2
        local integer b3
        if (f != ">I4" and f != "<I4") or s == null or pos < 1 then
            return null
        endif
        if StringLength(s) < pos + 3 then
            return null
        endif
        set b0 = DzCompat_LuaOrd(SubString(s, pos - 1, pos))
        set b1 = DzCompat_LuaOrd(SubString(s, pos, pos + 1))
        set b2 = DzCompat_LuaOrd(SubString(s, pos + 1, pos + 2))
        set b3 = DzCompat_LuaOrd(SubString(s, pos + 2, pos + 3))
        if b0 < 32 or b0 > 126 or b1 < 32 or b1 > 126 or b2 < 32 or b2 > 126 or b3 < 32 or b3 > 126 then
            return null
        endif
        if f == ">I4" then
            return I2S(((b0 * 256 + b1) * 256 + b2) * 256 + b3)
        endif
        return I2S(((b3 * 256 + b2) * 256 + b1) * 256 + b0)
    endfunction

    // string.find(s, pattern [, init [, plain]]) -> start index; string.match(s, pattern [, init]) -> first capture.
    function DzCompat_LuaFnFind takes boolean wantMatch returns string
        local string s = DzCompat_LuaArgString(0)
        local string pat = DzCompat_LuaArgString(1)
        local integer ls
        local integer init
        local integer idx
        local integer s1
        local integer e
        local integer p0 = 0
        local boolean plain
        local boolean anchor
        if s == null or pat == null then
            return null
        endif
        set ls = StringLength(s)
        set init = DzCompat_LuaPosRel(DzCompat_LuaArgInt(2, 1), ls)
        if init < 1 then
            set init = 1
        endif
        if init > ls + 1 then
            return null
        endif
        if not wantMatch then
            set plain = gDzLuaArgCount > 3 and gDzLuaArgKind[3] != 3 and not (gDzLuaArgKind[3] == 2 and gDzLuaArgText[3] == "false")
            if not plain then
                set plain = DzCompat_LuaNoSpecials(pat)
            endif
            if plain then
                set idx = DzCompat_LuaFind(s, pat, init - 1)
                if idx < 0 then
                    return null
                endif
                return I2S(idx + 1)
            endif
        endif
        if not DzCompat_LuaSetup(s, pat) then
            return null
        endif
        set anchor = gDzLuaPatLen > 0 and gDzLuaPatCode[0] == 94
        if anchor then
            set p0 = 1
        endif
        set s1 = init - 1
        loop
            set e = DzCompat_LuaTryAt(s1, p0)
            if gDzLuaError then
                return null
            endif
            if e != -1 then
                if wantMatch then
                    return DzCompat_LuaCapture(0, s1, e)
                endif
                return I2S(s1 + 1)
            endif
            set s1 = s1 + 1
            exitwhen anchor or s1 > ls
        endloop
        return null
    endfunction

    // string.gsub(s, pattern, repl [, n]) with a string replacement; first return value only.
    function DzCompat_LuaFnGsub takes nothing returns string
        local string s = DzCompat_LuaArgString(0)
        local string pat = DzCompat_LuaArgString(1)
        local string repl = DzCompat_LuaArgString(2)
        local string out = ""
        local string c
        local string r
        local integer ls
        local integer maxS
        local integer count = 0
        local integer src = 0
        local integer lastMatch = -1
        local integer p0 = 0
        local integer e
        local integer i
        local integer k
        local integer l
        local boolean anchor
        if s == null or pat == null or repl == null then
            return null
        endif
        set ls = StringLength(s)
        set maxS = DzCompat_LuaArgInt(3, ls + 1)
        if not DzCompat_LuaSetup(s, pat) then
            return null
        endif
        set anchor = gDzLuaPatLen > 0 and gDzLuaPatCode[0] == 94
        if anchor then
            set p0 = 1
        endif
        set k = StringLength(repl)
        loop
            exitwhen count >= maxS
            set e = DzCompat_LuaTryAt(src, p0)
            if gDzLuaError then
                return null
            endif
            if e != -1 and e != lastMatch then
                set count = count + 1
                set i = 0
                loop
                    exitwhen i >= k
                    set c = SubString(repl, i, i + 1)
                    if c != "%" then
                        set out = out + c
                    else
                        set i = i + 1
                        if i >= k then
                            return null
                        endif
                        set c = SubString(repl, i, i + 1)
                        if c == "%" then
                            set out = out + "%"
                        else
                            set l = DzCompat_LuaOrd(c)
                            if l < 48 or l > 57 then
                                return null
                            endif
                            if l == 48 then
                                set out = out + DzCompat_LuaSlice(src, e)
                            else
                                set r = DzCompat_LuaCapture(l - 49, src, e)
                                if gDzLuaError then
                                    return null
                                endif
                                set out = out + r
                            endif
                        endif
                    endif
                    set i = i + 1
                endloop
                // Lua 5.3.6: an empty match right after the previous match is skipped
                set src = e
                set lastMatch = e
            elseif src < ls then
                set out = out + SubString(s, src, src + 1)
                set src = src + 1
            else
                exitwhen true
            endif
            exitwhen anchor
        endloop
        if src < ls then
            set out = out + SubString(s, src, ls)
        endif
        return out
    endfunction

    // Runs the call DzCompat_LuaParseCall just parsed.
    function DzCompat_LuaRunString takes nothing returns string
        if gDzLuaFunc == "find" then
            return DzCompat_LuaFnFind(false)
        elseif gDzLuaFunc == "match" then
            return DzCompat_LuaFnFind(true)
        elseif gDzLuaFunc == "gsub" then
            return DzCompat_LuaFnGsub()
        elseif gDzLuaFunc == "sub" then
            return DzCompat_LuaFnSub()
        elseif gDzLuaFunc == "reverse" then
            return DzCompat_LuaFnReverse()
        elseif gDzLuaFunc == "pack" then
            return DzCompat_LuaFnPack()
        elseif gDzLuaFunc == "unpack" then
            return DzCompat_LuaFnUnpack()
        endif
        return null
    endfunction

    // ======================================================================
    // Entry point
    // ======================================================================
    function EXExecuteScript takes string script returns string
        local integer n = StringLength(script)
        local integer p
        local integer q
        local integer r
        local integer id
        local string tbl
        local string idText
        local string field
        local string c
        set r = DzCompat_LuaParseCall(script)
        if r > 0 then
            return DzCompat_LuaRunString()
        elseif r < 0 then
            return null
        endif
        set p = DzCompat_LuaFind(script, "YDWEXweiObjectSlk", 0)
        if p >= 0 and p <= 12 then
            return DzCompat_XweiRead(script, p)
        endif
        set p = DzCompat_LuaFind(script, "jass.slk", 0)
        if p < 0 then
            return null
        endif
        // skip the closing quote / parent / blanks after "jass.slk"
        set p = p + 8
        loop
            exitwhen p >= n
            set c = SubString(script, p, p + 1)
            exitwhen c != "'" and c != "\"" and c != ")" and c != " "
            set p = p + 1
        endloop
        if p >= n or SubString(script, p, p + 1) != "." then
            return null
        endif
        // .<table>[<integer>]
        set q = DzCompat_LuaFind(script, "[", p)
        if q < 0 then
            return null
        endif
        set r = DzCompat_LuaFind(script, "]", q + 1)
        if r < 0 then
            return null
        endif
        set tbl = DzCompat_LuaTrim(SubString(script, p + 1, q))
        set idText = DzCompat_LuaTrim(SubString(script, q + 1, r))
        if not DzCompat_LuaIsInteger(idText) then
            return null
        endif
        set id = S2I(idText)
        // .<field> up to the end of the script
        set p = DzCompat_LuaSkipBlanks(script, r + 1)
        if p >= n or SubString(script, p, p + 1) != "." then
            return null
        endif
        set field = DzCompat_LuaTrim(SubString(script, p + 1, n))
        return DzCompat_SlkLookup(tbl, id, field)
    endfunction
