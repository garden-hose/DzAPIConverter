import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.Charset;
import java.nio.charset.CharsetEncoder;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Bakes the object data that EXExecuteScript reads through {@code jass.slk}
 * into the converted script.
 *
 * YDWE's Lua engine answers {@code (require'jass.slk').item[id].Name} from the
 * map's object-data files at runtime; JASS cannot, and creating work items to
 * read the same values would desync when done from a local-only callback. So
 * the values are looked up here, at conversion time, in the W3x2lni table\*.ini
 * files and written out as DzCompat_SlkPut calls (see lib/DzCompat_Lua.j for the
 * runtime side).
 *
 * Only what is needed is baked:
 *   - columns: the (table, field) pairs found in the script's call sites (the
 *     field name is a string literal even when the object id is dynamic);
 *   - rows: for each (table, field), the object ids that can reach its call
 *     sites, traced through literals, hashtables and global variables by
 *     {@link IdSourceAnalyzer}. If the ids cannot be traced (an id that only
 *     exists at runtime, an untraceable hashtable, ...) the field falls back to a
 *     broader set: every object of the table when its needed columns are small,
 *     otherwise the ids that appear as rawcode literals in the script.
 */
final class SlkTableRegistry {

    private SlkTableRegistry() {}

    /** Statements per generated DzCompat_InitSlk_N function (each runs in its own thread). */
    private static final int STATEMENTS_PER_CHUNK = 100;
    /** Longest raw (unescaped) UTF-8 run put in one JASS string literal; longer values are concatenated. */
    private static final int MAX_LITERAL_BYTES = 300;

    /**
     * If every row of the needed columns of a table adds up to no more than this many bytes
     * of text, the whole table is baked; bigger tables are cut down to the object ids the
     * script mentions as rawcode literals (an id read at runtime has to come from somewhere).
     */
    private static final long BAKE_WHOLE_TABLE_MAX_BYTES = 512 * 1024;

    /** Name of the generated entry point; ForwardConverter hooks it into main(). */
    static final String INIT_FUNCTION = "DzCompat_InitSlk";

    /**
     * Decide whether EXExecuteScript can be converted at all. It needs the map's table
     * folder: when the "Map table path" input is empty, the folder does not exist, or it
     * holds no table .ini files, the EXExecuteScript conversion is skipped entirely (the
     * caller then stubs the native instead of giving it a real implementation).
     *
     * @param scriptPath the input script (a "table" folder next to it is offered to the prompt
     *                   as a suggestion; it is never used without the prompt confirming it)
     * @param prompt     supplies the table folder; null = none, so no conversion
     * @return the table folder to bake from, or null when EXExecuteScript must not be converted
     */
    static Path resolveTableFolder(Path scriptPath, SlkTablePrompt prompt, Logger logger) {
        Path tableDir = (prompt != null) ? prompt.requestTableFolder(findTableFolderNextTo(scriptPath)) : null;
        if (tableDir == null) {
            log(logger, "Map table path is empty");
            return null;
        }
        if (!Files.isDirectory(tableDir)) {
            log(logger, "Map table folder does not exist: " + tableDir);
            return null;
        }
        boolean anyIni = false;
        for (String fileName : listIniFiles(tableDir, logger).keySet()) {
            if (fileName.endsWith(".ini")) {
                anyIni = true;
                break;
            }
        }
        if (!anyIni) {
            log(logger, "No table .ini files found in " + tableDir);
            return null;
        }
        return tableDir;
    }

