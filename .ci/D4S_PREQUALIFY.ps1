param(
    [switch]$SelfTest,
    [switch]$PlumbingSelfTest,
    [string]$BundleOverride
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$StudyId='STOIX-VCFE-C1C2-D4S-FC-20261110-01'
$BundleSha='5792d146d135d1a655feb05aa6434d5c4711b8098d6788cc3ac128721bbbc8fd'
$AuthorizationSha='330b3d725d01a507019b57788174e7eb99a2ea829f07a854dc26d8592a123b14'
$ExpectedCommitment='1344463a84d475362b560daadc9d3bc9509f6e001263a25b4b39b3cb27ef40a3'
$ProtocolReceiptSha='53daa431988fc6dccbc15158c815099a1c8940730b7e7ec91c81ec8bc10614b8'
$SeparationReceiptSha='e6487ed4937f39074132379d011144192d101b938eae7fc39697bd9711b4817b'
$PrimaryEntropy='STOIX-VCFE-C1C2-D4S-PRIMARY'
$BackupEntropy='STOIX-VCFE-C1C2-D4S-BACKUP'
$BridgeSha='a3f18c19c2dd2814931313ab6a33445f916fb82e0817869434c967fa2b5f5713'

$AuthorizationJson=@'
{
  "adaptive_ordering": false,
  "base_change_authorized": false,
  "checkpoint": "D4S_PREQUALIFY",
  "commit": false,
  "custody_receipt_sha256": "53daa431988fc6dccbc15158c815099a1c8940730b7e7ec91c81ec8bc10614b8",
  "custody_replacement_authorized": false,
  "early_stop": false,
  "implementation_manifest_sha256": "ed58b0e5d925743fa707c31a936b1fd1304602ecfb0bc769315af8d3f14f77e8",
  "master_seed_commitment_sha256": "1344463a84d475362b560daadc9d3bc9509f6e001263a25b4b39b3cb27ef40a3",
  "maximum_launcher_invocations": 1,
  "model_calls_authorized": 0,
  "preregistration_sha256": "bb9b96d6e5f28b0de022c9d0b107554b81e167515b81b928610f92b0c44d3df2",
  "prior_collision_receipt_sha256": "e6487ed4937f39074132379d011144192d101b938eae7fc39697bd9711b4817b",
  "push": false,
  "real_prequalification_authorized": true,
  "reselection": false,
  "retry": false,
  "runtime_v2_image_id": "sha256:de727f8cdd1e2fcb9cb80d3444b95839af7e76302ca9778520a7243ebe6577ba",
  "schedule_sha256": "7e87b960a4670b7b4f9f7fb80c4a0bf47bd5889d46e376e3bdf21dcfbab3d3eb",
  "schema": "D4S_AUTHORIZATION_v1",
  "schema_sha256": "f844d87e8d8a519d9f6ce4278d6531b0da86315d40952c3959661b4239b2a5d0",
  "scientific_execution_authorized": false,
  "seed_generation_authorized": false,
  "selected_c1_exact_bytes_sha256": "60111278f17e0ccf40e1ad58fe7825f7af6445a81b08c2f769090ebee0b75483",
  "selected_c1_sha256": "1f0bf7503fc36f60072ba23fa87af3bbfb4b895f214746716ac0998700ca0f15",
  "selection_receipt_sha256": "ced37f44729092678365071328257c8ad0d6d8691d7a97c3cab518a529a18114",
  "stage": false,
  "study_id": "STOIX-VCFE-C1C2-D4S-FC-20261110-01",
  "substitute_calls": false,
  "text_format_sha256": "9d2594acc36161d0ec47a7cdfde2e59495bbbc48d24adcde351559b7e92548f3",
  "transport_smoke_receipt_sha256": "7695b525c0598fa5c9c2301942de67b5a74343ab8f173d65d1a900965b6b4add"
}
'@
$AuthorizationJson += "`n"

$BridgePython=@'
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
auth_path = Path(sys.argv[2]).resolve()
auth_sha = sys.argv[3]
custody_path = Path(sys.argv[4]).resolve()
separation_path = Path(sys.argv[5]).resolve()
separation_sha = sys.argv[6]
expected_commitment = sys.argv[7]

sys.path.insert(0, str(root))
import d4s_protocol as d

seed = bytearray(sys.stdin.buffer.read(32))
if len(seed) != 32:
    raise SystemExit("D4S_PREQUALIFY_STDIN_SEED_LENGTH")

master = None
try:
    if hashlib.sha256(seed).hexdigest() != expected_commitment:
        raise SystemExit("D4S_PREQUALIFY_STDIN_SEED_COMMITMENT")
    if not d.verify_inputs():
        raise SystemExit("D4S_PREQUALIFY_FROZEN_INPUTS")
    if not d.schema_neutrality():
        raise SystemExit("D4S_PREQUALIFY_SCHEMA_NEUTRALITY")
    if len(d.schedule_check()) != 30:
        raise SystemExit("D4S_PREQUALIFY_SCHEDULE")

    auth = d.Authorization(auth_path, auth_sha, "PREQUALIFY")
    master = d.real_master(bytes(seed), bytes(seed), auth, custody_path)

    count = {"n": 0}
    def counted_evaluator(task, source, candidate):
        count["n"] += 1
        if count["n"] % 120 == 0:
            print(f"D4S_PREQUALIFY_PROGRESS={count['n']}/720", flush=True)
        return d.verifier.evaluate_one(task, source, candidate)

    receipt_path = d.ROOT / d.PREQUALIFICATION_NAME
    gate = d.prequalify(master, receipt_path, separation_path, separation_sha, evaluator=counted_evaluator)
    if count["n"] != 720:
        raise SystemExit(f"D4S_PREQUALIFY_EVALUATOR_COUNT::{count['n']}")
    gate.check()
    raw = receipt_path.read_bytes()
    receipt = json.loads(raw)
    if receipt.get("status") != "PASS":
        raise SystemExit("D4S_PREQUALIFY_RECEIPT_STATUS")
    if receipt.get("model_calls") != 0 or receipt.get("scientific_executions") != 0:
        raise SystemExit("D4S_PREQUALIFY_ZERO_MODEL_CALL_BOUNDARY")
    if receipt.get("master_seed_commitment_sha256") != expected_commitment:
        raise SystemExit("D4S_PREQUALIFY_RECEIPT_COMMITMENT")
    rows = receipt.get("geometry_results")
    if not isinstance(rows, list) or len(rows) != 10:
        raise SystemExit("D4S_PREQUALIFY_GEOMETRY_ROWS")
    if sum(1 for row in rows if row.get("c1_alone_success")) != 0:
        raise SystemExit("D4S_PREQUALIFY_C1_ALONE_THRESHOLD")
    if sum(1 for row in rows if row.get("inert_success")) > 1:
        raise SystemExit("D4S_PREQUALIFY_INERT_THRESHOLD")
    if not all(row.get("reference_tasks_passed") == 24 for row in rows):
        raise SystemExit("D4S_PREQUALIFY_REFERENCE_TASK_COUNT")
    print("D4S_PREQUALIFICATION_STATUS=PASS", flush=True)
    print("D4S_PREQUALIFICATION_EVALUATOR_CALLS=720", flush=True)
    print("D4S_PREQUALIFICATION_MODEL_CALLS=0", flush=True)
    print("D4S_PREQUALIFICATION_SCIENTIFIC_EXECUTIONS=0", flush=True)
    print("D4S_PREQUALIFICATION_RECEIPT_PATH=" + str(receipt_path), flush=True)
    print("D4S_PREQUALIFICATION_RECEIPT_SHA256=" + gate.sha256, flush=True)
    print("D4S_MASTER_SEED_COMMITMENT_SHA256=" + expected_commitment, flush=True)
finally:
    if master is not None:
        master.clear()
    for i in range(len(seed)):
        seed[i] = 0
'@

function Require-Condition([bool]$Condition,[string]$Code){if(-not $Condition){throw $Code}}

function Get-Sha256Hex([byte[]]$Bytes){
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}
    finally{$sha.Dispose()}
}

