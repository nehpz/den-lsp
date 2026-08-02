use std::collections::{HashMap, HashSet};
use std::path::Path;
use tower_lsp::lsp_types::*;
use url::Url;

use crate::inventory::AnalysisDocument;
use crate::remap::remap_file_path;

pub fn extract_aspect_name(aspect_path: &str) -> &str {
    aspect_path
        .strip_prefix("den.aspects.")
        .or_else(|| aspect_path.strip_prefix("aspects."))
        .unwrap_or(aspect_path)
}

pub fn build_diagnostics_for_success(
    document: &AnalysisDocument,
    workspace_root: &Path,
    previously_published: &HashSet<Url>,
) -> (HashMap<Url, Vec<Diagnostic>>, HashSet<Url>) {
    let mut diagnostics_by_url: HashMap<Url, Vec<Diagnostic>> = HashMap::new();

    for finding in &document.findings {
        let severity = if finding.severity == "gating" {
            DiagnosticSeverity::ERROR
        } else {
            DiagnosticSeverity::WARNING
        };

        let message = format!(
            "{}\nfix: {}\nref: {}",
            finding.message, finding.fix, finding.doc_ref
        );

        let (file_path, line, col) = if let Some(pos) = &finding.position {
            (
                remap_file_path(&pos.file, workspace_root),
                pos.line.saturating_sub(1),
                pos.column.saturating_sub(1),
            )
        } else {
            let aspect_name = extract_aspect_name(&finding.aspect_path);
            if let Some(aspect_info) = document.inventory.aspects.get(aspect_name) {
                if let Some(file_str) = aspect_info
                    .file
                    .as_deref()
                    .or_else(|| aspect_info.position.as_ref().map(|p| p.file.as_str()))
                {
                    let line = aspect_info
                        .position
                        .as_ref()
                        .map(|p| p.line.saturating_sub(1))
                        .unwrap_or(0);
                    (remap_file_path(file_str, workspace_root), line, 0)
                } else {
                    (workspace_root.join("flake.nix"), 0, 0)
                }
            } else {
                (workspace_root.join("flake.nix"), 0, 0)
            }
        };

        let range = Range {
            start: Position::new(line, col),
            end: Position::new(line, col.max(1)),
        };

        let diagnostic = Diagnostic {
            range,
            severity: Some(severity),
            code: Some(NumberOrString::String(finding.rule.clone())),
            source: Some("den-lsp".to_string()),
            message,
            ..Default::default()
        };

        if let Ok(url) = Url::from_file_path(file_path) {
            diagnostics_by_url.entry(url).or_default().push(diagnostic);
        }
    }

    // Ensure all previously published URIs are accounted for (clearing any that no longer have findings)
    let mut updated_published = HashSet::new();
    let mut result_map = diagnostics_by_url.clone();

    for prev_url in previously_published {
        if !result_map.contains_key(prev_url) {
            result_map.insert(prev_url.clone(), Vec::new());
        }
    }

    for (url, diags) in &result_map {
        if !diags.is_empty() {
            updated_published.insert(url.clone());
        }
    }

    (result_map, updated_published)
}

pub fn build_diagnostic_for_eval_failure(
    error_msg: &str,
    file_pos: Option<(&str, u32)>,
    workspace_root: &Path,
) -> (Url, Diagnostic) {
    let (file_path, line) = if let Some((file, line)) = file_pos {
        (
            remap_file_path(file, workspace_root),
            line.saturating_sub(1),
        )
    } else {
        (workspace_root.join("flake.nix"), 0)
    };

    let range = Range {
        start: Position::new(line, 0),
        end: Position::new(line, 0),
    };

    let diagnostic = Diagnostic {
        range,
        severity: Some(DiagnosticSeverity::ERROR),
        code: Some(NumberOrString::String("eval-error".to_string())),
        source: Some("den-lsp".to_string()),
        message: error_msg.to_string(),
        ..Default::default()
    };

    let url =
        Url::from_file_path(file_path).unwrap_or_else(|_| Url::parse("file:///flake.nix").unwrap());
    (url, diagnostic)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::inventory::{Finding, FindingPosition, Inventory};

    #[test]
    fn test_broken_eval_single_r13_diagnostic_preserves_prior() {
        let workspace = Path::new("/workspace");

        // 1. Initial success with finding in aspect1.nix
        let doc = AnalysisDocument {
            version: 1,
            findings: vec![Finding {
                rule: "duplication".to_string(),
                severity: "gating".to_string(),
                aspect_path: "den.aspects.web".to_string(),
                position: Some(FindingPosition {
                    file: "modules/aspect1.nix".to_string(),
                    line: 10,
                    column: 5,
                }),
                message: "Duplicated block".to_string(),
                fix: "Extract shared aspect".to_string(),
                doc_ref: "docs/ref".to_string(),
            }],
            inventory: Inventory::default(),
            summary: None,
        };

        let previously_published = HashSet::new();
        let (success_map, published_uris) =
            build_diagnostics_for_success(&doc, workspace, &previously_published);

        let aspect1_url = Url::from_file_path("/workspace/modules/aspect1.nix").unwrap();
        assert!(success_map.contains_key(&aspect1_url));
        assert_eq!(success_map.get(&aspect1_url).unwrap().len(), 1);
        assert!(published_uris.contains(&aspect1_url));

        // 2. Subsequent broken eval in aspect2.nix
        let (err_url, err_diag) = build_diagnostic_for_eval_failure(
            "error: undefined variable 'foo'\nat /workspace/modules/aspect2.nix:15:2",
            Some(("modules/aspect2.nix", 15)),
            workspace,
        );

        let aspect2_url = Url::from_file_path("/workspace/modules/aspect2.nix").unwrap();
        assert_eq!(err_url, aspect2_url);
        assert_eq!(err_diag.severity, Some(DiagnosticSeverity::ERROR));
        assert!(err_diag.message.contains("undefined variable 'foo'"));

        // Crucially, `published_uris` still contains `aspect1_url` and we DO NOT issue empty diagnostics for aspect1_url!
        assert!(published_uris.contains(&aspect1_url));
    }
}
