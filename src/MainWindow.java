import com.formdev.flatlaf.FlatDarkLaf;

import javax.swing.*;
import javax.swing.border.EmptyBorder;
import javax.swing.filechooser.FileNameExtensionFilter;
import javax.swing.text.NumberFormatter;
import java.awt.*;
import java.awt.event.ActionEvent;
import java.io.File;
import java.io.IOException;
import java.text.NumberFormat;
import java.util.List;
import java.util.Optional;
import java.util.Properties;

/**
 * Swing front-end: path pickers, stub options, Convert / Reverse buttons and a console.
 * All conversion work is delegated to {@link ForwardConverter} / {@link ReverseConverter}.
 */
final class MainWindow {

    private JFrame frame;
    private JSpinner getMapLevelSpinner;

    // -------------------------------------------------------------------------
    // UI components
    // -------------------------------------------------------------------------
    private final JTextField inputField = new JTextField();
    private final JTextField outputField = new JTextField();
    /** Folder with the map's W3x2lni table ini files; feeds EXExecuteScript (jass.slk) conversion. */
    private final JTextField mapTableInputField = new JTextField();
    private final JComboBox<String> hasMallItemCombo = new JComboBox<>(new String[]{"True", "False"});

    private final JTextField getGuildNameField = new JTextField();
    /** When checked, the GetMapLevel/HasMallItem/GetGuildName fields are editable
     *  and their UI values are used as stub returns instead of the real
     *  archive-backed implementations. When unchecked (default), those three
     *  natives use their real implementations and the fields are disabled. */
    private final JCheckBox unlockCheckbox = new JCheckBox("Overrides");
    private final JButton convertButton = new JButton("Convert");
    private final JButton reverseButton = new JButton("Reverse Functions");
    /** When checked, Convert first removes "native dz..." declarations the script never uses. */
	private final JCheckBox clearUnusedNativesCheckbox = new JCheckBox("Clear unused natives", true);
    /** When checked, Convert strips leading spaces/tabs from every line of the converted script. */
    private final JCheckBox removeIndentationCheckbox = new JCheckBox("Remove indentation", false);
    private final JTextArea consoleArea = new JTextArea();
    private final JFileChooser fileChooser = new JFileChooser();

    // Stub options read from the UI when Convert is pressed
    private final ConversionSettings settings = new ConversionSettings();

    /** Build and show the GUI */
    public void showGui() {
        // Set FlatLaf Dark Theme
        try {
            UIManager.setLookAndFeel(new FlatDarkLaf());
        } catch (UnsupportedLookAndFeelException e) {
            e.printStackTrace();
        }

        frame = new JFrame("DzAPI Converter");
        frame.setDefaultCloseOperation(JFrame.EXIT_ON_CLOSE);
        frame.setMinimumSize(new Dimension(720, 520));
        frame.setLocationRelativeTo(null);

        fileChooser.setFileFilter(new FileNameExtensionFilter(
            "JASS / Text files (*.j, *.txt, *)", "j", "txt"));
        fileChooser.setAcceptAllFileFilterUsed(true);

        buildUI();
        wireEvents();
        loadSettings(); // Load settings on startup

        // Save settings on window close
        frame.addWindowListener(new java.awt.event.WindowAdapter() {
            @Override
            public void windowClosing(java.awt.event.WindowEvent e) {
                saveSettings();
                super.windowClosing(e);
            }
        });

        frame.setVisible(true);
    }

