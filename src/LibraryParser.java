import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Splits a DzCompat_*.j library file into its globals and per-function segments. */
final class LibraryParser {

    private LibraryParser() {}

    static ParsedLib parseLibFile(Path path) throws IOException {
        List<String> lines = Files.readAllLines(path, StandardCharsets.UTF_8);

        Map<String, String> globals = new LinkedHashMap<>();
        int gs = -1, ge = -1;
        for (int i = 0; i < lines.size(); i++) {
            String t = lines.get(i).trim();
            if (t.equals("globals")) gs = i;
            else if (t.equals("endglobals")) { ge = i; break; }
        }
        if (gs >= 0 && ge > gs + 1) {
            Pattern gPat = Pattern.compile("^(?:constant\\s+)?[A-Za-z][A-Za-z0-9_]*\\s+(?:array\\s+)?(\\w+)");
            for (int i = gs + 1; i < ge; i++) {
                String gl = lines.get(i);
                String trimmed = gl.trim();
                if (trimmed.isEmpty() || trimmed.startsWith("//")) continue;
                Matcher m = gPat.matcher(trimmed);
                if (m.find()) {
                    globals.put(m.group(1), gl);
                }
            }
        }

        List<Integer> funcStarts = new ArrayList<>();
        Pattern funcPat = Pattern.compile("^\\s*function\\s+\\w+\\s+takes");
        for (int i = 0; i < lines.size(); i++) {
            if (funcPat.matcher(lines.get(i)).find()) funcStarts.add(i);
        }

        List<Segment> segments = new ArrayList<>();
        Pattern namePat = Pattern.compile("function\\s+(\\w+)\\s+takes");
        for (int i = 0; i < funcStarts.size(); i++) {
            int start = funcStarts.get(i);
            int end = (i + 1 < funcStarts.size()) ? funcStarts.get(i + 1) - 1 : lines.size() - 1;
            List<String> segLines = new ArrayList<>(lines.subList(start, end + 1));
            Matcher nm = namePat.matcher(lines.get(start));
            String fname = nm.find() ? nm.group(1) : null;
            segments.add(new Segment(fname, segLines));
        }

        return new ParsedLib(globals, segments);
    }
}
