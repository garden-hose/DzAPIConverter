import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Creates custom unit entries for model paths that have no skin id yet, and writes
 * them (appended to a copy of unit.ini) to unit_patched.ini next to unit.ini.
 *
 * Each new entry follows the pattern
 * <pre>
 * [u01M]
 * _parent = "hpea"
 * -- Model File
 * file = "W\\YJMS.mdl"
 * </pre>
 * unit.ini itself is never modified.
 *
 * <b>Id choice.</b> New ids look like the editor's own custom ids with two digits in
 * the middle: one of u/h/o/e, a digit, a digit, then a digit or capital letter
 * (u000 ... u99Z). Base-game unit ids are four letters, or letters with at most one
 * trailing digit, so this shape is never one of theirs. An id is also skipped when it
 * is already a section name in any .ini of the table folder (any object type, compared
 * case-insensitively) or appears as a rawcode literal ('u01M' or $7530314D) in the
 * script. unit_patched.ini is not counted, so a rerun hands out the same ids again.
 */
final class UnitModelPatcher {

    static final String PATCHED_FILE_NAME = "unit_patched.ini";
    static final String PARENT_ID = "hpea";

    private static final String ID_PREFIXES = "uhoe";
    private static final String DIGITS = "0123456789";
    private static final String LAST = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";

    private static final Pattern SECTION = Pattern.compile("^\\s*\\[([^\\]\\r\\n]{4})\\]\\s*$");
    private static final Pattern QUOTED_RAWCODE = Pattern.compile("'([\\x20-\\x7E]{4})'");
    private static final Pattern HEX_RAWCODE = Pattern.compile("\\$([0-9A-Fa-f]{8})\\b");

    private UnitModelPatcher() {}

    /**
     * @param unresolved model key (any unique string) -> the script's path literal for it.
     *                   One entry is created per key, so .mdl/.mdx/case variants of one
     *                   model share a unit.
     * @return key -> new unit id; empty when nothing could be written (no unit.ini in
     *         the table folder, nothing to do, or an I/O error, which is logged)
     */
    static Map<String, String> patch(Path tableDir, List<String> jassScript,
                                      Map<String, String> unresolved,
                                      Charset scriptCharset, Logger logger) {
        Map<String, String> result = new LinkedHashMap<>();
        if (unresolved.isEmpty()) {
            return result;
        }
        if (tableDir == null) {
            logger.log("[" + Timestamps.now() + "] No map table folder: cannot create unit entries for "
                    + unresolved.size() + " unresolved model path(s)");
            return result;
        }
        Map<String, Path> files = SlkTableRegistry.listIniFiles(tableDir, logger);
        Path unitIni = files.get("unit.ini");
        if (unitIni == null) {
            logger.log("[" + Timestamps.now() + "] No unit.ini in the table folder: cannot write "
                    + PATCHED_FILE_NAME + " for " + unresolved.size() + " unresolved model path(s)");
            return result;
        }
        try {
            Set<String> used = collectUsedIds(files, jassScript);
            Charset cs = scriptCharset != null ? scriptCharset : StandardCharsets.UTF_8;
            byte[] original = Files.readAllBytes(unitIni);
            String eol = containsCrLf(original) ? "\r\n" : "\n";

            ByteArrayOutputStream out = new ByteArrayOutputStream(original.length + unresolved.size() * 96);
            out.write(original);
            if (original.length > 0 && original[original.length - 1] != '\n') {
                out.write(eol.getBytes(StandardCharsets.ISO_8859_1));
            }
            IdAllocator ids = new IdAllocator(used);
            for (Map.Entry<String, String> e : unresolved.entrySet()) {
                String id = ids.next();
                if (id == null) {
                    logger.log("[" + Timestamps.now() + "] Ran out of free unit ids; "
                            + (unresolved.size() - result.size()) + " path(s) left without one");
                    break;
                }
                writeEntry(out, id, e.getValue(), cs, eol);
                result.put(e.getKey(), id);
            }
            Path target = unitIni.resolveSibling(PATCHED_FILE_NAME);
            Files.write(target, out.toByteArray());
            logger.log("[" + Timestamps.now() + "] Wrote " + target.getFileName() + ": " + result.size()
                    + " new unit(s) (parent " + PARENT_ID + "), ids " + firstLast(result) + "; "
                    + unitIni.getFileName() + " left unchanged");
        } catch (IOException e) {
            logger.log("[" + Timestamps.now() + "] ERROR writing " + PATCHED_FILE_NAME + ": " + e.getMessage());
            result.clear();
        }
        return result;
    }

    private static String firstLast(Map<String, String> ids) {
        if (ids.isEmpty()) return "(none)";
        List<String> v = new ArrayList<>(ids.values());
        return v.size() == 1 ? v.get(0) : v.get(0) + " .. " + v.get(v.size() - 1);
    }

    private static boolean containsCrLf(byte[] b) {
        for (int i = 0; i + 1 < b.length; i++) {
            if (b[i] == '\r' && b[i + 1] == '\n') return true;
        }
        return false;
    }

    /**
     * One entry, written as bytes: the path keeps the exact bytes it has in the script
     * (so mixed GBK/UTF-8 names survive), with each backslash doubled as in the rest of
     * the ini.
     */
    private static void writeEntry(ByteArrayOutputStream out, String id, String path,
                                    Charset cs, String eol) throws IOException {
        put(out, "[" + id + "]" + eol);
        put(out, "_parent = \"" + PARENT_ID + "\"" + eol);
        put(out, "-- Model File" + eol);
        put(out, "file = \"");
        for (byte b : path.getBytes(cs)) {
            out.write(b);
            if (b == '\\') out.write('\\');
        }
        put(out, "\"" + eol);
        put(out, eol);
    }

    private static void put(ByteArrayOutputStream out, String ascii) throws IOException {
        out.write(ascii.getBytes(StandardCharsets.ISO_8859_1));
    }

    /** Ids that must not be reused, lower-cased. */
    private static Set<String> collectUsedIds(Map<String, Path> files, List<String> jassScript)
            throws IOException {
        Set<String> used = new HashSet<>();
        for (Map.Entry<String, Path> f : files.entrySet()) {
            String name = f.getKey();
            if (!name.endsWith(".ini") || name.equals(PATCHED_FILE_NAME)) continue;
            String text = new String(Files.readAllBytes(f.getValue()), StandardCharsets.ISO_8859_1);
            for (String line : text.split("\r\n|\n|\r")) {
                Matcher m = SECTION.matcher(line);
                if (m.matches()) used.add(m.group(1).toLowerCase(Locale.ROOT));
            }
        }
        for (String line : jassScript) {
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

    /** Hands out u000, u001, ... u00Z, u010, ... then h000... for the other prefixes. */
    private static final class IdAllocator {
        private final Set<String> used;
        private int index = 0;
        private final int total = ID_PREFIXES.length() * DIGITS.length() * DIGITS.length() * LAST.length();

        IdAllocator(Set<String> used) { this.used = used; }

        String next() {
            while (index < total) {
                int i = index++;
                int last = i % LAST.length(); i /= LAST.length();
                int d2 = i % DIGITS.length(); i /= DIGITS.length();
                int d1 = i % DIGITS.length(); i /= DIGITS.length();
                String id = "" + ID_PREFIXES.charAt(i) + DIGITS.charAt(d1) + DIGITS.charAt(d2) + LAST.charAt(last);
                if (used.add(id.toLowerCase(Locale.ROOT))) return id;
            }
            return null;
        }
    }
}
