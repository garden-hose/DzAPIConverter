import java.io.IOException;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Reverse conversion: undoes a forward conversion.
 *
 * <p>Scripts written by this version carry DzMarkers lines. Reverse uses them to delete every
 * injected block, put every native declaration back exactly as it was (including the natives
 * that are not listed in KKAPI.txt), drop the statements injected into main(), and turn the
 * call-site rewrites (DestroyTimer, UnitAddAbility, extended unit state, the RequestExtra
 * rename, renamed globals) back into the original calls.
 *
 * <p>Scripts converted by an older version have no markers. They are reversed the old way:
 * functions whose names appear in KKAPI.txt become native declarations again and the
 * RequestExtra rename is undone; nothing else can be recognised.
 *
 * <p>Not restorable, because the forward pass throws the original away: declarations of natives
 * and globals that Reforged's common.j already provides, "Clear unused natives" removals, the
 * "return bug" typecast bodies and comment lines.
 */
final class ReverseConverter {

    private static final String GET_WRAPPER = "DzCompat_GetExtUnitState";
    private static final String SET_WRAPPER = "DzCompat_SetExtUnitState";

    /** Wrapper call sites that map straight back to the stock native they wrapped. */
    private static final Map<String, String> WRAPPER_RESTORES = new LinkedHashMap<>();
    static {
        WRAPPER_RESTORES.put(TimerDestroyConverter.WRAPPER, "DestroyTimer");
        WRAPPER_RESTORES.put(AbilityAddConverter.WRAPPER, "UnitAddAbility");
    }

    /** What a marker-based reverse did, for the log. */
    private static final class Stats {
        int blocks, natives, injectedLines, wrapperCalls, extStateCalls, restoredGlobals;
    }

    void run(String inputPath, String outputPath, Logger logger) throws IOException {
        logger.log("[" + Timestamps.now() + "] Loading input file...");
        Path inPath = Paths.get(inputPath);
        if (!Files.isRegularFile(inPath)) {
            throw new IOException("Input file does not exist: " + inputPath);
        }

        InputValidator.rejectMapArchive(inputPath);

        DecodedText decoded = TextFileReader.readLenient(inPath, logger);
        List<String> jassScript = new ArrayList<>(decoded.lines);
        Charset inputCharset = decoded.charset;

        if (jassScript.isEmpty()) {
            throw new IOException("Input file is empty: " + inputPath);
        }

        List<String> finalOutput;
        if (DzMarkers.hasMarkers(jassScript)) {
            finalOutput = reverseMarked(jassScript, logger);
        } else {
            logger.log("[" + Timestamps.now() + "] No DZCOMPAT markers found: this script was converted by an older " +
                       "version. Falling back to KKAPI.txt - only the declared KKAPI natives and the RequestExtra " +
                       "rename can be undone. Convert the original script again with this version for a complete reverse.");
            finalOutput = reverseLegacy(jassScript, logger);
        }

        Files.write(Paths.get(outputPath), finalOutput, inputCharset);
        logger.log("[" + Timestamps.now() + "] Wrote output using encoding: " + inputCharset.name());
        logger.log("[" + Timestamps.now() + "] Reverse conversion SUCCESS");
    }

    // -------------------------------------------------------------------------
    // Marker-based reverse
    // -------------------------------------------------------------------------

