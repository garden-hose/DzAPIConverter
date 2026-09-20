import java.io.IOException;
import java.nio.charset.Charset;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Forward conversion: replaces Dz* native declarations in a map script with real
 * Reforged-compatible implementations (from lib/) or dummy stubs.
 */
final class ForwardConverter {

    private final ConversionSettings settings;
    private final UnitFilePrompt unitFilePrompt; // null in CLI mode
    private final SlkTablePrompt slkTablePrompt; // null in CLI mode
    private final NativeStubGenerator stubGenerator;

    /**
     * @param settings       stub options (defaults are fine for CLI use)
     * @param unitFilePrompt asks for an optional unit.ini/UnitStrings file; null = CLI mode
     */
    ForwardConverter(ConversionSettings settings, UnitFilePrompt unitFilePrompt) {
        this(settings, unitFilePrompt, null);
    }

    /**
     * @param slkTablePrompt supplies the W3x2lni table folder used to bake EXExecuteScript
     *                       (jass.slk) data; null (or a prompt that returns no folder, or a
     *                       folder without table .ini files) = EXExecuteScript is not converted
     */
    ForwardConverter(ConversionSettings settings, UnitFilePrompt unitFilePrompt, SlkTablePrompt slkTablePrompt) {
        this.settings = settings;
        this.unitFilePrompt = unitFilePrompt;
        this.slkTablePrompt = slkTablePrompt;
        this.stubGenerator = new NativeStubGenerator(settings);
    }

