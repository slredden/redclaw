/**
 * OpenClaw Gmail Plugin
 *
 * Direct Gmail API integration via Google OAuth2.
 * Replaces the Maton gateway with first-party Google API calls.
 *
 * Tools: gmail_profile, gmail_list, gmail_read, gmail_send, gmail_reply,
 *        gmail_label, gmail_trash, gmail_drafts, gmail_threads
 *
 * CLI: openclaw gmail auth — run initial OAuth consent flow
 */

import { Type } from "@sinclair/typebox";
import type { OpenClawPluginApi } from "openclaw/plugin-sdk";
import fs from "node:fs";
import path from "node:path";
import http from "node:http";
import { URL } from "node:url";

// ============================================================================
// Types
// ============================================================================

type GmailConfig = {
  clientSecretPath: string;
  tokenPath: string;
};

type ClientSecret = {
  installed: {
    client_id: string;
    client_secret: string;
    redirect_uris: string[];
    auth_uri: string;
    token_uri: string;
  };
};

type StoredToken = {
  access_token: string;
  refresh_token: string;
  token_type: string;
  expiry_date: number;
  scope: string;
};

// ============================================================================
// Constants
// ============================================================================

const SCOPES = [
  "https://www.googleapis.com/auth/gmail.readonly",
  "https://www.googleapis.com/auth/gmail.send",
  "https://www.googleapis.com/auth/gmail.modify",
  "https://www.googleapis.com/auth/gmail.compose",
];

const DEFAULT_CLIENT_SECRET_PATH = path.join(
  process.env.HOME ?? "~",
  ".openclaw",
  "credentials",
  "gmail-client-secret.json",
);

const DEFAULT_TOKEN_PATH = path.join(
  process.env.HOME ?? "~",
  ".openclaw",
  "credentials",
  "gmail-token.json",
);

// ============================================================================
// Config Parser
// ============================================================================

const gmailConfigSchema = {
  parse(value: unknown): GmailConfig {
    const cfg =
      value && typeof value === "object" && !Array.isArray(value)
        ? (value as Record<string, unknown>)
        : {};

    return {
      clientSecretPath:
        typeof cfg.clientSecretPath === "string" && cfg.clientSecretPath
          ? cfg.clientSecretPath
          : DEFAULT_CLIENT_SECRET_PATH,
      tokenPath:
        typeof cfg.tokenPath === "string" && cfg.tokenPath
          ? cfg.tokenPath
          : DEFAULT_TOKEN_PATH,
    };
  },
};

// ============================================================================
// OAuth2 Client
// ============================================================================

class GmailAuth {
  private clientSecret: ClientSecret | null = null;
  private token: StoredToken | null = null;
  private accessToken: string | null = null;

  constructor(
    private readonly clientSecretPath: string,
    private readonly tokenPath: string,
  ) {}

  private loadClientSecret(): ClientSecret {
    if (this.clientSecret) return this.clientSecret;
    if (!fs.existsSync(this.clientSecretPath)) {
      throw new Error(
        `Client secret not found at ${this.clientSecretPath}. ` +
          `Download it from Google Cloud Console and place it there.`,
      );
    }
    this.clientSecret = JSON.parse(
      fs.readFileSync(this.clientSecretPath, "utf-8"),
    );
    return this.clientSecret!;
  }

  private loadToken(): StoredToken | null {
    if (this.token) return this.token;
    if (!fs.existsSync(this.tokenPath)) return null;
    this.token = JSON.parse(fs.readFileSync(this.tokenPath, "utf-8"));
    return this.token;
  }

  private saveToken(token: StoredToken): void {
    const dir = path.dirname(this.tokenPath);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(this.tokenPath, JSON.stringify(token, null, 2));
    this.token = token;
    this.accessToken = token.access_token;
  }