    private void buildUI() {
        JPanel root = new JPanel(new BorderLayout(8, 8));
        root.setBorder(new EmptyBorder(12, 12, 12, 12));

        // --- top: path selectors ---
        JPanel pathsPanel = new JPanel();
        pathsPanel.setLayout(new BoxLayout(pathsPanel, BoxLayout.Y_AXIS));

        pathsPanel.add(makePathRow("Map script path:", inputField, e -> chooseInput()));
		inputField.setToolTipText("Input path to the map script (war3map.j)");
        pathsPanel.add(Box.createVerticalStrut(8));
        pathsPanel.add(makePathRow("Output path:", outputField, e -> chooseOutput()));
		outputField.setToolTipText("Output path to the converted map script");
        pathsPanel.add(Box.createVerticalStrut(8));
        pathsPanel.add(makePathRow("Map table path:", mapTableInputField, e -> chooseMapTableFolder()));
        mapTableInputField.setToolTipText(
            "Folder with the map's table ini files (W3x2lni: item.ini, unit.ini, ...). " +
            "Used to bake the object data that EXExecuteScript reads through jass.slk. " +
            "If this is empty, or the folder has no table .ini files, EXExecuteScript is not converted.");

        // --- red warning row under Map table path ---
        JPanel warningRow = new JPanel(new FlowLayout(FlowLayout.LEFT, 0, 0));
        JLabel warningLabel = new JLabel(
            "IMPORTANT: Extract your map's tables (Unit.ini, ability.ini, item.ini, etc.) " +
            "to a folder and set the folder in \"Map table path\" field");
        warningLabel.setForeground(Color.RED);
        warningRow.add(warningLabel);
        pathsPanel.add(warningRow);
        pathsPanel.add(Box.createVerticalStrut(8));
		
        // --- stub option fields ---
        JPanel optionsPanel = new JPanel(new GridBagLayout());
        optionsPanel.setBorder(BorderFactory.createTitledBorder("Native Overrides"));
        GridBagConstraints gc = new GridBagConstraints();
        gc.insets = new Insets(4, 6, 4, 6);
        gc.anchor = GridBagConstraints.WEST;
        gc.fill = GridBagConstraints.HORIZONTAL;

        // Row 0: "Override" checkbox (default off) — gates the three stub fields below.
        unlockCheckbox.setSelected(false);
        unlockCheckbox.setToolTipText(
            "When enabled, GetMapLevel / HasMallItem / GetGuildName get overwritten " +
            "values typed below. When disabled (default), those three natives use " +
            "their real archive-backed implementations.");
        gc.gridx = 0; gc.gridy = 0; gc.gridwidth = 5; gc.weightx = 1;
        optionsPanel.add(unlockCheckbox, gc);
        gc.gridwidth = 1;

        // Row 1: HasMallItem dropdown
        hasMallItemCombo.setSelectedItem("True");
        hasMallItemCombo.setPreferredSize(new Dimension(100, 24));
        gc.gridx = 0; gc.gridy = 1; gc.weightx = 0;
        optionsPanel.add(new JLabel("HasMallItem:"), gc);
        gc.gridx = 1; gc.weightx = 0;
        optionsPanel.add(hasMallItemCombo, gc);

        // Row 1 (cont.): GetMapLevel spinner, input limited
        getMapLevelSpinner = new JSpinner(new SpinnerNumberModel(0, 0, 999, 1));
        getMapLevelSpinner.setPreferredSize(new Dimension(80, 24));

        // Configure formatter
        JSpinner.NumberEditor editor = (JSpinner.NumberEditor) getMapLevelSpinner.getEditor();
        NumberFormat format = NumberFormat.getIntegerInstance();
        format.setGroupingUsed(false);
        NumberFormatter formatter = new NumberFormatter(format);
        formatter.setValueClass(Integer.class);
        formatter.setMinimum(0);
        formatter.setMaximum(999);
        formatter.setAllowsInvalid(false); // Reject invalid input

        // Apply the formatter
        editor.getTextField().setFormatterFactory(new javax.swing.text.DefaultFormatterFactory(formatter));

        gc.gridx = 2; gc.weightx = 0;
        optionsPanel.add(new JLabel("GetMapLevel:"), gc);
        gc.gridx = 3; gc.weightx = 0;
        optionsPanel.add(getMapLevelSpinner, gc);

        gc.gridx = 4; gc.weightx = 1;
        optionsPanel.add(Box.createHorizontalGlue(), gc);

        // Row 2: GetGuildName text field, max 255 chars
        getGuildNameField.setColumns(24);
        getGuildNameField.setToolTipText("Return value for DzAPI_Map_GetGuildName (max 255 characters)");
        ((javax.swing.text.AbstractDocument) getGuildNameField.getDocument())
            .setDocumentFilter(new LengthFilter(255));
        gc.gridx = 0; gc.gridy = 2; gc.weightx = 0;
        optionsPanel.add(new JLabel("GetGuildName:"), gc);
        gc.gridx = 1; gc.gridy = 2; gc.gridwidth = 4; gc.weightx = 1;
        optionsPanel.add(getGuildNameField, gc);
        gc.gridwidth = 1;

        // --- convert / reverse buttons ---
        JPanel buttonPanel = new JPanel(new FlowLayout(FlowLayout.LEFT, 12, 0));
        convertButton.setPreferredSize(new Dimension(140, 32));
        convertButton.setFont(convertButton.getFont().deriveFont(Font.BOLD));
        reverseButton.setPreferredSize(new Dimension(160, 32));
        reverseButton.setFont(reverseButton.getFont().deriveFont(Font.BOLD));
        reverseButton.setToolTipText(
            "Convert matching functions back to native declarations using signatures from KKAPI.txt");
        clearUnusedNativesCheckbox.setToolTipText(
            "Convert only: first removes every \"native dz...\" declaration that is declared " +
            "in the script but never used anywhere else.");
        removeIndentationCheckbox.setToolTipText(
            "Convert only: strips leading spaces and tabs from every line of the converted map script.");
        buttonPanel.add(convertButton);
        buttonPanel.add(reverseButton);
        buttonPanel.add(clearUnusedNativesCheckbox);
        buttonPanel.add(removeIndentationCheckbox);
        buttonPanel.setBorder(new EmptyBorder(10, 0, 6, 0));

        JPanel north = new JPanel(new BorderLayout());
        north.add(pathsPanel, BorderLayout.NORTH);
        north.add(optionsPanel, BorderLayout.CENTER);
        north.add(buttonPanel, BorderLayout.SOUTH);

        // --- console ---
        consoleArea.setEditable(false);
        consoleArea.setFont(new Font(Font.MONOSPACED, Font.PLAIN, 12));
        consoleArea.setLineWrap(false);
        JScrollPane scroll = new JScrollPane(consoleArea);
        scroll.setBorder(BorderFactory.createTitledBorder("Console"));
        scroll.setPreferredSize(new Dimension(0, 240));

        root.add(north, BorderLayout.NORTH);
        root.add(scroll, BorderLayout.CENTER);
        frame.setContentPane(root);
        frame.pack();
        frame.setSize(760, 612);
        
        wireUnlockToggle();
    }

