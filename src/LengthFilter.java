/** DocumentFilter that rejects input beyond maxLen characters. */
    final class LengthFilter extends javax.swing.text.DocumentFilter {
        private final int maxLen;
        LengthFilter(int maxLen) { this.maxLen = maxLen; }
        @Override
        public void insertString(FilterBypass fb, int offset, String string, javax.swing.text.AttributeSet attr)
                throws javax.swing.text.BadLocationException {
            if (string == null) return;
            if (fb.getDocument().getLength() + string.length() <= maxLen) {
                super.insertString(fb, offset, string, attr);
            }
        }
        @Override
        public void replace(FilterBypass fb, int offset, int length, String text, javax.swing.text.AttributeSet attrs)
                throws javax.swing.text.BadLocationException {
            if (text == null) return;
            if (fb.getDocument().getLength() - length + text.length() <= maxLen) {
                super.replace(fb, offset, length, text, attrs);
            }
        }
    }