    private List<String> reverseMarked(List<String> lines, Logger logger) throws IOException {
        Stats st = new Stats();
        List<String> out = new ArrayList<>(lines.size());
        int i = 0;
        while (i < lines.size()) {
            String line = lines.get(i);
            String t = line.trim();
            if (t.startsWith(DzMarkers.BLOCK)) {
                i = indexAfterEnd(lines, i);
                st.blocks++;
            } else if (t.startsWith(DzMarkers.STUB)) {
                out.add(DzMarkers.payload(line, DzMarkers.STUB));
                st.natives++;
                i = indexAfterEnd(lines, i);
            } else if (t.startsWith(DzMarkers.NATIVE)) {
                out.add(DzMarkers.payload(line, DzMarkers.NATIVE));
                st.natives++;
                i++;
            } else if (DzMarkers.endsWithInjectedMark(line)) {
                st.injectedLines++;
                i++;
            } else if (DzMarkers.isMarker(line)) {
                // An END marker with no opening one, or an unknown marker: drop the comment line.
                i++;
            } else {
                out.add(line);
                i++;
            }
        }

        // Call sites the forward pass rewrote. The wrapper functions are gone with their blocks,
        // so every call has to go back to the stock native.
        for (int k = 0; k < out.size(); k++) {
            String l = out.get(k);
            if (l.indexOf("DzCompat_") < 0 && l.indexOf("RequestExtra") < 0) continue;

            if (l.indexOf(GET_WRAPPER) >= 0 || l.indexOf(SET_WRAPPER) >= 0) {
                int[] count = new int[1];
                l = revertExtState(l, count);
                st.extStateCalls += count[0];
            }
            final int[] wrapperHits = new int[1];
            final int[] globalHits = new int[1];
            l = NameCollisionFixer.renameIdentifiers(l, token -> {
                String restored = WRAPPER_RESTORES.get(token);
                if (restored != null) { wrapperHits[0]++; return restored; }
                restored = ConverterConstants.REQUEST_EXTRA_RESTORES.get(token);
                if (restored != null) return restored;
                if (token.startsWith(NameCollisionFixer.RENAME_PREFIX)
                        && token.length() > NameCollisionFixer.RENAME_PREFIX.length()) {
                    globalHits[0]++;
                    return token.substring(NameCollisionFixer.RENAME_PREFIX.length());
                }
                return null;
            });
            st.wrapperCalls += wrapperHits[0];
            st.restoredGlobals += globalHits[0];
            out.set(k, l);
        }

        String now = "[" + Timestamps.now() + "] ";
        logger.log(now + st.natives + " native declaration(s) restored exactly as they were");
        logger.log(now + st.blocks + " injected block(s) removed, " + st.injectedLines + " line(s) injected into main() removed");
        if (st.wrapperCalls > 0) {
            logger.log(now + "Restored " + st.wrapperCalls + " DestroyTimer/UnitAddAbility call site(s)");
        }
        if (st.extStateCalls > 0) {
            logger.log(now + "Restored " + st.extStateCalls + " GetUnitState/SetUnitState extended-index call site(s)");
        }
        if (st.restoredGlobals > 0) {
            logger.log(now + "Renamed " + st.restoredGlobals + " global reference(s) back to their original names");
        }
        logger.log(now + "NOT restorable: declarations Reforged's common.j already provides, natives removed by " +
                   "\"Clear unused natives\", the \"return bug\" typecast bodies, and comment lines");
        return out;
    }

    /** Index of the line after the END marker that closes the block opened at {@code open}. */
    private static int indexAfterEnd(List<String> lines, int open) throws IOException {
        for (int j = open + 1; j < lines.size(); j++) {
            if (lines.get(j).trim().equals(DzMarkers.END)) return j + 1;
        }
        throw new IOException("The DZCOMPAT block opened at line " + (open + 1) +
                              " has no closing //DZCOMPAT:E line - the script was edited after conversion; " +
                              "restore the marker lines or convert the original script again.");
    }

    // ---- GetUnitState/SetUnitState extended-index call sites ----------------

    /** DzCompat_GetExtUnitState(u, N) -> GetUnitState(u, ConvertUnitState(N)), and likewise Set. */
    private static String revertExtState(String line, int[] count) {
        int end = JassExpr.codeEnd(line);
        return revertExpr(line.substring(0, end), count) + line.substring(end);
    }

    private static String revertExpr(String text, int[] count) {
        StringBuilder out = new StringBuilder(text.length() + 24);
        int n = text.length();
        int i = 0;
        boolean inString = false;
        while (i < n) {
            char c = text.charAt(i);
            if (inString) {
                out.append(c);
                if (c == '\\' && i + 1 < n) {
                    out.append(text.charAt(i + 1));
                    i += 2;
                    continue;
                }
                if (c == '"') inString = false;
                i++;
                continue;
            }
            if (c == '"') {
                inString = true;
                out.append(c);
                i++;
                continue;
            }
            if (JassExpr.isIdentChar(c) && (i == 0 || !JassExpr.isIdentChar(text.charAt(i - 1)))) {
                int j = i;
                while (j < n && JassExpr.isIdentChar(text.charAt(j))) j++;
                String name = text.substring(i, j);
                boolean isGet = name.equals(GET_WRAPPER);
                boolean isSet = name.equals(SET_WRAPPER);
                if (isGet || isSet) {
                    int k = j;
                    while (k < n && text.charAt(k) == ' ') k++;
                    int close = (k < n && text.charAt(k) == '(') ? JassExpr.findClosingParen(text, k, n) : -1;
                    if (close > 0) {
                        List<String> args = JassExpr.splitTopLevel(text.substring(k + 1, close), ',');
                        if ((isGet && args.size() == 2) || (isSet && args.size() == 3)) {
                            String unit = revertExpr(args.get(0).trim(), count);
                            String index = args.get(1).trim();
                            if (isGet) {
                                out.append("GetUnitState(").append(unit)
                                   .append(", ConvertUnitState(").append(index).append("))");
                            } else {
                                out.append("SetUnitState(").append(unit)
                                   .append(", ConvertUnitState(").append(index).append("), ")
                                   .append(revertExpr(args.get(2).trim(), count)).append(")");
                            }
                            count[0]++;
                            i = close + 1;
                            continue;
                        }
                    }
                }
                out.append(name);
                i = j;
                continue;
            }
            out.append(c);
            i++;
        }
        return out.toString();
    }