    private JPanel makePathRow(String label, JTextField field, java.awt.event.ActionListener browseAction) {
        JPanel row = new JPanel(new BorderLayout(6, 0));
        JLabel lbl = new JLabel(label);
        lbl.setPreferredSize(new Dimension(130, 24));
        field.setEditable(true);
        JButton browse = new JButton("Browse…");
        browse.addActionListener(browseAction);
        row.add(lbl, BorderLayout.WEST);
        row.add(field, BorderLayout.CENTER);
        row.add(browse, BorderLayout.EAST);
        return row;
    }

    private void wireEvents() {
        convertButton.addActionListener(this::onConvert);
        reverseButton.addActionListener(this::onReverse);
    }

    private void chooseInput() {
        fileChooser.setDialogTitle("Select input JASS script");
        fileChooser.setFileSelectionMode(JFileChooser.FILES_ONLY);
        if (fileChooser.showOpenDialog(frame) == JFileChooser.APPROVE_OPTION) {
            File f = fileChooser.getSelectedFile();
            inputField.setText(f.getAbsolutePath());
            // Suggest an output path next to the input if empty
            if (outputField.getText().trim().isEmpty()) {
                String name = f.getName();
                int dot = name.lastIndexOf('.');
                String base = (dot > 0) ? name.substring(0, dot) : name;
                String out = new File(f.getParentFile(), base + "_converted.j").getAbsolutePath();
                outputField.setText(out);
            }
        }
    }

    private void chooseOutput() {
        fileChooser.setDialogTitle("Select output file");
        fileChooser.setFileSelectionMode(JFileChooser.FILES_ONLY);
        if (fileChooser.showSaveDialog(frame) == JFileChooser.APPROVE_OPTION) {
            outputField.setText(fileChooser.getSelectedFile().getAbsolutePath());
        }
    }

    private void chooseMapTableFolder() {
        JFileChooser chooser = new JFileChooser();
        chooser.setDialogTitle("Select the map table folder (item.ini, unit.ini, ...)");
        chooser.setFileSelectionMode(JFileChooser.DIRECTORIES_ONLY);
        File current = new File(mapTableInputField.getText().trim());
        File inputParent = new File(inputField.getText().trim()).getParentFile();
        if (current.isDirectory()) {
            chooser.setSelectedFile(current);
        } else if (inputParent != null && inputParent.isDirectory()) {
            chooser.setCurrentDirectory(inputParent);
        }
        if (chooser.showOpenDialog(frame) == JFileChooser.APPROVE_OPTION) {
            mapTableInputField.setText(chooser.getSelectedFile().getAbsolutePath());
        }
    }

