use regex::Regex;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::process::Command;
use tokio::sync::{mpsc, RwLock};
use tokio::time::sleep;

pub const EVAL_TIMEOUT: Duration = Duration::from_secs(60);

/// Marks a synthetic deadline message produced by this crate, so the
/// orchestrator can distinguish it structurally from real nix stderr that
/// merely happens to contain the words "timed out" (e.g. a network
/// operation timeout inside an evaluation trace, which should still go
/// through `parse_nix_stderr` for file/line extraction).
pub const TIMEOUT_SENTINEL: &str = "den-lsp-timeout: ";

use crate::inventory::AnalysisDocument;

#[derive(Debug, Clone)]
pub enum EvalOutput {
    Success(AnalysisDocument),
    VersionMismatchOrInvalidJson(String),
    Error {
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

/// Mirrors the CLI's `classify_eval_err` non-fatal set (nix/check-cli.bash):
/// an error in this set means "this committed target is absent/unusable —
/// fall through", never "stop with a real eval failure". Nix phrases the
/// nested passthru miss as `attribute 'den-lsp' missing`, and a consumer
/// that declares a den-lsp input its outputs can't resolve phrases it as an
/// input error; both must reach the ephemeral-injection fallback.
fn is_missing_attribute(stderr: &str) -> bool {
    stderr.contains("does not provide attribute")
        || stderr.contains("attribute 'den-lsp-analysis' missing")
        || stderr.contains("attribute 'den-lsp' missing")
        || stderr.contains("does not provide input 'den-lsp'")
        || stderr.contains("does not have input 'den-lsp'")
        || stderr.contains("input 'den-lsp' not found")
        || stderr.contains("input 'den-lsp' does not exist")
        || stderr.contains("has no input 'den-lsp'")
        || stderr.contains("non-existent input 'den-lsp'")
}

/// Location of the KTD1a shim flake (`nix/` in the den-lsp tree).
///
/// Resolution order:
/// 1. `DEN_LSP_SHIM_PATH` baked in at compile time (`option_env!`) — set by the
///    Nix package derivation so editor installs are self-contained (KTD8).
/// 2. Dev fallback: `CARGO_MANIFEST_DIR/../nix` so `cargo test` / `cargo run`
///    from a source checkout work without a Nix-wrapped build.
fn den_lsp_shim_path() -> PathBuf {
    let raw = if let Some(p) = option_env!("DEN_LSP_SHIM_PATH") {
        PathBuf::from(p)
    } else {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("nix")
    };
    raw.canonicalize().unwrap_or(raw)
}

async fn nix_eval_json(args: &[&str]) -> Result<String, String> {
    let mut cmd = Command::new("nix");
    cmd.args(args)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);

    let child = cmd
        .spawn()
        .map_err(|e| format!("Failed to run nix eval analysis: {}", e))?;

    let output = match tokio::time::timeout(EVAL_TIMEOUT, child.wait_with_output()).await {
        Ok(Ok(out)) => out,
        Ok(Err(e)) => return Err(format!("Failed to run nix eval analysis: {}", e)),
        Err(_) => {
            return Err(format!(
                "{}nix eval timed out after {}s",
                TIMEOUT_SENTINEL,
                EVAL_TIMEOUT.as_secs()
            ))
        }
    };

    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).to_string())
    }
}

pub struct CommandNixEvaluator;

