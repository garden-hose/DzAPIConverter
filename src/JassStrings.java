/** Escape / unescape helpers for JASS double-quoted string literals. */
final class JassStrings {

    private JassStrings() {}

    /** Escape a string for use inside a JASS double-quoted literal. */
    static String escape(String s) {
        if (s == null) return "";
        StringBuilder sb = new StringBuilder(s.length() + 8);
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '\\': sb.append("\\\\"); break;
                case '"':  sb.append("\\\""); break;
                case '\n': sb.append("\\n"); break;
                case '\r': sb.append("\\r"); break;
                case '\t': sb.append("\\t"); break;
                default:   sb.append(c); break;
            }
        }
        return sb.toString();
    }

    /** Resolve JASS string escapes: \\ becomes \ and \" becomes ". Other backslashes are kept. */
    static String unescape(String s) {
        if (s == null || s.indexOf('\\') < 0) {
            return s == null ? "" : s;
        }
        StringBuilder sb = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '\\' && i + 1 < s.length()
                    && (s.charAt(i + 1) == '\\' || s.charAt(i + 1) == '"')) {
                sb.append(s.charAt(i + 1));
                i++;
            } else {
                sb.append(c);
            }
        }
        return sb.toString();
    }

    /**
     * Escape a real (already unescaped) model path for JASS output.
     */
    static String escapeForModelPath(String s) {
        if (s == null) return "";
        // Input must be the real (already unescaped) path, e.g. X\W\a.mdl.
        // Every single \ becomes \\ exactly once: X\\W\\a.mdl
        return s.replace("\\", "\\\\").replace("\"", "\\\"");
    }
}
