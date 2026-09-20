import java.nio.file.Path;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * DzCompat_Archive support: per-map folder-name detection/sanitization.
 */
final class MapNameResolver {

    private MapNameResolver() {}

    private static final Pattern SET_MAP_NAME = Pattern.compile(
            "SetMapName\\s*\\(\\s*\"((?:\\\\.|[^\"\\\\])*)\"\\s*\\)");
            
    /**
     * Best-effort detection of the map's real name, used as the DzCompat_Archive
     * per-map folder name. Every World-Editor-generated war3map.j contains a
     * "call SetMapName(\"...\")" line in its config() function; that is a
     * reliable source. Falls back to the input file name if it's
     * missing (e.g. a hand-trimmed / stripped script).
     */
    static String detectMapName(List<String> jassScript, Path inputFile) {
        for (String line : jassScript) {
            Matcher m = SET_MAP_NAME.matcher(line);
            if (m.find()) {
                String raw = m.group(1).replace("\\\"", "\"").replace("\\\\", "\\");
                if (!raw.trim().isEmpty()) {
                    return raw.trim();
                }
            }
        }
        String base = inputFile.getFileName().toString();
        int dot = base.lastIndexOf('.');
        if (dot > 0) base = base.substring(0, dot);
        if (base.isEmpty() || base.equalsIgnoreCase("war3map")) {
            // "war3map" is the generic extracted-script name and useless as a
            // per-map folder name on its own - try the containing folder instead.
            Path parent = inputFile.toAbsolutePath().getParent();
            if (parent != null && parent.getFileName() != null) {
                String parentName = parent.getFileName().toString();
                if (!parentName.isEmpty()) return parentName;
            }
        }
        return base;
    }

    private static final Set<String> WINDOWS_RESERVED_NAMES = new HashSet<>(Arrays.asList(
            "CON", "PRN", "AUX", "NUL",
            "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
            "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"));

    /** Turns an arbitrary map title into a safe Windows/macOS folder name. */
    static String sanitizeFolderName(String raw) {
        if (raw == null) return "UnknownMap";
        StringBuilder sb = new StringBuilder(raw.length());
        for (int i = 0; i < raw.length(); i++) {
            char c = raw.charAt(i);
            if (c < 0x20) continue; // drop control chars
            if (c == '<' || c == '>' || c == ':' || c == '"' || c == '/' ||
                c == '\\' || c == '|' || c == '?' || c == '*') {
                sb.append('_');
            } else {
                sb.append(c);
            }
        }
        String s = sb.toString().trim().replaceAll("\\s+", "_");
        while (s.endsWith(".") || s.endsWith("_")) {
            s = s.substring(0, s.length() - 1);
        }
        if (s.length() > 40) s = s.substring(0, 40);
        if (s.isEmpty()) s = "UnknownMap";
        if (WINDOWS_RESERVED_NAMES.contains(s.toUpperCase(Locale.ROOT))) s = s + "_Map";
        return s;
    }
}
