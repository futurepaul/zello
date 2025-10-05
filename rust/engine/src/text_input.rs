use std::collections::HashMap;
use std::ops::Range;

/// IME composition (preedit) state
#[derive(Default, Clone)]
pub struct ImeComposition {
    pub text: String,
    pub cursor_offset: usize,  // Cursor position within preedit text
}

/// State for a single text input widget
#[derive(Default)]
pub struct TextInputState {
    pub content: String,
    pub cursor: usize,  // Byte offset in UTF-8
    pub selection: Option<Range<usize>>,
    pub selection_anchor: Option<usize>,  // Where the selection started (for drag selection)
    pub ime_composition: Option<ImeComposition>,  // Active IME composition
}

impl TextInputState {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn insert_char(&mut self, ch: char) {
        // Delete selection if present
        if let Some(sel) = &self.selection {
            self.content.drain(sel.clone());
            self.cursor = sel.start;
            self.selection = None;
        }

        // Insert character at cursor
        self.content.insert(self.cursor, ch);
        self.cursor += ch.len_utf8();
    }

    pub fn backspace(&mut self) {
        if let Some(sel) = &self.selection {
            // Delete selection
            self.content.drain(sel.clone());
            self.cursor = sel.start;
            self.selection = None;
        } else if self.cursor > 0 {
            // Find previous grapheme boundary (simplified: just use char boundary)
            let prev = previous_char_boundary(&self.content, self.cursor);
            self.content.drain(prev..self.cursor);
            self.cursor = prev;
        }
    }

    pub fn delete(&mut self) {
        if let Some(sel) = &self.selection {
            // Delete selection
            self.content.drain(sel.clone());
            self.cursor = sel.start;
            self.selection = None;
        } else if self.cursor < self.content.len() {
            // Find next grapheme boundary (simplified: just use char boundary)
            let next = next_char_boundary(&self.content, self.cursor);
            self.content.drain(self.cursor..next);
        }
    }

    pub fn move_cursor_left(&mut self) {
        if self.cursor > 0 {
            self.cursor = previous_char_boundary(&self.content, self.cursor);
        }
    }

    pub fn move_cursor_right(&mut self) {
        if self.cursor < self.content.len() {
            self.cursor = next_char_boundary(&self.content, self.cursor);
        }
    }

    pub fn move_cursor_home(&mut self) {
        self.cursor = 0;
    }

    pub fn move_cursor_end(&mut self) {
        self.cursor = self.content.len();
    }

    pub fn set_cursor(&mut self, position: usize) {
        // Clamp to valid range and ensure on char boundary
        self.cursor = position.min(self.content.len());
        while !self.content.is_char_boundary(self.cursor) && self.cursor > 0 {
            self.cursor -= 1;
        }
    }

    pub fn insert_text(&mut self, text: &str) {
        // Delete selection if present
        if let Some(sel) = &self.selection {
            self.content.drain(sel.clone());
            self.cursor = sel.start;
            self.selection = None;
        }

        // Insert text at cursor
        self.content.insert_str(self.cursor, text);
        self.cursor += text.len();
    }

    pub fn set_text(&mut self, text: &str) {
        self.content = text.to_string();
        self.cursor = self.content.len();
        self.selection = None;
    }

    /// Start a selection at the current cursor position
    pub fn start_selection(&mut self) {
        self.selection = Some(self.cursor..self.cursor);
    }

    /// Extend selection to a specific byte position
    pub fn extend_selection_to(&mut self, position: usize) {
        let pos = position.min(self.content.len());
        let pos = ensure_char_boundary(&self.content, pos);

        // Get or set the anchor point (where selection started)
        let anchor = self.selection_anchor.unwrap_or(self.cursor);

        eprintln!("extend_selection_to: pos={}, anchor={}, cursor={}", pos, anchor, self.cursor);

        // Create selection from anchor to current position
        let start = anchor.min(pos);
        let end = anchor.max(pos);

        eprintln!("  selection range: {}..{}", start, end);

        if start < end {
            self.selection = Some(start..end);
            eprintln!("  SET selection to {:?}", self.selection);
        } else {
            self.selection = None;
            eprintln!("  CLEARED selection (start >= end)");
        }

        self.cursor = pos;
        self.selection_anchor = Some(anchor);
    }

