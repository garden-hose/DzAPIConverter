// ============================================================================
// DzCompat_Lua.j
// Reforged-compatible EXExecuteScript (YDWE Lua engine entry point).
//
// The real native wraps its argument as `return (<script>)`, runs it in YDWE's
// Lua state and hands back the result as a string (null on any failure). A JASS
// map cannot run Lua, so this file supports exactly one idiom - reading an
// object-data field through jass.slk:
//
//     EXExecuteScript("(require'jass.slk').item[" + I2S(itemcode) + "].Name")
//
// Grammar accepted (whitespace and the quote/parent style around jass.slk are
// tolerated):   <anything>jass.slk['")] . <table> [ <integer> ] . <field>
//
// The values come from a table that ForwardConverter bakes into the map from
// the W3x2lni table\*.ini files (see SlkTableRegistry.java): it calls
// DzCompat_SlkDeclare / DzCompat_SlkPut from DzCompat_InitSlk at map init.
// Nothing is created at runtime (no work items), so calling this from a
// local-only callback (frame events, GetLocalPlayer blocks) is desync-safe.
//
// [STATUS] Anything that does not match the grammar, or is not baked, returns
// null - the same value YDWE returns when the Lua expression fails. The only
// runtime fallback is the Name field of item/unit/ability, via GetObjectName
// (jassdoc: returns the literal "Default string" for an invalid id, and must
// not be called during global initialisation).
// ============================================================================

globals
    // parent key = object rawcode as integer, child key = field index
    hashtable gDzSlkData = InitHashtable()
    integer   gDzSlkFieldCount = 0
    string array gDzSlkFieldTable
    string array gDzSlkFieldName
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

    function EXExecuteScript takes string script returns string
        local integer n = StringLength(script)
        local integer p = DzCompat_LuaFind(script, "jass.slk", 0)
        local integer q
        local integer r
        local integer id
        local integer f
        local string tbl
        local string idText
        local string field
        local string c
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
        set p = r + 1
        loop
            exitwhen p >= n
            exitwhen SubString(script, p, p + 1) != " "
            set p = p + 1
        endloop
        if p >= n or SubString(script, p, p + 1) != "." then
            return null
        endif
        set field = DzCompat_LuaTrim(SubString(script, p + 1, n))
        set f = DzCompat_SlkFindField(tbl, field)
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