    void run(String inputPath, String outputPath, Logger logger) throws IOException {
        Path libDir = ResourceLocator.resolveLibDir();
        logger.log("[" + Timestamps.now() + "] Loading input file...");

        Path inPath = Paths.get(inputPath);
        if (!Files.isRegularFile(inPath)) {
            throw new IOException("Input file does not exist: " + inputPath);
        }

        InputValidator.rejectMapArchive(inputPath);

        DecodedText decoded = TextFileReader.readLenient(inPath, logger);
        List<String> jassScript = decoded.lines;
        Charset inputCharset = decoded.charset;

        if (jassScript.isEmpty()) {
            throw new IOException("Input file is empty: " + inputPath);
        }

        // Sanity check: a real JASS script almost always has "globals" or "native " or "function "
        boolean looksLikeJass = false;
        for (String line : jassScript) {
            String t = line.trim();
            if (t.startsWith("globals") || t.startsWith("native ") || t.startsWith("function ")
                    || t.startsWith("endglobals") || t.startsWith("library ") || t.startsWith("scope ")) {
                looksLikeJass = true;
                break;
            }
        }
        if (!looksLikeJass) {
            logger.log("WARNING: File does not look like a JASS script (no globals/native/function found).");
            logger.log("WARNING: If this is a binary map, extract war3map.j first.");
        }

        // "Clear unused natives" runs before anything else touches the script: drop the
        // "native dz..." declarations that are declared but never used.
        if (settings.clearUnusedNatives) {
            UnusedNativeRemover.Result cleared = UnusedNativeRemover.removeUnusedDzNatives(jassScript);
            jassScript = cleared.lines;
            logger.log("[" + Timestamps.now() + "] Clear unused natives: removed " + cleared.removedNames.size() +
                       " of " + cleared.dzNativeCount + " declared dz native(s) that are never used");
            for (String n : cleared.removedNames) {
                logger.log("[" + Timestamps.now() + "] - " + n);
            }
        }

        // RequestExtra*Data rename
        for (String[] pair : ConverterConstants.RENAME_PAIRS) {
            for (int i = 0; i < jassScript.size(); i++) {
                jassScript.set(i, jassScript.get(i).replace(pair[0], pair[1]));
            }
        }

        // Collect native declarations that have real implementations
        List<Integer> nativeIndices = new ArrayList<>();
        List<String> nativeNames = new ArrayList<>();
        for (int i = 0; i < jassScript.size(); i++) {
            String line = jassScript.get(i);
            if (JassScript.isNativeLine(line)) {
                String name = JassScript.extractNativeName(line);
                nativeIndices.add(i);
                nativeNames.add(name);
            }
        }

        Set<String> neededNames = new LinkedHashSet<>();
        int realCount = 0;
        for (String name : nativeNames) {
            if (name == null) continue;
            boolean implemented = ConverterConstants.IMPLEMENTED_NATIVES.contains(name);
            // These three route to real implementations only when Override is off.
            if (!settings.unlockStubs && ConverterConstants.UNLOCK_GATED_NATIVES.contains(name)) {
                implemented = true;
            }
            if (implemented) {
                neededNames.add(name);
                realCount++;
            }
        }

        // EXExecuteScript is only converted when there is a table folder with table .ini
        // files to work from. With an empty "Map table path" (or a folder without table
        // files) the whole EXExecuteScript process is skipped: no real implementation is
        // emitted, nothing is baked, and the native falls through to a dummy stub below.
        // Decided before the dependency closure so none of its helpers get pulled in.
        Path slkTableDir = null;
        if (neededNames.contains("EXExecuteScript")) {
            slkTableDir = SlkTableRegistry.resolveTableFolder(inPath, slkTablePrompt, logger);
            if (slkTableDir == null) {
                neededNames.remove("EXExecuteScript");
                realCount--;
                logger.log("[" + Timestamps.now() + "] EXExecuteScript: skipped - no map table files to work from " +
                           "(the native is stubbed instead)");
            }
        }
        logger.log("[" + Timestamps.now() + "] Found " + realCount +
                   " native declarations with real Reforged-compatible implementations");

        // EXExecuteScript: bake the jass.slk object data the script reads. Done before
        // the dependency closure because the generated code calls DzCompat_SlkDeclare /
        // DzCompat_SlkPut, which nothing in the library refers to, so they have to be
        // requested explicitly.
        List<String> slkLines = Collections.emptyList();
        if (slkTableDir != null) {
            slkLines = SlkTableRegistry.buildRegistry(jassScript, slkTableDir, inputCharset, logger);
            if (!slkLines.isEmpty()) {
                neededNames.add("DzCompat_SlkDeclare");
                neededNames.add("DzCompat_SlkPut");
            }
        }

        // Parse all lib files. Keep both a name->segment map and a flat list in
        // library-file order so we can emit only the needed functions while
        // preserving the dependency-safe order the .j files were written in.
        Map<String, Segment> segmentByName = new LinkedHashMap<>();
        List<Segment> segmentsInLibOrder = new ArrayList<>();
        Map<String, String> allGlobals = new LinkedHashMap<>(); // name -> full declaration line

        for (String libFile : ConverterConstants.LIB_FILES) {
            Path p = libDir.resolve(libFile);
            if (!Files.exists(p)) {
                logger.log("WARNING: Library file not found, skipping: " + p);
                continue;
            }
            ParsedLib pl = LibraryParser.parseLibFile(p);
            for (Segment seg : pl.segments) {
                if (seg.name != null) {
                    segmentByName.put(seg.name, seg);
                    segmentsInLibOrder.add(seg);
                }
            }
            allGlobals.putAll(pl.globals);
        }

        Set<String> allFunctionNames = segmentByName.keySet();
        Set<String> allGlobalNames = allGlobals.keySet();

        // Fixed-point closure over needed functions + globals
        Set<String> neededGlobals = new LinkedHashSet<>();
        boolean changed;
        do {
            changed = false;
            List<Segment> kept = new ArrayList<>();
            for (String n : neededNames) {
                Segment s = segmentByName.get(n);
                if (s != null) kept.add(s);
            }
            for (Segment seg : kept) {
                for (String call : DependencyAnalyzer.extractCalls(seg.lines, allFunctionNames)) {
                    if (neededNames.add(call)) changed = true;
                }
                for (String g : DependencyAnalyzer.extractGlobalRefs(seg.lines, allGlobalNames)) {
                    if (neededGlobals.add(g)) changed = true;
                }
            }
        } while (changed);

        int keptNativeCount = 0;
        for (String n : neededNames) {
            if (ConverterConstants.IMPLEMENTED_NATIVES.contains(n)) keptNativeCount++;
        }
        int keptHelperCount = neededNames.size() - keptNativeCount;
        logger.log("[" + Timestamps.now() + "] Kept " + keptNativeCount + " real implementations out of " +
                   ConverterConstants.IMPLEMENTED_NATIVES.size() + " available, plus " + keptHelperCount +
                   " internal helper function(s) and " + neededGlobals.size() + " global(s) they depend on");

        // Emit every needed real implementation (declared natives + pure helpers)
        // once, in library-file order, right after endglobals. That order is
        // dependency-safe because the .j files were authored with callees
        // before callers. Only names present in neededNames are included.
        List<String> orderedImplLines = new ArrayList<>();
        for (Segment seg : segmentsInLibOrder) {
            if (neededNames.contains(seg.name)) {
                orderedImplLines.addAll(seg.lines);
            }
        }

        // DzSetUnitModel path -> skin registry (optional unit.ini / UnitStrings).
        // Built up front so DzCompat_InitModelPaths can be written near the top
        // of the file (right after the compat implementations that follow
        // endglobals) instead of at the bottom.
        List<String> modelPathLines = Collections.emptyList();
        if (ModelPathRegistry.scriptUsesDzSetUnitModel(jassScript) || neededNames.contains("DzSetUnitModel")) {
            modelPathLines = ModelPathRegistry.buildRegistry(jassScript, unitFilePrompt, logger);
        }

        // Find first endglobals
        int firstEndGlobals = -1;
        for (int i = 0; i < jassScript.size(); i++) {
            if (jassScript.get(i).matches("^\\s*endglobals\\s*$")) {
                firstEndGlobals = i;
                break;
            }
        }
        if (firstEndGlobals < 0) {
            throw new IOException("No globals/endglobals block found in the input script - cannot place shared state.");
        }

        // Assemble output
        List<String> finalOutput = new ArrayList<>();
        int stubCount = 0;
        List<String> unknownNatives = new ArrayList<>();

        for (int i = 0; i < jassScript.size(); i++) {
            String line = jassScript.get(i);

            if (i == firstEndGlobals) {
                // Insert needed globals before endglobals, then all real
                // implementations (helpers + former natives) after, in lib order.
                for (String gName : neededGlobals) {
                    String decl = allGlobals.get(gName);
                    if (decl != null) finalOutput.add(decl);
                }
                finalOutput.add(line);
                finalOutput.add("");
                finalOutput.addAll(orderedImplLines);
                // DzCompat_InitModelPaths goes here, after the implementations
                // (it calls DzCompat_RegisterModelPath, and JASS requires a
                // function to be declared before it is called) but still
                // before any of the map's own code.
                if (!modelPathLines.isEmpty()) {
                    finalOutput.add("");
                    finalOutput.addAll(modelPathLines);
                }
                // Same reasoning for the baked jass.slk data (calls DzCompat_SlkPut).
                if (!slkLines.isEmpty()) {
                    finalOutput.add("");
                    finalOutput.addAll(slkLines);
                }
                continue;
            }

            if (JassScript.isNativeLine(line)) {
                String name = JassScript.extractNativeName(line);
                if (name != null && neededNames.contains(name) && segmentByName.containsKey(name)) {
                    // Real body already emitted after endglobals in lib order —
                    // skip the original native line so it is not duplicated
                    // and so definition order cannot be inverted.
                    continue;
                } else {
                    stubCount++;
                    if (name != null) {
                        unknownNatives.add(name);
                    } else {
                        unknownNatives.add(line.trim());
                    }
                    finalOutput.addAll(stubGenerator.convert(line));
                }
                continue;
            }

            finalOutput.add(line);
        }

        // Always omit lines that start with a // comment from the output
        finalOutput = JassScript.stripCommentLines(finalOutput);

        // Hook the (already emitted) registry into main() so it fills before gameplay
        if (!modelPathLines.isEmpty()) {
            if (JassScript.injectCallIntoMain(finalOutput, "DzCompat_InitModelPaths")) {
                logger.log("[" + Timestamps.now() + "] Injected " + modelPathLines.size() +
                           " lines for DzSetUnitModel path registry");
            } else {
                logger.log("[" + Timestamps.now() + "] WARNING: function main not found - call " +
                           "DzCompat_InitModelPaths() once at map init yourself");
            }
        }

        // Same for the jass.slk data. It is loaded through ExecuteFunc so the (possibly
        // large) fill runs in a fresh thread with its own op limit instead of eating
        // into main()'s.
        if (!slkLines.isEmpty()) {
            if (JassScript.injectStatementIntoMain(finalOutput,
                    "call ExecuteFunc(\"" + SlkTableRegistry.INIT_FUNCTION + "\")")) {
                logger.log("[" + Timestamps.now() + "] Injected " + slkLines.size() +
                           " lines for the EXExecuteScript jass.slk data");
            } else {
                logger.log("[" + Timestamps.now() + "] WARNING: function main not found - call " +
                           "ExecuteFunc(\"" + SlkTableRegistry.INIT_FUNCTION + "\") once at map init yourself");
            }
        }

        // DzCompat_Archive: give this specific map its own archive folder name
        // (see the __DZARCHIVE_MAP_NAME__ placeholder in DzCompat_Archive.j).
        if (neededNames.contains("GetMapName") || neededNames.contains("DzCompat_Archive_EnsureLoaded")) {
            String detectedMapName = MapNameResolver.detectMapName(jassScript, inPath);
            String safeMapName = MapNameResolver.sanitizeFolderName(detectedMapName);
            String jassEscapedMapName = JassStrings.escape(safeMapName);
            for (int i = 0; i < finalOutput.size(); i++) {
                String line = finalOutput.get(i);
                if (line.contains("__DZARCHIVE_MAP_NAME__")) {
                    finalOutput.set(i, line.replace("__DZARCHIVE_MAP_NAME__", jassEscapedMapName));
                }
            }
            logger.log("[" + Timestamps.now() + "] DzCompat_Archive: per-map folder name set to \"" + safeMapName + "\"");
        }

        // Write using the same encoding as the input so the map keeps working
        // (Chinese maps often need GBK/GB18030; rewriting as UTF-8 would break them)
        Files.write(Paths.get(outputPath), finalOutput, inputCharset);
        logger.log("[" + Timestamps.now() + "] Wrote output using encoding: " + inputCharset.name());

        logger.log("[" + Timestamps.now() + "] Conversion SUCCESS");
        logger.log("[" + Timestamps.now() + "] " + realCount + " natives given real implementations, " +
                   stubCount + " natives stubbed with dummy values");
        if (!unknownNatives.isEmpty()) {
            // De-dupe while preserving order for a cleaner log
            Set<String> seen = new LinkedHashSet<>(unknownNatives);
            logger.log("[" + Timestamps.now() + "] WARNING: " + seen.size() +
                       " native(s) had no real implementation and were stubbed:");
            for (String n : seen) {
                logger.log("[" + Timestamps.now() + "] - " + n);
            }
        }
    }
}