    private void onConvert(ActionEvent e) {
        String inPath = inputField.getText().trim();
        String outPath = outputField.getText().trim();

        if (inPath.isEmpty() || outPath.isEmpty()) {
            log("ERROR: Please select both input and output paths.");
            return;
        }
        File inFile = new File(inPath);
        if (!inFile.isFile()) {
            log("ERROR: Input file does not exist: " + inPath);
            return;
        }

        // Table folder for EXExecuteScript; empty = EXExecuteScript is not converted
        final String tablePath = mapTableInputField.getText().trim();
        if (!tablePath.isEmpty() && !new File(tablePath).isDirectory()) {
            log("ERROR: Map table folder does not exist: " + tablePath);
            return;
        }
        final SlkTablePrompt tablePrompt =
                suggested -> tablePath.isEmpty() ? null : new File(tablePath).toPath();

        // Read stub options from UI
        settings.stubHasMallItem = "True".equals(hasMallItemCombo.getSelectedItem());
        try {
            getMapLevelSpinner.commitEdit();
        } catch (java.text.ParseException ignored) {}
        Object levelVal = getMapLevelSpinner.getValue();
        settings.stubGetMapLevel = (levelVal instanceof Number) ? ((Number) levelVal).intValue() : 0;
        if (settings.stubGetMapLevel < 0) settings.stubGetMapLevel = 0;
        if (settings.stubGetMapLevel > 999) settings.stubGetMapLevel = 999;
        settings.stubGetGuildName = getGuildNameField.getText();
        if (settings.stubGetGuildName.length() > 255) {
            settings.stubGetGuildName = settings.stubGetGuildName.substring(0, 255);
        }
        settings.unlockStubs = unlockCheckbox.isSelected();
        settings.clearUnusedNatives = clearUnusedNativesCheckbox.isSelected();
        settings.removeIndentation = removeIndentationCheckbox.isSelected();

        // Save settings after reading UI values
        saveSettings();

        convertButton.setEnabled(false);
        reverseButton.setEnabled(false);
        consoleArea.setText("");
        log("Map script path: " + inPath);
        log("Output path: " + outPath);
        log("Map table path: " + (tablePath.isEmpty() ? "(none - EXExecuteScript will not be converted)" : tablePath));
        log("Clear unused natives = " + settings.clearUnusedNatives);
        log("Remove indentation = " + settings.removeIndentation);
        log("Overrides = " + settings.unlockStubs);

        // Run conversion off the EDT
        new SwingWorker<Void, String>() {
            @Override
            protected Void doInBackground() {
                try {
                    new ForwardConverter(settings, tablePrompt)
                            .run(inPath, outPath, this::publish);
                } catch (Exception ex) {
                    publish("ERROR: " + ex.getMessage());
                    ex.printStackTrace();
                }
                return null;
            }

            @Override
            protected void process(List<String> chunks) {
                for (String s : chunks) {
                    appendLog(s);
                }
            }

            @Override
            protected void done() {
                convertButton.setEnabled(true);
                reverseButton.setEnabled(true);
                // Save settings after successful conversion
                saveSettings();
            }
        }.execute();
    }

    private void onReverse(ActionEvent e) {
        String inPath = inputField.getText().trim();
        String outPath = outputField.getText().trim();

        if (inPath.isEmpty() || outPath.isEmpty()) {
            log("ERROR: Please select both input and output paths.");
            return;
        }
        File inFile = new File(inPath);
        if (!inFile.isFile()) {
            log("ERROR: Input file does not exist: " + inPath);
            return;
        }

        saveSettings();

        convertButton.setEnabled(false);
        reverseButton.setEnabled(false);
        consoleArea.setText("");
        log("Map script path: " + inPath);
        log("Output path: " + outPath);
        log("Mode: Reverse Natives (functions → natives from KKAPI.txt)");

        new SwingWorker<Void, String>() {
            @Override
            protected Void doInBackground() {
                try {
                    new ReverseConverter().run(inPath, outPath, this::publish);
                } catch (Exception ex) {
                    publish("ERROR: " + ex.getMessage());
                    ex.printStackTrace();
                }
                return null;
            }

            @Override
            protected void process(List<String> chunks) {
                for (String s : chunks) {
                    appendLog(s);
                }
            }

            @Override
            protected void done() {
                convertButton.setEnabled(true);
                reverseButton.setEnabled(true);
                saveSettings();
            }
        }.execute();
    }

