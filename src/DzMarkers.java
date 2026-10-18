import java.util.List;

/**
 * Sentinel comment lines that the forward converter writes into its output so the reverse
 * converter can undo exactly what was injected, without needing a list of known names.
 *
 * Every marker starts with {@link #PREFIX}. A plain "//" comment is used (not a "//!" directive)
 * so no compiler or map tool can treat it as anything but a comment. JassScript.stripCommentLines
 * and the indentation stripper both leave marker lines alone.
 *
 * <ul>
 *   <li>{@code //DZCOMPAT:B|name} ... {@code //DZCOMPAT:E} - an injected block (globals, compat
 *       implementations, baked tables). Reverse deletes it, markers included.</li>
 *   <li>{@code //DZCOMPAT:S|<original native line>} ... {@code //DZCOMPAT:E} - a stub that
 *       replaced a native declaration. Reverse swaps the whole block for the original line.</li>
 *   <li>{@code //DZCOMPAT:N|<original native line>} - the place where a native declaration was
 *       removed because a real implementation was emitted elsewhere. Reverse writes the
 *       original line back.</li>
 *   <li>{@code <statement> //DZCOMPAT:X} - a statement injected into main(). Reverse deletes
 *       the line.</li>
 * </ul>
 */
final class DzMarkers {

    private DzMarkers() {}

    static final String PREFIX = "//DZCOMPAT:";
    static final String BLOCK = PREFIX + "B|";
    static final String STUB = PREFIX + "S|";
    static final String NATIVE = PREFIX + "N|";
    static final String END = PREFIX + "E";
    /** Trailing marker on a statement the converter injected into main(). */
    static final String INJECTED = PREFIX + "X";

    static boolean isMarker(String line) {
        return line.trim().startsWith(PREFIX);
    }

    /** True when the script carries any marker, i.e. it was produced by a marker-aware conversion. */
    static boolean hasMarkers(List<String> lines) {
        for (String l : lines) {
            if (isMarker(l)) return true;
        }
        return false;
    }

    /** True when the script already contains an injected block (it has been converted). */
    static boolean isConverted(List<String> lines) {
        for (String l : lines) {
            if (l.trim().startsWith(BLOCK)) return true;
        }
        return false;
    }

    /** The text after {@code tag} on a marker line, or null when the line has no such marker. */
    static String payload(String line, String tag) {
        int i = line.indexOf(tag);
        return i < 0 ? null : line.substring(i + tag.length());
    }

    static boolean endsWithInjectedMark(String line) {
        return line.trim().endsWith(INJECTED);
    }
}