impl NixEvaluator for CommandNixEvaluator {
    fn detect_system(&self) -> futures_util::future::BoxFuture<'static, Result<String, String>> {
        Box::pin(async move {
            let mut cmd = Command::new("nix");
            cmd.args([
                "eval",
                "--impure",
                "--raw",
                "--expr",
                "builtins.currentSystem",
            ])
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true);

            let child = cmd
                .spawn()
                .map_err(|e| format!("Failed to execute nix eval: {}", e))?;

            let output = match tokio::time::timeout(EVAL_TIMEOUT, child.wait_with_output()).await {
                Ok(Ok(out)) => out,
                Ok(Err(e)) => return Err(format!("Failed to execute nix eval: {}", e)),
                Err(_) => {
                    return Err(format!(
                        "{}nix eval timed out after {}s",
                        TIMEOUT_SENTINEL,
                        EVAL_TIMEOUT.as_secs()
                    ))
                }
            };

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
            // Target resolution (KTD5), each step only after missing-attribute:
            // 1. path:<ws>#den-lsp-analysis (committed flake output)
            // 2. path:<ws>#checks.<system>.den-lsp.passthru.analysis (older module)
            // 3. ephemeral injection: same attr as (1) with
            //    --override-input flake-parts <shim> --no-write-lock-file
            //    where <shim> is den-lsp's nix/ directory (see den_lsp_shim_path).
            let committed = [
                format!("path:{}#den-lsp-analysis", workspace_root.display()),
                format!(
                    "path:{}#checks.{}.den-lsp.passthru.analysis",
                    workspace_root.display(),
                    system
                ),
            ];

            let mut last_err = String::new();
            let mut missing_committed = 0usize;
            for expr in &committed {
                // --no-write-lock-file: an editor-triggered eval must never
                // mutate the user's repo (same flag the CLI passes on every
                // analysis eval).
                match nix_eval_json(&["eval", "--json", expr, "--no-write-lock-file"]).await {
                    Ok(stdout) => return Ok(stdout),
                    Err(err) => {
                        last_err = err;
                        if is_missing_attribute(&last_err) {
                            missing_committed += 1;
                        } else {
                            // Real evaluation failure must surface as the R13
                            // diagnostic, not be retried against another target.
                            return Err(last_err);
                        }
                    }
                }
            }

            if missing_committed == committed.len() {
                let shim = den_lsp_shim_path();
                let expr = format!("path:{}#den-lsp-analysis", workspace_root.display());
                let shim_arg = shim.display().to_string();
                return nix_eval_json(&[
                    "eval",
                    "--json",
                    &expr,
                    "--override-input",
                    "flake-parts",
                    &shim_arg,
                    "--no-write-lock-file",
                ])
                .await;
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

/// Strip `TIMEOUT_SENTINEL` from a synthetic deadline, or parse real nix stderr.
/// Both the per-eval (`nix_eval_json`) deadline and the orchestrator-level
/// `tokio::time::timeout` around `eval_analysis` produce sentinel-prefixed
/// messages so this classification stays uniform.
fn classify_eval_stderr(stderr: &str) -> (String, Option<(String, u32)>) {
    if let Some(msg) = stderr.strip_prefix(TIMEOUT_SENTINEL) {
        (msg.to_string(), None)
    } else {
        parse_nix_stderr(stderr)
    }
}

pub struct EvalOrchestrator {
    last_known_good: Arc<RwLock<Option<AnalysisDocument>>>,
    trigger_tx: mpsc::Sender<()>,
    pub generation: Arc<AtomicU64>,
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
        Self::new_with_timeout(evaluator, workspace_root, EVAL_TIMEOUT, on_eval_complete)
    }

    pub fn new_with_timeout<F>(
        evaluator: Arc<dyn NixEvaluator>,
        workspace_root: PathBuf,
        eval_timeout: Duration,
        on_eval_complete: F,
    ) -> Self
    where
        F: Fn(EvalOutput) + Send + Sync + 'static,
    {
        let last_known_good = Arc::new(RwLock::new(None));
        let generation = Arc::new(AtomicU64::new(0));
        let (trigger_tx, mut trigger_rx) = mpsc::channel::<()>(100);

        let evaluator_clone = evaluator;
        let workspace_root_clone = workspace_root;
        let cached_system_clone: Arc<RwLock<Option<String>>> = Arc::new(RwLock::new(None));
        let last_known_good_clone = last_known_good.clone();
        let generation_clone = generation.clone();

        tokio::spawn(async move {
            let mut active_task: Option<tokio::task::JoinHandle<()>> = None;
            let on_eval_complete = Arc::new(on_eval_complete);

            while trigger_rx.recv().await.is_some() {
                // Debounce timer: wait 300ms while draining rapid triggers
                sleep(Duration::from_millis(300)).await;
                while trigger_rx.try_recv().is_ok() {}

                let current_gen = generation_clone.load(Ordering::SeqCst);

                // Abort superseded in-flight task
                if let Some(task) = active_task.take() {
                    task.abort();
                }

                let evaluator = evaluator_clone.clone();
                let workspace_root = workspace_root_clone.clone();
                let cached_system = cached_system_clone.clone();
                let last_known_good = last_known_good_clone.clone();
                let generation = generation_clone.clone();
                let on_eval_complete = on_eval_complete.clone();

                active_task = Some(tokio::spawn(async move {
                    // Detect system if not already cached
                    let system_opt = { cached_system.read().await.clone() };
                    let system = match system_opt {
                        Some(s) => s,
                        None => {
                            let sys_res =
                                tokio::time::timeout(eval_timeout, evaluator.detect_system()).await;
                            match sys_res {
                                Ok(Ok(s)) => {
                                    *cached_system.write().await = Some(s.clone());
                                    s
                                }
                                Ok(Err(e)) => {
                                    let (error_block, position) =
                                        if let Some(msg) = e.strip_prefix(TIMEOUT_SENTINEL) {
                                            (msg.to_string(), None)
                                        } else {
                                            (format!("Failed to detect system: {}", e), None)
                                        };
                                    publish_eval_result(
                                        &generation,
                                        current_gen,
                                        &last_known_good,
                                        on_eval_complete.as_ref(),
                                        EvalOutput::Error {
                                            error_block,
                                            position,
                                        },
                                    )
                                    .await;
                                    return;
                                }
                                Err(_) => {
                                    let e = format!(
                                        "{}Nix system detection timed out after {}s",
                                        TIMEOUT_SENTINEL,
                                        eval_timeout.as_secs()
                                    );
                                    let (error_block, position) =
                                        if let Some(msg) = e.strip_prefix(TIMEOUT_SENTINEL) {
                                            (msg.to_string(), None)
                                        } else {
                                            (format!("Failed to detect system: {}", e), None)
                                        };
                                    publish_eval_result(
                                        &generation,
                                        current_gen,
                                        &last_known_good,
                                        on_eval_complete.as_ref(),
                                        EvalOutput::Error {
                                            error_block,
                                            position,
                                        },
                                    )
                                    .await;
                                    return;
                                }
                            }
                        }
                    };

                    // Run evaluation
                    let eval_res = tokio::time::timeout(
                        eval_timeout,
                        evaluator.eval_analysis(workspace_root, system),
                    )
                    .await;

                    let output = match eval_res {
                        Ok(Ok(json_str)) => {
                            match serde_json::from_str::<AnalysisDocument>(&json_str) {
                                Ok(doc) => {
                                    if doc.version == 1 {
                                        EvalOutput::Success(doc)
                                    } else {
                                        EvalOutput::VersionMismatchOrInvalidJson(format!(
                                            "Unknown analysis document version: {}",
                                            doc.version
                                        ))
                                    }
                                }
                                Err(err) => EvalOutput::VersionMismatchOrInvalidJson(format!(
                                    "Failed to parse analysis JSON: {}",
                                    err
                                )),
                            }
                        }
                        Ok(Err(stderr)) => {
                            let (error_block, position) = classify_eval_stderr(&stderr);
                            EvalOutput::Error {
                                error_block,
                                position,
                            }
                        }
                        Err(_) => {
                            let stderr = format!(
                                "{}Nix evaluation timed out after {}s",
                                TIMEOUT_SENTINEL,
                                eval_timeout.as_secs()
                            );
                            let (error_block, position) = classify_eval_stderr(&stderr);
                            EvalOutput::Error {
                                error_block,
                                position,
                            }
                        }
                    };

                    publish_eval_result(
                        &generation,
                        current_gen,
                        &last_known_good,
                        on_eval_complete.as_ref(),
                        output,
                    )
                    .await;
                }));
            }
        });

        Self {
            last_known_good,
            trigger_tx,
            generation,
        }
    }

    pub fn trigger_eval(&self) {
        self.generation.fetch_add(1, Ordering::SeqCst);
        let _ = self.trigger_tx.try_send(());
    }

    pub async fn get_last_known_good(&self) -> Option<AnalysisDocument> {
        self.last_known_good.read().await.clone()
    }
}
async fn publish_eval_result<F>(
    generation: &AtomicU64,
    current_gen: u64,
    last_known_good: &RwLock<Option<AnalysisDocument>>,
    on_eval_complete: &F,
    output: EvalOutput,
) where
    F: Fn(EvalOutput),
{
    // One atomic decision under the last-known-good lock: the generation
    // re-check, the state write, and the publish happen together, so a
    // newer trigger can never observe an updated last-known-good document
    // that diagnostics were never shown (or vice versa).
    let mut guard = last_known_good.write().await;
    if generation.load(Ordering::SeqCst) != current_gen {
        return;
    }
    if let EvalOutput::Success(doc) = &output {
        *guard = Some(doc.clone());
    }
    // `on_eval_complete` is synchronous; holding the write guard across it
    // cannot deadlock (readers use the async lock and cannot run inside it).
    on_eval_complete(output);
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::inventory::{Finding, Inventory};
    use futures_util::future::{BoxFuture, FutureExt};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Mutex, MutexGuard};

    pub struct DropGuard {
        pub counter: Arc<AtomicUsize>,
        pub disarmed: bool,
    }

    impl Drop for DropGuard {
        fn drop(&mut self) {
            if !self.disarmed {
                self.counter.fetch_add(1, Ordering::SeqCst);
            }
        }
    }

    pub struct MockEvaluator {
        pub spawn_count: Arc<AtomicUsize>,
        pub drop_count: Arc<AtomicUsize>,
        pub detect_system_delay: Option<Duration>,
        pub eval_analysis_delay: Option<Duration>,
        pub json_response: String,
        pub fail_stderr: Option<String>,
        pub hold_eval: Option<Arc<tokio::sync::Notify>>,
    }

    impl NixEvaluator for MockEvaluator {
        fn detect_system(&self) -> BoxFuture<'static, Result<String, String>> {
            let delay = self.detect_system_delay;
            let drop_count = self.drop_count.clone();
            async move {
                let mut guard = DropGuard {
                    counter: drop_count,
                    disarmed: false,
                };
                if let Some(d) = delay {
                    sleep(d).await;
                }
                guard.disarmed = true;
                Ok("aarch64-darwin".to_string())
            }
            .boxed()
        }

        fn eval_analysis(
            &self,
            _workspace_root: PathBuf,
            _system: String,
        ) -> BoxFuture<'static, Result<String, String>> {
            let count = self.spawn_count.clone();
            let json = self.json_response.clone();
            let fail = self.fail_stderr.clone();
            let delay = self.eval_analysis_delay;
            let drop_count = self.drop_count.clone();
            let hold = self.hold_eval.clone();

            async move {
                let mut guard = DropGuard {
                    counter: drop_count,
                    disarmed: false,
                };
                count.fetch_add(1, Ordering::SeqCst);
                if let Some(gate) = hold {
                    gate.notified().await;
                }
                if let Some(d) = delay {
                    sleep(d).await;
                }
                guard.disarmed = true;
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
        let drop_count = Arc::new(AtomicUsize::new(0));
        let mock_doc = AnalysisDocument {
            version: 1,
            findings: vec![],
            inventory: Inventory::default(),
            summary: None,
        };
        let mock = Arc::new(MockEvaluator {
            spawn_count: spawn_count.clone(),
            drop_count,
            detect_system_delay: None,
            eval_analysis_delay: None,
            json_response: serde_json::to_string(&mock_doc).unwrap(),
            fail_stderr: None,
            hold_eval: None,
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
        let drop_count = Arc::new(AtomicUsize::new(0));
        let invalid_ver_json = r#"{"version": 99, "findings": [], "inventory": {}}"#.to_string();

        let mock = Arc::new(MockEvaluator {
            spawn_count,
            drop_count,
            detect_system_delay: None,
            eval_analysis_delay: None,
            json_response: invalid_ver_json,
            fail_stderr: None,
            hold_eval: None,
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

    #[tokio::test]
    async fn test_eval_analysis_timeout_surfaces_error() {
        let spawn_count = Arc::new(AtomicUsize::new(0));
        let drop_count = Arc::new(AtomicUsize::new(0));
        let mock = Arc::new(MockEvaluator {
            spawn_count,
            drop_count,
            detect_system_delay: None,
            eval_analysis_delay: Some(Duration::from_millis(500)),
            json_response: "{}".to_string(),
            fail_stderr: None,
            hold_eval: None,
        });
        let (res_tx, mut res_rx) = mpsc::channel(10);
        let orchestrator = EvalOrchestrator::new_with_timeout(
            mock,
            PathBuf::from("/workspace"),
            Duration::from_millis(50),
            move |output| {
                let _ = res_tx.try_send(output);
            },
        );

        orchestrator.trigger_eval();

        let res = tokio::time::timeout(Duration::from_millis(1000), res_rx.recv()).await;
        assert!(res.is_ok(), "Expected result within timeout");
        let output = res.unwrap().unwrap();
        if let EvalOutput::Error { error_block, .. } = output {
            assert!(
                error_block.contains("timed out"),
                "Expected error_block to contain 'timed out', got: {}",
                error_block
            );
            assert!(
                error_block.find(TIMEOUT_SENTINEL).is_none(),
                "TIMEOUT_SENTINEL is an internal marker and must be stripped before publish, got: {}",
                error_block
            );
        } else {
            panic!("Expected EvalOutput::Error, got {:?}", output);
        }
    }

    #[tokio::test]
    async fn test_hung_system_detection_surfaces_timeout() {
        let spawn_count = Arc::new(AtomicUsize::new(0));
        let drop_count = Arc::new(AtomicUsize::new(0));
        let mock = Arc::new(MockEvaluator {
            spawn_count,
            drop_count,
            detect_system_delay: Some(Duration::from_millis(500)),
            eval_analysis_delay: None,
            json_response: "{}".to_string(),
            fail_stderr: None,
            hold_eval: None,
        });
        let (res_tx, mut res_rx) = mpsc::channel(10);
        let orchestrator = EvalOrchestrator::new_with_timeout(
            mock,
            PathBuf::from("/workspace"),
            Duration::from_millis(50),
            move |output| {
                let _ = res_tx.try_send(output);
            },
        );

        orchestrator.trigger_eval();

        let res = tokio::time::timeout(Duration::from_millis(1000), res_rx.recv()).await;
        assert!(res.is_ok(), "Expected result within timeout");
        let output = res.unwrap().unwrap();
        if let EvalOutput::Error { error_block, .. } = output {
            assert!(
                error_block.contains("timed out"),
                "Expected error_block to contain 'timed out', got: {}",
                error_block
            );
            assert!(
                error_block.find(TIMEOUT_SENTINEL).is_none(),
                "TIMEOUT_SENTINEL is an internal marker and must be stripped before publish, got: {}",
                error_block
            );
        } else {
            panic!("Expected EvalOutput::Error, got {:?}", output);
        }
    }

    #[tokio::test]
    async fn test_superseded_eval_cancelled_and_child_dropped() {
        let spawn_count = Arc::new(AtomicUsize::new(0));
        let drop_count = Arc::new(AtomicUsize::new(0));

        let mock_doc = AnalysisDocument {
            version: 1,
            findings: vec![],
            inventory: Inventory::default(),
            summary: None,
        };
        let mock = Arc::new(MockEvaluator {
            spawn_count: spawn_count.clone(),
            drop_count: drop_count.clone(),
            detect_system_delay: None,
            eval_analysis_delay: Some(Duration::from_millis(500)),
            json_response: serde_json::to_string(&mock_doc).unwrap(),
            fail_stderr: None,
            hold_eval: None,
        });

        let (res_tx, mut res_rx) = mpsc::channel(10);
        let orchestrator = EvalOrchestrator::new_with_timeout(
            mock,
            PathBuf::from("/workspace"),
            Duration::from_secs(5),
            move |output| {
                let _ = res_tx.try_send(output);
            },
        );

        // Trigger 1
        orchestrator.trigger_eval();
        // Wait until trigger 1's evaluation is observably in flight — a fixed
        // debounce-sized sleep races on loaded CI runners.
        while spawn_count.load(Ordering::SeqCst) == 0 {
            sleep(Duration::from_millis(10)).await;
        }

        // Trigger 2 (supersedes trigger 1 while trigger 1 is sleeping inside eval_analysis)
        orchestrator.trigger_eval();

        let res = tokio::time::timeout(Duration::from_millis(2000), res_rx.recv()).await;
        assert!(res.is_ok(), "Expected result from trigger 2");
        assert!(
            drop_count.load(Ordering::SeqCst) >= 1,
            "Expected at least 1 cancelled drop, got {}",
            drop_count.load(Ordering::SeqCst)
        );
    }

    #[tokio::test]
    async fn test_stale_result_completing_after_newer_trigger_discarded() {
        let spawn_count = Arc::new(AtomicUsize::new(0));
        let drop_count = Arc::new(AtomicUsize::new(0));
        let hold = Arc::new(tokio::sync::Notify::new());

        let mock_doc = AnalysisDocument {
            version: 1,
            findings: vec![],
            inventory: Inventory::default(),
            summary: None,
        };
        let mock = Arc::new(MockEvaluator {
            spawn_count: spawn_count.clone(),
            drop_count,
            detect_system_delay: None,
            eval_analysis_delay: None,
            json_response: serde_json::to_string(&mock_doc).unwrap(),
            fail_stderr: None,
            hold_eval: Some(hold.clone()),
        });

        let (res_tx, mut res_rx) = mpsc::channel(10);
        let orchestrator = EvalOrchestrator::new_with_timeout(
            mock,
            PathBuf::from("/workspace"),
            Duration::from_secs(5),
            move |output| {
                let _ = res_tx.try_send(output);
            },
        );

        orchestrator.trigger_eval();
        // Wait until the gen-1 evaluation has actually started (held at the gate).
        while spawn_count.load(Ordering::SeqCst) == 0 {
            sleep(Duration::from_millis(10)).await;
        }

        // A newer trigger supersedes gen 1 while its evaluation is still in flight
        // through the production trigger_eval() path.
        orchestrator.trigger_eval();

        // Wait until the gen-2 evaluation has also started (held at the gate).
        while spawn_count.load(Ordering::SeqCst) == 1 {
            sleep(Duration::from_millis(10)).await;
        }

        // Release the held evaluation so it completes.
        hold.notify_waiters();

        // Only the newer result (from gen 2) should publish.
        let res = tokio::time::timeout(Duration::from_millis(1000), res_rx.recv()).await;
        assert!(res.is_ok(), "Expected result from second evaluation");
        if let Some(EvalOutput::Success(doc)) = res.unwrap() {
            assert_eq!(doc.version, 1);
        } else {
            panic!("Expected EvalOutput::Success");
        }

        // Ensure no extra (stale) result was published.
        let second_res = tokio::time::timeout(Duration::from_millis(100), res_rx.recv()).await;
        assert!(
            second_res.is_err(),
            "Only the newer result should be published"
        );
    }

    #[tokio::test]
    async fn test_stale_result_eval_completed_before_publish_recheck_discards() {
        let spawn_count = Arc::new(AtomicUsize::new(0));
        let drop_count = Arc::new(AtomicUsize::new(0));
        let hold = Arc::new(tokio::sync::Notify::new());

        let mock_doc = AnalysisDocument {
            version: 1,
            findings: vec![],
            inventory: Inventory::default(),
            summary: None,
        };
        let mock = Arc::new(MockEvaluator {
            spawn_count: spawn_count.clone(),
            drop_count,
            detect_system_delay: None,
            eval_analysis_delay: None,
            json_response: serde_json::to_string(&mock_doc).unwrap(),
            fail_stderr: None,
            hold_eval: Some(hold.clone()),
        });

        let (res_tx, mut res_rx) = mpsc::channel(10);
        let orchestrator = EvalOrchestrator::new_with_timeout(
            mock,
            PathBuf::from("/workspace"),
            Duration::from_secs(5),
            move |output| {
                let _ = res_tx.try_send(output);
            },
        );

        orchestrator.trigger_eval();
        while spawn_count.load(Ordering::SeqCst) == 0 {
            sleep(Duration::from_millis(10)).await;
        }

        // Increment generation while the eval is held to simulate a generation bump
        // right before publish re-check.
        orchestrator.generation.fetch_add(1, Ordering::SeqCst);

        // Release the held evaluation.
        hold.notify_waiters();

        // Result must be discarded and not received.
        let res = tokio::time::timeout(Duration::from_millis(300), res_rx.recv()).await;
        assert!(
            res.is_err(),
            "Stale result must be discarded by publish_eval_result re-check"
        );

        // last_known_good must remain unchanged (None).
        let lkg = orchestrator.get_last_known_good().await;
        assert!(
            lkg.is_none(),
            "last_known_good must not be updated for a stale eval"
        );
    }

    #[tokio::test]
    async fn test_normal_fast_path_publishes_findings() {
        let spawn_count = Arc::new(AtomicUsize::new(0));
        let drop_count = Arc::new(AtomicUsize::new(0));
        let mock_doc = AnalysisDocument {
            version: 1,
            findings: vec![],
            inventory: Inventory::default(),
            summary: None,
        };
        let mock = Arc::new(MockEvaluator {
            spawn_count: spawn_count.clone(),
            drop_count,
            detect_system_delay: None,
            eval_analysis_delay: None,
            json_response: serde_json::to_string(&mock_doc).unwrap(),
            fail_stderr: None,
            hold_eval: None,
        });

        let (res_tx, mut res_rx) = mpsc::channel(10);
        let orchestrator =
            EvalOrchestrator::new(mock, PathBuf::from("/workspace"), move |output| {
                let _ = res_tx.try_send(output);
            });

        orchestrator.trigger_eval();

        let res = tokio::time::timeout(Duration::from_millis(1000), res_rx.recv()).await;
        assert!(res.is_ok());
        if let Some(EvalOutput::Success(doc)) = res.unwrap() {
            assert_eq!(doc.version, 1);
        } else {
            panic!("Expected EvalOutput::Success");
        }
        assert_eq!(spawn_count.load(Ordering::SeqCst), 1);
    }

    // --- CommandNixEvaluator target-fallback (KTD5) ---
    // Production shells out to `nix`; these tests put a stub `nix` first on
    // PATH (serialized by NIX_STUB_LOCK) and record argv, mirroring the
    // existing MockEvaluator style at the process boundary.

    static NIX_STUB_LOCK: Mutex<()> = Mutex::new(());
    static NIX_STUB_SEQ: AtomicUsize = AtomicUsize::new(0);

    // POSIX sh, /bin/sh shebang: /usr/bin/env does not exist inside the Nix
    // Linux build sandbox, where the packaged test phase runs this stub.
    const NIX_STUB_SCRIPT: &str = r#"#!/bin/sh
set -eu
echo "$@" >> "${DEN_LSP_NIX_STUB_LOG}"

has_override=0
has_analysis=0
has_passthru=0
has_current_system=0
for arg in "$@"; do
  case "$arg" in
    --override-input) has_override=1 ;;
    *#den-lsp-analysis) has_analysis=1 ;;
    *#checks.*) has_passthru=1 ;;
    builtins.currentSystem) has_current_system=1 ;;
  esac
done

if [ "$has_current_system" -eq 1 ]; then
  printf '%s' "${DEN_LSP_NIX_STUB_SYSTEM:-aarch64-darwin}"
  exit 0
fi

if [ "$has_override" -eq 1 ]; then
  case "${DEN_LSP_NIX_STUB_INJECTION:-ok}" in
    ok)
      printf '%s' "${DEN_LSP_NIX_STUB_JSON}"
      exit 0
      ;;
    *)
      echo "${DEN_LSP_NIX_STUB_INJECTION_STDERR:-error: den-lsp: no flake-parts input (this wrapper analyzes flake-parts Den consumers)}" >&2
      exit 1
      ;;
  esac
fi

if [ "$has_passthru" -eq 1 ]; then
  case "${DEN_LSP_NIX_STUB_PASSTHRU:-missing}" in
    ok)
      printf '%s' "${DEN_LSP_NIX_STUB_JSON}"
      exit 0
      ;;
    missing)
      echo "error: flake 'path:/ws' does not provide attribute 'checks.aarch64-darwin.den-lsp.passthru.analysis'" >&2
      exit 1
      ;;
    *)
      echo "${DEN_LSP_NIX_STUB_PASSTHRU_STDERR:-error: undefined variable 'boom'}" >&2
      exit 1
      ;;
  esac
