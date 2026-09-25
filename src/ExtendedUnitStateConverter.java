import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeSet;

/**
 * Rewrites extended-unit-state call sites in a JASS script.
 *
 * kkapi/dzapi/YDWE's UnitState.cpp hooks the stock
 *     native GetUnitState takes unit whichUnit, unitstate whichUnitState returns real
 *     native SetUnitState takes unit whichUnit, unitstate whichUnitState, real newVal returns nothing
 * natives so that, beyond the four stock indices Reforged itself defines
 * (0-3: life/max life/mana/max mana), extra integer indices passed through
 * ConvertUnitState(N) become readable/writable - a unit's attack-1 base
 * damage, armor, attack cooldown, and so on.
 *
 * These are stock native *calls*, not "native X" *declarations* - the normal
 * ForwardConverter pass only ever replaces declared natives it finds in the
 * script, so it can never touch this pattern. Left alone, every one of these
 * calls hits Reforged's real GetUnitState/SetUnitState, which does not
 * recognize indices outside 0-3 and silently returns/writes 0 - the map
 * compiles and runs, but any damage/stat math that reads an extended index
 * silently computes using 0.
 *
 * This pass finds every GetUnitState/SetUnitState call whose state argument
 * is a literal ConvertUnitState(N) with N outside {0,1,2,3}, and rewrites it
 * to call DzCompat_GetExtUnitState(unit, N) / DzCompat_SetExtUnitState(unit,
 * N, value) instead (see lib/DzCompat_ExtendedUnitState.j), so each index
 * gets one real (or documented best-effort) Reforged implementation instead
 * of silently returning 0 at every call site.
 *
 * Parenthesis/string aware for the same reason ExecuteScriptScanner is: the
 * unit and value arguments are often themselves nested calls
 * (GetUnitState(GetTriggerUnit(), ConvertUnitState(21))), so a naive regex
 * would mis-split on the inner commas/parens.
 */
final class ExtendedUnitStateConverter {

    private ExtendedUnitStateConverter() {}

    private static final String GET_NAME = "GetUnitState";
    private static final String SET_NAME = "SetUnitState";
    private static final String CONVERT_NAME = "ConvertUnitState";

    /** Stock indices Reforged's own GetUnitState/SetUnitState already handle correctly. */
    private static boolean isStockIndex(long n) {
        return n >= 0 && n <= 3;
    }

    static final class Result {
        final List<String> lines;
        /** Extended index -> number of call sites rewritten to use it. */
        final Map<Long, Integer> rewrittenByIndex;
        /** True if at least one Get call site was rewritten (DzCompat_GetExtUnitState is needed). */
        final boolean usedGet;
        /** True if at least one Set call site was rewritten (DzCompat_SetExtUnitState is needed). */
        final boolean usedSet;

        Result(List<String> lines, Map<Long, Integer> rewrittenByIndex, boolean usedGet, boolean usedSet) {
            this.lines = lines;
            this.rewrittenByIndex = rewrittenByIndex;
            this.usedGet = usedGet;
            this.usedSet = usedSet;
        }

        boolean changedAnything() {
            return usedGet || usedSet;
        }

        /** Indices rewritten that lib/DzCompat_ExtendedUnitState.j does not yet implement
         *  a real case for (it still routes them through the wrapper, which falls back to
         *  0/no-op for them - same as before, just centralized and easy to extend later). */
        List<Long> unmappedIndices() {
            List<Long> out = new ArrayList<>();
            for (Long idx : rewrittenByIndex.keySet()) {
                if (!KNOWN_INDICES.contains(idx)) out.add(idx);
            }
            return out;
        }
    }

    /** Indices lib/DzCompat_ExtendedUnitState.j has a real/approximate case for. Kept in sync
     *  with that file by hand - update both when adding support for a new index. */
    private static final TreeSet<Long> KNOWN_INDICES = new TreeSet<>(List.of(18L, 20L, 21L, 22L, 32L, 37L, 81L));

    static Result convert(List<String> inputLines) {
        List<String> lines = new ArrayList<>(inputLines);
        Map<Long, Integer> rewrittenByIndex = new LinkedHashMap<>();
        boolean[] usedGet = {false};
        boolean[] usedSet = {false};

        for (int ln = 0; ln < lines.size(); ln++) {
            String line = lines.get(ln);
            if (!line.contains(GET_NAME) && !line.contains(SET_NAME)) continue;
            String rewritten = rewriteLine(line, rewrittenByIndex, usedGet, usedSet);
            if (rewritten != null) lines.set(ln, rewritten);
        }

        return new Result(lines, rewrittenByIndex, usedGet[0], usedSet[0]);
    }

    /** Rewrites every matching call on one line (a statement, so trailing // comments are kept
     *  untouched); returns null if nothing changed on it. */
    private static String rewriteLine(String line, Map<Long, Integer> rewrittenByIndex,
                                       boolean[] usedGet, boolean[] usedSet) {
        int end = JassExpr.codeEnd(line); // stop at a trailing // comment
        String rewrittenCode = rewriteExpr(line, end, rewrittenByIndex, usedGet, usedSet);
        if (rewrittenCode == null) return null;
        return rewrittenCode + line.substring(end);
    }

