import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;

/** Timestamp helper used for log lines. */
final class Timestamps {

    private Timestamps() {}

    static String now() {
        return LocalDateTime.now().format(DateTimeFormatter.ofPattern("dd-MM-yyyy HH:mm:ss"));
    }
}
