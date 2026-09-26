import java.io.IOException;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * Bakes table\ability.ini {@code _parent} values into a per-abilcode parent-id
 * mark the converted script uses for DATA_A..I (data_type 108-116).
 *
 * <p>One generated line per ability ({@code DzCompat_MarkAbilityParent}), not
 * one line per data slot. The fourCC + int/real kind for each parent live in
 * DzCompat_YDWE_EX.j ({@code DzCompat_GetAbilityDataField} /
 * {@code DzCompat_GetAbilityDataFieldKind}); this class only assigns
 * {@code abilcode -> parentId}. Parent ids must stay in sync with that JASS
 * switch (1=Aamk, 2=ANcl, ...).
 *
 * <p>Unknown parents are skipped so getters/setters keep bookkeeping-only
 * behavior rather than writing the wrong Blz field.
 */
final class AbilityDataFieldRegistry {

    private AbilityDataFieldRegistry() {}

    private static final int STATEMENTS_PER_CHUNK = 200;

    static final String INIT_FUNCTION = "DzCompat_InitAbilityDataFields";

    /**
     * Parent rawcode (uppercased) -> parentId used by DzCompat_MarkAbilityParent
     * and the JASS field/kind switches. Add new parents in both places.
     */
    private static final Map<String, Integer> PARENT_IDS = new LinkedHashMap<>();
    static {
        PARENT_IDS.put("AAMK", 1);
        PARENT_IDS.put("ANCL", 2);
        PARENT_IDS.put("AHTB", 3);
        PARENT_IDS.put("AHBZ", 4);
        PARENT_IDS.put("AEME", 5);
        PARENT_IDS.put("ACBF", 6);
        PARENT_IDS.put("AIAZ", 7);
        PARENT_IDS.put("AIDB", 8);
        PARENT_IDS.put("AILZ", 9);
        PARENT_IDS.put("AIMZ", 10);
    }

    static boolean scriptMayNeedRegistry(Set<String> neededNames) {
        return neededNames.contains("EXGetAbilityDataReal") ||
               neededNames.contains("EXSetAbilityDataReal") ||
               neededNames.contains("EXGetAbilityDataInteger") ||
               neededNames.contains("EXSetAbilityDataInteger");
    }

    static List<String> buildRegistry(Path tableDir, Logger logger) {
        Path file = findAbilityIni(tableDir, logger);
        if (file == null) {
            log(logger, "ability.ini not found in " + tableDir +
                    " - EXGet/SetAbilityDataReal/Integer data_type 108-116 stay bookkeeping-only");
            return List.of();
        }
        List<String> lines;
        try {
            lines = SlkTableRegistry.readIni(file, logger);
        } catch (IOException e) {
            log(logger, "ERROR reading " + file + ": " + e.getMessage());
            return List.of();
        }

        Map<String, String> abilParent = new LinkedHashMap<>();
        parseParents(lines, abilParent);
        if (abilParent.isEmpty()) {
            log(logger, file.getFileName() + ": no ability sections with a _parent field found");
            return List.of();
        }

        List<String> statements = new ArrayList<>();
        int mapped = 0;
        int unknownParents = 0;
        for (Map.Entry<String, String> e : abilParent.entrySet()) {
            String abilcode = e.getKey();
            Integer parentId = PARENT_IDS.get(e.getValue().toUpperCase(Locale.ROOT));
            if (parentId == null) {
                unknownParents++;
                continue;
            }
            statements.add("    call DzCompat_MarkAbilityParent('" + abilcode + "', " + parentId + ")");
            mapped++;
        }

        if (statements.isEmpty()) {
            log(logger, file.getFileName() + ": " + abilParent.size() +
                    " abilities with _parent, but none matched PARENT_IDS (" +
                    unknownParents + " unknown parent(s)) - data_type 108-116 stay bookkeeping-only");
            return List.of();
        }

        List<String> out = new ArrayList<>();
        out.add("// ---- Ability DATA_A..I parent registry, baked from " + file.getFileName() +
                " (auto-generated) ----");
        int chunkCount = (statements.size() + STATEMENTS_PER_CHUNK - 1) / STATEMENTS_PER_CHUNK;
        for (int c = 0; c < chunkCount; c++) {
            out.add("function " + INIT_FUNCTION + "_" + c + " takes nothing returns nothing");
            int to = Math.min(statements.size(), (c + 1) * STATEMENTS_PER_CHUNK);
            out.addAll(statements.subList(c * STATEMENTS_PER_CHUNK, to));
            out.add("endfunction");
        }
        out.add("function " + INIT_FUNCTION + " takes nothing returns nothing");
        for (int c = 0; c < chunkCount; c++) {
            out.add("    call ExecuteFunc(\"" + INIT_FUNCTION + "_" + c + "\")");
        }
        out.add("endfunction");
        log(logger, "Baked " + mapped + " ability parent mark(s) from " + file.getFileName() +
                " in " + chunkCount + " init function(s) (" + unknownParents +
                " ability(ies) had a _parent not in PARENT_IDS)");
        return out;
    }

    static Path findAbilityIni(Path tableDir, Logger logger) {
        Map<String, Path> files = SlkTableRegistry.listIniFiles(tableDir, logger);
        Path exact = files.get("ability.ini");
        if (exact != null) return exact;
        for (Map.Entry<String, Path> e : files.entrySet()) {
            String name = e.getKey();
            if (name.endsWith(".ini") && name.contains("abil")) return e.getValue();
        }
        return null;
    }

    // Use the real API (keep name matching the rest of the project):
    private static Map<String, Path> SlekTableRegistry_listIniFiles(Path tableDir, Logger logger) {
        return SlkTableRegistry.listIniFiles(tableDir, logger);
    }

    private static void parseParents(List<String> lines, Map<String, String> abilParent) {
        String current = null;
        int arrayDepth = 0;
        for (String raw : lines) {
            String t = raw.trim();
            if (arrayDepth > 0) {
                if (t.equals("}") || t.equals("},")) arrayDepth--;
                else if (t.endsWith("{")) arrayDepth++;
                continue;
            }
            if (t.isEmpty() || t.startsWith("--")) continue;
            if (t.charAt(0) == '[' && t.endsWith("]")) {
                String id = t.substring(1, t.length() - 1);
                current = SlkTableRegistry.ID_PATTERN.matcher(id).matches() ? id : null;
                continue;
            }
            int eq = t.indexOf('=');
            if (eq <= 0) continue;
            String key = t.substring(0, eq).trim();
            String val = t.substring(eq + 1).trim();
            if (val.startsWith("{")) {
                if (!val.endsWith("}")) arrayDepth = 1;
                continue;
            }
            if (current == null) continue;
            if (!key.equalsIgnoreCase("_parent")) continue;
            String value = SlkTableRegistry.parseValue(val);
            if (value != null && !value.isEmpty()) {
                abilParent.put(current, value);
            }
        }
    }

    private static void log(Logger logger, String msg) {
        if (logger != null) logger.log("[" + Timestamps.now() + "] " + msg);
    }
}