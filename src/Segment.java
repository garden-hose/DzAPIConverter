import java.util.List;

/** One top-level function of a library (.j) file: its name and its source lines. */
    final class Segment {
        final String name;
        final List<String> lines;
        Segment(String name, List<String> lines) {
            this.name = name;
            this.lines = lines;
        }
    }
