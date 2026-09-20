import java.util.ArrayList;
import java.util.List;

/**
 * Small string-level helpers for JASS expressions, shared by the EXExecuteScript
 * scanner and the id-source analyzer. JASS statements are single lines, so all of
 * this works on one line at a time. Everything is aware of string literals
 * (with \" escapes) and nested parentheses.
 */
final class JassExpr {

    private JassExpr() {}

    /** A whole expression of the form {@code name(arg, arg, ...)}. */
    static final class Call {
        final String name;
        final List<String> args;

        Call(String name, List<String> args) {
            this.name = name;
            this.args = args;
        }
    }

    static boolean isIdentChar(char c) {
        return Character.isLetterOrDigit(c) || c == '_';
    }

    static boolean isIdentifier(String s) {
        if (s.isEmpty() || Character.isDigit(s.charAt(0))) return false;
        for (int i = 0; i < s.length(); i++) {
            if (!isIdentChar(s.charAt(i))) return false;
        }
        return true;
    }

    /** Index where a trailing // comment starts (outside string literals), else the line length. */
    static int codeEnd(String line) {
        boolean inString = false;
        for (int i = 0; i < line.length(); i++) {
            char c = line.charAt(i);
            if (inString) {
                if (c == '\\') i++;
                else if (c == '"') inString = false;
            } else if (c == '"') {
                inString = true;
            } else if (c == '/' && i + 1 < line.length() && line.charAt(i + 1) == '/') {
                return i;
            }
        }
        return line.length();
    }

    /** The line without a trailing comment, trimmed. */
    static String code(String line) {
        return line.substring(0, codeEnd(line)).trim();
    }

    /** The line with the text of every string literal removed ("abc" becomes ""). */
    static String stripStrings(String line) {
        StringBuilder sb = new StringBuilder(line.length());
        boolean inString = false;
        for (int i = 0; i < line.length(); i++) {
            char c = line.charAt(i);
            if (inString) {
                if (c == '\\') i++;
                else if (c == '"') { inString = false; sb.append('"'); }
            } else {
                sb.append(c);
                if (c == '"') inString = true;
            }
        }
        return sb.toString();
    }

    /** Index of the ')' matching the '(' at {@code open}, or -1. Only looks before {@code end}. */
    static int findClosingParen(String s, int open, int end) {
        int depth = 0;
        boolean inString = false;
        for (int i = open; i < end; i++) {
            char c = s.charAt(i);
            if (inString) {
                if (c == '\\') i++;
                else if (c == '"') inString = false;
            } else if (c == '"') {
                inString = true;
            } else if (c == '(') {
                depth++;
            } else if (c == ')') {
                depth--;
                if (depth == 0) return i;
            }
        }
        return -1;
    }

