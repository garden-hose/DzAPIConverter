import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.Charset;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Post-conversion step for Reforged: writes {@code item_patched.ini}, a copy of the map's
 * {@code item.ini} in which every item that inherits a stock (Blizzard) item and has no
 * {@code Requires} field gets an explicit empty one:
 *
 * <pre>
 * -- Requirements
 * Requires = ""
 * </pre>
 *
 * <p>Reforged's built-in item data carries tech requirements for some stock items (for example
 * the Orb of Slow, 'oslo', shows "requires Castle" when a shop makes it), which the older game
 * versions DzAPI maps were built for did not enforce. An object that does not set the field
 * inherits the built-in requirement; setting it to an empty string clears it.
 *
 * <p>Only {@code item.ini} is read and only {@code item_patched.ini} is written; the input
 * file is never modified. The patched data has to be re-imported into the map by hand
 * (w3x2lni), exactly like the AIs2 ability parent fix.
 *
 * <p>An object is treated as stock-based when its {@code _parent} / {@code parent} value is a
 * stock item id, or - when it has no parent key - when its own section id is a stock item id.
 * Existing {@code Requires} values (including non-empty ones) are never touched.
 */
final class ItemRequirementPatcher {

    private ItemRequirementPatcher() {}

    /** Output file, written next to item.ini. */
    static final String OUTPUT_FILE_NAME = "item_patched.ini";
    /** Stock item rawcodes, one per line, in the lib folder. */
    static final String STOCK_IDS_FILE_NAME = "ReforgedStockItemIds.txt";

    private static final Pattern SECTION = Pattern.compile("^\\s*\\[([^\\]]*)\\]\\s*$");
    private static final Pattern PARENT = Pattern.compile(
            "^\\s*_?parent\\s*=\\s*\"?([^\"\\s]*)\"?\\s*$", Pattern.CASE_INSENSITIVE);
    private static final Pattern REQUIRES = Pattern.compile(
            "^\\s*requires\\s*=", Pattern.CASE_INSENSITIVE);

    private static final String COMMENT_LINE = "-- Requirements";
    private static final String REQUIRES_LINE = "Requires = \"\"";

    /** How many patched ids are listed in the log before the rest is summarised. */
    private static final int MAX_LOGGED_IDS = 30;

    /** @return the stock item ids, or null when the file is not in the lib folder */
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
     * @param tableDir folder holding item.ini (the same Map table path used elsewhere);
     *                 null = nothing to do
     * @param stockIds stock item rawcodes (see {@link #loadStockIds})
     * @return number of objects that received the empty Requires field
     */
    static int patch(Path tableDir, Set<String> stockIds, Logger logger) {
        if (tableDir == null) {
            log(logger, "Item requirements: skipped (no map table path)");
            return 0;
        }
        Path itemIni = SlkTableRegistry.listIniFiles(tableDir, logger).get("item.ini");
        if (itemIni == null) {
            log(logger, "Item requirements: item.ini not found in " + tableDir);
            return 0;
        }

        Source src;
        try {
            src = read(itemIni, logger);
        } catch (IOException e) {
            log(logger, "Item requirements: ERROR reading " + itemIni + ": " + e.getMessage());
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
            log(logger, "Item requirements: every stock-based item in " + itemIni.getFileName() +
                        " already sets Requires (or there are none); " + OUTPUT_FILE_NAME + " not written");
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

        Path outFile = itemIni.resolveSibling(OUTPUT_FILE_NAME);
        try {
            writeAll(outFile, out, src);
        } catch (IOException e) {
            log(logger, "Item requirements: ERROR writing " + outFile + ": " + e.getMessage());
            return 0;
        }

        log(logger, "Item requirements: added an empty Requires field to " + patchedIds.size() +
                    " stock-based item(s) in " + itemIni.getFileName());
        int shown = Math.min(patchedIds.size(), MAX_LOGGED_IDS);
        log(logger, "  " + String.join(", ", patchedIds.subList(0, shown)) +
                    (patchedIds.size() > shown ? " ... (+" + (patchedIds.size() - shown) + " more)" : ""));
        log(logger, "Wrote " + outFile + " (item.ini left unchanged). " +
                    "The patched item data needs to be manually re-imported into the map.");
        return patchedIds.size();
    }

    private static boolean isStockBased(String id, String parent, Set<String> stockIds) {
        if (parent != null && !parent.isEmpty()) return stockIds.contains(parent);
        return stockIds.contains(id);
    }

    // -------------------------------------------------------------------------
    // File reading / writing that keeps encoding, BOM and line endings of item.ini
    // -------------------------------------------------------------------------

    private static final class Source {
        final List<String> lines;
        final Charset charset;
        final boolean bom;
        final String eol;
        Source(List<String> lines, Charset charset, boolean bom, String eol) {
            this.lines = lines;
            this.charset = charset;
            this.bom = bom;
            this.eol = eol;
        }
    }

    private static Source read(Path file, Logger logger) throws IOException {
        byte[] bytes = Files.readAllBytes(file);
        boolean bom = bytes.length >= 3 && (bytes[0] & 0xFF) == 0xEF
                && (bytes[1] & 0xFF) == 0xBB && (bytes[2] & 0xFF) == 0xBF;
        boolean crlf = false;
        for (int i = 0; i + 1 < bytes.length; i++) {
            if (bytes[i] == '\r' && bytes[i + 1] == '\n') { crlf = true; break; }
        }
        String eol = crlf ? "\r\n" : "\n";

        try {
            String text = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes)).toString();
            if (text.startsWith("\uFEFF")) text = text.substring(1);
            List<String> lines = new ArrayList<>(Arrays.asList(
                    text.replace("\r\n", "\n").replace('\r', '\n').split("\n", -1)));
            return new Source(lines, StandardCharsets.UTF_8, bom, eol);
        } catch (CharacterCodingException e) {
            DecodedText decoded = TextFileReader.readLenient(file, logger);
            return new Source(new ArrayList<>(decoded.lines), decoded.charset, false, eol);
        }
    }

    private static void writeAll(Path file, List<String> lines, Source src) throws IOException {
        String text = String.join(src.eol, lines);
        byte[] body = text.getBytes(src.charset);
        if (!src.bom) {
            Files.write(file, body);
            return;
        }
        byte[] all = new byte[body.length + 3];
        all[0] = (byte) 0xEF;
        all[1] = (byte) 0xBB;
        all[2] = (byte) 0xBF;
        System.arraycopy(body, 0, all, 3, body.length);
        Files.write(file, all);
    }

    private static void log(Logger logger, String msg) {
        if (logger != null) logger.log("[" + Timestamps.now() + "] " + msg);
    }
}
