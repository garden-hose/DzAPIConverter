import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Rewrites the "return bug" typecast functions of old maps with a type-correct body.
 *
 * <p>Old map scripts convert between types by returning a value of another type, for
 * example {@code function H2I takes handle h returns integer / return h / endfunction}.
 * The compiler of the old game let that through when the function was wrapped in the
 * {@code //# +nosemanticerror} pragma. Reforged 3.0 does not know the pragma and refuses
 * the script. Every function that directly follows the pragma keeps its signature and gets
 * a body the compiler accepts:
 *
 * <ul>
 *   <li>handle -> integer: {@code GetHandleId(param)}, the real value;</li>
 *   <li>boolean -> integer: 1 or 0; integer -> boolean: {@code param != 0};
 *       string -> integer: {@code StringHash(param)};</li>
 *   <li>{@code returns code}: {@code return function DzCompat_NullCode}, an empty function this
 *       pass adds to the script;</li>
 *   <li>any other cast has no Reforged equivalent and returns a neutral value: 0, 0.0,
 *       false, "" or null. A call site that depended on the real cast will not work, so
 *       the functions the script still calls are reported.</li>
 * </ul>
 *
 * The pragma line is removed. Only real code lines are looked at: the call-site count
 * ignores string literals and // comments.
 *
 * <p>Independent of the pragma, in every function of the script: {@code return null} in a
 * function that returns code becomes {@code return function DzCompat_NullCode}, and a bare
 * {@code return} in a function that returns a value gets a neutral value, because the 3.0
 * compiler refuses both and the old one let them through.
 */
final class ReturnBugFixer {

    private ReturnBugFixer() {}

    /** Name of the empty function a rewritten function that returns code points at. */
    static final String NULL_CODE = "DzCompat_NullCode";

    private static final Pattern PRAGMA =
            Pattern.compile("^\\s*//#\\s*\\+nosemanticerror\\s*$");
    private static final Pattern FUNCTION_LINE =
            Pattern.compile("^(\\s*)(?:constant\\s+)?function\\s+(\\w+)\\s+takes\\s+(.*?)\\s+returns\\s+(\\w+)\\s*(?://.*)?$");
    private static final Pattern RETURN_NULL =
            Pattern.compile("^(\\s*return\\s+)null(\\s*)$");
    private static final Pattern RETURN_BARE =
            Pattern.compile("^(\\s*return)(\\s*)$");
    private static final Pattern NULL_CODE_DECL =
            Pattern.compile("^\\s*function\\s+" + NULL_CODE + "\\s+takes\\b");

    /** One rewritten function. */
    static final class Fixed {
        final String name;
        final String returnType;
        /** "exact" when the body does the same job as the old cast, "neutral" when it cannot. */
        final boolean exact;
        /** Calls of the function plus {@code function name} references, in the whole script. */
        int uses;

        Fixed(String name, String returnType, boolean exact) {
            this.name = name;
            this.returnType = returnType;
            this.exact = exact;
        }
    }

    static final class Result {
        final List<String> lines;
        final List<Fixed> fixed;
        /** Pragma lines that were not followed by a function (left in place). */
        final int strayPragmas;
        /** {@code return null} lines of functions that return code, rewritten anywhere in the script. */
        final int nullCodeReturns;
        /** Bare {@code return} lines of functions that return a value, given a neutral value. */
        final int emptyReturns;

        Result(List<String> lines, List<Fixed> fixed, int strayPragmas, int nullCodeReturns, int emptyReturns) {
            this.lines = lines;
            this.fixed = fixed;
            this.strayPragmas = strayPragmas;
            this.nullCodeReturns = nullCodeReturns;
            this.emptyReturns = emptyReturns;
        }

        boolean changedAnything() {
            return !fixed.isEmpty() || nullCodeReturns > 0 || emptyReturns > 0;
        }
    }

    static Result fix(List<String> inputLines) {
        List<String> out = new ArrayList<>(inputLines.size() + 8);
        List<Fixed> fixed = new ArrayList<>();
        int stray = 0;
        // Index in "out" of the first rewritten function that returns code: the empty
        // function it points at has to be declared above it.
        int firstCodeAt = -1;

        int i = 0;
        int n = inputLines.size();
        while (i < n) {
            String line = inputLines.get(i);
            if (!PRAGMA.matcher(line).matches()) {
                out.add(line);
                i++;
                continue;
            }
            int f = i + 1;
            while (f < n && inputLines.get(f).trim().isEmpty()) f++;
            Matcher m = f < n ? FUNCTION_LINE.matcher(inputLines.get(f)) : null;
            int end = -1;
            if (m != null && m.matches()) {
                for (int k = f + 1; k < n; k++) {
                    String t = inputLines.get(k).trim();
                    if (t.equals("endfunction") || t.startsWith("endfunction ")
                            || t.startsWith("endfunction\t") || t.startsWith("endfunction//")) {
                        end = k;
                        break;
                    }
                }
            }
            if (end < 0) {
                // Not followed by a function we can read: leave the pragma as it is.
                out.add(line);
                stray++;
                i++;
                continue;
            }

            String indent = m.group(1);
            String name = m.group(2);
            String params = m.group(3);
            String returnType = m.group(4);
            List<String> body = new ArrayList<>();
            boolean exact = body(returnType, params, body);
            if (returnType.equals("code") && firstCodeAt < 0) {
                firstCodeAt = out.size();
            }
            out.add(inputLines.get(f));
            for (String b : body) {
                out.add(indent + "    " + b);
            }
            fixed.add(new Fixed(name, returnType, exact));
            i = end; // the endfunction line is copied by the normal path
        }

        // Every function of the script, pragma or not (the ones rewritten above already
        // compile and are not touched again).
        int[] counts = new int[2];
        int firstReturnAt = fixReturns(out, counts);
        if (firstReturnAt >= 0 && (firstCodeAt < 0 || firstReturnAt < firstCodeAt)) {
            firstCodeAt = firstReturnAt;
        }

        if (firstCodeAt >= 0 && !declaresNullCode(out)) {
            out.add(firstCodeAt, "");
            out.add(firstCodeAt, "endfunction");
            out.add(firstCodeAt, "function " + NULL_CODE + " takes nothing returns nothing");
        }

        for (Fixed fx : fixed) {
            fx.uses = countUses(out, fx.name);
        }
        return new Result(out, fixed, stray, counts[0], counts[1]);
    }

    /**
     * {@code return null} in a function that returns code -> {@code return function DzCompat_NullCode};
     * a bare {@code return} in a function that returns a value -> a neutral value. Counts go into
     * {@code counts} (0 = null code, 1 = bare return). Returns the index of the first function
     * that now points at DzCompat_NullCode, or -1: the empty function has to be declared above it.
     */
    private static int fixReturns(List<String> lines, int[] counts) {
        int firstCodeAt = -1;
        String type = null;
        int functionAt = -1;
        for (int i = 0; i < lines.size(); i++) {
            String line = lines.get(i);
            Matcher fm = FUNCTION_LINE.matcher(line);
            if (fm.matches()) {
                type = fm.group(4);
                functionAt = i;
                continue;
            }
            String t = line.trim();
            if (t.equals("endfunction") || t.startsWith("endfunction ")
                    || t.startsWith("endfunction\t") || t.startsWith("endfunction//")) {
                type = null;
                continue;
            }
            if (type == null || type.equals("nothing")) continue;

            int end = JassExpr.codeEnd(line);
            String code = line.substring(0, end);
            String comment = line.substring(end);
            if (type.equals("code")) {
                Matcher m = RETURN_NULL.matcher(code);
                if (m.matches()) {
                    lines.set(i, m.group(1) + "function " + NULL_CODE + m.group(2) + comment);
                    counts[0]++;
                    if (firstCodeAt < 0) firstCodeAt = functionAt;
                    continue;
                }
            }
            Matcher b = RETURN_BARE.matcher(code);
            if (b.matches()) {
                lines.set(i, b.group(1) + " " + neutralValue(type) + b.group(2) + comment);
                counts[1]++;
                if (type.equals("code") && firstCodeAt < 0) firstCodeAt = functionAt;
            }
        }
        return firstCodeAt;
    }

    /** The value a bare return of a function with this return type gets. */
    private static String neutralValue(String returnType) {
        switch (returnType) {
            case "integer": return "0";
            case "real": return "0.";
            case "boolean": return "false";
            case "string": return "\"\"";
            case "code": return "function " + NULL_CODE;
            default: return "null";
        }
    }

    /** Fills {@code body} for a function with this signature; returns false for a neutral body. */
    private static boolean body(String returnType, String params, List<String> body) {
        String[] parts = params.trim().equals("nothing") ? new String[0] : params.split(",");
        String paramType = null;
        String paramName = null;
        if (parts.length == 1) {
            String[] pn = parts[0].trim().split("\\s+");
            if (pn.length == 2) {
                paramType = pn[0];
                paramName = pn[1];
            }
        }
        if (returnType.equals("nothing")) {
            return true;
        }
        if (returnType.equals("code")) {
            body.add("return function " + NULL_CODE);
            return false;
        }
        if (paramType != null) {
            if (returnType.equals("integer") && paramType.equals("boolean")) {
                body.add("if " + paramName + " then");
                body.add("    return 1");
                body.add("endif");
                body.add("return 0");
                return true;
            }
            if (returnType.equals("boolean") && paramType.equals("integer")) {
                body.add("return " + paramName + " != 0");
                return true;
            }
            if (returnType.equals("integer") && paramType.equals("string")) {
                body.add("return StringHash(" + paramName + ")");
                return true;
            }
            if (returnType.equals("integer") && !isValueType(paramType)) {
                body.add("return GetHandleId(" + paramName + ")");
                return true;
            }
        }
        switch (returnType) {
            case "integer": body.add("return 0"); break;
            case "real": body.add("return 0."); break;
            case "boolean": body.add("return false"); break;
            case "string": body.add("return \"\""); break;
            default: body.add("return null"); break;
        }
        return false;
    }

    private static boolean isValueType(String type) {
        return type.equals("integer") || type.equals("real") || type.equals("boolean")
                || type.equals("string") || type.equals("code") || type.equals("nothing");
    }

    private static boolean declaresNullCode(List<String> lines) {
        for (String line : lines) {
            if (NULL_CODE_DECL.matcher(line).find()) return true;
        }
        return false;
    }

    /** Calls of {@code name(...)} and {@code function name} references, declaration excluded. */
    private static int countUses(List<String> lines, String name) {
        Pattern call = Pattern.compile("(?<![\\w.])" + Pattern.quote(name) + "\\s*\\(");
        Pattern ref = Pattern.compile("\\bfunction\\s+" + Pattern.quote(name) + "\\b");
        int count = 0;
        for (String line : lines) {
            String stripped = JassExpr.stripStrings(line.substring(0, JassExpr.codeEnd(line)));
            String t = stripped.trim();
            if (t.startsWith("function ") || t.startsWith("constant function ")) {
                // the declaration of a function, not a use; a "function name" reference in an
                // argument list cannot start a line
                continue;
            }
            Matcher c = call.matcher(stripped);
            while (c.find()) count++;
            Matcher r = ref.matcher(stripped);
            while (r.find()) count++;
        }
        return count;
    }
}
