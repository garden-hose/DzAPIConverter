import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.Optional;
import java.util.Properties;

/** Reads/writes the GUI settings file in the current working directory. */
final class SettingsStore {

    private SettingsStore() {}

    // Location of settings file in current working directory
    private static final String SETTINGS_FILE = "settings.txt";

    /** @return the stored properties, or empty if no settings file exists yet. */
    static Optional<Properties> load() throws IOException {
        File file = new File(SETTINGS_FILE);
        if (!file.exists()) return Optional.empty();
        Properties props = new Properties();
        try (FileInputStream fis = new FileInputStream(file)) {
            props.load(fis);
        }
        return Optional.of(props);
    }

    static void save(Properties props) throws IOException {
        try (FileOutputStream fos = new FileOutputStream(SETTINGS_FILE)) {
            props.store(fos, "DzAPI Converter Settings");
        }
    }
}
