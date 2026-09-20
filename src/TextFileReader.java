import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.Charset;
import java.nio.charset.CharsetDecoder;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Lenient, encoding-sniffing text file reader for map scripts. */
final class TextFileReader {

    private TextFileReader() {}

    /**
     * Read a text file without requiring the user to change encoding.
     * Tries UTF-8, GB18030, GBK, etc. Picks the best clean decode.
     * Never fails on encoding: worst case uses REPLACE so conversion still runs.
     * Output is later written with the same charset.
     */
    static DecodedText readLenient(Path path, Logger logger) throws IOException {
        byte[] bytes = Files.readAllBytes(path);

        // Quick binary sniff: lots of null bytes → almost certainly not JASS text
        int nullCount = 0;
        int sample = Math.min(bytes.length, 4096);
        for (int i = 0; i < sample; i++) {
            if (bytes[i] == 0) nullCount++;
        }
        if (sample > 100 && nullCount > sample / 20) {
            throw new IOException(
                "File looks binary (many null bytes). This tool needs a plain-text JASS script\n" +
                "(usually war3map.j extracted from the map), not a .w3x/.w3m archive or other binary."
            );
        }

        Charset[] tryOrder = buildCharsetTryOrder();
        Charset bestCs = null;
        String bestText = null;
        int bestScore = Integer.MIN_VALUE;

        for (Charset cs : tryOrder) {
            try {
                // Strict first – prefer a charset that decodes without errors
                CharsetDecoder strict = cs.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT);
                String text = strict.decode(ByteBuffer.wrap(bytes)).toString();
                int score = scoreDecodedText(text) + 1_000_000; // huge bonus for clean decode
                if (score > bestScore) {
                    bestScore = score;
                    bestCs = cs;
                    bestText = text;
                }
            } catch (CharacterCodingException e) {
                // Fall through to lenient decode for scoring only
                try {
                    CharsetDecoder lenient = cs.newDecoder()
                        .onMalformedInput(CodingErrorAction.REPLACE)
                        .onUnmappableCharacter(CodingErrorAction.REPLACE);
                    String text = lenient.decode(ByteBuffer.wrap(bytes)).toString();
                    int score = scoreDecodedText(text);
                    if (score > bestScore) {
                        bestScore = score;
                        bestCs = cs;
                        bestText = text;
                    }
                } catch (Exception ignored) {}
            }
        }

        if (bestText == null || bestCs == null) {
            // Absolute fallback – cannot fail
            bestCs = StandardCharsets.ISO_8859_1;
            bestText = new String(bytes, bestCs);
            logger.log("WARNING: Fell back to ISO-8859-1 for reading.");
        } else if (!bestCs.equals(StandardCharsets.UTF_8)) {
            logger.log("[" + Timestamps.now() + "] Detected encoding: " + bestCs.name() +
                       " (file left unchanged; output will use the same encoding)");
        } else {
            logger.log("[" + Timestamps.now() + "] Detected encoding: UTF-8");
        }

        bestText = bestText.replace("\r\n", "\n").replace('\r', '\n');
        List<String> lines = new ArrayList<>(Arrays.asList(bestText.split("\n", -1)));
        return new DecodedText(lines, bestCs);
    }

    /** Higher score = more likely to be a real JASS script with good encoding. */
    private static int scoreDecodedText(String text) {
        int score = 0;
        // Penalize replacement characters (U+FFFD)
        for (int i = 0; i < text.length(); i++) {
            if (text.charAt(i) == '\uFFFD') score -= 50;
        }
        // Reward JASS keywords
        String sample = text.length() > 200_000 ? text.substring(0, 200_000) : text;
        if (sample.contains("globals")) score += 100;
        if (sample.contains("endglobals")) score += 100;
        if (sample.contains("function ")) score += 80;
        if (sample.contains("native ")) score += 80;
        if (sample.contains("endfunction")) score += 60;
        if (sample.contains("takes ")) score += 40;
        if (sample.contains("returns ")) score += 40;
        return score;
    }

    private static Charset[] buildCharsetTryOrder() {
        List<Charset> list = new ArrayList<>();
        list.add(StandardCharsets.UTF_8);
        for (String name : new String[]{"GB18030", "GBK", "GB2312", "Big5", "windows-1252", "ISO-8859-1"}) {
            try {
                list.add(Charset.forName(name));
            } catch (Exception ignored) {}
        }
        return list.toArray(new Charset[0]);
    }
}
