import java.util.ArrayList;
import java.util.List;

/**
 * Rewrites UnitAddAbility call sites so abilities pick up DATA_A..I values written earlier
 * through EXSetAbilityDataReal/Integer.
 *
 * In YDWE/KKAPI those natives change the ability's object data, so every instance added
 * afterwards carries the value. Reforged's Blz*LevelField only changes the single instance
 * it is given. The common map idiom is
 *     UnitAddAbility(dummy, id); EXSetAbilityDataReal(...); UnitAddAbility(hero, id)
 * which therefore gave the hero a default (zeroed) copy of the ability - for example a
 * hidden Aamk stat-bonus ability that granted nothing.
 *
 * The EX setters now remember what they wrote per ability rawcode (see
 * lib/DzCompat_YDWE_EX.j); this pass sends every UnitAddAbility call through
 * DzCompat_UnitAddAbility, which re-applies those values to the new instance.
 *
 * Only runs when the map uses EXSetAbilityDataReal/Integer. Call sites are rewritten
 * with the same string/paren-aware scanning as ExtendedUnitStateConverter.
 */
final class AbilityAddConverter {

    private AbilityAddConverter() {}

    private static final String NAME = "UnitAddAbility";
    static final String WRAPPER = "DzCompat_UnitAddAbility";

    static final class Result {
        final List<String> lines;
        final int rewritten;

        Result(List<String> lines, int rewritten) {
            this.lines = lines;
            this.rewritten = rewritten;
        }
    }

    static boolean scriptWritesAbilityData(List<String> lines) {
        for (String l : lines) {
            if (JassScript.isNativeLine(l)) continue;
            if (l.contains("EXSetAbilityDataReal") || l.contains("EXSetAbilityDataInteger")) return true;
        }
        return false;
    }

    static Result convert(List<String> inputLines) {
        List<String> lines = new ArrayList<>(inputLines);
        int count = 0;
        for (int ln = 0; ln < lines.size(); ln++) {
            String line = lines.get(ln);
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
                        // Only calls: skip "function UnitAddAbility" style declarations.
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
