import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Finds EXExecuteScript(...) call sites in a JASS script and classifies them.
 *
 * The argument is a JASS expression, usually a concatenation such as
 * {@code "(require'jass.slk').item["+I2S(LoadInteger(x,1,2))+"].Name"}. The
 * scanner is string- and parenthesis-aware (a plain regex cannot cope with the
 * nested calls and escaped quotes), splits the argument at its top-level '+',
 * and rebuilds a "template": literal parts verbatim, one {@code \u0001} for
 * every non-literal part. That is enough to recognise the jass.slk idiom and
 * to learn which (table, field) pairs a map reads even though the object id is
 * only known at runtime.
 */
final class ExecuteScriptScanner {

    private ExecuteScriptScanner() {}

    /** The tables jass.slk exposes (jass2lua docs); they match W3x2lni's table/*.ini names. */
    static final Set<String> SLK_TABLES = Collections.unmodifiableSet(new LinkedHashSet<>(Arrays.asList(
            "unit", "item", "destructable", "doodad", "ability", "buff", "upgrade", "misc")));

    enum Kind {
        /** (require'jass.slk').table[id].Field with a literal field name. */
        SLK_FIELD,
        /** Same idiom, but the field name is built at runtime (e.g. ".Cost" + I2S(level)). */
        SLK_DYNAMIC_FIELD,
        /** Anything else - not supported. */
        OTHER
    }

    static final class Call {
        /** 0-based index of the script line the call is on. */
        final int line;
        /** Literal parts of the argument; one \u0001 per non-literal part. */
        final String template;
        final Kind kind;
        /** slk table for the SLK_* kinds, else null. */
        final String table;
        /** Field name (SLK_FIELD) or its literal prefix (SLK_DYNAMIC_FIELD), else null. */
        final String field;
        /**
         * JASS integer expression that produces the object id ("LoadInteger(an,1,2)" for
         * {@code item["+I2S(LoadInteger(an,1,2))+"]}, or the digits of a literal id).
         * Null when the index is not a plain I2S(...) or literal.
         */
        final String idExpression;

        Call(int line, String template, Kind kind, String table, String field, String idExpression) {
            this.line = line;
            this.template = template;
            this.kind = kind;
            this.table = table;
            this.field = field;
            this.idExpression = idExpression;
        }

        /** Short human-readable form for log lines. */
        String describe() {
            switch (kind) {
                case SLK_FIELD:         return table + "." + field;
                case SLK_DYNAMIC_FIELD: return table + "." + field + "<runtime suffix>";
                default:
                    String t = template.replace('\u0001', '?');
                    return t.length() > 70 ? t.substring(0, 70) + "..." : t;
            }
        }
    }

    private static final String NAME = "EXExecuteScript";
    private static final char HOLE = '\u0001';

    // ...jass.slk'  )  .  table [ index ] . field   (end of script)   groups: table, index, field
    private static final Pattern SLK_READ = Pattern.compile(
            "jass\\.slk[)'\"\\s]*\\.\\s*(\\w+)\\s*\\[([^\\]]*)\\]\\s*\\.\\s*(\\w+)\\s*$");
    private static final Pattern SLK_READ_DYNAMIC_FIELD = Pattern.compile(
            "jass\\.slk[)'\"\\s]*\\.\\s*(\\w+)\\s*\\[([^\\]]*)\\]\\s*\\.\\s*(\\w*)" + HOLE);

    /** All EXExecuteScript(...) calls in the script, in file order. Comments are ignored. */
    static List<Call> scan(List<String> lines) {
        List<Call> calls = new ArrayList<>();
        for (int ln = 0; ln < lines.size(); ln++) {
            String line = lines.get(ln);
            if (!line.contains(NAME)) continue;
            int end = JassExpr.codeEnd(line);
            boolean inString = false;
            int i = 0;
            while (i < end) {
                char c = line.charAt(i);
                if (inString) {
                    if (c == '\\') i++;            // skip the escaped character
                    else if (c == '"') inString = false;
                    i++;
                    continue;
                }
                if (c == '"') {
                    inString = true;
                    i++;
                    continue;
                }
                if (line.startsWith(NAME, i) && (i == 0 || !JassExpr.isIdentChar(line.charAt(i - 1)))) {
                    int j = i + NAME.length();
                    while (j < end && line.charAt(j) == ' ') j++;
                    if (j < end && line.charAt(j) == '(') {
                        int close = JassExpr.findClosingParen(line, j, end);
                        if (close > 0) {
                            calls.add(classify(ln, line.substring(j + 1, close)));
                            i = close + 1;
                            continue;
                        }
                    }
                }
                i++;
            }
        }
        return calls;
    }

    private static Call classify(int lineIndex, String argument) {
        StringBuilder template = new StringBuilder();
        List<String> holes = new ArrayList<>();          // the non-literal parts, in order
        for (String part : JassExpr.splitTopLevel(argument, '+')) {
            String trimmed = part.trim();
            String literal = literalValue(trimmed);
            if (literal != null) {
                template.append(literal);
            } else {
                template.append(HOLE);
                holes.add(trimmed);
            }
        }
        String t = template.toString();

        Matcher m = SLK_READ.matcher(t);
        if (m.find() && SLK_TABLES.contains(m.group(1))) {
            return new Call(lineIndex, t, Kind.SLK_FIELD, m.group(1), m.group(3),
                            idExpression(t, m.start(2), m.group(2), holes));
        }
        m = SLK_READ_DYNAMIC_FIELD.matcher(t);
        if (m.find() && SLK_TABLES.contains(m.group(1))) {
            return new Call(lineIndex, t, Kind.SLK_DYNAMIC_FIELD, m.group(1), m.group(3),
                            idExpression(t, m.start(2), m.group(2), holes));
        }
        return new Call(lineIndex, t, Kind.OTHER, null, null, null);
    }

    /**
     * The integer expression inside the [ ] of the jass.slk read: literal digits, or the
     * argument of I2S(...) when the index is one non-literal part; otherwise null.
     */
    private static String idExpression(String template, int indexStart, String indexText, List<String> holes) {
        // not String.trim(): it would also strip the \u0001 placeholder
        String idx = indexText.replaceAll("^[ \\t]+|[ \\t]+$", "");
        if (idx.matches("\\d+")) return idx;
        if (idx.length() != 1 || idx.charAt(0) != HOLE) return null;
        int holesBefore = 0;
        for (int i = 0; i < indexStart; i++) {
            if (template.charAt(i) == HOLE) holesBefore++;
        }
        String part = holes.get(holesBefore);
        JassExpr.Call call = JassExpr.parseCall(part);
        if (call != null && call.name.equals("I2S") && call.args.size() == 1) {
            return call.args.get(0);
        }
        return null;
    }

    /** The unescaped text if {@code part} is exactly one string literal, else null. */
    private static String literalValue(String part) {
        if (part.length() < 2 || part.charAt(0) != '"') return null;
        for (int i = 1; i < part.length(); i++) {
            char c = part.charAt(i);
            if (c == '\\') {
                i++;
            } else if (c == '"') {
                if (i != part.length() - 1) return null;   // e.g. "a" b "c"
                return JassStrings.unescape(part.substring(1, i));
            }
        }
        return null;
    }
}
