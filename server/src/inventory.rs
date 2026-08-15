use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct AnalysisDocument {
    pub version: u32,
    pub findings: Vec<Finding>,
    pub inventory: Inventory,
    #[serde(default)]
    pub summary: Option<Summary>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct Summary {
    pub gating: usize,
    pub advisory: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Finding {
    pub rule: String,
    pub severity: String,
    #[serde(rename = "aspectPath")]
    pub aspect_path: String,
    pub position: Option<FindingPosition>,
    pub message: String,
    pub fix: String,
    #[serde(rename = "docRef")]
    pub doc_ref: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct FindingPosition {
    pub file: String,
    pub line: u32,
    #[serde(default)]
    pub column: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct Inventory {
    #[serde(default)]
    pub classes: HashMap<String, ClassInfo>,
    #[serde(default)]
    pub quirks: HashMap<String, QuirkInfo>,
    #[serde(default)]
    pub batteries: HashMap<String, BatteryInfo>,
    #[serde(default)]
    pub aspects: HashMap<String, AspectInfo>,
    #[serde(rename = "structuralKeys", default)]
    pub structural_keys: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct ClassInfo {
    pub description: Option<String>,
}

pub type QuirkInfo = ClassInfo;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct BatteryInfo {
    pub description: Option<String>,
    #[serde(default)]
    pub provides: Vec<String>,
    #[serde(default)]
    pub keys: Vec<String>,
    #[serde(default)]
    pub callable: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct AspectInfo {
    pub description: Option<String>,
    #[serde(default)]
    pub provides: Vec<String>,
    #[serde(default)]
    pub keys: Vec<String>,
    #[serde(default)]
    pub callable: bool,
    pub file: Option<String>,
    pub position: Option<FindingPosition>,
}
