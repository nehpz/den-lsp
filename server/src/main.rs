mod completions;
mod context;
mod diagnostics;
mod eval;
mod hover;
mod inventory;
mod remap;

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::RwLock;
use tower_lsp::jsonrpc::Result;
use tower_lsp::lsp_types::*;
use tower_lsp::{Client, LanguageServer, LspService, Server};
use url::Url;

use completions::get_completions;
use context::determine_context;
use diagnostics::{build_diagnostic_for_eval_failure, build_diagnostics_for_success};
use eval::{CommandNixEvaluator, EvalOrchestrator, EvalOutput};
use hover::get_hover;
use inventory::Inventory;

pub struct Backend {
    client: Client,
    workspace_root: Arc<RwLock<Option<PathBuf>>>,
    buffers: Arc<RwLock<HashMap<Url, String>>>,
    published_uris: Arc<RwLock<HashSet<Url>>>,
    orchestrator: Arc<RwLock<Option<EvalOrchestrator>>>,
}

impl Backend {
    pub fn new(client: Client) -> Self {
        Self {
            client,
            workspace_root: Arc::new(RwLock::new(None)),
            buffers: Arc::new(RwLock::new(HashMap::new())),
            published_uris: Arc::new(RwLock::new(HashSet::new())),
            orchestrator: Arc::new(RwLock::new(None)),
        }
    }
}

#[tower_lsp::async_trait]
impl LanguageServer for Backend {
    #[allow(deprecated)]
    async fn initialize(&self, params: InitializeParams) -> Result<InitializeResult> {
        let root_path = if let Some(uri) = params.root_uri {
            uri.to_file_path().ok()
        } else if let Some(path_str) = params.root_path {
            Some(PathBuf::from(path_str))
        } else if let Some(folders) = params.workspace_folders {
            folders.first().and_then(|f| f.uri.to_file_path().ok())
        } else {
            None
        };

        let workspace_root = root_path
            .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
        *self.workspace_root.write().await = Some(workspace_root.clone());

        let backend_client = self.client.clone();
        let pub_uris = self.published_uris.clone();
        let ws_root = self.workspace_root.clone();

        let orchestrator = EvalOrchestrator::new(
            Arc::new(CommandNixEvaluator),
            workspace_root.clone(),
            move |output| {
                let client = backend_client.clone();
                let root_store = ws_root.clone();
                let published_store = pub_uris.clone();

                tokio::spawn(async move {
                    let root_guard = root_store.read().await;
                    let root = root_guard
                        .as_ref()
                        .cloned()
                        .unwrap_or_else(|| PathBuf::from("."));

                    match output {
                        EvalOutput::Success(doc) => {
                            let mut prev_guard = published_store.write().await;
                            let (diags_map, updated_published) =
                                build_diagnostics_for_success(&doc, &root, &prev_guard);

                            for (url, diagnostics) in diags_map {
                                client.publish_diagnostics(url, diagnostics, None).await;
                            }
                            *prev_guard = updated_published;
                        }
                        EvalOutput::Error {
                            error_block,
                            position,
                            ..
                        } => {
                            let pos_tuple = position.as_ref().map(|(f, l)| (f.as_str(), *l));
                            let (target_url, diagnostic) =
                                build_diagnostic_for_eval_failure(&error_block, pos_tuple, &root);

                            published_store.write().await.insert(target_url.clone());
                            client
                                .publish_diagnostics(target_url, vec![diagnostic], None)
                                .await;
                        }
                        EvalOutput::VersionMismatchOrInvalidJson(msg) => {
                            client.log_message(MessageType::WARNING, msg).await;
                        }
                    }
                });
            },
        );

        *self.orchestrator.write().await = Some(orchestrator);

        Ok(InitializeResult {
            capabilities: ServerCapabilities {
                text_document_sync: Some(TextDocumentSyncCapability::Options(
                    TextDocumentSyncOptions {
                        open_close: Some(true),
                        change: Some(TextDocumentSyncKind::FULL),
                        save: Some(TextDocumentSyncSaveOptions::Supported(true)),
                        ..Default::default()
                    },
                )),
                completion_provider: Some(CompletionOptions::default()),
                hover_provider: Some(HoverProviderCapability::Simple(true)),
                ..Default::default()
            },
            server_info: Some(ServerInfo {
                name: "den-lsp-server".to_string(),
                version: Some("0.1.0".to_string()),
            }),
        })
    }