    /**
     * Scan the script's EXExecuteScript calls and, if any read jass.slk fields, build the
     * generated JASS (chunked DzCompat_InitSlk_N functions plus DzCompat_InitSlk).
     *
     * @param tableDir a folder accepted by {@link #resolveTableFolder}
     * @return the lines to emit, or an empty list when there is nothing to bake
     */
    static List<String> buildRegistry(List<String> jassScript, Path tableDir,
                                      Charset outputCharset, Logger logger) {
        List<ExecuteScriptScanner.Call> calls = ExecuteScriptScanner.scan(jassScript);
        if (calls.isEmpty()) {
            log(logger, "EXExecuteScript is declared but never called; nothing to bake");
            return Collections.emptyList();
        }

        // For every (table, field) the script reads: which object ids can reach its call sites?
        Map<String, Map<String, Demand>> demand = new LinkedHashMap<>();
        Set<String> dynamicFields = new LinkedHashSet<>();
        List<String> unsupported = new ArrayList<>();
        IdSourceAnalyzer analyzer = null;
        int slkReads = 0;
        for (ExecuteScriptScanner.Call c : calls) {
            switch (c.kind) {
                case SLK_FIELD:
                    slkReads++;
                    if (analyzer == null) analyzer = new IdSourceAnalyzer(jassScript);
                    demand.computeIfAbsent(c.table, k -> new LinkedHashMap<>())
                          .computeIfAbsent(c.field, k -> new Demand())
                          .add(c, analyzer);
                    break;
                case SLK_DYNAMIC_FIELD:
                    dynamicFields.add(c.describe());
                    break;
                default:
                    unsupported.add("line " + (c.line + 1) + ": " + c.describe());
                    break;
            }
        }
        log(logger, "EXExecuteScript: " + calls.size() + " call site(s), " + slkReads +
                    " read jass.slk fields " + describeDemand(demand));
        for (String d : dynamicFields) {
            log(logger, "WARNING: EXExecuteScript " + d + " - field name built at runtime, not supported (returns null)");
        }
        for (int i = 0; i < unsupported.size() && i < 8; i++) {
            log(logger, "WARNING: EXExecuteScript call not supported (returns null) - " + unsupported.get(i));
        }
        if (unsupported.size() > 8) {
            log(logger, "WARNING: ... and " + (unsupported.size() - 8) + " more unsupported EXExecuteScript call(s)");
        }
        if (demand.isEmpty()) {
            return Collections.emptyList();
        }

        Map<String, Path> iniFiles = listIniFiles(tableDir, logger);

        Set<String> candidateIds = null;   // rawcode literals of the script; only collected when needed

        // Read the needed columns of every needed table and decide, per (table, field), which
        // objects to keep: the traced ids, or - when the ids cannot be traced - a broader set.
        Map<String, TableData> tables = new LinkedHashMap<>();
        Map<String, Set<String>> keepOnly = new LinkedHashMap<>();   // "table\0field" -> ids; absent = every object
        for (Map.Entry<String, Map<String, Demand>> te : demand.entrySet()) {
            String table = te.getKey();
            Path file = iniFiles.get(table + ".ini");
            if (file == null) {
                log(logger, "WARNING: " + table + ".ini not found in " + tableDir + " - jass.slk." + table + " reads return null");
                continue;
            }
            TableData data;
            try {
                data = readTable(readIni(file, logger), te.getValue().keySet());
            } catch (IOException ex) {
                log(logger, "ERROR reading " + file + ": " + ex.getMessage());
                continue;
            }
            tables.put(table, data);
            for (String f : data.arrayFields) {
                log(logger, "WARNING: " + table + "." + f + " holds per-level (array) values in " +
                            file.getFileName() + " - not baked, returns null");
            }

            Set<String> traced = new LinkedHashSet<>();
            Boolean bakeWholeTable = null;
            for (Map.Entry<String, Demand> fe : te.getValue().entrySet()) {
                String field = fe.getKey();
                Demand d = fe.getValue();
                String key = table + "\u0000" + field;
                if (!d.broad) {
                    keepOnly.put(key, d.ids);
                    traced.addAll(d.ids);
                    log(logger, table + "." + field + ": " + d.ids.size() + " object id(s) traced from the script " + preview(d.ids));
                    continue;
                }
                if (bakeWholeTable == null) {
                    bakeWholeTable = data.textBytes() <= BAKE_WHOLE_TABLE_MAX_BYTES;
                }
                if (bakeWholeTable) {
                    log(logger, table + "." + field + ": ids could not be traced (" + d.reason + "); baking all " +
                                data.rows.size() + " object(s)");
                } else {
                    if (candidateIds == null) candidateIds = collectRawcodes(jassScript);
                    keepOnly.put(key, candidateIds);
                    log(logger, table + "." + field + ": ids could not be traced (" + d.reason + "); table too big to " +
                                "bake in full, baking the objects whose rawcode appears in the script");
                }
            }
            List<String> notInTable = new ArrayList<>();
            for (String id : traced) {
                if (!data.rows.containsKey(id)) notInTable.add(id);
            }
            if (!notInTable.isEmpty()) {
                log(logger, "WARNING: " + notInTable.size() + " traced " + table + " id(s) have none of the needed fields in " +
                            file.getFileName() + " (stock objects?) " + preview(notInTable));
            }
        }

        // Collect the values to bake.
        CharsetEncoder encoder = outputCharset.newEncoder();
        boolean byteTransparent = outputCharset.equals(StandardCharsets.ISO_8859_1);
        if (byteTransparent) {
            log(logger, "Script was read as ISO-8859-1 (byte-transparent); baked non-ASCII text is written as UTF-8 bytes");
        }
        List<Baked> baked = new ArrayList<>();
        int skippedEncoding = 0;
        for (Map.Entry<String, TableData> te : tables.entrySet()) {
            String table = te.getKey();
            int before = baked.size();
            for (Map.Entry<String, Map<String, String>> row : te.getValue().rows.entrySet()) {
                for (String field : demand.get(table).keySet()) {
                    String value = row.getValue().get(field);
                    if (value == null) continue;
                    Set<String> only = keepOnly.get(table + "\u0000" + field);
                    if (only != null && !only.contains(row.getKey())) continue;
                    if (!encoder.canEncode(toOutputText(value, byteTransparent))) {
                        skippedEncoding++;
                        continue;
                    }
                    baked.add(new Baked(table, field, row.getKey(), value));
                }
            }
            log(logger, table + ": " + (baked.size() - before) + " value(s) baked" +
                        (te.getValue().unsupportedValues > 0
                                ? ", " + te.getValue().unsupportedValues + " unreadable value(s) skipped" : ""));
        }
        if (skippedEncoding > 0) {
            log(logger, "WARNING: " + skippedEncoding + " value(s) skipped: characters not representable in " +
                        outputCharset.name() + " (the encoding the script is written in)");
        }
        if (baked.isEmpty()) {
            log(logger, "No object data matched; nothing baked");
            return Collections.emptyList();
        }

        // Field indices: one per (table, field) that has at least one baked value.
        Map<String, Integer> fieldIndex = new LinkedHashMap<>();
        for (Baked b : baked) {
            fieldIndex.putIfAbsent(b.table + "\u0000" + b.field, fieldIndex.size());
        }
        List<String> statements = new ArrayList<>();
        for (Map.Entry<String, Integer> e : fieldIndex.entrySet()) {
            String[] tf = e.getKey().split("\u0000");
            statements.add("    call DzCompat_SlkDeclare(" + e.getValue() + ",\"" + tf[0] + "\",\"" + tf[1] + "\")");
        }
        for (Baked b : baked) {
            statements.add("    call DzCompat_SlkPut('" + b.id + "'," + fieldIndex.get(b.table + "\u0000" + b.field) + "," +
                           jassLiteral(b.value, byteTransparent) + ")");
        }

        // Emit: chunk functions first, then the entry point that runs each chunk in
        // its own thread (ExecuteFunc) so no chunk can run into the op limit.
        List<String> out = new ArrayList<>();
        out.add("// ---- jass.slk object data for EXExecuteScript (auto-generated) ----");
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
        log(logger, "Baked " + (statements.size() - fieldIndex.size()) + " jass.slk value(s) in " +
                    chunkCount + " init function(s)");
        return out;
    }

