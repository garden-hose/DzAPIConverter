import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Works out which object ids (rawcodes such as 'shar') can reach an integer
 * expression, so that only the object data a map can really ask for is baked
 * for EXExecuteScript.
 *
 * The analysis is deliberately small. Starting from the expression in
 * {@code I2S(<expr>)} it follows:
 *   - integer constants ($73686172, 0x..., 'shar', decimal, and sums such as
 *     $D0647355+1)                                                -> an id
 *   - LoadInteger(H, p, c)  -> the value of the SaveInteger(H, p', c', value)
 *     statements that can feed it. Constant keys must be equal. When some store
 *     uses the very same constant keys the load uses, only those stores count
 *     (a slot written under constant keys is the slot read under them); otherwise
 *     every store whose keys are compatible counts, unless that is more than
 *     MAX_FAN_OUT of them (a fully dynamic read of a general-purpose hashtable,
 *     which cannot be traced)
 *   - a global integer variable or array -> everything assigned to it
 *
 * What it does NOT do, on purpose:
 *   - values it cannot see through (arithmetic, S2I, user functions, locals and
 *     parameters) are ignored, i.e. the analysis is optimistic about them;
 *   - but a value that comes straight from a native that returns an object id at
 *     runtime (GetItemTypeId, GetUnitTypeId, ...) makes the result "unresolved",
 *     as does a hashtable that is used other than through the Save/Load natives
 *     (it could be written to somewhere the scan cannot see). The caller then falls
 *     back to baking more data instead of risking a missing id.
 */
final class IdSourceAnalyzer {

    /** Natives whose result is an object id only known while the game runs. */
    private static final Set<String> RUNTIME_ID_NATIVES = Collections.unmodifiableSet(new HashSet<>(Arrays.asList(
            "GetItemTypeId", "GetUnitTypeId", "GetSpellAbilityId", "GetLearnedSkill", "GetResearched",
            "GetTrainedUnitType", "GetUpgradeId", "GetDestructableTypeId", "GetUnitBuildTime",
            "GetItemTypeId2", "BlzGetItemTypeId")));

    /** Loads that could be fed by more stores than this are not followed. */
    private static final int MAX_FAN_OUT = 256;

    /** What one expression can evaluate to. */
    static final class Result {
        /** Object ids reachable through literals, hashtables and globals. */
        final Set<String> ids = new LinkedHashSet<>();
        /** Non-null when the ids cannot be fully known from the script; says why. */
        String unresolved;
    }

    private static final class Store {
        final String parentKey, childKey, value;

        Store(String parentKey, String childKey, String value) {
            this.parentKey = parentKey;
            this.childKey = childKey;
            this.value = value;
        }
    }

    private final List<String> script;
    /** hashtable variable -> every SaveInteger into it */
    private final Map<String, List<Store>> stores = new HashMap<>();
    /** global integer variable/array -> every value assigned to it (including its initialiser) */
    private final Map<String, List<String>> globalValues = new HashMap<>();
    /** memo: hashtable variable -> reason it may be written to unseen (null = clean) */
    private final Map<String, String> escapeCache = new HashMap<>();

    private static final Pattern INT_GLOBAL = Pattern.compile(
            "^(?:constant\\s+)?integer\\s+(?:array\\s+)?(\\w+)\\s*(?:=\\s*(.*))?$");
    private static final Pattern SET_TARGET = Pattern.compile("^set\\s+(\\w+)\\s*(\\[|=)");
    private static final Pattern SAVE_INTEGER = Pattern.compile("^call\\s+SaveInteger\\s*\\((.*)\\)$");

    IdSourceAnalyzer(List<String> script) {
        this.script = script;
        index();
    }

    private void index() {
        boolean inGlobals = false;
        boolean globalsDone = false;
        for (String raw : script) {
            String line = raw.trim();
            if (line.isEmpty() || line.startsWith("//")) continue;

            if (!globalsDone) {
                if (!inGlobals) {
                    if (line.equals("globals")) inGlobals = true;
                    continue;
                }
                if (line.equals("endglobals")) {
                    globalsDone = true;
                    continue;
                }
                Matcher m = INT_GLOBAL.matcher(JassExpr.code(line));
                if (m.matches()) {
                    List<String> values = globalValues.computeIfAbsent(m.group(1), k -> new ArrayList<>());
                    if (m.group(2) != null) values.add(m.group(2).trim());
                }
                continue;
            }

            String code = JassExpr.code(line);
            Matcher save = SAVE_INTEGER.matcher(code);
            if (save.matches()) {
                List<String> args = JassExpr.splitTopLevel(save.group(1), ',');
                if (args.size() == 4 && JassExpr.isIdentifier(args.get(0).trim())) {
                    stores.computeIfAbsent(args.get(0).trim(), k -> new ArrayList<>())
                          .add(new Store(args.get(1).trim(), args.get(2).trim(), args.get(3).trim()));
                }
            } else if (code.startsWith("set")) {
                Matcher m = SET_TARGET.matcher(code);
                if (m.find() && globalValues.containsKey(m.group(1))) {
                    int eq = assignmentIndex(code, m.end(1));
                    if (eq > 0) globalValues.get(m.group(1)).add(code.substring(eq + 1).trim());
                }
            }
        }
    }

