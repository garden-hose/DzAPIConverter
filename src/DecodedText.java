import java.nio.charset.Charset;
import java.util.List;

    /** Result of decoding a text file: lines + the charset that worked best. */
    final class DecodedText {
        final List<String> lines;
        final Charset charset;
        DecodedText(List<String> lines, Charset charset) {
            this.lines = lines;
            this.charset = charset;
        }
    }
