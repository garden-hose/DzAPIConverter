import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Removes or renames map declarations that Reforged's common.j already provides:
 *
 * <ul>
 *   <li>{@code native X} declarations of natives that exist in Reforged (declaring them
 *       again is a compile error, and the real native is what the map needs anyway) are
 *       dropped;</li>
 *   <li>globals the map declares under a name common.j already uses (for example the
 *       {@code MOVE_TYPE_FOOT} / {@code DEFENSE_TYPE_LIGHT} family from the LBKKAPI
 *       library) are dropped when nothing uses them and renamed everywhere when
 *       something does, so the map keeps the value it always meant.</li>
 * </ul>
 *
 * Only real identifiers are looked at: string literals and // comments are ignored.
 */
final class NameCollisionFixer {

    private NameCollisionFixer() {}

    /** Prefix given to a renamed global. */
    static final String RENAME_PREFIX = "DzCompat_map_";

    private static final Pattern NATIVE_DECL =
            Pattern.compile("^\\s*(?:constant\\s+)?native\\s+(\\w+)\\s+takes\\b");
    private static final Pattern GLOBAL_DECL =
            Pattern.compile("^\\s*(?:constant\\s+)?[A-Za-z]\\w*\\s+(?:array\\s+)?([A-Za-z_]\\w*)\\s*(?:=.*)?$");
    private static final Pattern TOKEN = Pattern.compile("[A-Za-z0-9_]+");

    static final class Result {
        final List<String> lines;
        final List<String> removedNatives;
        final List<String> removedGlobals;
        final Map<String, String> renamedGlobals;

        Result(List<String> lines, List<String> removedNatives, List<String> removedGlobals,
               Map<String, String> renamedGlobals) {
            this.lines = lines;
            this.removedNatives = removedNatives;
            this.removedGlobals = removedGlobals;
            this.renamedGlobals = renamedGlobals;
        }

        boolean changedAnything() {
            return !removedNatives.isEmpty() || !removedGlobals.isEmpty() || !renamedGlobals.isEmpty();
        }
    }

    /**
     * @param lines the script; not modified
     * @return the fixed script (the same list instance when nothing needed fixing)
     */
    static Result fix(List<String> lines, ReforgedCommonNames names) {
        Map<Integer, String> nativeDecls = new LinkedHashMap<>();
        Map<Integer, String> globalDeclByLine = new LinkedHashMap<>();
        Set<String> collidingGlobals = new LinkedHashSet<>();

        // 1) find the declarations that collide
        boolean inGlobals = false;
        for (int i = 0; i < lines.size(); i++) {
            String line = lines.get(i);
            String trimmed = JassText.codeOnly(line).trim();
            if (trimmed.isEmpty()) continue;
            if (trimmed.equals("globals")) { inGlobals = true; continue; }
            if (trimmed.equals("endglobals")) { inGlobals = false; continue; }
            if (inGlobals) {
                Matcher m = GLOBAL_DECL.matcher(trimmed);
                if (m.matches() && names.globals.contains(m.group(1))) {
                    globalDeclByLine.put(i, m.group(1));
                    collidingGlobals.add(m.group(1));
                }
            } else if (trimmed.startsWith("native") || trimmed.startsWith("constant")) {
                Matcher m = NATIVE_DECL.matcher(trimmed);
                if (m.find() && names.natives.contains(m.group(1))) {
                    nativeDecls.put(i, m.group(1));
                }
            }
        }
        if (nativeDecls.isEmpty() && globalDeclByLine.isEmpty()) {
            return new Result(lines, Collections.<String>emptyList(), Collections.<String>emptyList(),
                              Collections.<String, String>emptyMap());
        }

        // 2) which colliding globals does the rest of the script actually use?
        Set<String> used = new HashSet<>();
        Set<Integer> linesWithUse = new HashSet<>();
        if (!collidingGlobals.isEmpty()) {
            for (int i = 0; i < lines.size(); i++) {
                if (globalDeclByLine.containsKey(i)) continue;
                String line = lines.get(i);
                if (line.isEmpty()) continue;
                Matcher m = JassText.IDENTIFIER.matcher(JassText.codeOnly(line));
                while (m.find()) {
                    String id = m.group();
                    if (collidingGlobals.contains(id)) {
                        used.add(id);
                        linesWithUse.add(i);
                    }
                }
            }
        }
        Map<String, String> renames = new LinkedHashMap<>();
        for (String g : collidingGlobals) {
            if (used.contains(g)) renames.put(g, RENAME_PREFIX + g);
        }

        // 3) rebuild
        List<String> out = new ArrayList<>(lines.size());
        Set<String> removedNatives = new LinkedHashSet<>();
        Set<String> removedGlobals = new LinkedHashSet<>();
        for (int i = 0; i < lines.size(); i++) {
            String line = lines.get(i);
            String nativeName = nativeDecls.get(i);
            if (nativeName != null) {
                removedNatives.add(nativeName);
                continue;
            }
            String globalName = globalDeclByLine.get(i);
            if (globalName != null) {
                if (!used.contains(globalName)) {
                    removedGlobals.add(globalName);
                    continue;
                }
                out.add(renameIdentifiers(line, renames));
                continue;
            }
            out.add(linesWithUse.contains(i) ? renameIdentifiers(line, renames) : line);
        }
        return new Result(out, new ArrayList<>(removedNatives), new ArrayList<>(removedGlobals), renames);
    }

    /** Replaces whole identifiers outside string literals and // comments. */
    static String renameIdentifiers(String line, Map<String, String> renames) {
        StringBuilder sb = new StringBuilder(line.length() + 16);
        boolean inString = false;
        int n = line.length();
        int i = 0;
        while (i < n) {
            char c = line.charAt(i);
            if (inString) {
                sb.append(c);
                if (c == '\\' && i + 1 < n) {
                    sb.append(line.charAt(i + 1));
                    i += 2;
                    continue;
                }
                if (c == '"') inString = false;
                i++;
            } else if (c == '"') {
                inString = true;
                sb.append(c);
                i++;
            } else if (c == '/' && i + 1 < n && line.charAt(i + 1) == '/') {
                sb.append(line, i, n);
                break;
            } else if (Character.isLetterOrDigit(c) || c == '_') {
                int j = i;
                while (j < n && (Character.isLetterOrDigit(line.charAt(j)) || line.charAt(j) == '_')) j++;
                String token = line.substring(i, j);
                String replacement = renames.get(token);
                sb.append(replacement != null ? replacement : token);
                i = j;
            } else {
                sb.append(c);
                i++;
            }
        }
        return sb.toString();
    }
}
