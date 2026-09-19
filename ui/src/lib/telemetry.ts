/**
 * AXIOM CLOUD LABS // VERDICTUM V2
 * MODULE: Live Telemetry WebSocket Client
 * STATUS: STRICT COMPLIANCE
 *
 * [ARCHIVE LOG: 2026-05-09]
 * Singleton WebSocket manager with Exponential Backoff reconnect
 * and 30s Heartbeat to prevent AWS API Gateway idle timeout.
 */

export interface TelemetryNodeUpdate {
    id: string;
    tension: number;
    status: string;
}

export interface TelemetryMessage {
    type: "UPDATE";
    payload: {
        entropy: number;
        nodes: TelemetryNodeUpdate[];
    };
}

export type TelemetryHandler = (msg: TelemetryMessage) => void;

const HEARTBEAT_INTERVAL_MS = 30_000;
const BACKOFF_BASE_MS = 1_000;
const BACKOFF_MAX_MS = 30_000;
const BACKOFF_MULTIPLIER = 2;

class TelemetryClient {
    private url: string;
    private token: string;
    private ws: WebSocket | null = null;
    private handler: TelemetryHandler | null = null;
    private onConnectCallback: (() => void) | null = null;
    private onDisconnectCallback: (() => void) | null = null;

    private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
    private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
    private reconnectDelay = BACKOFF_BASE_MS;

    private destroyed = false;

    constructor(url: string, token: string = '') {
        this.url = url;
        this.token = token;
    }

    connect(
        handler: TelemetryHandler,
        onConnect: () => void,
        onDisconnect: () => void
    ): void {
        this.handler = handler;
        this.onConnectCallback = onConnect;
        this.onDisconnectCallback = onDisconnect;
        this.destroyed = false;
        this._open();
    }

    destroy(): void {
        this.destroyed = true;
        this._clearTimers();
        if (this.ws) {
            this.ws.onclose = null;
            this.ws.onerror = null;
            this.ws.onmessage = null;
            this.ws.onopen = null;
            this.ws.close();
            this.ws = null;
        }
    }

    private _open(): void {
        if (this.destroyed) return;

        try {
            const wsUrl = this.token ? `${this.url}?token=${this.token}` : this.url;
            this.ws = new WebSocket(wsUrl);
        } catch {
            this._scheduleReconnect();
            return;
        }

        this.ws.onopen = () => {
            if (this.destroyed) return;
            this.reconnectDelay = BACKOFF_BASE_MS;
            this._startHeartbeat();
            this.onConnectCallback?.();
        };

        this.ws.onmessage = (event: MessageEvent) => {
            if (this.destroyed) return;
            try {
                const msg = JSON.parse(event.data as string) as TelemetryMessage;
                if (msg.type === "UPDATE") {
                    this.handler?.(msg);
                }
            } catch {
                // malformed frame — ignore
            }
        };

        this.ws.onclose = () => {
            if (this.destroyed) return;
            this._clearHeartbeat();
            this.onDisconnectCallback?.();
            this._scheduleReconnect();
        };

        this.ws.onerror = () => {
            // onerror is always followed by onclose; let onclose handle reconnect
            this.ws?.close();
        };
    }

    private _startHeartbeat(): void {
        this._clearHeartbeat();
        this.heartbeatTimer = setInterval(() => {
            if (this.ws?.readyState === WebSocket.OPEN) {
                this.ws.send(JSON.stringify({ type: "PING" }));
            }
        }, HEARTBEAT_INTERVAL_MS);
    }

    private _clearHeartbeat(): void {
        if (this.heartbeatTimer !== null) {
            clearInterval(this.heartbeatTimer);
            this.heartbeatTimer = null;
        }
    }

    private _scheduleReconnect(): void {
        if (this.destroyed) return;
        this._clearReconnect();
        this.reconnectTimer = setTimeout(() => {
            this.reconnectDelay = Math.min(
                this.reconnectDelay * BACKOFF_MULTIPLIER,
                BACKOFF_MAX_MS
            );
            this._open();
        }, this.reconnectDelay);
    }

    private _clearReconnect(): void {
        if (this.reconnectTimer !== null) {
            clearTimeout(this.reconnectTimer);
            this.reconnectTimer = null;
        }
    }

    private _clearTimers(): void {
        this._clearHeartbeat();
        this._clearReconnect();
    }
}

// --- Singleton registry keyed by URL ---
const _instances = new Map<string, TelemetryClient>();

export function getTelemetryClient(url: string, token: string = ''): TelemetryClient {
    const key = token ? `${url}?token=${token}` : url;
    if (!_instances.has(key)) {
        _instances.set(key, new TelemetryClient(url, token));
    }
    return _instances.get(key)!;
}

export function destroyTelemetryClient(url: string): void {
    const client = _instances.get(url);
    if (client) {
        client.destroy();
        _instances.delete(url);
    }
}
