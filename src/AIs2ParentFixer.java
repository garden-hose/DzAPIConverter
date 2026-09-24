import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Post-conversion step for Reforged 3.0: in ability.ini, rewrite the parent of any
 * ability that still inherits from the old attack-speed item ability {@code AIs2}
 * (which Blizzard reassigned to +2 Strength) to {@code AIsx} (attack-speed item ability).
 *
 * <p>Only the object-data parent field is changed. Ability rawcodes themselves are left
 * alone. The file is updated in place when at least one replacement is made.
 *
 * <p>Recognises both {@code _parent} (common in some w3x2lni / tool exports) and
 * {@code parent} (standard Lni), with optional spaces around {@code =} and optional quotes
 * around the value.
 */
final class AIs2ParentFixer {

    private AIs2ParentFixer() {}

    private static final String OLD_PARENT = "AIs2";
    private static final String NEW_PARENT = "AIsx";

    /**
     * Matches a parent assignment line whose value is AIs2.
     * Groups: (1) key with optional leading whitespace already trimmed in use,
     *         (2) spacing around '=', (3) optional quote, (4) closing quote or empty.
     * We rebuild the line to preserve the original key spelling and quote style.
     */
    private static final Pattern PARENT_LINE = Pattern.compile(
            "^(\\s*)(_?parent)(\\s*=\\s*)(\"?)" + Pattern.quote(OLD_PARENT) + "(\"?)" + "(\\s*)$",
            Pattern.CASE_INSENSITIVE);

    /**
     * @param tableDir folder that contains ability.ini (the same Map table path used for
     *                 EXExecuteScript / hotkeys); null = nothing to do
     * @return number of parent fields rewritten
     */
    static int fix(Path tableDir, Logger logger) {
        if (tableDir == null) {
            log(logger, "AIs2 parent fix: skipped (no map table path)");
            return 0;
        }
        Path abilityIni = findAbilityIni(tableDir, logger);
        if (abilityIni == null) {
            log(logger, "AIs2 parent fix: ability.ini not found in " + tableDir);
            return 0;
        }

        List<String> lines;
        try {
            lines = new ArrayList<>(SlkTableRegistry.readIni(abilityIni, logger));
        } catch (IOException e) {
            log(logger, "AIs2 parent fix: ERROR reading " + abilityIni + ": " + e.getMessage());
            return 0;
        }

        int changed = 0;
        List<String> changedIds = new ArrayList<>();
        String currentId = null;

        for (int i = 0; i < lines.size(); i++) {
            String raw = lines.get(i);
            String t = raw.trim();
            if (t.startsWith("[") && t.endsWith("]") && t.length() >= 2) {
                String id = t.substring(1, t.length() - 1);
                currentId = (id.length() == 4) ? id : null;
                continue;
            }
            Matcher m = PARENT_LINE.matcher(raw);
            if (!m.matches()) continue;

            // Rebuild preserving key spelling (_parent vs parent) and quote style
            String key = m.group(2);
            String eq = m.group(3);
            boolean quoted = !m.group(4).isEmpty() || !m.group(5).isEmpty();
            String leading = m.group(1);
            String trailing = m.group(6);
            String newVal = quoted ? ("\"" + NEW_PARENT + "\"") : NEW_PARENT;
            String replacement = leading + key + eq + newVal + trailing;
            lines.set(i, replacement);
            changed++;
            if (currentId != null) {
                changedIds.add(currentId);
            } else {
                changedIds.add("(unknown section)");
            }
        }

        if (changed == 0) {
            log(logger, "AIs2 parent fix: no _parent/parent = \"" + OLD_PARENT +
                        "\" entries found in " + abilityIni.getFileName());
            return 0;
        }

        try {
            // w3x2lni ability.ini is UTF-8; write with LF to match readIni normalisation
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < lines.size(); i++) {
                if (i > 0) sb.append('\n');
                sb.append(lines.get(i));
            }
            // Keep a trailing newline if the original file had content
            if (!lines.isEmpty()) sb.append('\n');
            Files.write(abilityIni, sb.toString().getBytes(StandardCharsets.UTF_8));
        } catch (IOException e) {
            log(logger, "AIs2 parent fix: ERROR writing " + abilityIni + ": " + e.getMessage());
            return 0;
        }

        log(logger, "AIs2 parent fix: rewrote " + changed + " parent field(s) " +
                    OLD_PARENT + " -> " + NEW_PARENT + " in " + abilityIni.getFileName());
		log(logger, "New fixed ability data needs to be manually re-imported into the map.");
        //for (String id : changedIds) {
        //    log(logger, "  - [" + id + "] parent set to " + NEW_PARENT);
        //}
        return changed;
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

    private static void log(Logger logger, String msg) {
        if (logger != null) logger.log("[" + Timestamps.now() + "] " + msg);
    }
}