    /** Index of the '=' of a set statement (skips an optional [index]), or -1. */
    private static int assignmentIndex(String code, int from) {
        int depth = 0;
        boolean inString = false;
        for (int i = from; i < code.length(); i++) {
            char c = code.charAt(i);
            if (inString) {
                if (c == '\\') i++;
                else if (c == '"') inString = false;
            } else if (c == '"') {
                inString = true;
            } else if (c == '[' || c == '(') {
                depth++;
            } else if (c == ']' || c == ')') {
                depth--;
            } else if (c == '=' && depth == 0) {
                return i;
            }
        }
        return -1;
    }

    /** Object ids the integer expression can evaluate to (see the class comment for the limits). */
    Result resolve(String expression) {
        Result result = new Result();
        collect(expression, result, new HashSet<Object>());
        return result;
    }

    private void collect(String expression, Result out, Set<Object> visited) {
        String expr = JassExpr.stripOuterParens(expression);
        if (expr.isEmpty()) return;

        Long literal = JassExpr.evalConstant(expr);
        if (literal != null) {
            String id = JassExpr.rawcodeOrNull(literal);
            if (id != null) out.ids.add(id);
            return;
        }

        JassExpr.Call call = JassExpr.parseCall(expr);
        if (call != null) {
            if (call.name.equals("LoadInteger") && call.args.size() == 3) {
                loadInteger(call.args, out, visited);
            } else if (RUNTIME_ID_NATIVES.contains(call.name)) {
                markUnresolved(out, "reaches " + call.name + "(), an id only known at runtime");
            }
            return;   // any other call: value not visible to this analysis
        }

        String variable = variableName(expr);
        if (variable != null) {
            List<String> values = globalValues.get(variable);
            if (values != null && visited.add("var:" + variable)) {
                for (String v : values) collect(v, out, visited);
            }
        }
        // anything else (arithmetic, locals, parameters): ignored
    }

    private void loadInteger(List<String> args, Result out, Set<Object> visited) {
        String table = args.get(0).trim();
        if (!JassExpr.isIdentifier(table)) {
            markUnresolved(out, "reads a hashtable given by an expression (" + table + ")");
            return;
        }
        String escape = hashtableEscape(table);
        if (escape != null) {
            markUnresolved(out, escape);
            return;
        }
        List<Store> list = stores.get(table);
        if (list == null) return;
        Long p = JassExpr.evalConstant(args.get(1));
        Long c = JassExpr.evalConstant(args.get(2));

        List<Store> compatible = new ArrayList<>();
        List<Store> sameConstantKeys = new ArrayList<>();
        for (Store s : list) {
            Long sp = JassExpr.evalConstant(s.parentKey);
            Long sc = JassExpr.evalConstant(s.childKey);
            if (p != null && sp != null && !p.equals(sp)) continue;   // different constant keys
            if (c != null && sc != null && !c.equals(sc)) continue;
            compatible.add(s);
            boolean matchesEveryLoadConstant = (p == null || sp != null) && (c == null || sc != null);
            if (matchesEveryLoadConstant && (p != null || c != null)) sameConstantKeys.add(s);
        }

        List<Store> chosen = sameConstantKeys.isEmpty() ? compatible : sameConstantKeys;
        if (chosen.size() > MAX_FAN_OUT) {
            markUnresolved(out, "reads hashtable " + table + " with keys computed at runtime (" +
                                chosen.size() + " possible stores)");
            return;
        }
        for (Store s : chosen) {
            if (visited.add(s)) collect(s.value, out, visited);
        }
    }

    /** "name" for {@code name} or {@code name[index]}, else null. */
    private static String variableName(String expr) {
        int bracket = expr.indexOf('[');
        String name = bracket < 0 ? expr : expr.substring(0, bracket).trim();
        if (bracket >= 0 && !expr.endsWith("]")) return null;
        return JassExpr.isIdentifier(name) ? name : null;
    }

    private static void markUnresolved(Result out, String reason) {
        if (out.unresolved == null) out.unresolved = reason;
    }

    /**
     * A hashtable is only trustworthy if every use is a declaration, an assignment
     * of InitHashtable(), or the first argument of a Save/Load/HaveSaved/Remove/Flush
     * native. Anything else (passed to a function, copied to another variable) means
     * values may be stored through a name the scan does not follow.
     */
    private String hashtableEscape(String name) {
        if (escapeCache.containsKey(name)) return escapeCache.get(name);
        Pattern use = Pattern.compile("(?<![A-Za-z0-9_$])" + Pattern.quote(name) + "(?![A-Za-z0-9_])");
        Pattern nativeOpen = Pattern.compile("(?:Save|Load|HaveSaved|Remove|Flush)[A-Za-z]*\\($");
        String reason = null;
        scan:
        for (String raw : script) {
            if (!raw.contains(name)) continue;
            String line = JassExpr.stripStrings(JassExpr.code(raw));   // words inside text don't count
            Matcher m = use.matcher(line);
            while (m.find()) {
                String before = line.substring(0, m.start()).trim();
                String after = line.substring(m.end()).trim();
                boolean declaration = before.equals("hashtable");
                boolean assignment = before.equals("set") && after.startsWith("=");
                boolean nativeArg = nativeOpen.matcher(before).find();
                if (!declaration && !assignment && !nativeArg) {
                    reason = "hashtable " + name + " is also used outside the Save/Load natives";
                    break scan;
                }
            }
        }
        escapeCache.put(name, reason);
        return reason;
    }
}
