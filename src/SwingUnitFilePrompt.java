import javax.swing.JFileChooser;
import javax.swing.JFrame;
import javax.swing.JOptionPane;
import javax.swing.SwingUtilities;
import javax.swing.filechooser.FileNameExtensionFilter;
import java.lang.reflect.InvocationTargetException;
import java.nio.file.Path;
import java.util.Locale;

/** Swing implementation of {@link UnitFilePrompt}: confirm dialog + file chooser. */
final class SwingUnitFilePrompt implements UnitFilePrompt {

    private final JFrame frame;

    SwingUnitFilePrompt(JFrame frame) {
        this.frame = frame;
    }

    /**
     * May be called from a background thread (the conversion runs in a SwingWorker).
     * The dialogs are always created and run on the Event Dispatch Thread; the caller
     * blocks until the user has answered.
     */
    @Override
    public Path requestUnitDataFile() {
        if (SwingUtilities.isEventDispatchThread()) {
            return showDialogs();
        }
        Path[] result = new Path[1];
        try {
            SwingUtilities.invokeAndWait(() -> result[0] = showDialogs());
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return null;
        } catch (InvocationTargetException e) {
            return null;
        }
        return result[0];
    }

    private Path showDialogs() {
        int choice = JOptionPane.showConfirmDialog(
                frame,
                "DzSetUnitModel detected.\n" +
                "Input unit.ini or UnitStrings.txt to populate BlzSetUnitSkin data?",
                "DzSetUnitModel",
                JOptionPane.YES_NO_OPTION,
                JOptionPane.QUESTION_MESSAGE);
        if (choice != JOptionPane.YES_OPTION) {
            return null;
        }

        JFileChooser chooser = new JFileChooser();
        chooser.setDialogTitle("Select unit.ini or UnitStrings.txt");
        chooser.setFileFilter(new FileNameExtensionFilter(
                "Unit data (*.ini, *.txt)", "ini", "txt"));
        chooser.setAcceptAllFileFilterUsed(false);
        if (chooser.showOpenDialog(frame) != JFileChooser.APPROVE_OPTION) {
            return null;
        }

        Path unitDataFile = chooser.getSelectedFile().toPath();
        String name = unitDataFile.getFileName().toString().toLowerCase(Locale.ROOT);
        if (!name.endsWith(".ini") && !name.endsWith(".txt")) {
            JOptionPane.showMessageDialog(frame,
                    "Only .ini or .txt files are accepted.",
                    "Invalid file",
                    JOptionPane.ERROR_MESSAGE);
            return null;
        }
        return unitDataFile;
    }
}
