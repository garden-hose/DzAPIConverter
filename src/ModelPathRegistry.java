import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * DzSetUnitModel path -> skin registry: detects model paths used by DzSetUnitModel
 * calls, resolves skin ids from the map's own unit.ini / any *UnitStrings.txt found
 * in the map table folder, and generates the DzCompat_InitModelPaths function.
 */
final class ModelPathRegistry {

    private ModelPathRegistry() {}

    /** True if the script mentions DzSetUnitModel (native, function, or call). */
    static boolean scriptUsesDzSetUnitModel(List<String> lines) {
        for (String line : lines) {
            if (line.contains("DzSetUnitModel")) {
                return true;
            }
        }
        return false;
    }

    /**
     * Collect unique model-path string literals from DzSetUnitModel(unit, "path") calls
     * and nothing else: comment lines, the native declaration and look-alike names
     * (e.g. MyDzSetUnitModel) are ignored.
     *
     * Returned paths are the real runtime strings (JASS escapes resolved, so a
     * source literal "X\\W\\a.mdl" comes back as X\W\a.mdl). They must be escaped
     * exactly once when written back out - see JassStrings.escapeForModelPath.
     */
    static LinkedHashSet<String> extractDzSetUnitModelPaths(List<String> lines) {
        LinkedHashSet<String> paths = new LinkedHashSet<>();
        // DzSetUnitModel( unitExpr , "path" )  - unitExpr may contain commas
        // (nested calls) but never a string literal.
        Pattern p = Pattern.compile(
                "\\bDzSetUnitModel\\s*\\([^\"]*?,\\s*\"([^\"]+)\"",
                Pattern.CASE_INSENSITIVE);
        for (String line : lines) {
            if (line.trim().startsWith("//")) {
                continue;
            }
            int commentStart = line.indexOf("//");
            Matcher m = p.matcher(line);
            while (m.find()) {
                // Ignore calls that sit inside a trailing // comment
                if (commentStart >= 0 && commentStart < m.start()) {
                    continue;
                }
                String path = JassStrings.unescape(m.group(1)).trim();
                if (!path.isEmpty()) {
                    paths.add(path);
                }
            }
        }
        return paths;
    }


    /**
     * Key used to match a script path against a unit.ini / UnitStrings path:
     * case-insensitive, / and \ treated alike, runs of backslashes collapsed
     * (unit files are sometimes written with doubled ones) and .mdl/.mdx treated
     * as the same file (the game loads either for a reference to the other).
     */
    static String modelPathKey(String path) {
        String k = path.trim().replace('/', '\\').replaceAll("\\\\+", "\\\\");
        k = k.toLowerCase(Locale.ROOT);
        if (k.endsWith(".mdl") || k.endsWith(".mdx")) {
            k = k.substring(0, k.length() - 4);
        }
        return k;
    }

    /**
     * Parse unit.ini / UnitStrings-style text: [SkinId] blocks and file= model paths.
     * Skin ids are case-sensitive. Returns path -> skinId (4-char or longer section name).
     */
    static Map<String, String> parseUnitModelFile(Path file, Logger logger) throws IOException {
        Map<String, String> pathToSkin = new LinkedHashMap<>();
        List<String> lines = Files.readAllLines(file);
        String currentId = null;
        // [H000] or [E001] — preserve case
        Pattern section = Pattern.compile("^\\s*\\[([^\\]]+)\\]\\s*$");
        // file = "..." or file=... or File = ...
        // file = "path.mdl"  |  file=path  |  file:hd=path (skin txt)
        Pattern fileKey = Pattern.compile(
                "^\\s*file(?:\\s*:\\s*hd)?\\s*=\\s*\"([^\"]+)\"\\s*$",
                Pattern.CASE_INSENSITIVE);
        Pattern fileKeyBare = Pattern.compile(
                "^\\s*file(?:\\s*:\\s*hd)?\\s*=\\s*([^\"\\s]+)\\s*$",
                Pattern.CASE_INSENSITIVE);

        for (String raw : lines) {
            String line = raw.trim();
            if (line.isEmpty() || line.startsWith("//") || line.startsWith("--")) {
                continue;
            }
            Matcher sm = section.matcher(line);
            if (sm.matches()) {
                currentId = sm.group(1); // case-sensitive
                continue;
            }
            if (currentId == null) {
                continue;
            }
            Matcher fm = fileKey.matcher(line);
            if (!fm.matches()) {
                fm = fileKeyBare.matcher(line);
            }
            if (fm.matches()) {
                String modelPath = fm.group(1).trim();
                int cmt = modelPath.indexOf("//");
                if (cmt >= 0) {
                    modelPath = modelPath.substring(0, cmt).trim();
                }
                if (!modelPath.isEmpty() && !modelPath.equalsIgnoreCase("none")
                        && !modelPath.equals(".")) {
                    pathToSkin.putIfAbsent(modelPath, currentId);
                }
            }
        }
        logger.log("[" + Timestamps.now() + "] Parsed " + pathToSkin.size() +
                   " model path(s) from " + file.getFileName());
        return pathToSkin;
    }

    /**
     * Format a skin id for JASS: 4-char codes use 'Abcd' syntax; otherwise integer 0.
     */
    static String formatSkinIdForJass(String skinId) {
        if (skinId == null || skinId.isEmpty()) {
            return "0";
        }
        if (skinId.length() == 4) {
            // Case-sensitive rawcode literal
            return "'" + skinId + "'";
        }
        // Non-4-char section names cannot be rawcode literals; try decimal if numeric
        try {
            return Integer.toString(Integer.parseInt(skinId));
        } catch (NumberFormatException e) {
            return "0";
        }
    }
    

