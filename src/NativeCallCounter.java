import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;

/** Counts how often a script refers to a set of natives outside their own declarations. */
final class NativeCallCounter {

    private NativeCallCounter() {}

    /**
     * @return for every name in {@code names}, the number of times it appears as an
     *         identifier in code (calls and {@code function} references) on lines that
     *         are not native declarations; names that never appear map to 0
     */
    static Map<String, Integer> count(List<String> lines, Set<String> names) {
        Map<String, Integer> counts = new HashMap<>();
        for (String n : names) counts.put(n, 0);
        if (names.isEmpty()) return counts;
        for (String line : lines) {
            if (line.isEmpty() || JassScript.isNativeLine(line)) continue;
            Matcher m = JassText.IDENTIFIER.matcher(JassText.codeOnly(line));
            while (m.find()) {
                Integer c = counts.get(m.group());
                if (c != null) counts.put(m.group(), c + 1);
            }
        }
        return counts;
    }
}
