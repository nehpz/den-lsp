use regex::Regex;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::process::Command;
use tokio::sync::{mpsc, RwLock};
use tokio::time::sleep;

use crate::inventory::AnalysisDocument;

#[allow(dead_code)]
#[derive(Debug, Clone)]
pub enum EvalOutput {
    Success(AnalysisDocument),
    VersionMismatchOrInvalidJson(String),
    Error {
        raw_stderr: String,
        error_block: String,
        position: Option<(String, u32)>,
    },
}

pub trait NixEvaluator: Send + Sync + 'static {
    fn detect_system(&self) -> futures_util::future::BoxFuture<'static, Result<String, String>>;
    fn eval_analysis(
        &self,
        workspace_root: PathBuf,
        system: String,
    ) -> futures_util::future::BoxFuture<'static, Result<String, String>>;
}

pub struct CommandNixEvaluator;

impl NixEvaluator for CommandNixEvaluator {
    fn detect_system(&self) -> futures_util::future::BoxFuture<'static, Result<String, String>> {
        Box::pin(async move {
            let output = Command::new("nix")
                .args([
                    "eval",
                    "--impure",
                    "--raw",
                    "--expr",
                    "builtins.currentSystem",
                ])
                .output()
                .await
                .map_err(|e| format!("Failed to execute nix eval: {}", e))?;

            if output.status.success() {
                Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
            } else {
                Err(String::from_utf8_lossy(&output.stderr).to_string())
            }
        })
    }

    fn eval_analysis(
        &self,
        workspace_root: PathBuf,
        system: String,
    ) -> futures_util::future::BoxFuture<'static, Result<String, String>> {
        Box::pin(async move {
            // Prefer the system-independent document (pure eval; exists even
            // when the editing machine's system declares no hosts), fall back
            // to the per-system gate's passthru for older den-lsp modules.
            let targets = [
                format!("path:{}#den-lsp-analysis", workspace_root.display()),
                format!(
                    "path:{}#checks.{}.den-lsp.passthru.analysis",
                    workspace_root.display(),
                    system
                ),
            ];

            let mut last_err = String::new();
            for (idx, expr) in targets.iter().enumerate() {
                let output = Command::new("nix")
                    .args(["eval", "--json", expr])
                    .output()
                    .await
                    .map_err(|e| format!("Failed to run nix eval analysis: {}", e))?;

                if output.status.success() {
                    return Ok(String::from_utf8_lossy(&output.stdout).to_string());
                }

                last_err = String::from_utf8_lossy(&output.stderr).to_string();
                // Only fall through when the attribute is missing (older
                // den-lsp module without the flake-level output); a real
                // evaluation failure must surface as the R13 diagnostic,
                // not be retried against a second target.
                let missing_attr = last_err.contains("does not provide attribute")
                    || last_err.contains("attribute 'den-lsp-analysis' missing");
                if idx == 0 && !missing_attr {
                    break;
                }
            }
            Err(last_err)
        })
    }
}

pub fn parse_nix_stderr(stderr: &str) -> (String, Option<(String, u32)>) {
    let error_block = if let Some(pos) = stderr.rfind("error:") {
        stderr[pos..].trim().to_string()
    } else {
        stderr.trim().to_string()
    };

    // Match pattern like `at /path/to/file.nix:12:5:` or `at file.nix:12:`
    let re = Regex::new(r"at\s+([^\s:]+):(\d+)").unwrap();
    let position = if let Some(caps) = re.captures(stderr) {
        let file = caps.get(1).unwrap().as_str().to_string();
        let line = caps.get(2).unwrap().as_str().parse::<u32>().unwrap_or(1);
        Some((file, line))
    } else {
        None
    };

    (error_block, position)
}

#[allow(dead_code)]
pub struct EvalOrchestrator {
    evaluator: Arc<dyn NixEvaluator>,
    workspace_root: PathBuf,
    cached_system: Arc<RwLock<Option<String>>>,
    last_known_good: Arc<RwLock<Option<AnalysisDocument>>>,
    trigger_tx: mpsc::Sender<()>,
}

