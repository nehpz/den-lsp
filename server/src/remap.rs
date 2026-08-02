use std::path::{Path, PathBuf};

/// Strips `/nix/store/<hash>-<name>/` prefix defensively if present, returning a cleaned path str.
pub fn strip_nix_store_prefix(file_path: &str) -> &str {
    if let Some(rest) = file_path.strip_prefix("/nix/store/") {
        if let Some(slash_idx) = rest.find('/') {
            return &rest[slash_idx + 1..];
        }
    }
    file_path
}

/// Rebases a file path (which may be repo-relative or store-prefixed) onto the absolute `workspace_root`.
pub fn remap_file_path(file_path: &str, workspace_root: &Path) -> PathBuf {
    let cleaned = strip_nix_store_prefix(file_path);
    let path = Path::new(cleaned);
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        workspace_root.join(path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_remap_store_path_and_relative() {
        let workspace = Path::new("/Users/stephen/Projects/infra");

        // Relative path
        let remapped1 = remap_file_path("modules/den.nix", workspace);
        assert_eq!(
            remapped1,
            PathBuf::from("/Users/stephen/Projects/infra/modules/den.nix")
        );

        // Nix store path fixture
        let remapped2 = remap_file_path(
            "/nix/store/w0fghq3408fj943f-source/modules/den.nix",
            workspace,
        );
        assert_eq!(
            remapped2,
            PathBuf::from("/Users/stephen/Projects/infra/modules/den.nix")
        );

        // Different nix store path fixture
        let remapped3 = remap_file_path("/nix/store/a1b2c3d4e5f6-den-lsp/flake.nix", workspace);
        assert_eq!(
            remapped3,
            PathBuf::from("/Users/stephen/Projects/infra/flake.nix")
        );

        // Absolute path outside store
        let remapped4 = remap_file_path("/tmp/custom.nix", workspace);
        assert_eq!(remapped4, PathBuf::from("/tmp/custom.nix"));
    }
}
