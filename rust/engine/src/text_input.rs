use std::collections::HashMap;
use std::ops::Range;

/// State for a single text input widget
#[derive(Default)]
pub struct TextInputState {
    pub content: String,
    pub cursor: usize,  // Byte offset in UTF-8
    pub selection: Option<Range<usize>>,
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
