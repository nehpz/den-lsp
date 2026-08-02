#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BufferContext {
    InIncludesList,
    AtAspectKey,
    InHosts,
    None,
}

/// Simple static text heuristic scanning backwards from cursor (line_idx, col_idx).
pub fn determine_context(buffer: &str, line_idx: usize, col_idx: usize) -> BufferContext {
    let lines: Vec<&str> = buffer.lines().collect();
    if line_idx >= lines.len() {
        return BufferContext::None;
    }

    // Build the text prefix up to the cursor position
    let mut prefix_lines: Vec<String> = Vec::new();
    for i in 0..line_idx {
        prefix_lines.push(lines[i].to_string());
    }
    let current_line = lines[line_idx];
    let end_col = col_idx.min(current_line.len());
    prefix_lines.push(current_line[..end_col].to_string());

    // Scan backwards line by line from current line
    let mut bracket_depth: i32 = 0;
    let mut brace_depth: i32 = 0;
    let mut in_includes = false;

    for line in prefix_lines.iter().rev() {
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
}