  /**
   * Get a valid access token, refreshing if needed.
   */
  async getAccessToken(): Promise<string> {
    const token = this.loadToken();
    if (!token) {
      throw new Error(
        "Not authenticated. Run `openclaw gmail auth` to sign in.",
      );
    }

    // If token is still valid (with 60s buffer), return it
    if (token.expiry_date > Date.now() + 60_000 && this.accessToken) {
      return this.accessToken;
    }

    // Refresh the token
    const secret = this.loadClientSecret();
    const body = new URLSearchParams({
      client_id: secret.installed.client_id,
      client_secret: secret.installed.client_secret,
      refresh_token: token.refresh_token,
      grant_type: "refresh_token",
    });

    const resp = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: body.toString(),
    });

    if (!resp.ok) {
      const errText = await resp.text();
      throw new Error(`Token refresh failed: ${resp.status} ${errText}`);
    }

    const data = (await resp.json()) as {
      access_token: string;
      expires_in: number;
      token_type: string;
      scope?: string;
    };

    const refreshed: StoredToken = {
      access_token: data.access_token,
      refresh_token: token.refresh_token, // keep existing refresh token
      token_type: data.token_type,
      expiry_date: Date.now() + data.expires_in * 1000,
      scope: data.scope ?? token.scope,
    };

    this.saveToken(refreshed);
    return refreshed.access_token;
  }

  /**
   * Run interactive OAuth consent flow. Opens browser, starts local server.
   */
  async runAuthFlow(): Promise<void> {
    const secret = this.loadClientSecret();
    const redirectPort = 8095;
    const redirectUri = `http://localhost:${redirectPort}`;

    const authUrl = new URL(secret.installed.auth_uri);
    authUrl.searchParams.set("client_id", secret.installed.client_id);
    authUrl.searchParams.set("redirect_uri", redirectUri);
    authUrl.searchParams.set("response_type", "code");
    authUrl.searchParams.set("scope", SCOPES.join(" "));
    authUrl.searchParams.set("access_type", "offline");
    authUrl.searchParams.set("prompt", "consent");

    return new Promise<void>((resolve, reject) => {
      const server = http.createServer(async (req, res) => {
        try {
          const reqUrl = new URL(req.url!, `http://localhost:${redirectPort}`);
          const code = reqUrl.searchParams.get("code");
          const error = reqUrl.searchParams.get("error");

          if (error) {
            res.writeHead(400, { "Content-Type": "text/html" });
            res.end(`<h1>Authorization failed</h1><p>${error}</p>`);
            server.close();
            reject(new Error(`OAuth error: ${error}`));
            return;
          }

          if (!code) {
            res.writeHead(400, { "Content-Type": "text/html" });
            res.end("<h1>No authorization code received</h1>");
            return;
          }

          // Exchange code for tokens
          const body = new URLSearchParams({
            code,
            client_id: secret.installed.client_id,
            client_secret: secret.installed.client_secret,
            redirect_uri: redirectUri,
            grant_type: "authorization_code",
          });

          const tokenResp = await fetch(
            "https://oauth2.googleapis.com/token",
            {
              method: "POST",
              headers: {
                "Content-Type": "application/x-www-form-urlencoded",
              },
              body: body.toString(),
            },
          );

          if (!tokenResp.ok) {
            const errText = await tokenResp.text();
            res.writeHead(500, { "Content-Type": "text/html" });
            res.end(`<h1>Token exchange failed</h1><pre>${errText}</pre>`);
            server.close();
            reject(new Error(`Token exchange failed: ${errText}`));
            return;
          }

          const data = (await tokenResp.json()) as {
            access_token: string;
            refresh_token: string;
            expires_in: number;
            token_type: string;
            scope: string;
          };

          const token: StoredToken = {
            access_token: data.access_token,
            refresh_token: data.refresh_token,
            token_type: data.token_type,
            expiry_date: Date.now() + data.expires_in * 1000,
            scope: data.scope,
          };

          this.saveToken(token);

          res.writeHead(200, { "Content-Type": "text/html" });
          res.end(
            "<h1>Gmail authorization successful!</h1><p>You can close this window and return to the terminal.</p>",
          );
          server.close();
          resolve();
        } catch (err) {
          res.writeHead(500, { "Content-Type": "text/html" });
          res.end(`<h1>Error</h1><pre>${String(err)}</pre>`);
          server.close();
          reject(err);
        }
      });

      server.listen(redirectPort, async () => {
        console.log(`\nOpening browser for Gmail authorization...`);
        console.log(`If the browser doesn't open, visit:\n${authUrl.toString()}\n`);
        try {
          const openMod = await import("open");
          const openFn = openMod.default ?? openMod;
          await openFn(authUrl.toString());
        } catch {
          // open might not work in headless environments
          console.log("Could not open browser automatically.");
        }
      });

      // Timeout after 2 minutes
      setTimeout(() => {
        server.close();
        reject(new Error("OAuth flow timed out after 2 minutes"));
      }, 120_000);
    });
  }
}

// ============================================================================
// Gmail API Helper
// ============================================================================

class GmailClient {
  constructor(private readonly auth: GmailAuth) {}

  private async request(
    endpoint: string,
    options: {
      method?: string;
      body?: unknown;
      params?: Record<string, string>;
    } = {},
  ): Promise<any> {
    const accessToken = await this.auth.getAccessToken();
    const url = new URL(
      `https://gmail.googleapis.com/gmail/v1/users/me/${endpoint}`,
    );
    if (options.params) {
      for (const [k, v] of Object.entries(options.params)) {
        url.searchParams.set(k, v);
      }
    }

    const fetchOptions: RequestInit = {
      method: options.method ?? "GET",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
    };

    if (options.body) {
      fetchOptions.body = JSON.stringify(options.body);
    }

    const resp = await fetch(url.toString(), fetchOptions);
    if (!resp.ok) {
      const errText = await resp.text();
      throw new Error(`Gmail API ${resp.status}: ${errText}`);
    }

    // Some endpoints return 204 No Content
    if (resp.status === 204) return {};

    return resp.json();
  }

  async getProfile() {
    return this.request("profile");
  }

