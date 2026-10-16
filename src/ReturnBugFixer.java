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
 */
final class ReturnBugFixer {

    private ReturnBugFixer() {}

    /** Name of the empty function a rewritten function that returns code points at. */
    static final String NULL_CODE = "DzCompat_NullCode";

    private static final Pattern PRAGMA =
            Pattern.compile("^\\s*//#\\s*\\+nosemanticerror\\s*$");
    private static final Pattern FUNCTION_LINE =
            Pattern.compile("^(\\s*)(?:constant\\s+)?function\\s+(\\w+)\\s+takes\\s+(.*?)\\s+returns\\s+(\\w+)\\s*(?://.*)?$");
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

        Result(List<String> lines, List<Fixed> fixed, int strayPragmas) {
            this.lines = lines;
            this.fixed = fixed;
            this.strayPragmas = strayPragmas;
        }

        boolean changedAnything() {
            return !fixed.isEmpty();
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

        if (firstCodeAt >= 0 && !declaresNullCode(out)) {
            out.add(firstCodeAt, "");
            out.add(firstCodeAt, "endfunction");
            out.add(firstCodeAt, "function " + NULL_CODE + " takes nothing returns nothing");
        }

        for (Fixed fx : fixed) {
            fx.uses = countUses(out, fx.name);
        }
        return new Result(out, fixed, stray);
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
