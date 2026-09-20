import java.util.List;
import java.util.Map;

/** Result of parsing one DzCompat_*.j library file. */
    final class ParsedLib {
        final Map<String, String> globals; // varName -> declaration line
        final List<Segment> segments;
        ParsedLib(Map<String, String> globals, List<Segment> segments) {
            this.globals = globals;
            this.segments = segments;
        }
    }