  async listMessages(query?: string, maxResults = 20, pageToken?: string) {
    const params: Record<string, string> = {
      maxResults: String(maxResults),
    };
    if (query) params.q = query;
    if (pageToken) params.pageToken = pageToken;
    return this.request("messages", { params });
  }

  async getMessage(id: string, format: "full" | "metadata" | "minimal" = "full") {
    return this.request(`messages/${id}`, {
      params: { format },
    });
  }

  async sendMessage(raw: string) {
    return this.request("messages/send", {
      method: "POST",
      body: { raw },
    });
  }

  async trashMessage(id: string) {
    return this.request(`messages/${id}/trash`, { method: "POST" });
  }

  async modifyMessage(
    id: string,
    addLabels: string[],
    removeLabels: string[],
  ) {
    return this.request(`messages/${id}/modify`, {
      method: "POST",
      body: {
        addLabelIds: addLabels,
        removeLabelIds: removeLabels,
      },
    });
  }

  async listLabels() {
    return this.request("labels");
  }

  async listDrafts(maxResults = 20) {
    return this.request("drafts", {
      params: { maxResults: String(maxResults) },
    });
  }

  async getDraft(id: string) {
    return this.request(`drafts/${id}`, {
      params: { format: "full" },
    });
  }

  async createDraft(raw: string) {
    return this.request("drafts", {
      method: "POST",
      body: { message: { raw } },
    });
  }

  async sendDraft(draftId: string) {
    return this.request("drafts/send", {
      method: "POST",
      body: { id: draftId },
    });
  }

  async listThreads(query?: string, maxResults = 20, pageToken?: string) {
    const params: Record<string, string> = {
      maxResults: String(maxResults),
    };
    if (query) params.q = query;
    if (pageToken) params.pageToken = pageToken;
    return this.request("threads", { params });
  }

  async getThread(id: string, format: "full" | "metadata" | "minimal" = "full") {
    return this.request(`threads/${id}`, {
      params: { format },
    });
  }
}

// ============================================================================
// Message Helpers
// ============================================================================

function getHeader(
  headers: Array<{ name: string; value: string }>,
  name: string,
): string {
  const h = headers?.find(
    (h) => h.name.toLowerCase() === name.toLowerCase(),
  );
  return h?.value ?? "";
}

function decodeBase64Url(data: string): string {
  const base64 = data.replace(/-/g, "+").replace(/_/g, "/");
  return Buffer.from(base64, "base64").toString("utf-8");
}

function extractTextBody(payload: any): string {
  // Direct body
  if (payload.body?.data) {
    return decodeBase64Url(payload.body.data);
  }

  // Multipart — recurse
  if (payload.parts) {
    // Prefer text/plain, fall back to text/html
    for (const mimeType of ["text/plain", "text/html"]) {
      for (const part of payload.parts) {
        if (part.mimeType === mimeType && part.body?.data) {
          let text = decodeBase64Url(part.body.data);
          if (mimeType === "text/html") {
            // Basic HTML stripping for readability
            text = text
              .replace(/<style[^>]*>[\s\S]*?<\/style>/gi, "")
              .replace(/<script[^>]*>[\s\S]*?<\/script>/gi, "")
              .replace(/<[^>]+>/g, " ")
              .replace(/&nbsp;/g, " ")
              .replace(/&amp;/g, "&")
              .replace(/&lt;/g, "<")
              .replace(/&gt;/g, ">")
              .replace(/&quot;/g, '"')
              .replace(/\s+/g, " ")
              .trim();
          }
          return text;
        }
        // Nested multipart (e.g., multipart/alternative inside multipart/mixed)
        if (part.parts) {
          const nested = extractTextBody(part);
          if (nested) return nested;
        }
      }
    }
  }

  return "";
}

function listAttachments(payload: any): Array<{ filename: string; mimeType: string; size: number }> {
  const attachments: Array<{ filename: string; mimeType: string; size: number }> = [];

  function walk(part: any) {
    if (part.filename && part.body?.attachmentId) {
      attachments.push({
        filename: part.filename,
        mimeType: part.mimeType ?? "application/octet-stream",
        size: part.body.size ?? 0,
      });
    }
    if (part.parts) {
      for (const sub of part.parts) walk(sub);
    }
  }

  walk(payload);
  return attachments;
}

function formatMessageSummary(msg: any): string {
  const headers = msg.payload?.headers ?? [];
  const from = getHeader(headers, "From");
  const to = getHeader(headers, "To");
  const subject = getHeader(headers, "Subject");
  const date = getHeader(headers, "Date");
  const snippet = msg.snippet ?? "";

  return `ID: ${msg.id} | Thread: ${msg.threadId}\nFrom: ${from}\nTo: ${to}\nDate: ${date}\nSubject: ${subject}\nSnippet: ${snippet}`;
}

