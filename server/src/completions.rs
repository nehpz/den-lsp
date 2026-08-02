use crate::context::BufferContext;
use crate::inventory::Inventory;
use tower_lsp::lsp_types::*;

pub fn get_completions(inventory: &Inventory, context: BufferContext) -> Vec<CompletionItem> {
    let mut items = Vec::new();

    match context {
        BufferContext::InIncludesList => {
            // Batteries as den.batteries.<name>
            for (name, battery) in &inventory.batteries {
                let label = format!("den.batteries.{}", name);
                let doc = battery.description.as_deref().unwrap_or("Den battery");
                let detail = if !battery.provides.is_empty() {
                    format!("provides: {}", battery.provides.join(", "))
                } else {
                    "battery".to_string()
                };

                items.push(CompletionItem {
                    label,
                    kind: Some(CompletionItemKind::VALUE),
                    detail: Some(detail),
                    documentation: Some(Documentation::MarkupContent(MarkupContent {
                        kind: MarkupKind::Markdown,
                        value: doc.to_string(),
                    })),
                    ..Default::default()
                });
            }

            // Provider aspects as den.aspects.<name> (declared aspects with nonempty provides)
            for (name, aspect) in &inventory.aspects {
                if !aspect.provides.is_empty() {
                    let label = format!("den.aspects.{}", name);
                    let doc = aspect.description.as_deref().unwrap_or("Provider aspect");
                    let detail =
                        format!("provider aspect (provides: {})", aspect.provides.join(", "));

                    items.push(CompletionItem {
                        label,
                        kind: Some(CompletionItemKind::MODULE),
                        detail: Some(detail),
                        documentation: Some(Documentation::MarkupContent(MarkupContent {
                            kind: MarkupKind::Markdown,
                            value: doc.to_string(),
                        })),
                        ..Default::default()
                    });
                }
            }
        }
        BufferContext::AtAspectKey => {
            // Registered classes
            for (name, class_info) in &inventory.classes {
                let doc = class_info
                    .description
                    .as_deref()
                    .unwrap_or("Registered class");
                items.push(CompletionItem {
                    label: name.clone(),
                    kind: Some(CompletionItemKind::CLASS),
                    detail: Some("registered class".to_string()),
                    documentation: Some(Documentation::MarkupContent(MarkupContent {
                        kind: MarkupKind::Markdown,
                        value: doc.to_string(),
                    })),
                    ..Default::default()
                });
            }

            // Registered quirks
            for (name, quirk_info) in &inventory.quirks {
                let doc = quirk_info
                    .description
                    .as_deref()
                    .unwrap_or("Registered quirk");
                items.push(CompletionItem {
                    label: name.clone(),
                    kind: Some(CompletionItemKind::PROPERTY),
                    detail: Some("registered quirk".to_string()),
                    documentation: Some(Documentation::MarkupContent(MarkupContent {
                        kind: MarkupKind::Markdown,
                        value: doc.to_string(),
                    })),
                    ..Default::default()
                });
            }
        }
        BufferContext::InHosts | BufferContext::None => {}
    }

    items.sort_by(|a, b| a.label.cmp(&b.label));
    items
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::inventory::{AspectInfo, BatteryInfo, ClassInfo};

    // Covers AE5.
    #[test]
    fn covers_ae5_includes_completion() {
        let mut inventory = Inventory::default();
        inventory.batteries.insert(
            "define-user".to_string(),
            BatteryInfo {
                description: Some("Define user account".to_string()),
                provides: vec!["user".to_string()],
                ..Default::default()
            },
        );
        inventory.aspects.insert(
            "common-base".to_string(),
            AspectInfo {
                description: Some("Base aspect".to_string()),
                provides: vec!["base-sys".to_string()],
                ..Default::default()
            },
        );
        inventory.aspects.insert(
            "non-provider".to_string(),
            AspectInfo {
                description: Some("Empty aspect".to_string()),
                provides: vec![],
                ..Default::default()
            },
        );
        inventory.classes.insert(
            "nixos".to_string(),
            ClassInfo {
                description: Some("NixOS system".to_string()),
            },
        );

        let completions = get_completions(&inventory, BufferContext::InIncludesList);
        let labels: Vec<&str> = completions.iter().map(|c| c.label.as_str()).collect();

        assert_eq!(
            labels,
            vec!["den.aspects.common-base", "den.batteries.define-user"]
        );
    }
}
