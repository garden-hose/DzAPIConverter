import java.io.IOException;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Bakes table\ability.ini's {@code _parent = "Aamk"} abilities into a lookup the converted
 * script can query at runtime, so {@code EXGet/SetAbilityDataReal} and
 * {@code EXGet/SetAbilityDataInteger} can tell data_type 108/109/110 (Data A/B/C) apart from
 * the same field ids on an unrelated ability - see DzCompat_YDWE_EX.j's
 * DzCompat_MarkAamkAbility/DzCompat_IsAamkAbility and the data_type 108/109/110 cases in the
 * four EX* functions above.
 *
 * <p>"Aamk" is the base ability commonly used across kk/dzapi-style maps to grant a raw,
 * uncapped Agility/Intelligence/Strength bonus (its Data A/B/C fields) without a visible
 * button (Data D = Hide Button). Reforged's Blz*AbilityIntegerLevelField constants are
 * generated per base-ability field layout rather than as one generic "Data A" slot valid for
 * every ability, so a plain data_type-only dispatch (as used for DUR/HERODUR/COOL/AREA/RNG)
 * would silently misroute field 108 on an ability that is not Aamk-derived - it only means
 * "Agility Bonus" for this one family. This registry, and the abilcode check the compat layer
 * makes against it, exist so that misrouting cannot happen: an ability not recognized here
 * keeps falling through to the pre-existing bookkeeping-only stub exactly as before.
 *
 * <p>Same reasoning and shape as {@link AbilityHotkeyRegistry}: a small lookup baked once, at
 * conversion time, from the map's own object data.
 *
 * <p>LIMITATION: only abilities table\ability.ini actually lists are covered - a stock Aamk
 * instance the map never customized (no override recorded by W3x2lni) has no entry here and
 * is not recognized. In practice, an Aamk-derived ability is always a custom ability (Aamk
 * itself has Hide Button set and is not meant to be used un-cloned), so this should cover
 * every real use; if a map somehow reads/writes field 108-110 on an abilcode this misses, the
 * getter/setter simply falls back to the previous bookkeeping-only behavior rather than
 * misrouting to the wrong field.
 */
final class AbilityDataFieldRegistry {

    private AbilityDataFieldRegistry() {}

    /** Statements per generated chunk function (mirrors AbilityHotkeyRegistry/SlkTableRegistry). */
    private static final int STATEMENTS_PER_CHUNK = 200;

    /** Name of the generated entry point; ForwardConverter hooks it into main(). */
    static final String INIT_FUNCTION = "DzCompat_InitAamkAbilities";

    private static final String AAMK_PARENT = "Aamk";

    /**
     * @return true when the script has any call that could reach the data_type 108/109/110
     *         cases through EXGet/SetAbilityDataReal or EXGet/SetAbilityDataInteger. Unlike
     *         AbilityHotkeyRegistry's scriptMayNeedHotkeys, this does not look for the field
     *         id as a literal at the call site: maps commonly wrap these EX natives in their
     *         own short helper (e.g. an "ex"/"er" pass-through that takes the field id as a
     *         parameter), so the literal 108/109/110 usually appears only where that wrapper
     *         is *called*, never next to the native name itself - a text scan tied to the
     *         native name would miss it (a false negative, silently leaving the ability
     *         un-fixed). Baking the (small) registry whenever the map references any of these
     *         four natives at all is deliberately loose in the same spirit as
     *         AbilityHotkeyRegistry's own scan: a false positive only costs a handful of
     *         unused DzCompat_MarkAamkAbility calls.
     */
    static boolean scriptMayNeedRegistry(Set<String> neededNames) {
        return neededNames.contains("EXGetAbilityDataReal") ||
               neededNames.contains("EXSetAbilityDataReal") ||
               neededNames.contains("EXGetAbilityDataInteger") ||
               neededNames.contains("EXSetAbilityDataInteger");
    }

    /**
     * @param tableDir the folder resolved by {@link SlkTableRegistry#resolveTableFolder}
     *                 (ability.ini, when present, lives next to the other table .ini files -
     *                 same file AbilityHotkeyRegistry reads)
     * @return the lines to emit (chunk functions + {@link #INIT_FUNCTION}), or empty when no
     *         ability.ini was found or it had no _parent = "Aamk" entries
     */
    static List<String> buildRegistry(Path tableDir, Logger logger) {
        Path file = findAbilityIni(tableDir, logger);
        if (file == null) {
            log(logger, "ability.ini not found in " + tableDir + " - EXGet/SetAbilityDataReal/Integer data_type 108/109/110 stay stubbed for every ability");
            return List.of();
        }
        List<String> lines;
        try {
            lines = SlkTableRegistry.readIni(file, logger);
        } catch (IOException e) {
            log(logger, "ERROR reading " + file + ": " + e.getMessage());
            return List.of();
        }
        Set<String> aamkAbilities = new LinkedHashSet<>();
        parse(lines, aamkAbilities);
        if (aamkAbilities.isEmpty()) {
            log(logger, file.getFileName() + ": no abilities with _parent = \"" + AAMK_PARENT + "\" found");
            return List.of();
        }

        List<String> statements = new ArrayList<>();
        for (String abilcode : aamkAbilities) {
            statements.add("    call DzCompat_MarkAamkAbility('" + abilcode + "')");
        }

        List<String> out = new ArrayList<>();
        out.add("// ---- Aamk-derived ability lookup, baked from " + file.getFileName() + " (auto-generated) ----");
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
        log(logger, "Baked " + aamkAbilities.size() + " Aamk-derived ability rawcode(s) from " + file.getFileName() +
                    " in " + chunkCount + " init function(s), so EXGet/SetAbilityDataReal/Integer can grant real " +
                    "Agility/Intelligence/Strength Bonus (data_type 108/109/110) for them");
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

    /** Reads [code] sections, keeping ids whose _parent equals "Aamk" (case-insensitive). */
    private static void parse(List<String> lines, Set<String> aamkAbilities) {
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
            if (value != null && value.equalsIgnoreCase(AAMK_PARENT)) {
                aamkAbilities.add(current);
            }
        }
    }

    private static void log(Logger logger, String msg) {
        if (logger != null) logger.log("[" + Timestamps.now() + "] " + msg);
    }
}