function encodeRawEmail(options: {
  to: string;
  subject: string;
  body: string;
  cc?: string;
  bcc?: string;
  inReplyTo?: string;
  references?: string;
  threadId?: string;
}): string {
  const lines: string[] = [];
  lines.push(`To: ${options.to}`);
  if (options.cc) lines.push(`Cc: ${options.cc}`);
  if (options.bcc) lines.push(`Bcc: ${options.bcc}`);
  lines.push(`Subject: ${options.subject}`);
  lines.push("Content-Type: text/plain; charset=utf-8");
  if (options.inReplyTo) lines.push(`In-Reply-To: ${options.inReplyTo}`);
  if (options.references) lines.push(`References: ${options.references}`);
  lines.push("");
  lines.push(options.body);

  const raw = lines.join("\r\n");
  return Buffer.from(raw)
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

// ============================================================================
// Plugin Definition
// ============================================================================

const gmailPlugin = {
  id: "openclaw-gmail",
  name: "Gmail",
  description: "Gmail integration via Google OAuth2 — direct API, no third-party proxy",
  kind: "tool" as const,
  configSchema: gmailConfigSchema,

  register(api: OpenClawPluginApi) {
    const cfg = gmailConfigSchema.parse(api.pluginConfig);
    const auth = new GmailAuth(cfg.clientSecretPath, cfg.tokenPath);
    const gmail = new GmailClient(auth);

    api.logger.info(
      `openclaw-gmail: registered (clientSecret: ${cfg.clientSecretPath}, token: ${cfg.tokenPath})`,
    );

    // ========================================================================
    // Tools
    // ========================================================================

    // --- gmail_profile ---
    api.registerTool(
      {
        name: "gmail_profile",
        label: "Gmail Profile",
        description:
          "Get the authenticated Gmail user's profile (email address, message count, thread count).",
        parameters: Type.Object({}),
        async execute() {
          try {
            const profile = await gmail.getProfile();
            return {
              content: [
                {
                  type: "text",
                  text: `Email: ${profile.emailAddress}\nMessages: ${profile.messagesTotal}\nThreads: ${profile.threadsTotal}\nHistory ID: ${profile.historyId}`,
                },
              ],
              details: profile,
            };
          } catch (err) {
            return {
              content: [{ type: "text", text: `Failed: ${String(err)}` }],
              details: { error: String(err) },
            };
          }
        },
      },
      { name: "gmail_profile" },
    );

    // --- gmail_list ---
    api.registerTool(
      {
        name: "gmail_list",
        label: "Gmail List",
        description:
          'List or search Gmail messages using Gmail query syntax (e.g. "is:unread", "from:user@example.com", "subject:invoice newer_than:7d"). Returns message IDs and snippets.',
        parameters: Type.Object({
          query: Type.Optional(
            Type.String({
              description:
                'Gmail search query (e.g. "is:unread", "from:boss@co.com newer_than:1d")',
            }),
          ),
          maxResults: Type.Optional(
            Type.Number({
              description: "Max messages to return (default: 20, max: 100)",
            }),
          ),
          pageToken: Type.Optional(
            Type.String({ description: "Pagination token from previous call" }),
          ),
        }),
        async execute(_toolCallId, params) {
          const {
            query,
            maxResults = 20,
            pageToken,
          } = params as {
            query?: string;
            maxResults?: number;
            pageToken?: string;
          };

          try {
            const result = await gmail.listMessages(
              query,
              Math.min(maxResults, 100),
              pageToken,
            );
            const messages = result.messages ?? [];

            if (messages.length === 0) {
              return {
                content: [
                  {
                    type: "text",
                    text: `No messages found${query ? ` for query: "${query}"` : ""}.`,
                  },
                ],
                details: { count: 0 },
              };
            }

            // Fetch metadata for each message
            const details = await Promise.all(
              messages.map((m: any) => gmail.getMessage(m.id, "metadata")),
            );

            const summaries = details.map((msg: any) => {
              const headers = msg.payload?.headers ?? [];
              const from = getHeader(headers, "From");
              const subject = getHeader(headers, "Subject");
              const date = getHeader(headers, "Date");
              const labels = (msg.labelIds ?? []).join(", ");
              return `- ${msg.id} | ${date} | ${from} | ${subject} [${labels}]`;
            });

            let text = `Found ${result.resultSizeEstimate ?? messages.length} messages:\n\n${summaries.join("\n")}`;
            if (result.nextPageToken) {
              text += `\n\nMore results available. Use pageToken: "${result.nextPageToken}"`;
            }

            return {
              content: [{ type: "text", text }],
              details: {
                count: messages.length,
                nextPageToken: result.nextPageToken,
                messages: details.map((m: any) => ({
                  id: m.id,
                  threadId: m.threadId,
                  snippet: m.snippet,
                  labelIds: m.labelIds,
                  from: getHeader(m.payload?.headers ?? [], "From"),
                  subject: getHeader(m.payload?.headers ?? [], "Subject"),
                  date: getHeader(m.payload?.headers ?? [], "Date"),
                })),
              },
            };
          } catch (err) {
            return {
              content: [{ type: "text", text: `Failed: ${String(err)}` }],
              details: { error: String(err) },
            };
          }
        },
      },
      { name: "gmail_list" },
    );

    // --- gmail_read ---
    api.registerTool(
      {
        name: "gmail_read",
        label: "Gmail Read",
        description:
          "Get a full email message by ID. Returns headers, body text, and attachment list.",
        parameters: Type.Object({
          messageId: Type.String({ description: "The message ID to read" }),
        }),
        async execute(_toolCallId, params) {
          const { messageId } = params as { messageId: string };

          try {
            const msg = await gmail.getMessage(messageId, "full");
            const headers = msg.payload?.headers ?? [];
            const body = extractTextBody(msg.payload);
            const attachments = listAttachments(msg.payload);

            const headerBlock = [
              `From: ${getHeader(headers, "From")}`,
              `To: ${getHeader(headers, "To")}`,
              `Cc: ${getHeader(headers, "Cc")}`,
              `Date: ${getHeader(headers, "Date")}`,
              `Subject: ${getHeader(headers, "Subject")}`,
              `Message-ID: ${getHeader(headers, "Message-ID")}`,
              `Labels: ${(msg.labelIds ?? []).join(", ")}`,
            ]
              .filter((l) => !l.endsWith(": "))
              .join("\n");

            let text = `${headerBlock}\n\n${body}`;

            if (attachments.length > 0) {
              text += `\n\nAttachments (${attachments.length}):\n`;
              text += attachments
                .map(
                  (a) =>
                    `- ${a.filename} (${a.mimeType}, ${Math.round(a.size / 1024)}KB)`,
                )
                .join("\n");
            }

            return {
              content: [{ type: "text", text }],
              details: {
                id: msg.id,
                threadId: msg.threadId,
                labelIds: msg.labelIds,
                attachments,
              },
            };
          } catch (err) {
            return {
              content: [{ type: "text", text: `Failed: ${String(err)}` }],
              details: { error: String(err) },
            };
          }
        },
      },
      { name: "gmail_read" },
    );

    // --- gmail_send ---
    api.registerTool(
      {
        name: "gmail_send",
        label: "Gmail Send",
        description: "Send a new email message.",
        parameters: Type.Object({
          to: Type.String({ description: "Recipient email address(es), comma-separated" }),
          subject: Type.String({ description: "Email subject line" }),
          body: Type.String({ description: "Email body text (plain text)" }),
          cc: Type.Optional(
            Type.String({ description: "CC recipients, comma-separated" }),
          ),
          bcc: Type.Optional(
            Type.String({ description: "BCC recipients, comma-separated" }),
          ),
        }),
        async execute(_toolCallId, params) {
          const { to, subject, body, cc, bcc } = params as {
            to: string;
            subject: string;
            body: string;
            cc?: string;
            bcc?: string;
          };

          try {
            const raw = encodeRawEmail({ to, subject, body, cc, bcc });
            const result = await gmail.sendMessage(raw);

            return {
              content: [
                {
                  type: "text",
                  text: `Email sent successfully.\nMessage ID: ${result.id}\nThread ID: ${result.threadId}`,
                },
              ],
              details: { id: result.id, threadId: result.threadId },
            };
          } catch (err) {
            return {
              content: [{ type: "text", text: `Failed: ${String(err)}` }],
              details: { error: String(err) },
            };
          }
        },
      },
      { name: "gmail_send" },
    );

    // --- gmail_reply ---
    api.registerTool(
      {
        name: "gmail_reply",
        label: "Gmail Reply",
        description:
          "Reply to an existing email message. Automatically sets In-Reply-To/References headers and keeps the thread.",
        parameters: Type.Object({
          messageId: Type.String({
            description: "ID of the message to reply to",
          }),
          body: Type.String({ description: "Reply body text (plain text)" }),
          cc: Type.Optional(
            Type.String({ description: "CC recipients, comma-separated" }),
          ),
          replyAll: Type.Optional(
            Type.Boolean({
              description: "Reply to all recipients (default: false)",
            }),
          ),
        }),
        async execute(_toolCallId, params) {
          const { messageId, body, cc, replyAll = false } = params as {
            messageId: string;
            body: string;
            cc?: string;
            replyAll?: boolean;
          };

          try {
            // Fetch original message headers
            const original = await gmail.getMessage(messageId, "metadata");
            const headers = original.payload?.headers ?? [];
            const origFrom = getHeader(headers, "From");
            const origTo = getHeader(headers, "To");
            const origSubject = getHeader(headers, "Subject");
            const origMessageId = getHeader(headers, "Message-ID");
            const origReferences = getHeader(headers, "References");

            // Determine reply-to address
            const to = replyAll
              ? [origFrom, origTo].filter(Boolean).join(", ")
              : origFrom;

            const subject = origSubject.startsWith("Re:")
              ? origSubject
              : `Re: ${origSubject}`;

            const references = origReferences
              ? `${origReferences} ${origMessageId}`
              : origMessageId;

            const raw = encodeRawEmail({
              to,
              subject,
              body,
              cc,
              inReplyTo: origMessageId,
              references,
            });

            // Send as part of the same thread
            const accessToken = await auth.getAccessToken();
            const sendUrl = new URL(
              "https://gmail.googleapis.com/gmail/v1/users/me/messages/send",
            );
            const resp = await fetch(sendUrl.toString(), {
              method: "POST",
              headers: {
                Authorization: `Bearer ${accessToken}`,
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                raw,
                threadId: original.threadId,
              }),
            });

            if (!resp.ok) {
              throw new Error(
                `Gmail API ${resp.status}: ${await resp.text()}`,
              );
            }

            const result = await resp.json();

            return {
              content: [
                {
                  type: "text",
                  text: `Reply sent successfully.\nMessage ID: ${(result as any).id}\nThread ID: ${(result as any).threadId}`,
                },
              ],
              details: { id: (result as any).id, threadId: (result as any).threadId },
            };
          } catch (err) {
            return {
              content: [{ type: "text", text: `Failed: ${String(err)}` }],
              details: { error: String(err) },
            };
          }
        },
      },
      { name: "gmail_reply" },
    );

    // --- gmail_label ---
    api.registerTool(
      {
        name: "gmail_label",
        label: "Gmail Label",
        description:
          'Add or remove labels on a message. Common label IDs: INBOX, UNREAD, STARRED, IMPORTANT, SPAM, TRASH, CATEGORY_PERSONAL, CATEGORY_SOCIAL, CATEGORY_PROMOTIONS. Use action "list" to see all available labels.',
        parameters: Type.Object({
          action: Type.Union(
            [
              Type.Literal("add"),
              Type.Literal("remove"),
              Type.Literal("list"),
            ],
            {
              description:
                '"add" or "remove" labels on a message, or "list" all available labels',
            },
          ),
          messageId: Type.Optional(
            Type.String({
              description: "Message ID (required for add/remove)",
            }),
          ),
          labelIds: Type.Optional(
            Type.Array(Type.String(), {
              description:
                "Label IDs to add or remove (required for add/remove)",
            }),
          ),
        }),
        async execute(_toolCallId, params) {
          const { action, messageId, labelIds } = params as {
            action: "add" | "remove" | "list";
            messageId?: string;
            labelIds?: string[];
          };

          try {
            if (action === "list") {
              const result = await gmail.listLabels();
              const labels = (result.labels ?? []) as Array<{
                id: string;
                name: string;
                type: string;
              }>;

              const text = labels
                .map((l) => `- ${l.id}: ${l.name} (${l.type})`)
                .join("\n");

              return {
                content: [
                  {
                    type: "text",
                    text: `${labels.length} labels:\n${text}`,
                  },
                ],
                details: { labels },
              };
            }

            if (!messageId || !labelIds?.length) {
              return {
                content: [
                  {
                    type: "text",
                    text: "messageId and labelIds are required for add/remove.",
                  },
                ],
                details: { error: "missing_params" },
              };
            }

            const addLabels = action === "add" ? labelIds : [];
            const removeLabels = action === "remove" ? labelIds : [];

            await gmail.modifyMessage(messageId, addLabels, removeLabels);

            return {
              content: [
                {
                  type: "text",
                  text: `Labels ${action === "add" ? "added" : "removed"}: ${labelIds.join(", ")} on message ${messageId}`,
                },
              ],
              details: { action, messageId, labelIds },
            };
          } catch (err) {
            return {
              content: [{ type: "text", text: `Failed: ${String(err)}` }],
              details: { error: String(err) },
            };
          }
        },
      },
      { name: "gmail_label" },
    );

    // --- gmail_trash ---
    api.registerTool(
      {
        name: "gmail_trash",
        label: "Gmail Trash",
        description: "Move a message to the trash.",
        parameters: Type.Object({
          messageId: Type.String({ description: "Message ID to trash" }),
        }),
        async execute(_toolCallId, params) {
          const { messageId } = params as { messageId: string };

          try {
            await gmail.trashMessage(messageId);
            return {
              content: [
                {
                  type: "text",
                  text: `Message ${messageId} moved to trash.`,
                },
              ],
              details: { messageId, action: "trashed" },
            };
          } catch (err) {
            return {
              content: [{ type: "text", text: `Failed: ${String(err)}` }],
              details: { error: String(err) },
            };
          }
        },
      },
      { name: "gmail_trash" },
    );

    // --- gmail_drafts ---
    api.registerTool(
      {
        name: "gmail_drafts",
        label: "Gmail Drafts",
        description:
          'Manage Gmail drafts. Actions: "list" drafts, "create" a new draft, "read" a draft, or "send" an existing draft.',
        parameters: Type.Object({
          action: Type.Union(
            [
              Type.Literal("list"),
              Type.Literal("create"),
              Type.Literal("read"),
              Type.Literal("send"),
            ],
            {
              description: '"list", "create", "read", or "send" a draft',
            },
          ),
          draftId: Type.Optional(
            Type.String({
              description: "Draft ID (required for read/send)",
            }),
          ),
          to: Type.Optional(
            Type.String({
              description: "Recipient (required for create)",
            }),
          ),
          subject: Type.Optional(
            Type.String({
              description: "Subject (required for create)",
            }),
          ),
          body: Type.Optional(
            Type.String({
              description: "Body text (required for create)",
            }),
          ),
          cc: Type.Optional(Type.String({ description: "CC recipients" })),
          bcc: Type.Optional(Type.String({ description: "BCC recipients" })),
          maxResults: Type.Optional(
            Type.Number({
              description: "Max drafts to list (default: 20)",
            }),
          ),
        }),
        async execute(_toolCallId, params) {
          const {
            action,
            draftId,
            to,
            subject,
            body,
            cc,
            bcc,
            maxResults = 20,
          } = params as {
            action: "list" | "create" | "read" | "send";
            draftId?: string;
            to?: string;
            subject?: string;
            body?: string;
            cc?: string;
            bcc?: string;
            maxResults?: number;
          };

          try {
            if (action === "list") {
              const result = await gmail.listDrafts(maxResults);
              const drafts = result.drafts ?? [];

              if (drafts.length === 0) {
                return {
                  content: [{ type: "text", text: "No drafts found." }],
                  details: { count: 0 },
                };
              }

              // Fetch metadata for each draft
              const details = await Promise.all(
                drafts.map((d: any) => gmail.getDraft(d.id)),
              );

              const summaries = details.map((d: any) => {
                const headers = d.message?.payload?.headers ?? [];
                const draftTo = getHeader(headers, "To");
                const draftSubject = getHeader(headers, "Subject");
                return `- ${d.id}: To: ${draftTo} | Subject: ${draftSubject}`;
              });

              return {
                content: [
                  {
                    type: "text",
                    text: `${drafts.length} drafts:\n${summaries.join("\n")}`,
                  },
                ],
                details: { count: drafts.length },
              };
            }

            if (action === "create") {
              if (!to || !subject || !body) {
                return {
                  content: [
                    {
                      type: "text",
                      text: "to, subject, and body are required for creating a draft.",
                    },
                  ],
                  details: { error: "missing_params" },
                };
              }

              const raw = encodeRawEmail({ to, subject, body, cc, bcc });
              const result = await gmail.createDraft(raw);

              return {
                content: [
                  {
                    type: "text",
                    text: `Draft created.\nDraft ID: ${result.id}\nMessage ID: ${result.message?.id}`,
                  },
                ],
                details: { id: result.id, messageId: result.message?.id },
              };
            }

            if (action === "read") {
              if (!draftId) {
                return {
                  content: [
                    {
                      type: "text",
                      text: "draftId is required for reading a draft.",
                    },
                  ],
                  details: { error: "missing_params" },
                };
              }

              const draft = await gmail.getDraft(draftId);
              const msg = draft.message;
              const headers = msg?.payload?.headers ?? [];
              const draftBody = extractTextBody(msg?.payload);

              const text = [
                `Draft ID: ${draft.id}`,
                `To: ${getHeader(headers, "To")}`,
                `Subject: ${getHeader(headers, "Subject")}`,
                ``,
                draftBody,
              ].join("\n");

              return {
                content: [{ type: "text", text }],
                details: { id: draft.id },
              };
            }

            if (action === "send") {
              if (!draftId) {
                return {
                  content: [
                    {
                      type: "text",
                      text: "draftId is required for sending a draft.",
                    },
                  ],
                  details: { error: "missing_params" },
                };
              }

              const result = await gmail.sendDraft(draftId);

              return {
                content: [
                  {
                    type: "text",
                    text: `Draft sent successfully.\nMessage ID: ${result.id}\nThread ID: ${result.threadId}`,
                  },
                ],
                details: {
                  id: result.id,
                  threadId: result.threadId,
                },
              };
            }

            return {
              content: [
                { type: "text", text: `Unknown action: ${action}` },
              ],
              details: { error: "unknown_action" },
            };
          } catch (err) {
            return {
              content: [{ type: "text", text: `Failed: ${String(err)}` }],
              details: { error: String(err) },
            };
          }
        },
      },
      { name: "gmail_drafts" },
    );

    // --- gmail_threads ---
    api.registerTool(
      {
        name: "gmail_threads",
        label: "Gmail Threads",
        description:
          'List or read Gmail threads. Use action "list" to search/list threads, or "read" to get all messages in a thread.',
        parameters: Type.Object({
          action: Type.Union(
            [Type.Literal("list"), Type.Literal("read")],
            { description: '"list" threads or "read" a specific thread' },
          ),
          threadId: Type.Optional(
            Type.String({ description: "Thread ID (required for read)" }),
          ),
          query: Type.Optional(
            Type.String({
              description: "Gmail search query (for list)",
            }),
          ),
          maxResults: Type.Optional(
            Type.Number({
              description: "Max threads to return (default: 20)",
            }),
          ),
          pageToken: Type.Optional(
            Type.String({ description: "Pagination token" }),
          ),
        }),
        async execute(_toolCallId, params) {
          const {
            action,
            threadId,
            query,
            maxResults = 20,
            pageToken,
          } = params as {
            action: "list" | "read";
            threadId?: string;
            query?: string;
            maxResults?: number;
            pageToken?: string;
          };

          try {
            if (action === "list") {
              const result = await gmail.listThreads(
                query,
                Math.min(maxResults, 100),
                pageToken,
              );
              const threads = result.threads ?? [];

              if (threads.length === 0) {
                return {
                  content: [
                    {
                      type: "text",
                      text: `No threads found${query ? ` for query: "${query}"` : ""}.`,
                    },
                  ],
                  details: { count: 0 },
                };
              }

              // Get metadata for each thread
              const details = await Promise.all(
                threads.map((t: any) =>
                  gmail.getThread(t.id, "metadata"),
                ),
              );

              const summaries = details.map((t: any) => {
                const firstMsg = t.messages?.[0];
                const headers = firstMsg?.payload?.headers ?? [];
                const from = getHeader(headers, "From");
                const subject = getHeader(headers, "Subject");
                const msgCount = t.messages?.length ?? 0;
                return `- ${t.id} (${msgCount} msg) | ${from} | ${subject}`;
              });

              let text = `${threads.length} threads:\n\n${summaries.join("\n")}`;
              if (result.nextPageToken) {
                text += `\n\nMore results available. Use pageToken: "${result.nextPageToken}"`;
              }

              return {
                content: [{ type: "text", text }],
                details: {
                  count: threads.length,
                  nextPageToken: result.nextPageToken,
                },
              };
            }

            if (action === "read") {
              if (!threadId) {
                return {
                  content: [
                    {
                      type: "text",
                      text: "threadId is required for reading a thread.",
                    },
                  ],
                  details: { error: "missing_params" },
                };
              }

              const thread = await gmail.getThread(threadId, "full");
              const messages = thread.messages ?? [];

              const formatted = messages.map((msg: any, i: number) => {
                const headers = msg.payload?.headers ?? [];
                const from = getHeader(headers, "From");
                const date = getHeader(headers, "Date");
                const body = extractTextBody(msg.payload);
                const attachments = listAttachments(msg.payload);

                let text = `--- Message ${i + 1}/${messages.length} (${msg.id}) ---\nFrom: ${from}\nDate: ${date}\n\n${body}`;
                if (attachments.length > 0) {
                  text += `\n\nAttachments: ${attachments.map((a) => a.filename).join(", ")}`;
                }
                return text;
              });

              const subject = getHeader(
                messages[0]?.payload?.headers ?? [],
                "Subject",
              );

              return {
                content: [
                  {
                    type: "text",
                    text: `Thread: ${threadId} | Subject: ${subject} | ${messages.length} messages\n\n${formatted.join("\n\n")}`,
                  },
                ],
                details: {
                  threadId,
                  messageCount: messages.length,
                  messageIds: messages.map((m: any) => m.id),
                },
              };
            }

            return {
              content: [
                { type: "text", text: `Unknown action: ${action}` },
              ],
              details: { error: "unknown_action" },
            };
          } catch (err) {
            return {
              content: [{ type: "text", text: `Failed: ${String(err)}` }],
              details: { error: String(err) },
            };
          }
        },
      },
      { name: "gmail_threads" },
    );

    // ========================================================================
    // CLI Commands
    // ========================================================================

    api.registerCli(
      ({ program }) => {
        const gmailCmd = program
          .command("gmail")
          .description("Gmail plugin commands");

        gmailCmd
          .command("auth")
          .description("Run Gmail OAuth2 consent flow (opens browser)")
          .action(async () => {
            try {
              await auth.runAuthFlow();
              console.log("\nAuthentication successful!");

              // Test by fetching profile
              const profile = await gmail.getProfile();
              console.log(`Connected to: ${profile.emailAddress}`);
              console.log(`Messages: ${profile.messagesTotal}`);
              console.log(`Threads: ${profile.threadsTotal}`);
            } catch (err) {
              console.error(`Authentication failed: ${String(err)}`);
              process.exit(1);
            }
          });

        gmailCmd
          .command("status")
          .description("Check Gmail authentication status")
          .action(async () => {
            try {
              const profile = await gmail.getProfile();
              console.log(`Authenticated as: ${profile.emailAddress}`);
              console.log(`Messages: ${profile.messagesTotal}`);
              console.log(`Threads: ${profile.threadsTotal}`);
            } catch (err) {
              console.log(
                `Not authenticated. Run "openclaw gmail auth" to sign in.`,
              );
              console.log(`Error: ${String(err)}`);
            }
          });
      },
      { commands: ["gmail"] },
    );

    // ========================================================================
    // Service
    // ========================================================================

    api.registerService({
      id: "openclaw-gmail",
      start: () => {
        api.logger.info(
          `openclaw-gmail: initialized (clientSecret: ${cfg.clientSecretPath})`,
        );
      },
      stop: () => {
        api.logger.info("openclaw-gmail: stopped");
      },
    });
  },
};

export default gmailPlugin;
