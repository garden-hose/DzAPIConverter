import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * Restores the cast range of custom abilities whose table\ability.ini has no {@code Rng} line.
 *
 * <p>w3x2lni leaves out every field that still has the base ability's default, so an ability
 * such as a Channel ('ANcl') clone without a {@code Rng} line is saved with no range at all and
 * takes whatever default the running game has. The KKAPI game version gave Channel a very long
 * range; Reforged's default is short, so after conversion the hero has to walk next to the
 * target before the spell can start.
 *
 * <p>For each such ability this class bakes one {@code DzCompat_CastRangePut(abilcode, range)}
 * line. The JASS side (DzCompat_YDWE_EX.j, {@code DzCompat_CastRangeStart}) applies the range
 * to every instance of the ability on units already on the map, units entering the map and
 * heroes learning the ability. An ability that does have a {@code Rng} line is never touched.
 *
 * <p>The original range is not stored anywhere in the map data, and it differs from spell to
 * spell, so no single value is right for all of them. Ranges are therefore chosen per ability:
 * an optional {@value #OVERRIDE_FILE} in the table folder lists {@code ABILITYID = range}
 * lines (blank lines and lines starting with "--", "//" or "#" are ignored). A listed ability
 * gets exactly that range, whatever its parent.
 *
 * <p>An unlisted Channel ('ANcl') clone without a Rng line gets a tier chosen from its first
 * level's Target Type (DataB) and Area:
 * <ul>
 *   <li>DataB 0 (no target): nothing is applied, range is irrelevant;</li>
 *   <li>DataB 1 (unit target): {@link #RANGE_STANDARD};</li>
 *   <li>DataB 2 or 3 (point, or unit or point): {@link #RANGE_LONG} when Area is at least
 *       {@link #LONG_AREA_THRESHOLD}, otherwise {@link #RANGE_STANDARD};</li>
 *   <li>DataB absent or unreadable: {@link #RANGE_LONG}.</li>
 * </ul>
 * The tiers are common spell ranges, not the original game's data, so the log lists every
 * ability that got a guessed value. Setting a Rng in the object editor makes all of this
 * unnecessary for that ability.
 */
final class CastRangeRegistry {

    private CastRangeRegistry() {}

    static final String INIT_FUNCTION = "DzCompat_InitCastRanges";

    private static final int STATEMENTS_PER_CHUNK = 200;

    static final String OVERRIDE_FILE = "castrange.ini";

    /** Standard point-and-click spell range (Storm Bolt, Death Coil, Slow, ...). */
    static final float RANGE_STANDARD = 600.0f;
    /** Long-reach area spell range (Blizzard, ...). */
    static final float RANGE_LONG = 800.0f;
    /** A point-targeted spell with at least this Area gets {@link #RANGE_LONG}. */
    static final float LONG_AREA_THRESHOLD = 400.0f;

    static List<String> buildRegistry(Path tableDir, Logger logger) {
        Path file = AbilityDataFieldRegistry.findAbilityIni(tableDir, logger);
        if (file == null) {
            log(logger, "ability.ini not found in " + tableDir + " - cast range fix skipped");
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
        Set<String> hasRange = new LinkedHashSet<>();
        Map<String, Map<String, String>> firstValues = new LinkedHashMap<>();
        parse(lines, abilParent, hasRange, firstValues);

        Map<String, Float> overrides = readOverrides(tableDir, logger);

        List<String> statements = new ArrayList<>();
        List<String> guessed = new ArrayList<>();
        for (Map.Entry<String, String> e : abilParent.entrySet()) {
            String id = e.getKey();
            if (hasRange.contains(id)) {
                if (overrides.containsKey(id)) {
                    log(logger, id + " is listed in " + OVERRIDE_FILE + " but already has a Rng in " +
                            "ability.ini - the ini value is kept");
                }
                continue;
            }
            Float range = overrides.get(id);
            if (range == null && "ANCL".equals(e.getValue().toUpperCase(Locale.ROOT))) {
                Map<String, String> first = firstValues.getOrDefault(id, Map.of());
                int targetType = parseInt(first.get("DATAB"), -1);
                float area = parseFloat(first.get("AREA"), 0f);
                if (targetType == 0) {
                    guessed.add(id + " (no target: skipped)");
                    continue;
                }
                if (targetType == 1) {
                    range = RANGE_STANDARD;
                } else if (targetType == 2 || targetType == 3) {
                    range = area >= LONG_AREA_THRESHOLD ? RANGE_LONG : RANGE_STANDARD;
                } else {
                    range = RANGE_LONG;
                }
                guessed.add(id + " (DataB " + (targetType < 0 ? "?" : String.valueOf(targetType)) +
                        ", Area " + area + " -> " + range + ")");
            }
            if (range == null) continue;
            statements.add("    call DzCompat_CastRangePut('" + id + "'," + range + ")");
        }
        if (!guessed.isEmpty()) {
            log(logger, "Cast range guessed from Target Type/Area for " + guessed.size() +
                    " Channel ability(ies) not listed in " + OVERRIDE_FILE + ": " + guessed);
        }
        if (statements.isEmpty()) {
            log(logger, file.getFileName() + ": no abilities need a cast range fix");
            return List.of();
        }

        List<String> out = new ArrayList<>();
        out.add("// ---- Cast range restore for abilities without a Rng line, baked from " +
                file.getFileName() + " (auto-generated) ----");
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
        out.add("    call DzCompat_CastRangeStart()");
        out.add("endfunction");
        log(logger, "Baked cast range fix for " + statements.size() + " ability(ies) from " +
                file.getFileName());
        return out;
    }

    /** Reads {@value #OVERRIDE_FILE} from the table folder: {@code ABILITYID = range} lines. */
    private static Map<String, Float> readOverrides(Path tableDir, Logger logger) {
        Map<String, Float> out = new LinkedHashMap<>();
        Path file = tableDir.resolve(OVERRIDE_FILE);
        if (!Files.isRegularFile(file)) return out;
        List<String> lines;
        try {
            lines = SlkTableRegistry.readIni(file, logger);
        } catch (IOException e) {
            log(logger, "ERROR reading " + file + ": " + e.getMessage());
            return out;
        }
        for (String raw : lines) {
            String t = raw.trim();
            if (t.isEmpty() || t.startsWith("--") || t.startsWith("//") || t.startsWith("#")) continue;
            int eq = t.indexOf('=');
            if (eq <= 0) continue;
            String id = t.substring(0, eq).trim();
            String val = t.substring(eq + 1).trim();
            if (!SlkTableRegistry.ID_PATTERN.matcher(id).matches()) {
                log(logger, OVERRIDE_FILE + ": ignored line (not an ability id): " + t);
                continue;
            }
            try {
                float range = Float.parseFloat(val);
                if (range < 0) throw new NumberFormatException();
                out.put(id, range);
            } catch (NumberFormatException e) {
                log(logger, OVERRIDE_FILE + ": ignored line (bad range): " + t);
            }
        }
        log(logger, "Read " + out.size() + " cast range override(s) from " + OVERRIDE_FILE);
        return out;
    }

    /** Collects each section's _parent and the sections that have a Rng line. */
    private static void parse(List<String> lines, Map<String, String> abilParent, Set<String> hasRange,
                              Map<String, Map<String, String>> firstValues) {
        String current = null;
        int arrayDepth = 0;
        String pendingKey = null; // multi-line array whose first element is still to come
        for (String raw : lines) {
            String t = raw.trim();
            if (arrayDepth > 0) {
                if (pendingKey != null && !t.isEmpty() && !t.startsWith("--")
                        && !t.equals("}") && !t.equals("},") && !t.endsWith("{")) {
                    storeFirst(firstValues, current, pendingKey, firstElement(t));
                    pendingKey = null;
                }
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
            if (current != null && key.equalsIgnoreCase("Rng")) hasRange.add(current);
            boolean wanted = key.equalsIgnoreCase("DataB") || key.equalsIgnoreCase("Area");
            if (val.startsWith("{")) {
                if (val.endsWith("}")) {
                    if (wanted) storeFirst(firstValues, current, key, firstElement(val.substring(1, val.length() - 1)));
                } else {
                    arrayDepth = 1;
                    pendingKey = wanted ? key : null;
                }
                continue;
            }
            if (wanted) storeFirst(firstValues, current, key, firstElement(val));
            if (current == null || !key.equalsIgnoreCase("_parent")) continue;
            String value = SlkTableRegistry.parseValue(val);
            if (value != null && !value.isEmpty()) abilParent.put(current, value);
        }
    }

    private static void storeFirst(Map<String, Map<String, String>> firstValues, String id,
                                   String key, String value) {
        if (id == null || value == null) return;
        firstValues.computeIfAbsent(id, k -> new LinkedHashMap<>()).put(key.toUpperCase(Locale.ROOT), value);
    }

    /** First comma-separated element of an array body (or the scalar itself), trimmed. */
    private static String firstElement(String s) {
        int comma = s.indexOf(',');
        String v = (comma >= 0 ? s.substring(0, comma) : s).trim();
        if (v.endsWith(",")) v = v.substring(0, v.length() - 1).trim();
        return v.isEmpty() ? null : v;
    }

    private static int parseInt(String v, int fallback) {
        if (v == null) return fallback;
        try {
            return (int) Float.parseFloat(v);
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    private static float parseFloat(String v, float fallback) {
        if (v == null) return fallback;
        try {
            return Float.parseFloat(v);
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    private static void log(Logger logger, String msg) {
        if (logger != null) logger.log("[" + Timestamps.now() + "] " + msg);
    }
}
