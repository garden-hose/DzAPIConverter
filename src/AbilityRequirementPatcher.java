import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Post-conversion step for Reforged: writes {@code ability_patched.ini}, a copy of the map's
 * {@code ability.ini} in which every ability that inherits a stock (Blizzard) ability and has no
 * {@code Requires} field gets an explicit empty one:
 *
 * <pre>
 * -- Requirements
 * Requires = ""
 * </pre>
 *
 * <p>Same idea as {@link ItemRequirementPatcher}, for abilities: Reforged's built-in ability data
 * can carry tech requirements that the older game versions DzAPI maps were built for did not
 * enforce. An object that does not set the field inherits the built-in requirement; setting it to
 * an empty string clears it.
 *
 * <p>Only {@code ability.ini} is read and only {@code ability_patched.ini} is written; the input
 * file is never modified. The patched data has to be re-imported into the map by hand
 * (w3x2lni), exactly like the item requirement patch.
 *
 * <p>An object is treated as stock-based when its {@code _parent} / {@code parent} value is a
 * stock ability id, or - when it has no parent key - when its own section id is a stock ability
 * id. Existing {@code Requires} values (including non-empty ones) are never touched, and the
 * separate {@code Requiresamount} field is neither required nor changed.
 */
final class AbilityRequirementPatcher {

    private AbilityRequirementPatcher() {}

    /** Output file, written next to ability.ini. */
    static final String OUTPUT_FILE_NAME = "ability_patched.ini";
    /** Stock ability rawcodes, one per line, in the lib folder. */
    static final String STOCK_IDS_FILE_NAME = "ReforgedStockAbilityIds.txt";

    private static final Pattern SECTION = Pattern.compile("^\\s*\\[([^\\]]*)\\]\\s*$");
    private static final Pattern PARENT = Pattern.compile(
            "^\\s*_?parent\\s*=\\s*\"?([^\"\\s]*)\"?\\s*$", Pattern.CASE_INSENSITIVE);
    private static final Pattern REQUIRES = Pattern.compile(
            "^\\s*requires\\s*=", Pattern.CASE_INSENSITIVE);

    private static final String COMMENT_LINE = "-- Requirements";
    private static final String REQUIRES_LINE = "Requires = \"\"";

    /** How many patched ids are listed in the log before the rest is summarised. */
    private static final int MAX_LOGGED_IDS = 30;

    /** @return the stock ability ids, or null when the file is not in the lib folder */
    static Set<String> loadStockIds(Path libDir) throws IOException {
        Path file = libDir.resolve(STOCK_IDS_FILE_NAME);
        if (!Files.isRegularFile(file)) return null;
        Set<String> ids = new HashSet<>();
        for (String raw : Files.readAllLines(file, StandardCharsets.UTF_8)) {
            String line = raw.trim();
            if (line.isEmpty() || line.startsWith("#")) continue;
            ids.add(line);
        }
        return ids;
    }

    /**
     * @param tableDir folder holding ability.ini (the same Map table path used elsewhere);
     *                 null = nothing to do
     * @param stockIds stock ability rawcodes (see {@link #loadStockIds})
     * @return number of objects that received the empty Requires field
     */
    static int patch(Path tableDir, Set<String> stockIds, Logger logger) {
        if (tableDir == null) {
            ItemRequirementPatcher.log(logger, "Ability requirements: skipped (no map table path)");
            return 0;
        }
        Path abilityIni = SlkTableRegistry.listIniFiles(tableDir, logger).get("ability.ini");
        if (abilityIni == null) {
            ItemRequirementPatcher.log(logger, "Ability requirements: ability.ini not found in " + tableDir);
            return 0;
        }

        ItemRequirementPatcher.Source src;
        try {
            src = ItemRequirementPatcher.read(abilityIni, logger);
        } catch (IOException e) {
            ItemRequirementPatcher.log(logger, "Ability requirements: ERROR reading " + abilityIni + ": " + e.getMessage());
            return 0;
        }

        // Pass 1: for every section decide whether a Requires block must be added, and after
        // which line (the last non-blank line of the section).
        List<String> lines = src.lines;
        List<Integer> insertAfter = new ArrayList<>();
        List<String> patchedIds = new ArrayList<>();

        String id = null;
        String parent = null;
        boolean hasRequires = false;
        int lastContent = -1;

        for (int i = 0; i <= lines.size(); i++) {
            String line = (i < lines.size()) ? lines.get(i) : null;
            Matcher sm = (line != null) ? SECTION.matcher(line) : null;
            boolean boundary = (line == null) || sm.matches();
            if (boundary) {
                if (id != null && lastContent >= 0 && !hasRequires && isStockBased(id, parent, stockIds)) {
                    insertAfter.add(lastContent);
                    patchedIds.add(id);
                }
                if (line == null) break;
                id = sm.group(1).trim();
                parent = null;
                hasRequires = false;
                lastContent = i;
                continue;
            }
            if (id == null) continue; // text before the first section
            if (line.trim().isEmpty()) continue;
            lastContent = i;
            if (line.trim().startsWith("--")) continue; // w3x2lni comment line
            Matcher pm = PARENT.matcher(line);
            if (pm.matches()) {
                parent = pm.group(1);
            } else if (REQUIRES.matcher(line).find()) {
                hasRequires = true;
            }
        }

        if (patchedIds.isEmpty()) {
            ItemRequirementPatcher.log(logger, "Ability requirements: every stock-based ability in " +
                    abilityIni.getFileName() + " already sets Requires (or there are none); " +
                    OUTPUT_FILE_NAME + " not written");
            return 0;
        }

        // Pass 2: build the patched file.
        List<String> out = new ArrayList<>(lines.size() + insertAfter.size() * 2);
        int next = 0;
        for (int i = 0; i < lines.size(); i++) {
            out.add(lines.get(i));
            if (next < insertAfter.size() && insertAfter.get(next) == i) {
                out.add(COMMENT_LINE);
                out.add(REQUIRES_LINE);
                next++;
            }
        }

        Path outFile = abilityIni.resolveSibling(OUTPUT_FILE_NAME);
        try {
            ItemRequirementPatcher.writeAll(outFile, out, src);
        } catch (IOException e) {
            ItemRequirementPatcher.log(logger, "Ability requirements: ERROR writing " + outFile + ": " + e.getMessage());
            return 0;
        }

        ItemRequirementPatcher.log(logger, "Ability requirements: added an empty Requires field to " +
                patchedIds.size() + " stock-based ability(ies) in " + abilityIni.getFileName());
        int shown = Math.min(patchedIds.size(), MAX_LOGGED_IDS);
        ItemRequirementPatcher.log(logger, "  " + String.join(", ", patchedIds.subList(0, shown)) +
                (patchedIds.size() > shown ? " ... (+" + (patchedIds.size() - shown) + " more)" : ""));
        ItemRequirementPatcher.log(logger, "Wrote " + outFile + " (ability.ini left unchanged). " +
                "The patched ability data needs to be manually re-imported into the map.");
        return patchedIds.size();
    }

    private static boolean isStockBased(String id, String parent, Set<String> stockIds) {
        if (parent != null && !parent.isEmpty()) return stockIds.contains(parent);
        return stockIds.contains(id);
    }
}