    /// Set selection to a specific range
    pub fn set_selection(&mut self, start: usize, end: usize, cursor: usize) {
        let start = ensure_char_boundary(&self.content, start.min(self.content.len()));
        let end = ensure_char_boundary(&self.content, end.min(self.content.len()));
        let cursor = ensure_char_boundary(&self.content, cursor.min(self.content.len()));

        if start < end {
            self.selection = Some(start..end);
        } else {
            self.selection = None;
        }
        self.cursor = cursor;
    }

    /// Clear the selection
    pub fn clear_selection(&mut self) {
        self.selection = None;
    }

    /// Get the selected text
    pub fn get_selection_text(&self) -> Option<&str> {
        self.selection.as_ref().map(|sel| &self.content[sel.clone()])
    }

    /// Get selection range
    pub fn get_selection(&self) -> Option<Range<usize>> {
        self.selection.clone()
    }
}

/// Find the previous character boundary
fn previous_char_boundary(text: &str, cursor: usize) -> usize {
    let mut offset = cursor;
    while offset > 0 {
        offset -= 1;
        if text.is_char_boundary(offset) {
            break;
        }
    }
    offset
}

/// Find the next character boundary
fn next_char_boundary(text: &str, cursor: usize) -> usize {
    let mut offset = cursor;
    while offset < text.len() {
        offset += 1;
        if text.is_char_boundary(offset) {
            break;
        }
    }
    offset
}

/// Ensure a position is on a character boundary, moving backward if necessary
fn ensure_char_boundary(text: &str, position: usize) -> usize {
    let mut pos = position.min(text.len());
    while pos > 0 && !text.is_char_boundary(pos) {
        pos -= 1;
    }
    pos
}

/// Manager for all text input states
pub struct TextInputManager {
    states: HashMap<u64, TextInputState>,
}

impl TextInputManager {
    pub fn new() -> Self {
        Self {
            states: HashMap::new(),
        }
    }

    pub fn get_or_create(&mut self, id: u64) -> &mut TextInputState {
        self.states.entry(id).or_insert_with(TextInputState::new)
    }

    pub fn get(&self, id: u64) -> Option<&TextInputState> {
        self.states.get(&id)
    }

    pub fn get_mut(&mut self, id: u64) -> Option<&mut TextInputState> {
        self.states.get_mut(&id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_insert_char() {
        let mut state = TextInputState::new();
        state.insert_char('H');
        state.insert_char('i');
        assert_eq!(state.content, "Hi");
        assert_eq!(state.cursor, 2);
    }

    #[test]
    fn test_backspace() {
        let mut state = TextInputState::new();
        state.insert_text("Hello");
        state.backspace();
        assert_eq!(state.content, "Hell");
        assert_eq!(state.cursor, 4);
    }

    #[test]
    fn test_cursor_movement() {
        let mut state = TextInputState::new();
        state.insert_text("Test");
        state.move_cursor_home();
        assert_eq!(state.cursor, 0);
        state.move_cursor_right();
        assert_eq!(state.cursor, 1);
        state.move_cursor_end();
        assert_eq!(state.cursor, 4);
    }

    #[test]
    fn test_utf8_handling() {
        let mut state = TextInputState::new();
        state.insert_char('日');  // 3 bytes in UTF-8
        assert_eq!(state.cursor, 3);
        state.insert_char('本');  // 3 bytes in UTF-8
        assert_eq!(state.cursor, 6);
        state.backspace();
        assert_eq!(state.content, "日");
        assert_eq!(state.cursor, 3);
    }
}