    /** Splits at {@code sep} characters that are outside strings and parentheses/brackets. */
    static List<String> splitTopLevel(String s, char sep) {
        List<String> parts = new ArrayList<>();
        int depth = 0;
        boolean inString = false;
        int start = 0;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (inString) {
                if (c == '\\') i++;
                else if (c == '"') inString = false;
            } else if (c == '"') {
                inString = true;
            } else if (c == '(' || c == '[') {
                depth++;
            } else if (c == ')' || c == ']') {
                depth--;
            } else if (c == sep && depth == 0) {
                parts.add(s.substring(start, i));
                start = i + 1;
            }
        }
        parts.add(s.substring(start));
        return parts;
    }

    /** Removes parentheses that wrap the whole expression: "((a))" -> "a". */
    static String stripOuterParens(String s) {
        s = s.trim();
        while (s.length() >= 2 && s.charAt(0) == '(' && findClosingParen(s, 0, s.length()) == s.length() - 1) {
            s = s.substring(1, s.length() - 1).trim();
        }
        return s;
    }

    /** Parses {@code s} if it is exactly one function call, else null. */
    static Call parseCall(String s) {
        s = stripOuterParens(s);
        int open = s.indexOf('(');
        if (open <= 0 || s.charAt(s.length() - 1) != ')') return null;
        String name = s.substring(0, open).trim();
        if (!isIdentifier(name)) return null;
        if (findClosingParen(s, open, s.length()) != s.length() - 1) return null;
        String inner = s.substring(open + 1, s.length() - 1);
        List<String> args = new ArrayList<>();
        if (!inner.trim().isEmpty()) {
            for (String a : splitTopLevel(inner, ',')) args.add(a.trim());
        }
        return new Call(name, args);
    }

    /**
     * Value of an integer literal in any of JASS's spellings - {@code 123}, {@code -5},
     * {@code $7368617A}, {@code 0x7368617A}, {@code 'shar'} - as a signed 32-bit number,
     * or null if the text is not such a literal.
     */
    static Long parseIntegerLiteral(String s) {
        s = s.trim();
        try {
            if (s.length() == 6 && s.charAt(0) == '\'' && s.charAt(5) == '\'') {
                long v = 0;
                for (int i = 1; i <= 4; i++) v = (v << 8) | (s.charAt(i) & 0xFF);
                return (long) (int) v;
            }
            if (s.length() > 1 && s.charAt(0) == '$') {
                return hex(s.substring(1));
            }
            if (s.length() > 2 && s.charAt(0) == '0' && (s.charAt(1) == 'x' || s.charAt(1) == 'X')) {
                return hex(s.substring(2));
            }
            if (s.matches("-?\\d{1,10}")) {
                long v = Long.parseLong(s);
                return (v >= Integer.MIN_VALUE && v <= Integer.MAX_VALUE) ? Long.valueOf(v) : null;
            }
        } catch (NumberFormatException e) {
            // fall through: not a literal
        }
        return null;
    }

    /**
     * Value of an expression made only of integer literals, + - * and parentheses
     * ("$D0647355+1", "'A000'+16") as a signed 32-bit number, or null if it involves
     * anything else (variables, calls, ...).
     */
    static Long evalConstant(String s) {
        ConstantParser p = new ConstantParser(s);
        try {
            long v = p.expression();
            return p.atEnd() ? Long.valueOf((int) v) : null;
        } catch (IllegalArgumentException e) {
            return null;
        }
    }

    private static final class ConstantParser {
        private final String s;
        private int pos;

        ConstantParser(String s) {
            this.s = s;
        }

        boolean atEnd() {
            skipBlanks();
            return pos == s.length();
        }

        private void skipBlanks() {
            while (pos < s.length() && s.charAt(pos) == ' ') pos++;
        }

        private char peek() {
            skipBlanks();
            return pos < s.length() ? s.charAt(pos) : '\0';
        }

        long expression() {
            long v = term();
            for (char c = peek(); c == '+' || c == '-'; c = peek()) {
                pos++;
                long w = term();
                v = (c == '+') ? v + w : v - w;
            }
            return v;
        }

        private long term() {
            long v = factor();
            while (peek() == '*') {
                pos++;
                v *= factor();
            }
            return v;
        }

        private long factor() {
            char c = peek();
            if (c == '-') {
                pos++;
                return -factor();
            }
            if (c == '(') {
                pos++;
                long v = expression();
                if (peek() != ')') throw new IllegalArgumentException();
                pos++;
                return v;
            }
            return atom();
        }

        private long atom() {
            skipBlanks();
            int start = pos;
            if (pos >= s.length()) throw new IllegalArgumentException();
            char c = s.charAt(pos);
            if (c == '\'') {
                if (pos + 6 > s.length() || s.charAt(pos + 5) != '\'') throw new IllegalArgumentException();
                long v = 0;
                for (int i = 1; i <= 4; i++) v = (v << 8) | (s.charAt(pos + i) & 0xFF);
                pos += 6;
                return v;
            }
            int radix = 10;
            if (c == '$') {
                radix = 16;
                pos++;
            } else if (c == '0' && pos + 1 < s.length() && (s.charAt(pos + 1) == 'x' || s.charAt(pos + 1) == 'X')) {
                radix = 16;
                pos += 2;
            }
            int digitsStart = pos;
            while (pos < s.length() && Character.digit(s.charAt(pos), radix) >= 0) pos++;
            if (pos == digitsStart || pos - digitsStart > (radix == 16 ? 8 : 10)) {
                pos = start;
                throw new IllegalArgumentException();
            }
            // an identifier glued to the number ("12abc") is not a literal
            if (pos < s.length() && isIdentChar(s.charAt(pos))) throw new IllegalArgumentException();
            return Long.parseLong(s.substring(digitsStart, pos), radix);
        }
    }

    private static Long hex(String digits) {
        if (digits.length() > 8) return null;
        return (long) (int) Long.parseLong(digits, 16);
    }

    /**
     * The 4-character object id ("shar") encoded by an integer, or null if it does not
     * decode to four letters/digits (i.e. it is not a plausible object rawcode).
     */
    static String rawcodeOrNull(long v) {
        int x = (int) v;
        if (x < 0x30303030 || x > 0x7A7A7A7A) return null;
        char[] c = new char[4];
        for (int i = 0; i < 4; i++) {
            int b = (x >> (24 - 8 * i)) & 0xFF;
            boolean alnum = (b >= '0' && b <= '9') || (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z');
            if (!alnum) return null;
            c[i] = (char) b;
        }
        return new String(c);
    }
}