fi

if [ "$has_analysis" -eq 1 ]; then
  case "${DEN_LSP_NIX_STUB_ANALYSIS:-missing}" in
    ok)
      printf '%s' "${DEN_LSP_NIX_STUB_JSON}"
      exit 0
      ;;
    missing)
      echo "error: flake 'path:/ws' does not provide attribute 'packages.aarch64-darwin.den-lsp-analysis', 'legacyPackages.aarch64-darwin.den-lsp-analysis' or 'den-lsp-analysis'" >&2
      exit 1
      ;;
    *)
      echo "${DEN_LSP_NIX_STUB_ANALYSIS_STDERR:-error: undefined variable 'boom'}" >&2
      exit 1
      ;;
  esac
fi

echo "error: unexpected nix stub invocation: $*" >&2
exit 1
"#;

    struct NixStubEnv {
        _lock: MutexGuard<'static, ()>,
        log_path: PathBuf,
        stub_dir: PathBuf,
        prev_path: String,
    }

    impl Drop for NixStubEnv {
        fn drop(&mut self) {
            set_env_var("PATH", &self.prev_path);
            let _ = std::fs::remove_dir_all(&self.stub_dir);
        }
    }

    fn set_env_var(key: &str, val: &str) {
        // Safety: callers hold `NIX_STUB_LOCK` for the whole stub lifetime.
        #[allow(unused_unsafe)]
        unsafe {
            std::env::set_var(key, val);
        }
    }

    fn sample_findings_json() -> String {
        serde_json::to_string(&AnalysisDocument {
            version: 1,
            findings: vec![Finding {
                rule: "duplication".to_string(),
                severity: "gating".to_string(),
                aspect_path: "den.aspects.web".to_string(),
                position: None,
                message: "duplicated block".to_string(),
                fix: "extract shared aspect".to_string(),
                doc_ref: "docs/ref".to_string(),
            }],
            inventory: Inventory::default(),
            summary: None,
        })
        .unwrap()
    }

    fn install_nix_stub(analysis: &str, passthru: &str, injection: &str) -> NixStubEnv {
        let lock = NIX_STUB_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let seq = NIX_STUB_SEQ.fetch_add(1, Ordering::SeqCst);
        let stub_dir =
            std::env::temp_dir().join(format!("den-lsp-nix-stub-{}-{}", std::process::id(), seq));
        std::fs::create_dir_all(&stub_dir).unwrap();
        let nix_path = stub_dir.join("nix");
        std::fs::write(&nix_path, NIX_STUB_SCRIPT).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&nix_path, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let log_path = stub_dir.join("argv.log");
        std::fs::write(&log_path, "").unwrap();

        let prev_path = std::env::var("PATH").unwrap_or_default();
        set_env_var("PATH", &format!("{}:{}", stub_dir.display(), prev_path));
        set_env_var("DEN_LSP_NIX_STUB_LOG", &log_path.display().to_string());
        set_env_var("DEN_LSP_NIX_STUB_ANALYSIS", analysis);
        set_env_var("DEN_LSP_NIX_STUB_PASSTHRU", passthru);
        set_env_var("DEN_LSP_NIX_STUB_INJECTION", injection);
        set_env_var("DEN_LSP_NIX_STUB_JSON", &sample_findings_json());
        set_env_var(
            "DEN_LSP_NIX_STUB_INJECTION_STDERR",
            "error: den-lsp: no flake-parts input (this wrapper analyzes flake-parts Den consumers)",
        );

        NixStubEnv {
            _lock: lock,
            log_path,
            stub_dir,
            prev_path,
        }
    }

    fn stub_log(env: &NixStubEnv) -> Vec<String> {
        std::fs::read_to_string(&env.log_path)
            .unwrap_or_default()
            .lines()
            .map(str::to_string)
            .filter(|l| !l.is_empty())
            .collect()
    }

    fn is_injection_invocation(line: &str) -> bool {
        line.contains("--override-input") && line.contains("flake-parts")
    }

    #[tokio::test]
    async fn test_unwired_repo_resolves_via_injection_and_yields_findings() {
        let _stub = install_nix_stub("missing", "missing", "ok");
        let json = CommandNixEvaluator
            .eval_analysis(PathBuf::from("/unwired"), "aarch64-darwin".to_string())
            .await
            .expect("unwired eval should succeed via injection");
        let doc: AnalysisDocument = serde_json::from_str(&json).expect("v1 document");
        assert_eq!(doc.version, 1);
        assert!(
            !doc.findings.is_empty(),
            "injection target should yield findings, got: {json}"
        );
        let log = stub_log(&_stub);
        assert!(
            log.iter().any(|l| is_injection_invocation(l)),
            "expected an injection invocation, log: {log:?}"
        );
    }

    #[tokio::test]
    async fn test_wired_repo_never_attempts_injection() {
        // Committed flake-level output present.
        {
            let stub = install_nix_stub("ok", "missing", "ok");
            let json = CommandNixEvaluator
                .eval_analysis(PathBuf::from("/wired"), "aarch64-darwin".to_string())
                .await
                .expect("wired den-lsp-analysis should succeed");
            let doc: AnalysisDocument = serde_json::from_str(&json).unwrap();
            assert!(!doc.findings.is_empty());
            let log = stub_log(&stub);
            assert!(
                log.iter().all(|l| !is_injection_invocation(l)),
                "wired primary target must not inject, log: {log:?}"
            );
            assert_eq!(
                log.len(),
                1,
                "only the primary committed target, log: {log:?}"
            );
        }
        // Older module: primary missing, passthru present.
        {
            let stub = install_nix_stub("missing", "ok", "ok");
            let json = CommandNixEvaluator
                .eval_analysis(
                    PathBuf::from("/wired-passthru"),
                    "aarch64-darwin".to_string(),
                )
                .await
                .expect("wired passthru should succeed");
            let doc: AnalysisDocument = serde_json::from_str(&json).unwrap();
            assert!(!doc.findings.is_empty());
            let log = stub_log(&stub);
            assert!(
                log.iter().all(|l| !is_injection_invocation(l)),
                "wired passthru must not inject, log: {log:?}"
            );
            assert_eq!(log.len(), 2, "primary then passthru, log: {log:?}");
        }
    }

    #[tokio::test]
    async fn test_injection_only_after_both_committed_targets_missing_attribute() {
        {
            let stub = install_nix_stub("missing", "missing", "ok");
            CommandNixEvaluator
                .eval_analysis(PathBuf::from("/unwired"), "aarch64-darwin".to_string())
                .await
                .expect("injection after both missing-attribute");
            let log = stub_log(&stub);
            assert_eq!(
                log.len(),
                3,
                "two committed probes then injection, log: {log:?}"
            );
            assert!(
                log[0].contains("#den-lsp-analysis") && !is_injection_invocation(&log[0]),
                "first call is committed den-lsp-analysis, got {}",
                log[0]
            );
            assert!(
                log[1].contains("#checks.") && log[1].contains("den-lsp.passthru.analysis"),
                "second call is committed passthru, got {}",
                log[1]
            );
            assert!(
                is_injection_invocation(&log[2]),
                "third call is injection, got {}",
                log[2]
            );
            assert!(
                log[2].contains("--no-write-lock-file"),
                "injection must pass --no-write-lock-file, got {}",
                log[2]
            );
            assert!(
                log[2].contains("#den-lsp-analysis"),
                "injection evals den-lsp-analysis on the workspace, got {}",
                log[2]
            );
        }
        // A real error on the second committed target must not inject.
        {
            let stub = install_nix_stub("missing", "error", "ok");
            let err = CommandNixEvaluator
                .eval_analysis(PathBuf::from("/broken"), "aarch64-darwin".to_string())
                .await
                .expect_err("passthru eval error should surface");
            assert!(
                err.contains("undefined variable"),
                "expected passthru eval error, got: {err}"
            );
            let log = stub_log(&stub);
            assert!(
                log.iter().all(|l| !is_injection_invocation(l)),
                "must not inject after a real committed-target error, log: {log:?}"
            );
        }
    }

    #[tokio::test]
    async fn test_nested_missing_attribute_wording_reaches_injection() {
        // Nix phrases the passthru miss as "attribute 'den-lsp' missing" on
        // some paths; that wording must be classified as fall-through so the
        // zero-touch fallback still fires (CLI classifier parity).
        let stub = install_nix_stub("missing", "error", "ok");
        set_env_var(
            "DEN_LSP_NIX_STUB_PASSTHRU_STDERR",
            "error: attribute 'den-lsp' missing",
        );
        let json = CommandNixEvaluator
            .eval_analysis(PathBuf::from("/unwired"), "aarch64-darwin".to_string())
            .await
            .expect("nested missing-attribute wording should reach injection");
        std::env::remove_var("DEN_LSP_NIX_STUB_PASSTHRU_STDERR");
        assert!(json.contains("\"version\""), "injection yielded a document");
        let log = stub_log(&stub);
        assert!(
            log.iter().any(|l| is_injection_invocation(l)),
            "expected an injection invocation, log: {log:?}"
        );
    }

    #[tokio::test]
    async fn test_real_eval_error_on_primary_analysis_short_circuits_chain() {
        // Real evaluation failure on the PRIMARY committed target must surface
        // immediately: no passthru probe, no injection argv.
        // passthru=ok / injection=ok so a missing short-circuit would succeed
        // instead of returning Err.
        let stub = install_nix_stub("error", "ok", "ok");
        let err = CommandNixEvaluator
            .eval_analysis(
                PathBuf::from("/broken-primary"),
                "aarch64-darwin".to_string(),
            )
            .await
            .expect_err("primary analysis eval error should surface");
        assert!(
            err.contains("undefined variable"),
            "expected analysis stderr, got: {err}"
        );
        let log = stub_log(&stub);
        assert_eq!(
            log.len(),
            1,
            "only the primary target; no passthru probe, no injection argv, log: {log:?}"
        );
        assert!(
            log[0].contains("#den-lsp-analysis") && !is_injection_invocation(&log[0]),
            "single call is committed den-lsp-analysis, got {}",
            log[0]
        );
    }

    #[tokio::test]
    async fn test_injection_failure_yields_eval_error_and_retains_last_known_good() {
        let _stub = install_nix_stub("missing", "missing", "error");
        let (res_tx, mut res_rx) = mpsc::channel(10);
        let orchestrator = EvalOrchestrator::new(
            Arc::new(CommandNixEvaluator),
            PathBuf::from("/unwired-broken"),
            move |output| {
                let _ = res_tx.try_send(output);
            },
        );

        let v1_doc = AnalysisDocument {
            version: 1,
            findings: vec![],
            inventory: Inventory::default(),
            summary: None,
        };
        *orchestrator.last_known_good.write().await = Some(v1_doc.clone());

        orchestrator.trigger_eval();

        let res = tokio::time::timeout(Duration::from_millis(1000), res_rx.recv()).await;
        assert!(res.is_ok(), "expected one eval-error diagnostic");
        match res.unwrap() {
            Some(EvalOutput::Error { error_block, .. }) => {
                assert!(
                    error_block.contains("den-lsp: no flake-parts input"),
                    "injection failure should surface the R4-style message, got: {error_block}"
                );
            }
            other => panic!("expected EvalOutput::Error, got {other:?}"),
        }

        let second = tokio::time::timeout(Duration::from_millis(100), res_rx.recv()).await;
        assert!(second.is_err(), "exactly one eval-error diagnostic");

        let lkg = orchestrator.get_last_known_good().await;
        assert_eq!(lkg, Some(v1_doc), "last-known-good must be retained");
    }
}
