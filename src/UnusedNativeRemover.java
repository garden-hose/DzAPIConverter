import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * "Clear unused natives": drops {@code native dz...} declarations that the script
 * declares but never refers to anywhere else.
 *
 * A declaration counts as used when its name shows up as an identifier on any
 * other line of the script (a call, a {@code function} reference, ...). The scan
 * deliberately errs on the side of keeping a native: string literals are not
 * blanked out, and only // comments are ignored, so a leftover declaration is the
 * worst that can happen - never a removed native that the map still needs.
 */
final class UnusedNativeRemover {

    private UnusedNativeRemover() {}

    private static final Pattern IDENTIFIER = Pattern.compile("[A-Za-z_][A-Za-z0-9_]*");

    /** The script after the pass plus the natives that were dropped. */
    static final class Result {
        final List<String> lines;
        final List<String> removedNames;
        /** How many distinct "native dz..." natives the script declared before the pass. */
        final int dzNativeCount;

        Result(List<String> lines, List<String> removedNames, int dzNativeCount) {
            this.lines = lines;
            this.removedNames = removedNames;
            this.dzNativeCount = dzNativeCount;
        }
    }

    /**
     * @param lines the script; not modified
     * @return the script without unused {@code native dz...} declarations
     *         (the same list instance when there was nothing to remove)
     */
    static Result removeUnusedDzNatives(List<String> lines) {
        // 1) every "native dz..." declaration line and its name
        Set<Integer> declarationLines = new HashSet<>();
        Set<String> declaredNames = new LinkedHashSet<>();
        for (int i = 0; i < lines.size(); i++) {
            String line = lines.get(i);
            if (!JassScript.isNativeLine(line)) continue;
            String name = JassScript.extractNativeName(line);
            if (name == null || !name.regionMatches(true, 0, "dz", 0, 2)) continue;
            declarationLines.add(i);
            declaredNames.add(name);
        }
        if (declarationLines.isEmpty()) {
            return new Result(lines, Collections.<String>emptyList(), 0);
        }

        // 2) which of those names appear anywhere outside their own declarations
        Set<String> usedNames = new HashSet<>();
        for (int i = 0; i < lines.size(); i++) {
            if (declarationLines.contains(i)) continue;
            Matcher m = IDENTIFIER.matcher(codePart(lines.get(i)));
            while (m.find()) {
                String id = m.group();
                if (declaredNames.contains(id)) usedNames.add(id);
            }
        }

        // 3) rebuild the script without the declarations nothing refers to
        List<String> kept = new ArrayList<>(lines.size());
        Set<String> removed = new LinkedHashSet<>();
        for (int i = 0; i < lines.size(); i++) {
            if (declarationLines.contains(i)) {
                String name = JassScript.extractNativeName(lines.get(i));
                if (!usedNames.contains(name)) {
                    removed.add(name);
                    continue;
                }
            }
            kept.add(lines.get(i));
        }
        if (removed.isEmpty()) {
            return new Result(lines, Collections.<String>emptyList(), declaredNames.size());
        }
        return new Result(kept, new ArrayList<>(removed), declaredNames.size());
    }

    /**
     * The line without its trailing // comment. Quote-aware, so the // in a string
     * such as "http://x" does not cut the code that follows it. An unbalanced quote
     * leaves the rest of the line in place (treated as string text).
     */
    private static String codePart(String line) {
        boolean inString = false;
        for (int i = 0; i < line.length(); i++) {
            char c = line.charAt(i);
            if (inString) {
                if (c == '\\') {
                    i++; // skip the escaped character (\" and \\)
                } else if (c == '"') {
                    inString = false;
                }
            } else if (c == '"') {
                inString = true;
            } else if (c == '/' && i + 1 < line.length() && line.charAt(i + 1) == '/') {
                return line.substring(0, i);
            }
        }
        return line;
    }
}