    // -------------------------------------------------------------------------
    // Legacy reverse (scripts converted before the markers existed)
    // -------------------------------------------------------------------------

    /**
     * Replace function bodies whose names appear in KKAPI.txt with the corresponding native
     * declarations, and undo the RequestExtra* renames.
     */
    private List<String> reverseLegacy(List<String> jassScript, Logger logger) throws IOException {
        logger.log("[" + Timestamps.now() + "] Loading KKAPI native signatures...");
        Map<String, String> kkapiNatives = loadKkapiNatives(logger);
        logger.log("[" + Timestamps.now() + "] Loaded " + kkapiNatives.size() + " native signatures from KKAPI.txt");

        // Undo the RequestExtra*Data rename (whole identifiers, outside strings and comments).
        for (int i = 0; i < jassScript.size(); i++) {
            String l = jassScript.get(i);
            if (l.indexOf("RequestExtra") < 0) continue;
            jassScript.set(i, NameCollisionFixer.renameIdentifiers(l, ConverterConstants.REQUEST_EXTRA_RESTORES));
        }

        Pattern funcStart = Pattern.compile("^\\s*function\\s+(\\w+)\\s+takes\\b");
        Pattern endFunc = Pattern.compile("^\\s*endfunction\\s*$");

        List<String> finalOutput = new ArrayList<>();
        int reversedCount = 0;
        int i = 0;
        while (i < jassScript.size()) {
            String line = jassScript.get(i);
            Matcher fm = funcStart.matcher(line);
            if (fm.find()) {
                String fname = fm.group(1);
                if (kkapiNatives.containsKey(fname)) {
                    // Skip entire function body until endfunction
                    int j = i + 1;
                    while (j < jassScript.size() && !endFunc.matcher(jassScript.get(j)).matches()) {
                        j++;
                    }
                    if (j < jassScript.size()) {
                        // Include endfunction line in the skip
                        j++;
                    }
                    finalOutput.add(kkapiNatives.get(fname));
                    reversedCount++;
                    i = j;
                    continue;
                }
            }
            finalOutput.add(line);
            i++;
        }

        // Always omit lines that start with a // comment from the output
        finalOutput = JassScript.stripCommentLines(finalOutput);
        logger.log("[" + Timestamps.now() + "] " + reversedCount + " functions restored to native declarations");
        return finalOutput;
    }

    /**
     * Load native name → full "native ..." declaration from KKAPI.txt.
     * Strips trailing parenthetical notes (e.g. "(dup also in ...)").
     */
    private Map<String, String> loadKkapiNatives(Logger logger) throws IOException {
        Path kkapi = ResourceLocator.resolveKkapiPath();
        logger.log("[" + Timestamps.now() + "] KKAPI path: " + kkapi.toAbsolutePath());
        List<String> lines = Files.readAllLines(kkapi, StandardCharsets.UTF_8);
        Map<String, String> map = new LinkedHashMap<>();
        Pattern nativePat = Pattern.compile("^\\s*native\\s+(\\w+)\\s+takes\\b");
        for (String raw : lines) {
            String line = raw.trim();
            if (line.isEmpty()) continue;
            Matcher m = nativePat.matcher(line);
            if (!m.find()) continue;
            String name = m.group(1);
            // Drop trailing comments like " (dup also in BlizzardAPI.j)"
            int paren = line.indexOf(" (");
            if (paren > 0) {
                line = line.substring(0, paren).trim();
            }
            // Ensure it starts with "native "
            if (!line.startsWith("native ")) {
                line = "native " + line.substring(line.indexOf(name));
            }
            map.put(name, line);
        }
        if (map.isEmpty()) {
            throw new IOException("No native declarations found in KKAPI.txt: " + kkapi);
        }
        return map;
    }
}