    async fn initialized(&self, _: InitializedParams) {
        self.client
            .log_message(MessageType::INFO, "den-lsp server initialized")
            .await;
        if let Some(orch) = self.orchestrator.read().await.as_ref() {
            orch.trigger_eval();
        }
    }

    async fn shutdown(&self) -> Result<()> {
        Ok(())
    }

    async fn did_open(&self, params: DidOpenTextDocumentParams) {
        let uri = params.text_document.uri;
        let text = params.text_document.text;
        self.buffers.write().await.insert(uri, text);

        if let Some(orch) = self.orchestrator.read().await.as_ref() {
            orch.trigger_eval();
        }
    }

    async fn did_change(&self, params: DidChangeTextDocumentParams) {
        let uri = params.text_document.uri;
        if let Some(change) = params.content_changes.first() {
            self.buffers.write().await.insert(uri, change.text.clone());
        }
    }

    async fn did_save(&self, params: DidSaveTextDocumentParams) {
        if let Some(text) = params.text {
            self.buffers
                .write()
                .await
                .insert(params.text_document.uri, text);
        }

        if let Some(orch) = self.orchestrator.read().await.as_ref() {
            orch.trigger_eval();
        }
    }

    async fn completion(&self, params: CompletionParams) -> Result<Option<CompletionResponse>> {
        let uri = &params.text_document_position.text_document.uri;
        let pos = params.text_document_position.position;

        let buffer_opt = self.buffers.read().await.get(uri).cloned();
        let buffer = match buffer_opt {
            Some(b) => b,
            None => return Ok(None),
        };

        let context = determine_context(&buffer, pos.line as usize, pos.character as usize);

        let inventory = if let Some(orch) = self.orchestrator.read().await.as_ref() {
            orch.get_last_known_good()
                .await
                .unwrap_or_default()
                .inventory
        } else {
            Inventory::default()
        };

        let completions = get_completions(&inventory, context);
        Ok(Some(CompletionResponse::Array(completions)))
    }

    async fn hover(&self, params: HoverParams) -> Result<Option<Hover>> {
        let uri = &params.text_document_position_params.text_document.uri;
        let pos = params.text_document_position_params.position;

        let buffer_opt = self.buffers.read().await.get(uri).cloned();
        let buffer = match buffer_opt {
            Some(b) => b,
            None => return Ok(None),
        };

        let lines: Vec<&str> = buffer.lines().collect();
        if pos.line as usize >= lines.len() {
            return Ok(None);
        }
        let line = lines[pos.line as usize];
        let col = pos.character as usize;
        if col >= line.len() {
            return Ok(None);
        }

        let bytes = line.as_bytes();
        let mut start = col;
        while start > 0
            && (bytes[start - 1].is_ascii_alphanumeric()
                || bytes[start - 1] == b'-'
                || bytes[start - 1] == b'.'
                || bytes[start - 1] == b'_')
        {
            start -= 1;
        }
        let mut end = col;
        while end < line.len()
            && (bytes[end].is_ascii_alphanumeric()
                || bytes[end] == b'-'
                || bytes[end] == b'.'
                || bytes[end] == b'_')
        {
            end += 1;
        }

        let word = &line[start..end];
        if word.is_empty() {
            return Ok(None);
        }

        let inventory = if let Some(orch) = self.orchestrator.read().await.as_ref() {
            orch.get_last_known_good()
                .await
                .unwrap_or_default()
                .inventory
        } else {
            Inventory::default()
        };

        Ok(get_hover(&inventory, word))
    }
}

#[tokio::main]
async fn main() {
    let stdin = tokio::io::stdin();
    let stdout = tokio::io::stdout();

    let (service, socket) = LspService::new(Backend::new);
    Server::new(stdin, stdout, socket).serve(service).await;
}
