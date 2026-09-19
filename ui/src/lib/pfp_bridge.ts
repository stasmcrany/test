/**
 * AXIOM CLOUD LABS // VERDICTUM V2
 * MODULE: Platform Feedback Protocol Bridge (PFP)
 * STATUS: STRICT COMPLIANCE
 *
 * [ARCHIVE LOG: 2026-05-09]
 * Implements PFP packet signing for AEGIS enforcement requests.
 * Parity rule: sign_string must match aegis.py:verify_pfp_signature exactly.
 * sign_string = `${magic_bytes}|${timestamp}|${action}|${target_arn}|${license_tier}|${nonce}`
 * HMAC-SHA256 via Web Crypto API (browser-compatible, no Node.js crypto).
 */

const MAGIC_BYTES = "AXM_V1";
const PFP_SECRET = process.env.NEXT_PUBLIC_PFP_SECRET ?? "AXM_FIBO_0112358";
const STOIX_API_KEY = process.env.NEXT_PUBLIC_STOIX_API_KEY ?? "";

async function hmacSha256Hex(secret: string, message: string): Promise<string> {
    const enc = new TextEncoder();
    const key = await crypto.subtle.importKey(
        "raw",
        enc.encode(secret),
        { name: "HMAC", hash: "SHA-256" },
        false,
        ["sign"]
    );
    const sigBuffer = await crypto.subtle.sign("HMAC", key, enc.encode(message));
    return Array.from(new Uint8Array(sigBuffer))
        .map(b => b.toString(16).padStart(2, "0"))
        .join("");
}

export interface EnforcementResult {
    success: boolean;
    status: number;
    latency: number;
    body: Record<string, unknown>;
    error?: string;
}

export async function executeEnforcement(
    action: string,
    targetArn: string,
    ticket: Record<string, any>, // ИНЖЕКТ: Теперь принимаем объект билета
    endpoint: string
): Promise<EnforcementResult> {
    const t0 = performance.now();

    if (!endpoint) {
        console.error("[PFP] ENFORCE_API_URL is not configured.");
        return { success: false, status: 0, latency: 0, body: {}, error: "ENDPOINT_NOT_CONFIGURED" };
    }

    const timestamp = Date.now().toString();
    const nonce = crypto.randomUUID();
    
    // Извлекаем tier для сохранения обратной совместимости старой подписи PFP
    const licenseTier = ticket.major_status || "COMMUNITY"; 
    
    const signString = `${MAGIC_BYTES}|${timestamp}|${action}|${targetArn}|${licenseTier}|${nonce}`;
    const signature = await hmacSha256Hex(PFP_SECRET, signString);

    const packet = {
        magic_bytes: MAGIC_BYTES,
        timestamp,
        action,
        target_arn: targetArn,
        license_tier: licenseTier,
        nonce,
        signature,
        ticket // <-- ПЕРЕДАЧА БИЛЕТА ДЛЯ НОВОГО GATEKEEPER
    };

    // [PFP] Packet dispatched (logs removed for production)

    try {
        const response = await fetch(endpoint, {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                "x-api-key": STOIX_API_KEY,
            },
            body: JSON.stringify(packet),
        });

        const latency = Math.round(performance.now() - t0);
        let body: Record<string, unknown> = {};
        try { body = await response.json(); } catch { /* non-JSON body */ }

        // [PFP] Response received (logs removed for production)

        return {
            success: response.ok,
            status: response.status,
            latency,
            body,
        };
    } catch (err) {
        const latency = Math.round(performance.now() - t0);
        const errorMsg = err instanceof Error ? err.message : String(err);
        console.error("[PFP] <<< Network/CORS error:", errorMsg);
        return { success: false, status: 0, latency, body: {}, error: errorMsg };
    }
}