    /** Catalog file names to auto-load from the map table folder, besides unit.ini itself. */
    private static final String UNIT_STRINGS_SUFFIX = "unitstrings.txt";

    /**
     * Automatically collect the unit.ini / *UnitStrings.txt catalog file(s) sitting in
     * the map table folder (no prompt): the map's own unit.ini (in case it also
     * carries the [id]/file= skin-catalog shape) plus every file whose name ends in
     * "UnitStrings.txt", case-insensitive. Parsed in the order returned by the
     * directory listing; a path already resolved by an earlier file is left alone.
     *
     * @param tableDir the map table folder (same one used for the umdl lookup and the
     *                 EXExecuteScript bake), or null when there is none
     * @return path -> skin id, merged across every catalog file found; empty (never
     *         null) when tableDir is null or no matching file is found
     */
    private static Map<String, String> loadCatalogFromTableFolder(Path tableDir, Logger logger) {
        Map<String, String> pathToSkin = new LinkedHashMap<>();
        if (tableDir == null) {
            return pathToSkin;
        }
        Map<String, Path> files = SlkTableRegistry.listIniFiles(tableDir, logger);
        List<Path> catalogFiles = new ArrayList<>();
        Path unitIni = files.get("unit.ini");
        if (unitIni != null) {
            catalogFiles.add(unitIni);
        }
        for (Map.Entry<String, Path> e : files.entrySet()) {
            if (e.getKey().endsWith(UNIT_STRINGS_SUFFIX)) {
                catalogFiles.add(e.getValue());
            }
        }
        for (Path file : catalogFiles) {
            try {
                for (Map.Entry<String, String> e : parseUnitModelFile(file, logger).entrySet()) {
                    pathToSkin.putIfAbsent(e.getKey(), e.getValue());
                }
            } catch (IOException e) {
                logger.log("[" + Timestamps.now() + "] ERROR reading unit data: " + e.getMessage());
            }
        }
        return pathToSkin;
    }

    /**
     * After conversion: if DzSetUnitModel is present, resolve model paths to skin ids
     * and emit DzCompat_RegisterModelPath calls wrapped in DzCompat_InitModelPaths.
     *
     * @param tableDir        the map table folder ("Map table path"), or null when
     *                        there is none; used both to read tableModelPaths' umdl
     *                        source and, here, to auto-load a unit.ini / *UnitStrings.txt
     *                        catalog with no prompt (see {@link #loadCatalogFromTableFolder}).
     * @param tableModelPaths model path -> unit rawcode, from
     *                        {@link SlkTableRegistry#buildUnitModelPathIndex} (the umdl
     *                        field of this map's own unit table). Every rawcode it
     *                        gives is a real unit type this map already has, so it is
     *                        always a valid BlzSetUnitSkin skinId; checked first. May be
     *                        empty (no table folder, no unit.ini, no umdl matches) -
     *                        never null.
     */
    static List<String> buildRegistry(List<String> jassScript, Path tableDir,
                                       Map<String, String> tableModelPaths, Logger logger) {
        LinkedHashSet<String> scriptPaths = extractDzSetUnitModelPaths(jassScript);
        logger.log("[" + Timestamps.now() + "] DzSetUnitModel detected; found " +
                   scriptPaths.size() + " model path literal(s) in script");

        Map<String, String> pathToSkin = loadCatalogFromTableFolder(tableDir, logger);

        // Only paths that are actually passed to DzSetUnitModel are registered; every
        // other model path in either source is ignored. The map's own object data
        // (tableModelPaths, already keyed by modelPathKey) is checked first - it is
        // always a valid skin id, since its rawcode is a unit type this map already
        // has. The unit.ini / UnitStrings catalog fills in whatever is left.
        Map<String, String> skinByKey = new HashMap<>();
        int fromTable = 0;
        for (Map.Entry<String, String> e : tableModelPaths.entrySet()) {
            if (skinByKey.putIfAbsent(e.getKey(), e.getValue()) == null) fromTable++;
        }
        int fromCatalog = 0;
        for (Map.Entry<String, String> e : pathToSkin.entrySet()) {
            if (skinByKey.putIfAbsent(modelPathKey(e.getKey()), e.getValue()) == null) fromCatalog++;
        }
        if (fromTable > 0 || fromCatalog > 0) {
            logger.log("[" + Timestamps.now() + "] Model path -> skin id: " + fromTable +
                       " resolved from this map's own object data (umdl)" +
                       (fromCatalog > 0 ? ", " + fromCatalog + " from the map table folder's unit.ini/UnitStrings.txt" : ""));
        }
        LinkedHashSet<String> pathsToRegister = new LinkedHashSet<>(scriptPaths);

        if (pathsToRegister.isEmpty()) {
            logger.log("[" + Timestamps.now() + "] No model paths to register for DzSetUnitModel");
            return Collections.emptyList();
        }

        List<String> out = new ArrayList<>();
        out.add("// ---- DzSetUnitModel path -> skin registry (auto-generated) ----");
        out.add("// Called from main() when present; skin ids are case-sensitive rawcodes.");
        out.add("function DzCompat_InitModelPaths takes nothing returns nothing");
        int withId = 0;
        for (String path : pathsToRegister) {
            String skin = skinByKey.get(modelPathKey(path));
            if (skin != null) {
                withId++;
            }
            String skinLit = (skin != null) ? formatSkinIdForJass(skin) : "0";
            out.add("    call DzCompat_RegisterModelPath(\"" + JassStrings.escapeForModelPath(path) + "\", " + skinLit + ")");
        }
        out.add("endfunction");

        logger.log("[" + Timestamps.now() + "] Model path registry: " + pathsToRegister.size() +
                   " path(s), " + withId + " with skin id, " +
                   (pathsToRegister.size() - withId) + " with empty id (0)");
        return out;
    }
}
