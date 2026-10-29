import java.io.IOException;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
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

    /** True if the script mentions DzSetUnitModel or its SetUnitModel alias (native, function, or call). */
    static boolean scriptUsesDzSetUnitModel(List<String> lines) {
        for (String line : lines) {
            // "SetUnitModel" is also a substring of "DzSetUnitModel", so one check covers both
            if (line.contains("SetUnitModel")) {
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
        // DzSetUnitModel( unitExpr , "path" ) or its SetUnitModel alias - unitExpr may
        // contain commas (nested calls) but never a string literal.
        Pattern p = Pattern.compile(
                "\\b(?:Dz)?SetUnitModel\\s*\\([^\"]*?,\\s*\"([^\"]+)\"",
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


    /** The character Model_Encrypt (sumneko/Model_Encrypt) appends to a model name: "%s体". */
    private static final String ENCRYPT_SUFFIX = "\u4F53";
    /** The same character as UTF-8 bytes (E4 BD 93), one char per byte - the tool edits the map byte for byte. */
    private static final String ENCRYPT_SUFFIX_BYTES = "\u00E4\u00BD\u0093";

    /** Strip one trailing .mdl / .mdx (case-insensitive); a path with no model extension is left alone. */
    private static String stripModelExtension(String path) {
        int n = path.length();
        if (n >= 4 && path.charAt(n - 4) == '.') {
            char a = Character.toLowerCase(path.charAt(n - 3));
            char b = Character.toLowerCase(path.charAt(n - 2));
            char c = Character.toLowerCase(path.charAt(n - 1));
            if (a == 'm' && b == 'd' && (c == 'l' || c == 'x')) {
                return path.substring(0, n - 4);
            }
        }
        return path;
    }

    /**
     * Shared normalisation: trim, / becomes \, runs of backslashes collapse (unit files are
     * sometimes written with doubled ones), case-insensitive, and the .mdl/.mdx extension
     * is dropped so both spellings - and a path written with no extension at all, which the
     * game completes itself - give the same key.
     *
     * @param asciiOnly lower-case A-Z only. Used for byte strings (one char per byte):
     *                  a locale lower-case would also rewrite bytes 0xC0-0xDE and could
     *                  make two different byte sequences collide.
     */
    private static String normalizeModelPath(String path, boolean asciiOnly) {
        String k = path.trim().replace('/', '\\').replaceAll("\\\\+", "\\\\");
        if (asciiOnly) {
            StringBuilder sb = new StringBuilder(k.length());
            for (int i = 0; i < k.length(); i++) {
                char c = k.charAt(i);
                sb.append(c >= 'A' && c <= 'Z' ? (char) (c + 32) : c);
            }
            k = sb.toString();
        } else {
            k = k.toLowerCase(Locale.ROOT);
        }
        return stripModelExtension(k);
    }

    /**
     * Key used to match a script path against a unit.ini / UnitStrings path:
     * case-insensitive, / and \ treated alike, runs of backslashes collapsed
     * and .mdl/.mdx treated as the same file (the game loads either for a reference
     * to the other). Works on decoded text; see {@link #modelPathByteKey}
     * for the encoding-independent twin.
     */
    static String modelPathKey(String path) {
        return normalizeModelPath(path, false);
    }

    /**
     * Encoding-independent key: the path as the bytes it has in the script file
     * (re-encoded with the charset the script was decoded with), one char per byte,
     * normalised like {@link #modelPathKey}. Mixed-encoding names (part GBK, part
     * UTF-8, as some map protectors write them) decode differently depending on which
     * charset the sniffer picks for which file; compared as raw bytes they still match.
     */
    static String modelPathByteKey(String path, Charset scriptCharset) {
        Charset cs = scriptCharset != null ? scriptCharset : StandardCharsets.UTF_8;
        return normalizeModelPath(new String(path.getBytes(cs), StandardCharsets.ISO_8859_1), true);
    }

    /** modelPathKey with a trailing Model_Encrypt marker removed, or null if it has none. */
    private static String withoutEncryptSuffix(String key) {
        return key.endsWith(ENCRYPT_SUFFIX) ? key.substring(0, key.length() - ENCRYPT_SUFFIX.length()) : null;
    }

    private static String withoutEncryptSuffixBytes(String byteKey) {
        return byteKey.endsWith(ENCRYPT_SUFFIX_BYTES)
                ? byteKey.substring(0, byteKey.length() - ENCRYPT_SUFFIX_BYTES.length()) : null;
    }

    /**
     * path key -> skin id, in tiers so the most exact match always wins:
     * decoded-text key, then raw-byte key, then either with the Model_Encrypt
     * suffix (体) removed from one side. The last tier lets a script that
     * names "foo体.mdl" find the catalog's plain "foo.mdl" (an unencrypted export of
     * the same map) and the other way round; it is never allowed to override a
     * real match.
     */
    static final class SkinIndex {
        private final Map<String, String> text = new HashMap<>();
        private final Map<String, String> bytes = new HashMap<>();
        private final Map<String, String> textAlias = new HashMap<>();
        private final Map<String, String> bytesAlias = new HashMap<>();

        /** @return true if the key was new */
        boolean addTextKey(String key, String skin) {
            String bare = withoutEncryptSuffix(key);
            if (bare != null) textAlias.putIfAbsent(bare, skin);
            return text.putIfAbsent(key, skin) == null;
        }

        boolean addByteKey(String key, String skin) {
            String bare = withoutEncryptSuffixBytes(key);
            if (bare != null) bytesAlias.putIfAbsent(bare, skin);
            return bytes.putIfAbsent(key, skin) == null;
        }

        String find(String path, Charset scriptCharset) {
            String tk = modelPathKey(path);
            String bk = modelPathByteKey(path, scriptCharset);
            String skin = text.get(tk);
            if (skin == null) skin = bytes.get(bk);
            if (skin != null) return skin;
            // Encrypted script path, plain catalog
            String bareT = withoutEncryptSuffix(tk);
            String bareB = withoutEncryptSuffixBytes(bk);
            if (bareT != null) skin = text.get(bareT);
            if (skin == null && bareB != null) skin = bytes.get(bareB);
            if (skin != null) return skin;
            // Plain script path, encrypted catalog
            skin = textAlias.get(tk);
            if (skin == null) skin = bytesAlias.get(bk);
            return skin;
        }
    }

    /**
     * Parse unit.ini / UnitStrings-style text: [SkinId] blocks and file= model paths.
     * Skin ids are case-sensitive. Returns path -> skinId (4-char or longer section name).
     *
     * The file is decoded like every other table file (strict UTF-8, otherwise the
     * encoding sniffer), so a unit.ini that is not valid UTF-8 - GBK names, or names
     * that mix GBK and UTF-8 - is read instead of failing. The raw-byte view of the
     * same file is {@link #parseUnitModelFileRaw}.
     */
    static Map<String, String> parseUnitModelFile(Path file, Logger logger) throws IOException {
        Map<String, String> pathToSkin = parseUnitModelLines(SlkTableRegistry.readIni(file, logger));
        logger.log("[" + Timestamps.now() + "] Parsed " + pathToSkin.size() +
                   " model path(s) from " + file.getFileName());
        return pathToSkin;
    }

    /**
     * Same parse over the file's bytes, one char per byte (ISO-8859-1), so the paths
     * come back exactly as stored whatever their encoding - see {@link #modelPathByteKey}.
     */
    static Map<String, String> parseUnitModelFileRaw(Path file) throws IOException {
        String text = new String(Files.readAllBytes(file), StandardCharsets.ISO_8859_1);
        if (text.startsWith("\u00EF\u00BB\u00BF")) text = text.substring(3); // UTF-8 BOM
        return parseUnitModelLines(java.util.Arrays.asList(
                text.replace("\r\n", "\n").replace('\r', '\n').split("\n", -1)));
    }

    private static Map<String, String> parseUnitModelLines(List<String> lines) {
        Map<String, String> pathToSkin = new LinkedHashMap<>();
        String currentId = null;
        // [H000] or [E001] — preserve case
        Pattern section = Pattern.compile("^\\s*\\[([^\\]]+)\\]\\s*$");
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

    /** The catalog files read both ways: decoded text and raw bytes (see modelPathByteKey). */
    private static final class Catalog {
        final Map<String, String> text = new LinkedHashMap<>();
        final Map<String, String> raw = new LinkedHashMap<>();
    }

    /**
     * Automatically collect the unit.ini / *UnitStrings.txt catalog file(s) sitting in
     * the map table folder (no prompt): the map's own unit.ini (in case it also
     * carries the [id]/file= skin-catalog shape) plus every file whose name ends in
     * "UnitStrings.txt", case-insensitive. Parsed in the order returned by the
     * directory listing; a path already resolved by an earlier file is left alone.
     *
     * @param tableDir the map table folder (same one used for the umdl lookup and the
     *                 EXExecuteScript bake), or null when there is none
     * @return the catalog merged across every file found; empty (never null) when
     *         tableDir is null or no matching file is found
     */
    private static Catalog loadCatalogFromTableFolder(Path tableDir, Logger logger) {
        Catalog catalog = new Catalog();
        if (tableDir == null) {
            return catalog;
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
                    catalog.text.putIfAbsent(e.getKey(), e.getValue());
                }
                for (Map.Entry<String, String> e : parseUnitModelFileRaw(file).entrySet()) {
                    catalog.raw.putIfAbsent(e.getKey(), e.getValue());
                }
            } catch (IOException e) {
                logger.log("[" + Timestamps.now() + "] ERROR reading unit data: " + e.getMessage());
            }
        }
        return catalog;
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
     * @param scriptCharset   the charset the script was decoded with (and is written back
     *                        with); used for the raw-byte comparison. Null means UTF-8.
     */
    static List<String> buildRegistry(List<String> jassScript, Path tableDir,
                                       Map<String, String> tableModelPaths,
                                       Charset scriptCharset, Logger logger) {
        LinkedHashSet<String> scriptPaths = extractDzSetUnitModelPaths(jassScript);
        logger.log("[" + Timestamps.now() + "] DzSetUnitModel detected; found " +
                   scriptPaths.size() + " model path literal(s) in script");

        Catalog catalog = loadCatalogFromTableFolder(tableDir, logger);

        // Only paths that are actually passed to DzSetUnitModel are registered; every
        // other model path in either source is ignored. The map's own object data
        // (tableModelPaths, already keyed by modelPathKey) is checked first - it is
        // always a valid skin id, since its rawcode is a unit type this map already
        // has. The unit.ini / UnitStrings catalog fills in whatever is left.
        SkinIndex index = new SkinIndex();
        int fromTable = 0;
        for (Map.Entry<String, String> e : tableModelPaths.entrySet()) {
            if (index.addTextKey(e.getKey(), e.getValue())) fromTable++;
        }
        int fromCatalog = 0;
        for (Map.Entry<String, String> e : catalog.text.entrySet()) {
            if (index.addTextKey(modelPathKey(e.getKey()), e.getValue())) fromCatalog++;
        }
        // Raw-byte twin of the catalog: still matches when the script and the catalog
        // were decoded with different charsets (mixed GBK/UTF-8 names).
        for (Map.Entry<String, String> e : catalog.raw.entrySet()) {
            index.addByteKey(modelPathByteKey(e.getKey(), StandardCharsets.ISO_8859_1), e.getValue());
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

        // Resolve every path first; the ones with no skin id get a new custom unit
        // (UnitModelPatcher writes them to unit_patched.ini) so they are not left at 0.
        Map<String, String> skinByPath = new LinkedHashMap<>();
        Map<String, String> unresolved = new LinkedHashMap<>(); // byte key -> first path literal
        for (String path : pathsToRegister) {
            String skin = index.find(path, scriptCharset);
            if (skin != null) {
                skinByPath.put(path, skin);
            } else if (!path.trim().isEmpty()) {
                unresolved.putIfAbsent(modelPathByteKey(path, scriptCharset), path);
            }
        }
        int patched = 0;
        if (!unresolved.isEmpty()) {
            Map<String, String> created =
                    UnitModelPatcher.patch(tableDir, jassScript, unresolved, scriptCharset, logger);
            for (String path : pathsToRegister) {
                String id = created.get(modelPathByteKey(path, scriptCharset));
                if (id != null && !skinByPath.containsKey(path)) {
                    skinByPath.put(path, id);
                    patched++;
                }
            }
        }

        List<String> out = new ArrayList<>();
        out.add("// ---- DzSetUnitModel path -> skin registry (auto-generated) ----");
        out.add("// Called from main() when present; skin ids are case-sensitive rawcodes.");
        out.add("function DzCompat_InitModelPaths takes nothing returns nothing");
        int withId = 0;
        for (String path : pathsToRegister) {
            String skin = skinByPath.get(path);
            if (skin != null) {
                withId++;
            }
            String skinLit = (skin != null) ? formatSkinIdForJass(skin) : "0";
            out.add("    call DzCompat_RegisterModelPath(\"" + JassStrings.escapeForModelPath(path) + "\", " + skinLit + ")");
        }
        out.add("endfunction");

        logger.log("[" + Timestamps.now() + "] Model path registry: " + pathsToRegister.size() +
                   " path(s), " + withId + " with skin id (" + patched + " from new units in " +
                   UnitModelPatcher.PATCHED_FILE_NAME + "), " +
                   (pathsToRegister.size() - withId) + " with empty id (0)");
        return out;
    }
}