    // ------------------------------------------------------------------
    // Table folder / ini reading
    // ------------------------------------------------------------------

    /** A folder called "table" next to the script or one level above it, else null. */
    private static Path findTableFolderNextTo(Path scriptPath) {
        Path dir = scriptPath.toAbsolutePath().getParent();
        for (int i = 0; i < 2 && dir != null; i++, dir = dir.getParent()) {
            Path candidate = dir.resolve("table");
            if (Files.isDirectory(candidate)) return candidate;
        }
        return null;
    }

    /** lower-case file name -> path for every regular file in the folder. */
    static Map<String, Path> listIniFiles(Path dir, Logger logger) {
        Map<String, Path> map = new LinkedHashMap<>();
        try (DirectoryStream<Path> stream = Files.newDirectoryStream(dir)) {
            for (Path p : stream) {
                if (Files.isRegularFile(p)) {
                    map.put(p.getFileName().toString().toLowerCase(Locale.ROOT), p);
                }
            }
        } catch (IOException e) {
            log(logger, "ERROR listing " + dir + ": " + e.getMessage());
        }
        return map;
    }

    /** W3x2lni writes UTF-8; anything else goes through the lenient sniffing reader. */
    static List<String> readIni(Path file, Logger logger) throws IOException {
        byte[] bytes = Files.readAllBytes(file);
        String text;
        try {
            text = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes)).toString();
        } catch (CharacterCodingException e) {
            return TextFileReader.readLenient(file, logger).lines;
        }
        if (text.startsWith("\uFEFF")) text = text.substring(1);
        return java.util.Arrays.asList(text.replace("\r\n", "\n").replace('\r', '\n').split("\n", -1));
    }

    /** Object ids that can be written as a JASS rawcode literal. */
    static final Pattern ID_PATTERN = Pattern.compile("[A-Za-z0-9]{4}");

    /** One value to bake. */
    private static final class Baked {
        final String table, field, id, value;

        Baked(String table, String field, String id, String value) {
            this.table = table;
            this.field = field;
            this.id = id;
            this.value = value;
        }
    }

    /** Which objects one (table, field) can be asked about. */
    private static final class Demand {
        final Set<String> ids = new LinkedHashSet<>();
        /** True when the ids could not be traced, so a broader set of objects has to be baked. */
        boolean broad;
        String reason;

        void add(ExecuteScriptScanner.Call call, IdSourceAnalyzer analyzer) {
            if (broad) return;
            String where = "line " + (call.line + 1) + ": ";
            if (call.idExpression == null) {
                broad = true;
                reason = where + "the index is not written as I2S(...) or a literal";
                return;
            }
            IdSourceAnalyzer.Result r = analyzer.resolve(call.idExpression);
            if (r.unresolved != null) {
                broad = true;
                reason = where + r.unresolved;
            } else if (r.ids.isEmpty()) {
                broad = true;
                reason = where + "no object id literal reaches it";
            } else {
                ids.addAll(r.ids);
            }
        }
    }

    private static final class TableData {
        /** object id -> (field -> value), in ini order; only the wanted fields. */
        final Map<String, Map<String, String>> rows = new LinkedHashMap<>();
        /** wanted fields that are per-level arrays in the ini (not supported). */
        final Set<String> arrayFields = new LinkedHashSet<>();
        int unsupportedValues;

        long textBytes() {
            long total = 0;
            for (Map<String, String> row : rows.values()) {
                for (String v : row.values()) total += v.getBytes(StandardCharsets.UTF_8).length;
            }
            return total;
        }


    }

    /**
     * Minimal reader for W3x2lni's lni tables: [id] sections, "key = value" lines
     * (quoted string or bare number), "--" comments, and "key = {" ... "}" arrays,
     * which are skipped.
     */
    private static TableData readTable(List<String> lines, Set<String> wantedFields) {
        TableData data = new TableData();
        String current = null;
        int arrayDepth = 0;
        for (String raw : lines) {
            String t = raw.trim();
            if (arrayDepth > 0) {
                if (t.equals("}") || t.equals("},")) arrayDepth--;
                else if (t.endsWith("{")) arrayDepth++;
                continue;
            }
            if (t.isEmpty() || t.startsWith("--")) continue;
            if (t.charAt(0) == '[' && t.endsWith("]")) {
                String id = t.substring(1, t.length() - 1);
                current = ID_PATTERN.matcher(id).matches() ? id : null;
                continue;
            }
            int eq = t.indexOf('=');
            if (eq <= 0) continue;
            String key = t.substring(0, eq).trim();
            String val = t.substring(eq + 1).trim();
            if (val.startsWith("{")) {
                if (!val.endsWith("}")) arrayDepth = 1;
                if (current != null && wantedFields.contains(key)) data.arrayFields.add(key);
                continue;
            }
            if (current == null || !wantedFields.contains(key)) continue;
            String value = parseValue(val);
            if (value == null) {
                data.unsupportedValues++;
                continue;
            }
            data.rows.computeIfAbsent(current, k -> new LinkedHashMap<>()).put(key, value);
        }
        return data;
    }

    /**
     * A quoted lni string (Lua-style escapes) becomes its real text; a bare value
     * (number, boolean) is kept as written. Null for anything unreadable or empty.
     */
    static String parseValue(String raw) {
        if (raw.isEmpty()) return null;
        if (raw.charAt(0) != '"') return raw;
        StringBuilder sb = new StringBuilder(raw.length());
        for (int i = 1; i < raw.length(); i++) {
            char c = raw.charAt(i);
            if (c == '\\' && i + 1 < raw.length()) {
                char n = raw.charAt(++i);
                switch (n) {
                    case '\\': sb.append('\\'); break;
                    case '"':  sb.append('"'); break;
                    case '\'': sb.append('\''); break;
                    case 'n':  sb.append('\n'); break;
                    case 'r':  sb.append('\r'); break;
                    case 't':  sb.append('\t'); break;
                    default:   sb.append('\\').append(n); break;
                }
            } else if (c == '"') {
                return i == raw.length() - 1 ? sb.toString() : null;
            } else {
                sb.append(c);
            }
        }
        return null;   // unterminated
    }

    // ------------------------------------------------------------------
    // Rawcode literals
    // ------------------------------------------------------------------

    private static final Pattern RAWCODE = Pattern.compile(
            "'([A-Za-z0-9]{4})'|\\$([0-9A-Fa-f]{8})\\b|\\b0[xX]([0-9A-Fa-f]{8})\\b|\\b(\\d{9,10})\\b");

    /** Every 4-character alphanumeric id the script mentions, in any of JASS's integer spellings. */
    static Set<String> collectRawcodes(List<String> lines) {
        Set<String> ids = new LinkedHashSet<>();
        for (String line : lines) {
            Matcher m = RAWCODE.matcher(line);
            while (m.find()) {
                if (m.group(1) != null) {
                    ids.add(m.group(1));
                    continue;
                }
                long v;
                if (m.group(2) != null) v = Long.parseLong(m.group(2), 16);
                else if (m.group(3) != null) v = Long.parseLong(m.group(3), 16);
                else v = Long.parseLong(m.group(4));
                String id = JassExpr.rawcodeOrNull(v);
                if (id != null) ids.add(id);
            }
        }
        return ids;
    }

    // ------------------------------------------------------------------
    // JASS output helpers
    // ------------------------------------------------------------------

    /**
     * The converter writes the script back with the charset it was read with. When that
     * is ISO-8859-1 the file is being passed through byte for byte (typically a UTF-8
     * script with a stray invalid sequence that defeated the strict UTF-8 decode), so
     * non-ASCII text must be handed over as its UTF-8 bytes, one char per byte.
     */
    static String toOutputText(String value, boolean byteTransparent) {
        return byteTransparent
                ? new String(value.getBytes(StandardCharsets.UTF_8), StandardCharsets.ISO_8859_1)
                : value;
    }

    /**
     * A JASS expression for the value: one escaped string literal, or several joined by
     * '+' when the value is long (keeps every literal well under 1023 bytes even after
     * backslashes are doubled).
     */
    static String jassLiteral(String value, boolean byteTransparent) {
        if (value.isEmpty()) return "\"\"";
        List<String> pieces = new ArrayList<>();
        StringBuilder cur = new StringBuilder();
        int bytes = 0;
        for (int i = 0; i < value.length(); ) {
            int cp = value.codePointAt(i);
            int b = cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
            if (bytes + b > MAX_LITERAL_BYTES && cur.length() > 0) {
                pieces.add(cur.toString());
                cur.setLength(0);
                bytes = 0;
            }
            cur.appendCodePoint(cp);
            bytes += b;
            i += Character.charCount(cp);
        }
        pieces.add(cur.toString());
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < pieces.size(); i++) {
            if (i > 0) sb.append(" + ");
            // pieces were cut on character boundaries; convert each one afterwards
            sb.append('"').append(JassStrings.escape(toOutputText(pieces.get(i), byteTransparent))).append('"');
        }
        return sb.toString();
    }

    private static String describeDemand(Map<String, Map<String, Demand>> demand) {
        List<String> parts = new ArrayList<>();
        for (Map.Entry<String, Map<String, Demand>> e : demand.entrySet()) {
            for (String f : e.getValue().keySet()) parts.add(e.getKey() + "." + f);
        }
        return parts.isEmpty() ? "" : "(" + String.join(", ", parts) + ")";
    }

    /** "(shar, sand, pghe, ... )" - the first few ids of a collection. */
    private static String preview(Iterable<String> ids) {
        List<String> shown = new ArrayList<>();
        int total = 0;
        for (String id : ids) {
            if (shown.size() < 6) shown.add(id);
            total++;
        }
        return "(" + String.join(", ", shown) + (total > shown.size() ? ", ..." : "") + ")";
    }

    private static void log(Logger logger, String msg) {
        logger.log("[" + Timestamps.now() + "] " + msg);
    }
}
