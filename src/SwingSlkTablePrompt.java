import javax.swing.JFileChooser;
import javax.swing.JFrame;
import javax.swing.JOptionPane;
import javax.swing.SwingUtilities;
import java.lang.reflect.InvocationTargetException;
import java.nio.file.Files;
import java.nio.file.Path;

/** Swing implementation of {@link SlkTablePrompt}: confirm dialog + folder chooser. */
final class SwingSlkTablePrompt implements SlkTablePrompt {

    private final JFrame frame;

    SwingSlkTablePrompt(JFrame frame) {
        this.frame = frame;
    }

    /**
     * May be called from a background thread (the conversion runs in a SwingWorker).
     * The dialogs are always created and run on the Event Dispatch Thread; the caller
     * blocks until the user has answered.
     */
    @Override
    public Path requestTableFolder(Path suggested) {
        if (SwingUtilities.isEventDispatchThread()) {
            return showDialogs(suggested);
        }
        Path[] result = new Path[1];
        try {
            SwingUtilities.invokeAndWait(() -> result[0] = showDialogs(suggested));
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return null;
        } catch (InvocationTargetException e) {
            return null;
        }
        return result[0];
    }

    private Path showDialogs(Path suggested) {
        String hint = suggested != null
                ? "\nFound a table folder next to the script:\n" + suggested + "\n"
                : "";
        int choice = JOptionPane.showConfirmDialog(
                frame,
                "EXExecuteScript reading jass.slk object data detected.\n" +
                "Select the map's table folder (W3x2lni item.ini, unit.ini, ...)\n" +
                "so the data it reads can be baked into the script?" + hint,
                "EXExecuteScript",
                JOptionPane.YES_NO_OPTION,
                JOptionPane.QUESTION_MESSAGE);
        if (choice != JOptionPane.YES_OPTION) {
            return null;
        }

        JFileChooser chooser = new JFileChooser();
        chooser.setDialogTitle("Select the table folder (containing item.ini, unit.ini, ...)");
        chooser.setFileSelectionMode(JFileChooser.DIRECTORIES_ONLY);
        if (suggested != null) {
            chooser.setCurrentDirectory(suggested.toFile().getParentFile());
            chooser.setSelectedFile(suggested.toFile());
        }
        if (chooser.showOpenDialog(frame) != JFileChooser.APPROVE_OPTION) {
            return null;
        }

        Path dir = chooser.getSelectedFile().toPath();
        if (!Files.isDirectory(dir)) {
            JOptionPane.showMessageDialog(frame,
                    "Please select a folder.",
                    "Invalid selection",
                    JOptionPane.ERROR_MESSAGE);
            return null;
        }
        return dir;
    }
}