    /**
     * Rewrites every GetUnitState/SetUnitState(..., ConvertUnitState(N), ...) call found in
     * {@code text[0, end)}, recursing into each call's own arguments first - a value argument
     * is itself a full expression and very often contains its own nested GetUnitState call, as
     * in the common read-modify-write idiom
     *     SetUnitState(u, ConvertUnitState(18), GetUnitState(u, ConvertUnitState(18)) + bonus)
     * where both the outer Set and the inner Get need rewriting. Returns null if nothing in
     * this range changed.
     */
    private static String rewriteExpr(String text, int end, Map<Long, Integer> rewrittenByIndex,
                                       boolean[] usedGet, boolean[] usedSet) {
        StringBuilder out = new StringBuilder();
        int cursor = 0;
        boolean changed = false;
        boolean inString = false;
        int i = 0;
        while (i < end) {
            char c = text.charAt(i);
            if (inString) {
                if (c == '\\') i++;
                else if (c == '"') inString = false;
                i++;
                continue;
            }
            if (c == '"') {
                inString = true;
                i++;
                continue;
            }
            String name = matchNameAt(text, i, end);
            if (name != null && (i == 0 || !JassExpr.isIdentChar(text.charAt(i - 1)))) {
                int j = i + name.length();
                while (j < end && text.charAt(j) == ' ') j++;
                if (j < end && text.charAt(j) == '(') {
                    int close = JassExpr.findClosingParen(text, j, end);
                    if (close > 0) {
                        String replacement = tryRewriteCall(name, text.substring(j + 1, close),
                                rewrittenByIndex, usedGet, usedSet);
                        if (replacement != null) {
                            out.append(text, cursor, i).append(replacement);
                            cursor = close + 1;
                            changed = true;
                        }
                        // tryRewriteCall recurses into this call's own arguments itself (a
                        // value argument is a full expression and very often contains its
                        // own nested GetUnitState/SetUnitState call - the common
                        // read-modify-write idiom), so nothing further to do here either way.
                        i = close + 1;
                        continue;
                    }
                }
            }
            i++;
        }
        if (!changed) return null;
        out.append(text, cursor, end);
        return out.toString();
    }

    private static String matchNameAt(String line, int i, int end) {
        if (line.startsWith(GET_NAME, i)) return GET_NAME;
        if (line.startsWith(SET_NAME, i)) return SET_NAME;
        return null;
    }

    /**
     * {@code args} is the raw text between GetUnitState(/SetUnitState( and its closing paren.
     * Returns the replacement call text, or null if nothing at all changed for this call site
     * (including recursively within its own arguments).
     *
     * Recurses into the unit argument (and, for Set, the value argument) first: either of
     * those is a full expression and very often contains its own nested GetUnitState call -
     * most commonly the read-modify-write idiom
     *     SetUnitState(u, ConvertUnitState(18), GetUnitState(u, ConvertUnitState(18)) + bonus)
     * where both the outer Set and the inner Get need rewriting, not just one.
     *
     * The outer call itself is only rewritten (to DzCompat_Get/SetExtUnitState) when its own
     * state argument is a literal ConvertUnitState(N) with N outside the stock 0-3 range;
     * otherwise it's rebuilt with the same GetUnitState/SetUnitState name, keeping any
     * recursive rewrite from its arguments.
     */
    private static String tryRewriteCall(String funcName, String args, Map<Long, Integer> rewrittenByIndex,
                                          boolean[] usedGet, boolean[] usedSet) {
        List<String> parts = JassExpr.splitTopLevel(args, ',');
        boolean isGet = funcName.equals(GET_NAME);
        if (isGet && parts.size() != 2) return null;
        if (!isGet && parts.size() != 3) return null;

        String unitArg = parts.get(0).trim();
        String stateArg = parts.get(1).trim();
        String valueArg = isGet ? null : parts.get(2).trim();

        String rewrittenUnitArg = rewriteExpr(unitArg, unitArg.length(), rewrittenByIndex, usedGet, usedSet);
        String rewrittenValueArg = isGet ? null
                : rewriteExpr(valueArg, valueArg.length(), rewrittenByIndex, usedGet, usedSet);
        String effectiveUnitArg = rewrittenUnitArg != null ? rewrittenUnitArg : unitArg;
        String effectiveValueArg = rewrittenValueArg != null ? rewrittenValueArg : valueArg;
        boolean innerChanged = rewrittenUnitArg != null || rewrittenValueArg != null;

        Long idx = extractConvertUnitStateLiteral(stateArg);
        if (idx == null || isStockIndex(idx)) {
            // This call itself isn't one to rewrite (stock 0-3, or a non-literal state
            // expression), but a nested call within its arguments might still have changed.
            if (!innerChanged) return null;
            return isGet
                    ? GET_NAME + "(" + effectiveUnitArg + ", " + stateArg + ")"
                    : SET_NAME + "(" + effectiveUnitArg + ", " + stateArg + ", " + effectiveValueArg + ")";
        }

        rewrittenByIndex.merge(idx, 1, Integer::sum);
        if (isGet) {
            usedGet[0] = true;
            return "DzCompat_GetExtUnitState(" + effectiveUnitArg + ", " + idx + ")";
        } else {
            usedSet[0] = true;
            return "DzCompat_SetExtUnitState(" + effectiveUnitArg + ", " + idx + ", " + effectiveValueArg + ")";
        }
    }

    /** Returns N if {@code s} is exactly "ConvertUnitState(<integer literal>)", else null. */
    private static Long extractConvertUnitStateLiteral(String s) {
        JassExpr.Call call = JassExpr.parseCall(s);
        if (call == null || !call.name.equals(CONVERT_NAME) || call.args.size() != 1) return null;
        return JassExpr.parseIntegerLiteral(call.args.get(0).trim());
    }
}
