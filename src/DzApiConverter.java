import com.formdev.flatlaf.FlatDarkLaf;

import java.nio.file.Path;
import java.nio.file.Paths;
import javax.swing.SwingUtilities;
import javax.swing.UIManager;
import javax.swing.UnsupportedLookAndFeelException;

/**
 * DzAPI Convert
 *
 * Converts a Warcraft 3 map JASS script by replacing Dz* native declarations
 * with real Reforged-compatible implementations (from lib/) or dummy stubs.
 */
public class DzApiConverter {

    // -------------------------------------------------------------------------
    // Entry point
    // -------------------------------------------------------------------------
    public static void main(String[] args) {
        // CLI mode: java DzApiConverter <input> <output> [tableFolder]
        //   tableFolder: W3x2lni table\ folder for EXExecuteScript (jass.slk) data;
        //   when omitted (or without table .ini files) EXExecuteScript is not converted.
        // CLI reverse: java DzApiConverter <input> <output> reverse
        if (args.length == 2 || args.length == 3) {
            try {
                if (args.length == 3 && "reverse".equalsIgnoreCase(args[2])) {
                    new ReverseConverter().run(args[0], args[1], msg -> System.out.println(msg));
                } else {
                    SlkTablePrompt tables = null;
                    if (args.length == 3) {
                        Path tableFolder = Paths.get(args[2]);
                        tables = suggested -> tableFolder;
                    }
                    new ForwardConverter(new ConversionSettings(), tables)
                            .run(args[0], args[1], msg -> System.out.println(msg));
                }
            } catch (Exception e) {
                System.err.println("ERROR: " + e.getMessage());
                e.printStackTrace();
                System.exit(1);
            }
            return;
        }

        // GUI mode with dark theme
        SwingUtilities.invokeLater(() -> {
            try {
                UIManager.setLookAndFeel(new FlatDarkLaf());
            } catch (UnsupportedLookAndFeelException ignored) {}
            new MainWindow().showGui();
        });
    }
}