function Get-FileSha256Hex([string]$Path){
    $b=[IO.File]::ReadAllBytes($Path)
    try{return Get-Sha256Hex $b}
    finally{if($b){[Array]::Clear($b,0,$b.Length)}}
}

function Write-NewUtf8([string]$Path,[string]$Text){
    $enc=[Text.UTF8Encoding]::new($false)
    $bytes=$enc.GetBytes($Text)
    try{
        $fs=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$fs.Write($bytes,0,$bytes.Length);$fs.Flush($true)}finally{$fs.Dispose()}
    }finally{[Array]::Clear($bytes,0,$bytes.Length)}
}

function Protect-Bytes([byte[]]$Plain,[string]$EntropyText,[Security.Cryptography.DataProtectionScope]$Scope){
    $entropy=[Text.Encoding]::UTF8.GetBytes($EntropyText)
    try{return [byte[]][Security.Cryptography.ProtectedData]::Protect($Plain,$entropy,$Scope)}
    finally{[Array]::Clear($entropy,0,$entropy.Length)}
}

function Unprotect-Bytes([byte[]]$Cipher,[string]$EntropyText,[Security.Cryptography.DataProtectionScope]$Scope){
    $entropy=[Text.Encoding]::UTF8.GetBytes($EntropyText)
    try{return [byte[]][Security.Cryptography.ProtectedData]::Unprotect($Cipher,$entropy,$Scope)}
    finally{[Array]::Clear($entropy,0,$entropy.Length)}
}

function Get-Python312 {
    $py=Get-Command py.exe -ErrorAction Si∂ªßq´^u˙+v+)ï¨ü∫Ym¢âbûõ≠≠ÎZäwù