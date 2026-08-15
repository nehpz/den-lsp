#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BufferContext {
    InIncludesList,
    AtAspectKey,
    InHosts,
    None,
}

/// Convert an LSP `Position.character` (UTF-16 code units) into a byte index
/// on `line`, clamped to the line length, always landing on a char boundary.
pub fn utf16_col_to_byte_idx(line: &str, col: usize) -> usize {
    let mut utf16_acc = 0;
    for (byte_idx, ch) in line.char_indices() {
        if utf16_acc >= col {
            return byte_idx;
        }
        utf16_acc += ch.len_utf16();
    }
    line.len()
}

/// Simple static text heuristic scanning backwards from cursor.
///
/// `col_idx` is an LSP `Position.character`: UTF-16 code units into the line,
/// not a byte offset.
pub fn determine_context(buffer: &str, line_idx: usize, col_idx: usize) -> BufferContext {
    let lines: Vec<&str> = buffer.lines().collect();
    if line_idx >= lines.len() {
        return BufferContext::None;
    }

    let current_line = lines[line_idx];
    let end_col = utf16_col_to_byte_idx(current_line, col_idx);

    // Scan backwards line by line from current line, using slices (current
    // line truncated at the cursor) instead of allocating owned prefix strings.
    let mut bracket_depth: i32 = 0;
    let mut brace_depth: i32 = 0;
    let mut in_includes = false;

    for i in (0..=line_idx).rev() {
        let line = if i == line_idx {
            &current_line[..end_col]
        } else {
            lines[i]
        };
        for ch in line.chars().rev() {
            match ch {
                ']' => bracket_depth += 1,
                '[' => {
                    bracket_depth -= 1;
                    if bracket_depth < 0 && !in_includes {
                        // Check if this '[' belongs to an includes assignment
                        if line.contains("includes") {
                            in_includes = true;
                        }
                    }
                }
                '}' => brace_depth += 1,
                '{' => brace_depth -= 1,
                _ => {}
            }
        }

        if in_includes && bracket_depth < 0 {
            return BufferContext::InIncludesList;
        }

        // If we found an unclosed brace, check what opened it
        if brace_depth < 0 && bracket_depth == 0 {
            if line.contains("den.aspects") || line.contains("aspects.") {
                return BufferContext::AtAspectKey;
            }
            if line.contains("den.hosts") || line.contains("hosts.") {
                return BufferContext::InHosts;
            }
        }
    }

    if in_includes {
        BufferContext::InIncludesList
    } else {
        BufferContext::None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_context_heuristics_includes_aspect_none() {
        let includes_buf = r#"{
  den.aspects.igloo = {
    includes = [
      den.batteries.import-tree
    ];
  };
}"#;
        // Cursor on line 3 (inside includes list)
        assert_eq!(
            determine_context(includes_buf, 3, 10),
            BufferContext::InIncludesList
        );

        let aspect_buf = r#"{
  den.aspects.igloo = {
    nixos = { };
  };
}"#;
        // Cursor on line 2 inside aspect block
        assert_eq!(
            determine_context(aspect_buf, 2, 4),
            BufferContext::AtAspectKey
        );

        let hosts_buf = r#"{
  den.hosts.igloo = {
    nixos = { };
  };
}"#;
        // Cursor on line 2 inside hosts block
        assert_eq!(determine_context(hosts_buf, 2, 4), BufferContext::InHosts);

        let none_buf = r#"{
  foo = 123;
}"#;
        assert_eq!(determine_context(none_buf, 1, 4), BufferContext::None);
    }

    #[test]
    fn test_context_utf16_column_after_non_ascii() {
        // "é" is 1 UTF-16 code unit and 2 UTF-8 bytes. Slicing the line at the
        // LSP column as if it were a byte index lands mid-character and panics.
        let buf = r#"{
  den.aspects.igloo = {
    includes = [
      "café"
    ];
  };
}"#;
        // Cursor on the closing quote, after é, still inside the includes list.
        let col = "      \"café".encode_utf16().count();
        assert_eq!(
            determine_context(buf, 3, col),
            BufferContext::InIncludesList
        );
    }

    #[test]
    fn test_context_ascii_mid_line_column_unchanged() {
        let buf = r#"{
  den.aspects.igloo = {
    nixos = { };
  };
}"#;
        // ASCII line: UTF-16 offset equals byte offset; mid-line cursor is unchanged.
        assert_eq!(determine_context(buf, 2, 4), BufferContext::AtAspectKey);
    }

    #[test]
    fn test_utf16_col_to_byte_idx_boundaries() {
        // "🦀" is 2 UTF-16 code units and 4 UTF-8 bytes; "é" is 1 and 2.
        let line = "a🦀é-word";
        // Every returned index must be a char boundary (slicing must not panic).
        for col in 0..=line.encode_utf16().count() + 2 {
            let idx = utf16_col_to_byte_idx(line, col);
            let _ = &line[..idx];
        }
        assert_eq!(utf16_col_to_byte_idx(line, 0), 0);
        assert_eq!(utf16_col_to_byte_idx(line, 1), 1); // after 'a'
        assert_eq!(utf16_col_to_byte_idx(line, 3), 5); // after the 2-unit crab
        assert_eq!(utf16_col_to_byte_idx(line, 4), 7); // after 'é'
        assert_eq!(utf16_col_to_byte_idx(line, 99), line.len()); // clamped
    }
}