    private void loadSettings() {
        Properties props;
        try {
            Optional<Properties> stored = SettingsStore.load();
            if (!stored.isPresent()) return;
            props = stored.get();
        } catch (IOException e) {
            log("Failed to load settings: " + e.getMessage());
            return;
        }

        inputField.setText(props.getProperty("inputFieldPath", ""));
        outputField.setText(props.getProperty("outputFieldPath", ""));
        mapTableInputField.setText(props.getProperty("mapTableInputPath", ""));

        String stubHasMallItemStr = props.getProperty("stubHasMallItem", "true");
        hasMallItemCombo.setSelectedItem(stubHasMallItemStr);
        String stubGetMapLevelStr = props.getProperty("stubGetMapLevel", "99");
        try {
            getMapLevelSpinner.setValue(Integer.parseInt(stubGetMapLevelStr));
        } catch (NumberFormatException e) {
            getMapLevelSpinner.setValue(0);
        }
        getGuildNameField.setText(props.getProperty("stubGetGuildName", "Warcraft III"));

        clearUnusedNativesCheckbox.setSelected(Boolean.parseBoolean(
            props.getProperty("clearUnusedNatives", "true")));
        removeIndentationCheckbox.setSelected(Boolean.parseBoolean(
            props.getProperty("removeIndentation", "false")));

        // Apply the Unlock gate last, so it locks/unlocks the fields only
        // after their saved values have been restored.
        unlockCheckbox.setSelected(Boolean.parseBoolean(
            props.getProperty("unlockStubs", "false")));
        applyUnlockState();
    }

    private void saveSettings() {
        Properties props = new Properties();
        props.setProperty("inputFieldPath", inputField.getText().trim());
        props.setProperty("outputFieldPath", outputField.getText().trim());
        props.setProperty("mapTableInputPath", mapTableInputField.getText().trim());
        props.setProperty("unlockStubs", Boolean.toString(unlockCheckbox.isSelected()));
        props.setProperty("clearUnusedNatives", Boolean.toString(clearUnusedNativesCheckbox.isSelected()));
        props.setProperty("removeIndentation", Boolean.toString(removeIndentationCheckbox.isSelected()));
        props.setProperty("stubHasMallItem", (hasMallItemCombo.getSelectedItem() != null) ? hasMallItemCombo.getSelectedItem().toString() : "true");
        Object levelVal = getMapLevelSpinner.getValue();
        props.setProperty("stubGetMapLevel", (levelVal instanceof Number) ? levelVal.toString() : "99");
        props.setProperty("stubGetGuildName", getGuildNameField.getText().trim());
        try {
            SettingsStore.save(props);
        } catch (IOException e) {
            log("Failed to save settings: " + e.getMessage());
        }
    }

    private void log(String msg) {
        // Called from EDT for immediate feedback
        appendLog(msg);
    }

    private void appendLog(String msg) {
        String ts = Timestamps.now();
        // If the message already starts with a bracketed timestamp from the converter, keep it
        if (msg.startsWith("[")) {
            consoleArea.append(msg + "\n");
        } else {
            consoleArea.append("[" + ts + "] " + msg + "\n");
        }
        consoleArea.setCaretPosition(consoleArea.getDocument().getLength());
    }

    /** Enable/disable the three gated stub fields based on unlockCheckbox. */
    private void wireUnlockToggle() {
        unlockCheckbox.addActionListener(e -> applyUnlockState());
        applyUnlockState();
    }
    
    /** Push unlockCheckbox's current state onto the three gated fields. */
    private void applyUnlockState() {
        boolean on = unlockCheckbox.isSelected();
        hasMallItemCombo.setEnabled(on);
        getMapLevelSpinner.setEnabled(on);
        getGuildNameField.setEnabled(on);
        // Keep the tooltip in sync so the user can always see why they're greyed out.
        String tip = on
            ? "Overrides value will be used."
            : "Disabled — real archive-backed implementation will be used. Enable \"Override\" to override.";
        hasMallItemCombo.setToolTipText(tip);
        getMapLevelSpinner.setToolTipText(tip);
        getGuildNameField.setToolTipText(tip);
    }
}
