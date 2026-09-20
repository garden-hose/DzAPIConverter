import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Finds which known functions / globals a block of JASS source refers to. */
final class DependencyAnalyzer {

    private DependencyAnalyzer() {}

    static Set<String> extractCalls(List<String> lines, Set<String> knownFunctions) {
        String text = String.join("\n", lines);
        Set<String> calls = new LinkedHashSet<>();

        // Match word followed by optional whitespace and '(' - ordinary calls,
        // e.g. "call Foo(" or "Foo(args)".
        Pattern callPat = Pattern.compile("\\b([A-Za-z][A-Za-z0-9_]*)\\s*\\(");
        Matcher cm = callPat.matcher(text);
        while (cm.find()) {
            String name = cm.group(1);
            if (knownFunctions.contains(name)) calls.add(name);
        }

        // Match bare "function Name" references - JASS's function-pointer/
        // code-literal syntax, e.g. "TriggerAddAction(trig, function Foo)" or
        // "Filter(function Bar)". These never have a '(' right after the name
        // (the callee is passed BY NAME, not invoked), so the pattern above
        // misses them entirely - without this, a helper only ever wired up as
        // a trigger action/condition gets silently dropped from the output
        // while everything that references it (by call) is kept, leaving a
        // dangling reference to an undeclared function. This also matches a
        // segment's own "function Name takes ..." declaration line, which is
        // a harmless no-op self-reference (the segment is already kept).
        Pattern funcRefPat = Pattern.compile("\\bfunction\\s+([A-Za-z][A-Za-z0-9_]*)\\b");
        Matcher fm = funcRefPat.matcher(text);
        while (fm.find()) {
            String name = fm.group(1);
            if (knownFunctions.contains(name)) calls.add(name);
        }

        return calls;
    }

    static Set<String> extractGlobalRefs(List<String> lines, Set<String> knownGlobals) {
        String text = String.join("\n", lines);
        Pattern p = Pattern.compile("\\b([A-Za-z][A-Za-z0-9_]*)\\b");
        Matcher m = p.matcher(text);
        Set<String> refs = new LinkedHashSet<>();
        while (m.find()) {
            String w = m.group(1);
            if (knownGlobals.contains(w)) refs.add(w);
        }
        return refs;
    }
}
