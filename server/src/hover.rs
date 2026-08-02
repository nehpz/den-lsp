use crate::inventory::Inventory;
use tower_lsp::lsp_types::*;

pub fn get_hover(inventory: &Inventory, word_at_cursor: &str) -> Option<Hover> {
    let trimmed = word_at_cursor.trim();
    if trimmed.is_empty() {
        return None;
    }

    // 1. Check battery (either `den.batteries.<name>` or bare `<name>`)
    let battery_key = trimmed.strip_prefix("den.batteries.").unwrap_or(trimmed);
    if let Some(battery) = inventory.batteries.get(battery_key) {
        let desc = battery.description.as_deref().unwrap_or("Den battery");
        let provides_str = if battery.provides.is_empty() {
            "none".to_string()
        } else {
            battery.provides.join(", ")
        };

        let markdown = format!(
            "### den.batteries.{}\n{}\n\n**Provides:** {}",
            battery_key, desc, provides_str
        );

        return Some(Hover {
            contents: HoverContents::Markup(MarkupContent {
                kind: MarkupKind::Markdown,
                value: markdown,
            }),
            range: None,
        });
    }

    // 2. Check class
    let class_key = trimmed.strip_prefix("den.classes.").unwrap_or(trimmed);
    if let Some(class_info) = inventory.classes.get(class_key) {
        let desc = class_info
            .description
            .as_deref()
            .unwrap_or("Registered class");
        let markdown = format!("### class {}\n{}", class_key, desc);

        return Some(Hover {
            contents: HoverContents::Markup(MarkupContent {
                kind: MarkupKind::Markdown,
                value: markdown,
            }),
            range: None,
        });
    }

    // 3. Check aspect (either `den.aspects.<name>` or bare `<name>`)
    let aspect_key = trimmed.strip_prefix("den.aspects.").unwrap_or(trimmed);
    if let Some(aspect) = inventory.aspects.get(aspect_key) {
        let desc = aspect.description.as_deref().unwrap_or("Aspect");
        let provides_str = if aspect.provides.is_empty() {
            "none".to_string()
        } else {
            aspect.provides.join(", ")
        };

        let markdown = format!(
            "### den.aspects.{}\n{}\n\n**Provides:** {}",
            aspect_key, desc, provides_str
        );

        return Some(Hover {
            contents: HoverContents::Markup(MarkupContent {
                kind: MarkupKind::Markdown,
                value: markdown,
            }),
            range: None,
        });
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::inventory::{BatteryInfo, ClassInfo};

    // Covers AE8.
    #[test]
    fn covers_ae8_battery_hover() {
        let mut inventory = Inventory::default();
        inventory.batteries.insert(
            "import-tree".to_string(),
            BatteryInfo {
                description: Some(
                    "Recursively imports non-dendritic .nix files by class.".to_string(),
                ),
                provides: vec!["host".to_string(), "home".to_string(), "user".to_string()],
                ..Default::default()
            },
        );
        inventory.classes.insert(
            "nixos".to_string(),
            ClassInfo {
                description: Some("NixOS system configuration".to_string()),
            },
        );

        let hover1 = get_hover(&inventory, "den.batteries.import-tree");
        assert!(hover1.is_some());
        if let Some(Hover {
            contents: HoverContents::Markup(m),
            ..
        }) = hover1
        {
            assert!(m
                .value
                .contains("Recursively imports non-dendritic .nix files"));
            assert!(m.value.contains("**Provides:** host, home, user"));
        } else {
            panic!("Expected Markup hover");
        }

        let hover2 = get_hover(&inventory, "nixos");
        assert!(hover2.is_some());
        if let Some(Hover {
            contents: HoverContents::Markup(m),
            ..
        }) = hover2
        {
            assert!(m.value.contains("NixOS system configuration"));
        } else {
            panic!("Expected Markup hover");
        }
    }
}
