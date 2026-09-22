import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Bakes the "Hotkey" and "Researchhotkey" fields of table\ability.ini into a lookup the
 * converted script can query at runtime for EXGetAbilityDataInteger data types 200
 * (ABILITY_DATA_HOTKET) and 202 (ABILITY_DATA_RESEARCH_HOTKEY).
 *
 * <p>Reforged has no getter for either field, so - the same reasoning as
 * {@link SlkTableRegistry} for {@code EXExecuteScript} - the values are read once, at
 * conversion time, from the map's own object data and written out as a lookup the runtime
 * side (see DzCompat_YDWE_EX.j's EXGetAbilityDataInteger) can query by ability rawcode.
 *
 * <p>Unlike jass.slk's item/unit tables, this needs no per-call-site id tracing: an
 * ability's hotkey does not depend on who reads it or at what level (the field is not
 * leveled in ability.ini), so the whole table is baked unconditionally once the script is
 * seen to read type 200 or 202 - it is small (one character per ability) regardless of map
 * size.
 *
 * <p>LIMITATION: {@code table\ability.ini}, as produced by W3x2lni from a map's object
 * modifications, holds only abilities the map customizes. An ability that never overrides
 * Hotkey/Researchhotkey (a stock ability used with its default hotkey) has no entry here,
 * because the stock Blizzard object data those defaults come from is not part of the map
 * and is not available to the converter. Such lookups return 0 (see below) and are counted
 * in the log so the gap is visible rather than silent.
 */
final class AbilityHotkeyRegistry {

    private AbilityHotkeyRegistry() {}

    /** Statements per generated chunk function (mirrors SlkTableRegistry). */
    private static final int STATEMENTS_PER_CHUNK = 200;

    /** Name of the generated entry point; ForwardConverter hooks it into main(). */
    static final String INIT_FUNCTION = "DzCompat_InitHotkey";

    private static final Pattern DATA_TYPE_200_OR_202 = Pattern.compile("\\b(200|202)\\s*\\)");

    /**
     * @return true when the script has any call that could be reading data type 200 or 202
     *         through EXGetAbilityDataInteger (directly, or via a map wrapper such as
     *         YDWEGetUnitAbilityDataInteger that just forwards its last argument - the scan
     *         is over the whole script's text for "200)"/"202)" after an
     *         EXGetAbilityDataInteger-shaped call opens, which is deliberately loose: a
     *         false positive only costs an unused bake, a false negative would silently
     *         drop hotkeys the map actually reads)
     */
    static boolean scriptMayNeedHotkeys(List<String> jassScript) {
        for (String line : jassScript) {
            if (line.isEmpty()) continue;
            String code = JassText.codeOnly(line);
            if (code.indexOf("AbilityDataInteger") < 0) continue;
            if (DATA_TYPE_200_OR_202.matcher(code).find()) return true;
        }
        return false;
    }

    /**
     * @param tableDir the folder resolved by {@link SlkTableRegistry#resolveTableFolder}
     *                 (ability.ini, when present, lives next to the other table .ini files)
     * @return the lines to emit (chunk functions + {@link #INIT_FUNCTION}), or empty when
     *         no ability.ini was found or it had no Hotkey/Researchhotkey values
     */
    static List<String> buildRegistry(Path tableDir, Logger logger) {
        Path file = findAbilityIni(tableDir, logger);
        if (file == null) {
            log(logger, "ability.ini not found in " + tableDir + " - EXGetAbilityDataInteger types 200/202 stay stubbed");
            return List.of();
        }
        List<String> lines;
        try {
            lines = SlkTableRegistry.readIni(file, logger);
        } catch (IOException e) {
            log(logger, "ERROR reading " + file + ": " + e.getMessage());
            return List.of();
        }
        Map<String, Character> hotkey = new LinkedHashMap<>();
        Map<String, Character> researchHotkey = new LinkedHashMap<>();
        parse(lines, hotkey, researchHotkey);
        if (hotkey.isEmpty() && researchHotkey.isEmpty()) {
            log(logger, file.getFileName() + ": no Hotkey/Researchhotkey values found");
            return List.of();
        }

        List<String> statements = new ArrayList<>();
        for (Map.Entry<String, Character> e : hotkey.entrySet()) {
            statements.add("    call DzCompat_HotkeyPut('" + e.getKey() + "',0," + (int) e.getValue().charValue() + ")");
        }
        for (Map.Entry<String, Character> e : researchHotkey.entrySet()) {
            statements.add("    call DzCompat_HotkeyPut('" + e.getKey() + "',1," + (int) e.getValue().charValue() + ")");
        }

        List<String> out = new ArrayList<>();
        out.add("// ---- ability Hotkey / Researchhotkey lookup, baked from " + file.getFileName() + " (auto-generated) ----");
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
        log(logger, "Baked " + hotkey.size() + " Hotkey and " + researchHotkey.size() +
                    " Researchhotkey value(s) from " + file.getFileName() + " in " + chunkCount + " init function(s). " +
                    "An ability the map calls type 200/202 for but that never overrides the field in " + file.getFileName() +
                    " (a stock hotkey) is not covered - see the class comment in AbilityHotkeyRegistry.java");
        return out;
    }

    private static Path findAbilityIni(Path tableDir, Logger logger) {
        Map<String, Path> files = SlkTableRegistry.listIniFiles(tableDir, logger);
        Path exact = files.get("ability.ini");
        if (exact != null) return exact;
        for (Map.Entry<String, Path> e : files.entrySet()) {
            String name = e.getKey();
            if (name.endsWith(".ini") && name.contains("abil")) return e.getValue();
        }
        return null;
    }

    /** Reads [code] sections, keeping only Hotkey and Researchhotkey (single non-empty character). */
    private static void parse(List<String> lines, Map<String, Character> hotkey, Map<String, Character> researchHotkey) {
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
            boolean isHotkey = key.equalsIgnoreCase("Hotkey");
            boolean isResearch = key.equalsIgnoreCase("Researchhotkey");
            if (!isHotkey && !isResearch) continue;
            String value = SlkTableRegistry.parseValue(val);
            if (value == null || value.length() != 1) continue; // "" (no hotkey) or something unexpected
            char c = value.charAt(0);
            if (isHotkey) hotkey.put(current, c); else researchHotkey.put(current, c);
        }
    }

    private static void log(Logger logger, String msg) {
        if (logger != null) logger.log("[" + Timestamps.now() + "] " + msg);
    }
}
