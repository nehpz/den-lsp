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
                let mut cmd = Command::new("nix");
                cmd.args(["eval", "--json", expr])
                    .stdout(std::process::Stdio::piped())
                    .stderr(std::process::Stdio::piped())
                    .kill_on_drop(true);

                let child = cmd
                    .spawn()
                    .map_err(|e| format!("Failed to run nix eval analysis: {}", e))?;

                let output =
                    match tokio::time::timeout(EVAL_TIMEOUT, child.wait_with_output()).await {
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
                                tokio::time::timeout(eval_timeout, evaluator.detect_system())
                                    .await;
                            match sys_res {
                                Ok(Ok(s)) => {
                                    *cached_system.write().await = Some(s.clone());
                                    s
                                }
                                Ok(Err(e)) => {
                                    let (error_block, position) = if let Some(msg) = e.strip_prefix(TIMEOUT_SENTINEL) {
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
                                    let err_msg = format!(
                                        "Nix system detection timed out after {}s",
                                        eval_timeout.as_secs()
                                    );
                                    publish_eval_result(
                                        &generation,
                                        current_gen,
                                        &last_known_good,
                                        on_eval_complete.as_ref(),
                                        EvalOutput::Error {
                                            error_block: err_msg,
                                            position: None,
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
                                Err(err) => {
                                    EvalOutput::VersionMismatchOrInvalidJson(format!(
                                        "Failed to parse analysis JSON: {}",
                                        err
                                    ))
                                }
                            }
                        }
                        Ok(Err(stderr)) => {
                            let (error_block, position) = if let Some(msg) = stderr.strip_prefix(TIMEOUT_SENTINEL) {
                                (msg.to_string(), None)
                            } else {
                                parse_nix_stderr(&stderr)
                            };
                            EvalOutput::Error {
                                error_block,
                                position,
                            }
                        }
                        Err(_) => {
                            let err_msg = format!(
                                "Nix evaluation timed out after {}s",
                                eval_timeout.as_secs()
                            );
                            EvalOutput::Error {
                                error_block: err_msg,
                                position: None,
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
    use crate::inventory::Inventory;
    use futures_util::future::{BoxFuture, FutureExt};
    use std::sync::atomic::{AtomicUsize, Ordering};

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
        let orchestrator = EvalOrchestrator::new(mock, PathBuf::from("/workspace"), move |output| {
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
}