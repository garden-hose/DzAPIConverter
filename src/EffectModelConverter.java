import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Rewrites effect creation and destruction call sites to the DzCompat_ wrappers that remember an
 * effect's model path:
 * AddSpecialEffect, AddSpecialEffectLoc, AddSpecialEffectTarget, AddSpecialEffectLocBJ,
 * AddSpecialEffectTargetUnitBJ and DestroyEffect.
 *
 * Reforged has no getter for an effect's model path, and DzBindEffect / DzSetEffectModel need
 * it (see lib/DzCompat_Effect.j). Only run for a map that calls one of those natives: the
 * wrappers cost a hashtable write per effect, and a map without them has no use for it.
 *
 * Same string/paren-aware scanning as TimerDestroyConverter. Only calls are rewritten; a
 * {@code function AddSpecialEffectLocBJ takes ...} of the map's own is left alone. The reverse
 * conversion maps each wrapper back to its original name (see {@link #RESTORES}).
 */
final class EffectModelConverter {

    private EffectModelConverter() {}

    /** Original name -> wrapper, in the order they are listed in the log. */
    static final Map<String, String> WRAPPERS = new LinkedHashMap<>();
    /** Wrapper -> original name, for the reverse conversion. */
    static final Map<String, String> RESTORES = new LinkedHashMap<>();
    static {
        WRAPPERS.put("AddSpecialEffect", "DzCompat_AddSpecialEffect");
        WRAPPERS.put("AddSpecialEffectLoc", "DzCompat_AddSpecialEffectLoc");
        WRAPPERS.put("AddSpecialEffectTarget", "DzCompat_AddSpecialEffectTarget");
        WRAPPERS.put("AddSpecialEffectLocBJ", "DzCompat_AddSpecialEffectLocBJ");
        WRAPPERS.put("AddSpecialEffectTargetUnitBJ", "DzCompat_AddSpecialEffectTargetUnitBJ");
        WRAPPERS.put("DestroyEffect", "DzCompat_DestroyEffect");
        for (Map.Entry<String, String> e : WRAPPERS.entrySet()) {
            RESTORES.put(e.getValue(), e.getKey());
        }
    }

    /** The natives that make the map need effect model tracking. */
    static final Set<String> TRIGGER_NATIVES = new LinkedHashSet<>(java.util.Arrays.asList(
            "DzBindEffect", "DzSetEffectModel", "DzSetEffectAttachedModelScale"));

    static final class Result {
        final List<String> lines;
        final int rewritten;
        /** The wrappers that ended up in the script, to be pulled in from the library. */
        final Set<String> used;

        Result(List<String> lines, int rewritten, Set<String> used) {
            this.lines = lines;
            this.rewritten = rewritten;
            this.used = used;
        }
    }

    static Result convert(List<String> inputLines) {
        List<String> lines = new ArrayList<>(inputLines);
        Set<String> used = new LinkedHashSet<>();
        int count = 0;
        // True while the cursor is inside the body of one of the wrappers, so a second
        // conversion pass does not turn the wrapper's own native call into a recursive call.
        boolean insideWrapper = false;
        for (int ln = 0; ln < lines.size(); ln++) {
            String line = lines.get(ln);
            String trimmed = line.trim();
            if (trimmed.startsWith("function DzCompat_")) {
                int sp = trimmed.indexOf(' ', "function ".length());
                String name = sp < 0 ? trimmed.substring("function ".length())
                        : trimmed.substring("function ".length(), sp);
                if (RESTORES.containsKey(name)) {
                    insideWrapper = true;
                    continue;
                }
            }
            if (insideWrapper) {
                if (trimmed.equals("endfunction") || trimmed.startsWith("endfunction ")
                        || trimmed.startsWith("endfunction\t")) {
                    insideWrapper = false;
                }
                continue;
            }
            int end = JassExpr.codeEnd(line);
            StringBuilder out = null;
            int cursor = 0;
            boolean inString = false;
            for (int i = 0; i < end; i++) {
                char c = line.charAt(i);
                if (inString) {
                    if (c == '\\') i++;
                    else if (c == '"') inString = false;
                    continue;
                }
                if (c == '"') { inString = true; continue; }
                if (!Character.isLetter(c) || (i > 0 && JassExpr.isIdentChar(line.charAt(i - 1)))) continue;
                // the identifier that starts here, whole
                int j = i;
                while (j < end && JassExpr.isIdentChar(line.charAt(j))) j++;
                String ident = line.substring(i, j);
                String wrapper = WRAPPERS.get(ident);
                if (wrapper != null) {
                    int k = j;
                    while (k < end && line.charAt(k) == ' ') k++;
                    // Only calls: "function X" / "native X" are followed by "takes", not "(".
                    if (k < end && line.charAt(k) == '(') {
                        if (out == null) out = new StringBuilder();
                        out.append(line, cursor, i).append(wrapper);
                        cursor = j;
                        count++;
                        used.add(wrapper);
                    }
                }
                i = j - 1;
            }
            if (out != null) {
                out.append(line, cursor, line.length());
                lines.set(ln, out.toString());
            }
        }
        return new Result(lines, count, used);
    }
}
