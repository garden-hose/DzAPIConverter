import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Prepares DzSetUnitID to change a unit's type for real (see lib/DzCompat_Morph.j).
 *
 * <p>Reforged changes a unit's type through a Chaos ability ({@code Acha}) whose unit type field
 * is the target. For every unit type id the script can pass to DzSetUnitID this class
 * <ol>
 *   <li>finds the ids: each call's second argument goes through {@link IdSourceAnalyzer}
 *       (literals, YDWE hashtable loads, globals);</li>
 *   <li>picks a free ability id for each one ({@code K9} + two digits or capital letters, never a
 *       stock ability, never a section of any .ini of the table folder, never a rawcode of
 *       the script);</li>
 *   <li>writes the new abilities to {@value #OUTPUT_FILE_NAME} next to ability.ini - the new
 *       sections only, to be added to the map's ability data by hand (w3x2lni); ability.ini and
 *       ability_patched.ini are never touched;</li>
 *   <li>returns the JASS that registers {@code target -> ability} at map start.</li>
 * </ol>
 *
 * <p>A target the analysis cannot see (a value that is only known while the game runs) has no
 * Chaos ability, and DzSetUnitID changes only the look of the unit for it, as before.
 */
final class UnitTypeMorphRegistry {

    private UnitTypeMorphRegistry() {}

    static final String INIT_FUNCTION = "DzCompat_InitMorphChaos";
    static final String OUTPUT_FILE_NAME = "ability_morph.ini";
    static final String PARENT_ID = "Acha";
    private static final String NATIVE = "DzSetUnitID";
    private static final String ID_PREFIX = "K9";
    private static final String ID_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    private static final int STATEMENTS_PER_CHUNK = 100;
    private static final int MAX_LOGGED = 20;

    private static final Pattern RAWCODE = Pattern.compile("[0-9A-Za-z]{4}");
    private static final Pattern SECTION = Pattern.compile("^\\s*\\[([^\\]\\r\\n]{4})\\]\\s*$");
    private static final Pattern QUOTED_RAWCODE = Pattern.compile("'([\\x20-\\x7E]{4})'");
    private static final Pattern HEX_RAWCODE = Pattern.compile("\\$([0-9A-Fa-f]{8})\\b");
    /** A leveled field of an existing ability, to see how the table writes such values. */
    private static final Pattern LEVELED_FIELD = Pattern.compile(
            "^\\s*(?:Cast|Cool|Dur|HeroDur|Cost|Area|Rng)\\s*=\\s*(\\S.*)$");

    /** True when the script calls DzSetUnitID. */
    static boolean scriptCallsNative(List<String> script) {
        return NativeCallCounter.count(script, Set.of(NATIVE)).get(NATIVE) > 0;
    }

    /**
     * @param tableDir the map table folder (ability.ini), or null
     * @param libDir   the lib folder (ReforgedStockAbilityIds.txt)
     * @return the JASS lines of {@link #INIT_FUNCTION} (with its chunk functions), or an empty
     *         list when no ability could be made - DzSetUnitID then changes the look only
     */
    static List<String> buildRegistry(List<String> script, Path tableDir, Path libDir, Logger logger) {
        Set<String> targets = new LinkedHashSet<>();
        int sites = collectTargets(script, targets, logger);
        if (sites == 0) {
            return List.of();
        }
        if (targets.isEmpty()) {
            log(logger, NATIVE + ": no unit type id could be read from its " + sites +
                    " call(s); it changes the look only");
            return List.of();
        }
        if (tableDir == null) {
            log(logger, NATIVE + ": no map table folder, so no Chaos ability can be made for " + targets.size() +
                    " target type(s); it changes the look only");
            return List.of();
        }
        Map<String, Path> files = SlkTableRegistry.listIniFiles(tableDir, logger);
        Path abilityIni = files.get("ability.ini");
        if (abilityIni == null) {
            log(logger, NATIVE + ": no ability.ini in the table folder, so no Chaos ability can be made for " +
                    targets.size() + " target type(s); it changes the look only");
            return List.of();
        }

        Map<String, String> chaos = new LinkedHashMap<>();
        List<String> iniLines;
        try {
            Set<String> used = collectUsedIds(files, script);
            Set<String> stock = AbilityRequirementPatcher.loadStockIds(libDir);
            if (stock != null) {
                for (String s : stock) used.add(s.toLowerCase(Locale.ROOT));
            }
            List<String> abilityLines = SlkTableRegistry.readIni(abilityIni, logger);
            boolean braces = leveledValuesUseBraces(abilityLines);
            String eol = usesCrLf(abilityIni) ? "\r\n" : "\n";
            iniLines = new ArrayList<>();
            iniLines.add("-- " + NATIVE + ": one Chaos ability per target unit type (auto-generated).");
            iniLines.add("-- Add these sections to the map's ability data; ability.ini is not modified.");
            iniLines.add("");
            for (String target : targets) {
                String id = nextId(used);
                if (id == null) {
                    log(logger, NATIVE + ": ran out of free ability ids; " + (targets.size() - chaos.size()) +
                            " target type(s) left without one");
                    break;
                }
                chaos.put(target, id);
                iniLines.add("[" + id + "]");
                iniLines.add("_parent = \"" + PARENT_ID + "\"");
                iniLines.add("-- Data - Unit Type");
                iniLines.add(braces ? "UnitID = {\"" + target + "\"}" : "UnitID = \"" + target + "\"");
                iniLines.add("-- Button Image");
                iniLines.add("Art = \"\"");
                iniLines.add("");
            }
            Path out = abilityIni.resolveSibling(OUTPUT_FILE_NAME);
            Files.write(out, String.join(eol, iniLines).concat(eol).getBytes(StandardCharsets.UTF_8));
            log(logger, "Wrote " + out.getFileName() + ": " + chaos.size() + " Chaos ability(ies) (parent " + PARENT_ID +
                    "), ids " + firstLast(chaos) + "; ability.ini left unchanged. They have to be added to the " +
                    "map's ability data by hand, or " + NATIVE + " changes the look only");
            log(logger, "  field written as " + (braces ? "a one-level list (UnitID = {\"xxxx\"})" : "a plain value (UnitID = \"xxxx\")")
                    + ", like the leveled fields of ability.ini; check the import on the first ability");
        } catch (IOException e) {
            log(logger, "ERROR writing " + OUTPUT_FILE_NAME + ": " + e.getMessage() + "; " + NATIVE +
                    " changes the look only");
            return List.of();
        }

        List<String> statements = new ArrayList<>();
        for (Map.Entry<String, String> e : chaos.entrySet()) {
            statements.add("    call DzCompat_MorphChaosPut('" + e.getKey() + "','" + e.getValue() + "')");
        }
        List<String> out = new ArrayList<>();
        out.add("// ---- Chaos ability per DzSetUnitID target, baked from the script (auto-generated) ----");
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
        log(logger, "Baked " + statements.size() + " " + NATIVE + " target(s) -> Chaos ability");
        return out;
    }

    /**
     * Adds every unit type id a DzSetUnitID call can pass to {@code targets}.
     * @return the number of calls found
     */
    private static int collectTargets(List<String> script, Set<String> targets, Logger logger) {
        IdSourceAnalyzer analyzer = null;
        int sites = 0;
        int unresolved = 0;
        List<String> why = new ArrayList<>();
        for (int ln = 0; ln < script.size(); ln++) {
            String line = script.get(ln);
            if (!line.contains(NATIVE)) continue;
            int end = JassExpr.codeEnd(line);
            String code = line.substring(0, end);
            String trimmed = code.trim();
            // the declaration and the library's own copy are not calls
            if (trimmed.startsWith("native ") || trimmed.startsWith("constant native ")
                    || trimmed.startsWith("function ")) continue;
            int from = 0;
            while (true) {
                int at = code.indexOf(NATIVE, from);
                if (at < 0) break;
                from = at + NATIVE.length();
                if (at > 0 && JassExpr.isIdentChar(code.charAt(at - 1))) continue;
                int open = from;
                while (open < code.length() && code.charAt(open) == ' ') open++;
                if (open >= code.length() || code.charAt(open) != '(') continue;
                int close = JassExpr.findClosingParen(code, open, code.length());
                if (close < 0) continue;
                List<String> args = JassExpr.splitTopLevel(code.substring(open + 1, close), ',');
                if (args.size() != 2) continue;
                sites++;
                if (analyzer == null) analyzer = new IdSourceAnalyzer(script);
                IdSourceAnalyzer.Result r = analyzer.resolve(args.get(1).trim(), ln);
                int before = targets.size();
                for (String id : r.ids) {
                    if (RAWCODE.matcher(id).matches()) targets.add(id);
                }
                if (r.unresolved != null || (r.ids.isEmpty() && targets.size() == before)) {
                    unresolved++;
                    if (why.size() < MAX_LOGGED) {
                        why.add("line " + (ln + 1) + ": " + (r.unresolved != null ? r.unresolved : "no unit type id reaches it"));
                    }
                }
            }
        }
        if (sites > 0) {
            log(logger, NATIVE + ": " + sites + " call(s), " + targets.size() + " target unit type id(s) found" +
                    (unresolved > 0 ? ", " + unresolved + " call(s) with a value the script does not show" : ""));
            for (String w : why) log(logger, "  " + w);
        }
        return sites;
    }

    private static String nextId(Set<String> used) {
        for (int a = 0; a < ID_CHARS.length(); a++) {
            for (int b = 0; b < ID_CHARS.length(); b++) {
                String id = ID_PREFIX + ID_CHARS.charAt(a) + ID_CHARS.charAt(b);
                if (used.add(id.toLowerCase(Locale.ROOT))) return id;
            }
        }
        return null;
    }

    /** Ids that must not be reused, lower-cased: every .ini section of the folder and every script rawcode. */
    private static Set<String> collectUsedIds(Map<String, Path> files, List<String> script) throws IOException {
        Set<String> used = new HashSet<>();
        for (Map.Entry<String, Path> f : files.entrySet()) {
            String name = f.getKey();
            // the output of an earlier run is not counted, so a rerun hands out the same ids
            if (!name.endsWith(".ini") || name.equals(OUTPUT_FILE_NAME)) continue;
            String text = new String(Files.readAllBytes(f.getValue()), StandardCharsets.ISO_8859_1);
            for (String line : text.split("\r\n|\n|\r")) {
                Matcher m = SECTION.matcher(line);
                if (m.matches()) used.add(m.group(1).toLowerCase(Locale.ROOT));
            }
        }
        for (String line : script) {
            Matcher q = QUOTED_RAWCODE.matcher(line);
            while (q.find()) used.add(q.group(1).toLowerCase(Locale.ROOT));
            Matcher h = HEX_RAWCODE.matcher(line);
            while (h.find()) {
                String hex = h.group(1);
                StringBuilder sb = new StringBuilder(4);
                for (int i = 0; i < 8; i += 2) {
                    int c = Integer.parseInt(hex.substring(i, i + 2), 16);
                    if (c < 0x20 || c > 0x7E) { sb = null; break; }
                    sb.append((char) c);
                }
                if (sb != null) used.add(sb.toString().toLowerCase(Locale.ROOT));
            }
        }
        return used;
    }

    /** True when the first leveled field found in ability.ini is written as a list ({@code Cool = {...}}). */
    private static boolean leveledValuesUseBraces(List<String> abilityLines) {
        for (String line : abilityLines) {
            Matcher m = LEVELED_FIELD.matcher(line);
            if (m.matches()) return m.group(1).trim().startsWith("{");
        }
        return false;
    }

    private static boolean usesCrLf(Path file) throws IOException {
        byte[] b = Files.readAllBytes(file);
        for (int i = 0; i + 1 < b.length; i++) {
            if (b[i] == '\r' && b[i + 1] == '\n') return true;
        }
        return false;
    }

    private static String firstLast(Map<String, String> ids) {
        if (ids.isEmpty()) return "(none)";
        List<String> v = new ArrayList<>(ids.values());
        return v.size() == 1 ? v.get(0) : v.get(0) + " .. " + v.get(v.size() - 1);
    }

    private static void log(Logger logger, String msg) {
        logger.log("[" + Timestamps.now() + "] " + msg);
    }
}
