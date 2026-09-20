import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Small line-level helpers for working with a JASS script held as a list of lines. */
final class JassScript {

    private JassScript() {}

    static boolean isNativeLine(String line) {
        return line.matches("^\\s*native\\b.*");
    }

    private static final Pattern NATIVE_NAME = Pattern.compile("native\\s+(\\w+)\\s+takes");

    static String extractNativeName(String line) {
        Matcher m = NATIVE_NAME.matcher(line);
        return m.find() ? m.group(1) : null;
    }

    /** Returns a copy of {@code lines} without any line that starts with a // comment
     *  (leading whitespace ignored). Trailing comments after code are left untouched. */
    static List<String> stripCommentLines(List<String> lines) {
        List<String> filtered = new ArrayList<>(lines.size());
        for (String line : lines) {
            if (line.trim().startsWith("//")) continue;
            filtered.add(line);
        }
        return filtered;
    }

    /**
     * Insert {@code call funcName()} at the start of {@code function main}.
     * @return true if main was found and the call inserted, false otherwise
     *         (nothing is written to the script in that case, since comment
     *         lines are always omitted from the output).
     */
    static boolean injectCallIntoMain(List<String> lines, String funcName) {
        return injectStatementIntoMain(lines, "call " + funcName + "()");
    }

    /**
     * Insert one statement at the start of {@code function main}. JASS requires
     * local declarations to come first in a function, so the statement goes
     * after any leading {@code local} lines rather than straight after the header.
     *
     * @return true if main was found and the statement inserted, false otherwise
     */
    static boolean injectStatementIntoMain(List<String> lines, String statement) {
        Pattern mainStart = Pattern.compile("^\\s*function\\s+main\\s+takes\\b");
        for (int i = 0; i < lines.size(); i++) {
            if (mainStart.matcher(lines.get(i)).find()) {
                int at = i + 1;
                while (at < lines.size() && lines.get(at).trim().startsWith("local ")) {
                    at++;
                }
                lines.add(at, "    " + statement);
                return true;
            }
        }
        return false;
    }
}
