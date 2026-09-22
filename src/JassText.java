import java.util.regex.Pattern;

/** Small lexical helpers shared by the passes that look for identifiers in JASS source lines. */
final class JassText {

    private JassText() {}

    static final Pattern IDENTIFIER = Pattern.compile("[A-Za-z_][A-Za-z0-9_]*");

    /**
     * The code of a line with everything that is not code blanked out: the trailing
     * // comment is dropped and the contents of string literals are replaced by spaces
     * (the quotes stay). Identifiers found in the result are real identifiers, never
     * text inside a string or a comment. An unbalanced quote blanks the rest of the line.
     */
    static String codeOnly(String line) {
        StringBuilder sb = null; // created lazily: most lines contain no string
        boolean inString = false;
        int n = line.length();
        for (int i = 0; i < n; i++) {
            char c = line.charAt(i);
            if (inString) {
                if (c == '\\' && i + 1 < n) {
                    if (sb == null) sb = new StringBuilder(line);
                    sb.setCharAt(i, ' ');
                    sb.setCharAt(i + 1, ' ');
                    i++;
                } else if (c == '"') {
                    inString = false;
                } else {
                    if (sb == null) sb = new StringBuilder(line);
                    sb.setCharAt(i, ' ');
                }
            } else if (c == '"') {
                inString = true;
            } else if (c == '/' && i + 1 < n && line.charAt(i + 1) == '/') {
                if (sb == null) return line.substring(0, i);
                sb.setLength(i);
                return sb.toString();
            }
        }
        return sb == null ? line : sb.toString();
    }
}
