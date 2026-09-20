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
 * Reverse conversion: turns compat functions back into native declarations
 * (signatures come from KKAPI.txt) and undoes the RequestExtra* renames.
 */
final class ReverseConverter {

    /**
     * Reverse conversion: replace function bodies whose names appear in KKAPI.txt
     * with the corresponding native declarations, and undo RequestExtra* renames.
     */
    void run(String inputPath, String outputPath, Logger logger) throws IOException {
        logger.log("[" + Timestamps.now() + "] Loading KKAPI native signatures...");
        Map<String, String> kkapiNatives = loadKkapiNatives(logger);
        logger.log("[" + Timestamps.now() + "] Loaded " + kkapiNatives.size() + " native signatures from KKAPI.txt");

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

        // Undo RequestExtra*Data rename (forward conversion appends an extra 'a')
        for (String[] pair : ConverterConstants.RENAME_PAIRS) {
            for (int i = 0; i < jassScript.size(); i++) {
                jassScript.set(i, jassScript.get(i).replace(pair[1], pair[0]));
            }
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

        Files.write(Paths.get(outputPath), finalOutput, inputCharset);
        logger.log("[" + Timestamps.now() + "] Wrote output using encoding: " + inputCharset.name());
        logger.log("[" + Timestamps.now() + "] Reverse conversion SUCCESS");
        logger.log("[" + Timestamps.now() + "] " + reversedCount + " functions restored to native declarations");
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