impl EvalOrchestrator {
    pub fn new<F>(
        evaluator: Arc<dyn NixEvaluator>,
        workspace_root: PathBuf,
        on_eval_complete: F,
    ) -> Self
    where
        F: Fn(EvalOutput) + Send + Sync + 'static,
    {
        let cached_system = Arc::new(RwLock::new(None));
        let last_known_good = Arc::new(RwLock::new(None));
        let (trigger_tx, mut trigger_rx) = mpsc::channel::<()>(100);

        let evaluator_clone = evaluator.clone();
        let workspace_root_clone = workspace_root.clone();
        let cached_system_clone = cached_system.clone();
        let last_known_good_clone = last_known_good.clone();

        tokio::spawn(async move {
            while trigger_rx.recv().await.is_some() {
                // Debounce timer: wait 300ms while draining rapid triggers
                sleep(Duration::from_millis(300)).await;
                while trigger_rx.try_recv().is_ok() {}

                // Detect system if not already cached
                let system_opt = { cached_system_clone.read().await.clone() };
                let system = match system_opt {
                    Some(s) => s,
                    None => match evaluator_clone.detect_system().await {
                        Ok(s) => {
                            *cached_system_clone.write().await = Some(s.clone());
                            s
                        }
                        Err(e) => {
                            on_eval_complete(EvalOutput::Error {
                                raw_stderr: e.clone(),
                                error_block: format!("Failed to detect system: {}", e),
                                position: None,
                            });
                            continue;
                        }
                    },
                };

                // Run evaluation
                match evaluator_clone
                    .eval_analysis(workspace_root_clone.clone(), system)
                    .await
                {
                    Ok(json_str) => match serde_json::from_str::<AnalysisDocument>(&json_str) {
                        Ok(doc) => {
                            if doc.version == 1 {
                                *last_known_good_clone.write().await = Some(doc.clone());
                                on_eval_complete(EvalOutput::Success(doc));
                            } else {
                                on_eval_complete(EvalOutput::VersionMismatchOrInvalidJson(
                                    format!("Unknown analysis document version: {}", doc.version),
                                ));
                            }
                        }
                        Err(err) => {
                            on_eval_complete(EvalOutput::VersionMismatchOrInvalidJson(format!(
                                "Failed to parse analysis JSON: {}",
                                err
                            )));
                        }
                    },
                    Err(stderr) => {
                        let (error_block, position) = parse_nix_stderr(&stderr);
                        on_eval_complete(EvalOutput::Error {
                            raw_stderr: stderr,
                            error_block,
                            position,
                        });
                    }
                }
            }
        });

        Self {
            evaluator,
            workspace_root,
            cached_system,
            last_known_good,
            trigger_tx,
        }
    }

    pub fn trigger_eval(&self) {
        let _ = self.trigger_tx.try_send(());
    }

    pub async fn get_last_known_good(&self) -> Option<AnalysisDocument> {
        self.last_known_good.read().await.clone()
    }
}
#[cfg(test)]
mod tests {

    use super::*;
    use crate::inventory::Inventory;
    use futures_util::future::{BoxFuture, FutureExt};
    use std::sync::atomic::{AtomicUsize, Ordering};

    pub struct MockEvaluator {
        pub spawn_count: Arc<AtomicUsize>,
        pub json_response: String,
        pub fail_stderr: Option<String>,
    }

    impl NixEvaluator for MockEvaluator {
        fn detect_system(&self) -> BoxFuture<'static, Result<String, String>> {
            async move { Ok("aarch64-darwin".to_string()) }.boxed()
        }

        fn eval_analysis(
            &self,
            _workspace_root: PathBuf,
            _system: String,
        ) -> BoxFuture<'static, Result<String, String>> {
            let count = self.spawn_count.clone();
            let json = self.json_response.clone();
            let fail = self.fail_stderr.clone();

            async move {
                count.fetch_add(1, Ordering::SeqCst);
                if let Some(err) = fail {
                    Err(err)
                } else {
                    Ok(json)
                }
            }
            .boxed()
        }
    }

    #[tokio::test]
    async fn test_debounce_coalescing_two_rapid_triggers() {
        let spawn_count = Arc::new(AtomicUsize::new(0));
        let mock_doc = AnalysisDocument {
            version: 1,
            findings: vec![],
            inventory: Inventory::default(),
            summary: None,
        };
        let mock = Arc::new(MockEvaluator {
            spawn_count: spawn_count.clone(),
            json_response: serde_json::to_string(&mock_doc).unwrap(),
            fail_stderr: None,
        });

        let (res_tx, mut res_rx) = mpsc::channel(10);
        let orchestrator =
            EvalOrchestrator::new(mock, PathBuf::from("/workspace"), move |output| {
                let _ = res_tx.try_send(output);
            });

        // Rapid triggers
        orchestrator.trigger_eval();
        orchestrator.trigger_eval();

        // Wait for evaluation result
        let res = tokio::time::timeout(Duration::from_millis(1000), res_rx.recv()).await;
        assert!(res.is_ok());
        assert_eq!(spawn_count.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn test_unknown_version_keeps_last_known_good() {
        let spawn_count = Arc::new(AtomicUsize::new(0));
        let invalid_ver_json = r#"{"version": 99, "findings": [], "inventory": {}}"#.to_string();

        let mock = Arc::new(MockEvaluator {
            spawn_count,
            json_response: invalid_ver_json,
            fail_stderr: None,
        });

        let (res_tx, mut res_rx) = mpsc::channel(10);
        let orchestrator =
            EvalOrchestrator::new(mock, PathBuf::from("/workspace"), move |output| {
                let _ = res_tx.try_send(output);
            });

        // Pre-populate last-known-good with V1
        let v1_doc = AnalysisDocument {
            version: 1,
            findings: vec![],
            inventory: Inventory::default(),
            summary: None,
        };
        *orchestrator.last_known_good.write().await = Some(v1_doc.clone());

        orchestrator.trigger_eval();

        let res = tokio::time::timeout(Duration::from_millis(1000), res_rx.recv()).await;
        assert!(res.is_ok());
        if let Some(EvalOutput::VersionMismatchOrInvalidJson(msg)) = res.unwrap() {
            assert!(msg.contains("Unknown analysis document version"));
        } else {
            panic!("Expected VersionMismatchOrInvalidJson");
        }

        // Assert last-known-good was kept unchanged
        let lkg = orchestrator.get_last_known_good().await;
        assert_eq!(lkg, Some(v1_doc));
    }
}
