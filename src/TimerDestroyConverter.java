import java.util.ArrayList;
import java.util.List;

/**
 * Rewrites DestroyTimer call sites to DzCompat_DestroyTimer.
 *
 * Destroying the same timer handle twice (common when a callback and a cleanup path
 * both tear it down) can crash Reforged. The wrapper null-checks and pauses before
 * destroy. Uses the same string/paren-aware scanning as AbilityAddConverter.
 *
 * Always safe to run: maps that never call DestroyTimer simply rewrite zero sites.
 * Re-running conversion on an already-converted script leaves the wrapper body alone
 * so its internal DestroyTimer call is not turned into a recursive call.
 */
final class TimerDestroyConverter {

    private TimerDestroyConverter() {}

    private static final String NAME = "DestroyTimer";
    static final String WRAPPER = "DzCompat_DestroyTimer";

    static final class Result {
        final List<String> lines;
        final int rewritten;

        Result(List<String> lines, int rewritten) {
            this.lines = lines;
            this.rewritten = rewritten;
        }
    }

    static Result convert(List<String> inputLines) {
        List<String> lines = new ArrayList<>(inputLines);
        int count = 0;
        // True while the cursor is inside "function DzCompat_DestroyTimer ... endfunction"
        // so a second conversion pass does not rewrite the wrapper's own DestroyTimer call.
        boolean insideWrapper = false;
        for (int ln = 0; ln < lines.size(); ln++) {
            String line = lines.get(ln);
            String trimmed = line.trim();
            if (trimmed.startsWith("function " + WRAPPER + " ")
                    || trimmed.startsWith("function " + WRAPPER + "\t")) {
                insideWrapper = true;
                continue;
            }
            if (insideWrapper) {
                if (trimmed.equals("endfunction") || trimmed.startsWith("endfunction ")
                        || trimmed.startsWith("endfunction\t")) {
                    insideWrapper = false;
                }
                continue;
            }
            if (!line.contains(NAME)) continue;
            int end = JassExpr.codeEnd(line);
            StringBuilder out = new StringBuilder();
            int cursor = 0;
            boolean inString = false;
            int changed = 0;
            for (int i = 0; i < end; i++) {
                char c = line.charAt(i);
                if (inString) {
                    if (c == '\\') i++;
                    else if (c == '"') inString = false;
                    continue;
                }
                if (c == '"') { inString = true; continue; }
                if (line.startsWith(NAME, i)
                        && (i == 0 || !JassExpr.isIdentChar(line.charAt(i - 1)))
                        && (i + NAME.length() >= end || !JassExpr.isIdentChar(line.charAt(i + NAME.length())))) {
                    int j = i + NAME.length();
                    while (j < end && line.charAt(j) == ' ') j++;
                    if (j < end && line.charAt(j) == '(') {
                        // Only calls: skip "function DestroyTimer" / "native DestroyTimer".
                        out.append(line, cursor, i).append(WRAPPER);
                        cursor = i + NAME.length();
                        changed++;
                        i = cursor - 1;
                    }
                }
            }
            if (changed > 0) {
                out.append(line, cursor, line.length());
                lines.set(ln, out.toString());
                count += changed;
            }
        }
        return new Result(lines, count);
    }
}
