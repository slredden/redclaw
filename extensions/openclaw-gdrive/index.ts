/**
 * OpenClaw Google Drive Plugin
 *
 * Direct Google Drive API integration via OAuth2.
 *
 * Tools: gdrive_list, gdrive_search, gdrive_read, gdrive_info,
 *        gdrive_upload, gdrive_mkdir, gdrive_drives, gdrive_trash, gdrive_share
 *
 * CLI: openclaw gdrive auth — run initial OAuth consent flow
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

type PluginConfig = {
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
  "https://www.googleapis.com/auth/drive",
  "https://www.googleapis.com/auth/drive.file",
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
  "gdrive-token.json",
);

// Google Docs export MIME types
const EXPORT_MIME_TYPES: Record<string, { mime: string; ext: string }> = {
  "application/vnd.google-apps.document": {
    mime: "text/plain",
    ext: "txt",
  },
  "application/vnd.google-apps.spreadsheet": {
    mime: "text/csv",
    ext: "csv",
  },
  "application/vnd.google-apps.presentation": {
    mime: "text/plain",
    ext: "txt",
  },
  "application/vnd.google-apps.drawing": {
    mime: "image/png",
    ext: "png",
  },
};

// ============================================================================
// Config Parser
// ============================================================================

const configSchema = {
  parse(value: unknown): PluginConfig {
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

class GoogleAuth {
  private clientSecret: ClientSecret | null = null;
  private token: StoredToken | null = null;
  private accessToken: string | null = null;

  constructor(
    private readonly clientSecretPath: string,
    private readonly tokenPath: string,
    private readonly scopes: string[],
    private readonly port: number,
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

  async getAccessToken(): Promise<string> {
    const token = this.loadToken();
    if (!token) {
      throw new Error(
        "Not authenticated. Run `openclaw gdrive auth` to sign in.",
      );
    }

    if (token.expiry_date > Date.now() + 60_000 && this.accessToken) {
      return this.accessToken;
    }

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
      refresh_token: token.refresh_token,
      token_type: data.token_type,
      expiry_date: Date.now() + data.expires_in * 1000,
      scope: data.scope ?? token.scope,
    };

    this.saveToken(refreshed);
    return refreshed.access_token;
  }

  async runAuthFlow(): Promise<void> {
    const secret = this.loadClientSecret();
    const redirectUri = `http://localhost:${this.port}`;

    const authUrl = new URL(secret.installed.auth_uri);
    authUrl.searchParams.set("client_id", secret.installed.client_id);
    authUrl.searchParams.set("redirect_uri", redirectUri);
    authUrl.searchParams.set("response_type", "code");
    authUrl.searchParams.set("scope", this.scopes.join(" "));
    authUrl.searchParams.set("access_type", "offline");
    authUrl.searchParams.set("prompt", "consent");

    return new Promise<void>((resolve, reject) => {
      const server = http.createServer(async (req, res) => {
        try {
          const reqUrl = new URL(req.url!, `http://localhost:${this.port}`);
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

          this.saveToken({
            access_token: data.access_token,
            refresh_token: data.refresh_token,
            token_type: data.token_type,
            expiry_date: Date.now() + data.expires_in * 1000,
            scope: data.scope,
          });

          res.writeHead(200, { "Content-Type": "text/html" });
          res.end(
            "<h1>Authorization successful!</h1><p>You can close this window and return to the terminal.</p>",
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

      server.listen(this.port, async () => {
        console.log(`\nOpening browser for authorization...`);
        console.log(
          `If the browser doesn't open, visit:\n${authUrl.toString()}\n`,
        );
        try {
          const openMod = await import("open");
          const openFn = openMod.default ?? openMod;
          await openFn(authUrl.toString());
        } catch {
          console.log("Could not open browser automatically.");
        }
      });

      setTimeout(() => {
        server.close();
        reject(new Error("OAuth flow timed out after 2 minutes"));
      }, 120_000);
    });
  }
}

// ============================================================================
// Drive API Client
// ============================================================================

class DriveClient {
  constructor(private readonly auth: GoogleAuth) {}

  private async request(
    endpoint: string,
    options: {
      method?: string;
      body?: unknown;
      params?: Record<string, string>;
      rawResponse?: boolean;
    } = {},
  ): Promise<any> {
    const accessToken = await this.auth.getAccessToken();
    const url = new URL(
      `https://www.googleapis.com/drive/v3/${endpoint}`,
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
      throw new Error(`Drive API ${resp.status}: ${errText}`);
    }

    if (resp.status === 204) return {};
    if (options.rawResponse) return resp;
    return resp.json();
  }

  async about() {
    return this.request("about", {
      params: { fields: "user,storageQuota" },
    });
  }

  async listFiles(options: {
    query?: string;
    pageSize?: number;
    pageToken?: string;
    orderBy?: string;
    fields?: string;
    spaces?: string;
    corpora?: string;
    driveId?: string;
  } = {}) {
    const params: Record<string, string> = {
      fields:
        options.fields ??
        "nextPageToken,files(id,name,mimeType,size,modifiedTime,parents,webViewLink,owners,driveId)",
      pageSize: String(options.pageSize ?? 20),
      supportsAllDrives: "true",
      includeItemsFromAllDrives: "true",
    };
    if (options.query) params.q = options.query;
    if (options.pageToken) params.pageToken = options.pageToken;
    if (options.orderBy) params.orderBy = options.orderBy;
    if (options.spaces) params.spaces = options.spaces;
    if (options.corpora) params.corpora = options.corpora;
    if (options.driveId) params.driveId = options.driveId;
    return this.request("files", { params });
  }

  async getFile(fileId: string) {
    return this.request(`files/${encodeURIComponent(fileId)}`, {
      params: {
        fields:
          "id,name,mimeType,size,modifiedTime,createdTime,parents,webViewLink,owners,description,starred,trashed,capabilities,driveId",
        supportsAllDrives: "true",
      },
    });
  }

  async getFileContent(fileId: string): Promise<string> {
    const accessToken = await this.auth.getAccessToken();
    const url = `https://www.googleapis.com/drive/v3/files/${encodeURIComponent(fileId)}?alt=media&supportsAllDrives=true`;
    const resp = await fetch(url, {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    if (!resp.ok) {
      throw new Error(`Drive API ${resp.status}: ${await resp.text()}`);
    }
    return resp.text();
  }

  async exportFile(fileId: string, mimeType: string): Promise<string> {
    const accessToken = await this.auth.getAccessToken();
    const url = `https://www.googleapis.com/drive/v3/files/${encodeURIComponent(fileId)}/export?mimeType=${encodeURIComponent(mimeType)}&supportsAllDrives=true`;
    const resp = await fetch(url, {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    if (!resp.ok) {
      throw new Error(`Drive API ${resp.status}: ${await resp.text()}`);
    }
    return resp.text();
  }

  async createFile(metadata: any, content?: string) {
    const accessToken = await this.auth.getAccessToken();

    if (content) {
      // Multipart upload
      const boundary = "openclaw_boundary_" + Date.now();
      const metaPart = JSON.stringify(metadata);
      const body = [
        `--${boundary}`,
        "Content-Type: application/json; charset=UTF-8",
        "",
        metaPart,
        `--${boundary}`,
        `Content-Type: ${metadata.mimeType ?? "text/plain"}`,
        "",
        content,
        `--${boundary}--`,
      ].join("\r\n");

      const resp = await fetch(
        "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name,mimeType,webViewLink&supportsAllDrives=true",
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${accessToken}`,
            "Content-Type": `multipart/related; boundary=${boundary}`,
          },
          body,
        },
      );

      if (!resp.ok) {
        throw new Error(`Drive API ${resp.status}: ${await resp.text()}`);
      }
      return resp.json();
    }

    // Metadata-only (e.g. folders)
    return this.request("files", {
      method: "POST",
      body: metadata,
      params: { fields: "id,name,mimeType,webViewLink", supportsAllDrives: "true" },
    });
  }

  async trashFile(fileId: string) {
    return this.request(`files/${encodeURIComponent(fileId)}`, {
      method: "PATCH",
      body: { trashed: true },
      params: { fields: "id,name,trashed", supportsAllDrives: "true" },
    });
  }

  async shareFile(
    fileId: string,
    email: string,
    role: string,
    type: string,
  ) {
    return this.request(
      `files/${encodeURIComponent(fileId)}/permissions`,
      {
        method: "POST",
        body: { role, type, emailAddress: email },
        params: { fields: "id,role,type,emailAddress", supportsAllDrives: "true" },
      },
    );
  }

  async listPermissions(fileId: string) {
    return this.request(
      `files/${encodeURIComponent(fileId)}/permissions`,
      {
        params: { fields: "permissions(id,role,type,emailAddress,displayName)", supportsAllDrives: "true" },
      },
    );
  }

  async listDrives(options: { pageSize?: number; pageToken?: string } = {}) {
    const params: Record<string, string> = {
      pageSize: String(options.pageSize ?? 100),
      fields: "nextPageToken,drives(id,name,createdTime,capabilities)",
    };
    if (options.pageToken) params.pageToken = options.pageToken;
    return this.request("drives", { params });
  }
}

// ============================================================================
// Helpers
// ============================================================================

function formatFileSize(bytes: number | string | undefined): string {
  if (!bytes) return "unknown";
  const n = typeof bytes === "string" ? parseInt(bytes, 10) : bytes;
  if (n < 1024) return `${n}B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)}KB`;
  if (n < 1024 * 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)}MB`;
  return `${(n / (1024 * 1024 * 1024)).toFixed(1)}GB`;
}

function formatFileOneLiner(f: any): string {
  const size = f.size ? ` (${formatFileSize(f.size)})` : "";
  const isFolder =
    f.mimeType === "application/vnd.google-apps.folder" ? " [FOLDER]" : "";
  return `- ${f.id} | ${f.name}${isFolder}${size} | ${f.modifiedTime ?? ""}`;
}

// ============================================================================
// Plugin Definition
// ============================================================================

const gdrivePlugin = {
  id: "openclaw-gdrive",
  name: "Google Drive",
  description:
    "Google Drive integration via OAuth2 — files, folders, search, upload, share",
  kind: "tool" as const,
  configSchema,

  register(api: OpenClawPluginApi) {
    const cfg = configSchema.parse(api.pluginConfig);
    const auth = new GoogleAuth(
      cfg.clientSecretPath,
      cfg.tokenPath,
      SCOPES,
      8097,
    );
    const drive = new DriveClient(auth);

    api.logger.info(
      `openclaw-gdrive: registered (token: ${cfg.tokenPath})`,
    );

    // ========================================================================
    // Tools
    // ========================================================================

    // --- gdrive_list ---
    api.registerTool(
      {
        name: "gdrive_list",
        label: "Drive List",
        description:
          'List files and folders in Google Drive. Can list a specific folder\'s contents by providing folderId, or list root files. Use orderBy for sorting (e.g. "modifiedTime desc", "name").',
        parameters: Type.Object({
          folderId: Type.Optional(
            Type.String({
              description:
                'Folder ID to list contents of (default: root). Use "root" for top-level.',
            }),
          ),
          driveId: Type.Optional(
            Type.String({
              description:
                "Shared drive ID to list files from. Use gdrive_drives to discover available shared drives.",
            }),
          ),
          maxResults: Type.Optional(
            Type.Number({
              description: "Max files to return (default: 20, max: 100)",
            }),
          ),
          orderBy: Type.Optional(
            Type.String({
              description:
                'Sort order (e.g. "modifiedTime desc", "name", "createdTime desc")',
            }),
          ),
          pageToken: Type.Optional(
            Type.String({ description: "Pagination token" }),
          ),
        }),
        async execute(_toolCallId, params) {
          const {
            folderId,
            driveId,
            maxResults = 20,
            orderBy = "modifiedTime desc",
            pageToken,
          } = params as {
            folderId?: string;
            driveId?: string;
            maxResults?: number;
            orderBy?: string;
            pageToken?: string;
          };

          try {
            const query = folderId
              ? `'${folderId}' in parents and trashed = false`
              : "trashed = false";

            const corpora = driveId ? "drive" : folderId ? undefined : "allDrives";

            const result = await drive.listFiles({
              query,
              pageSize: Math.min(maxResults, 100),
              orderBy,
              pageToken,
              corpora,
              driveId,
            });

            const files = result.files ?? [];

            if (files.length === 0) {
              return {
                content: [
                  { type: "text", text: "No files found." },
                ],
                details: { count: 0 },
              };
            }

            const lines = files.map(formatFileOneLiner);
            let text = `${files.length} files:\n\n${lines.join("\n")}`;
            if (result.nextPageToken) {
              text += `\n\nMore results available. Use pageToken: "${result.nextPageToken}"`;
            }

            return {
              content: [{ type: "text", text }],
              details: {
                count: files.length,
                nextPageToken: result.nextPageToken,
                files: files.map((f: any) => ({
                  id: f.id,
                  name: f.name,
                  mimeType: f.mimeType,
                  size: f.size,
                  modifiedTime: f.modifiedTime,
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
      { name: "gdrive_list" },
    );

    // --- gdrive_search ---
    api.registerTool(
      {
        name: "gdrive_search",
        label: "Drive Search",
        description:
          'Search Google Drive files by name, content, or type. Supports Drive query syntax: name contains "report", mimeType = "application/pdf", etc. Or just provide a simple text query.',
        parameters: Type.Object({
          query: Type.String({
            description:
              'Search query. Simple text (searches file names/content) or Drive query syntax (e.g. "name contains \'budget\' and mimeType = \'application/pdf\'")',
          }),
          driveId: Type.Optional(
            Type.String({
              description:
                "Shared drive ID to search within. Use gdrive_drives to discover available shared drives.",
            }),
          ),
          maxResults: Type.Optional(
            Type.Number({
              description: "Max results (default: 20)",
            }),
          ),
          pageToken: Type.Optional(
            Type.String({ description: "Pagination token" }),
          ),
        }),
        async execute(_toolCallId, params) {
          const {
            query,
            driveId,
            maxResults = 20,
            pageToken,
          } = params as {
            query: string;
            driveId?: string;
            maxResults?: number;
            pageToken?: string;
          };

          try {
            // If query looks like Drive query syntax, use directly;
            // otherwise wrap as fullText search
            const isRawQuery =
              query.includes(" contains ") ||
              query.includes(" = ") ||
              query.includes(" in ") ||
              query.includes("mimeType") ||
              query.includes("parents");

            const driveQuery = isRawQuery
              ? `${query} and trashed = false`
              : `fullText contains '${query.replace(/'/g, "\\'")}' and trashed = false`;

            const corpora = driveId ? "drive" : "allDrives";

            const result = await drive.listFiles({
              query: driveQuery,
              pageSize: Math.min(maxResults, 100),
              pageToken,
              corpora,
              driveId,
            });

            const files = result.files ?? [];

            if (files.length === 0) {
              return {
                content: [
                  {
                    type: "text",
                    text: `No files found for: "${query}"`,
                  },
                ],
                details: { count: 0 },
              };
            }

            const lines = files.map(formatFileOneLiner);
            let text = `${files.length} files found:\n\n${lines.join("\n")}`;
            if (result.nextPageToken) {
              text += `\n\nMore results available. Use pageToken: "${result.nextPageToken}"`;
            }

            return {
              content: [{ type: "text", text }],
              details: {
                count: files.length,
                nextPageToken: result.nextPageToken,
                files: files.map((f: any) => ({
                  id: f.id,
                  name: f.name,
                  mimeType: f.mimeType,
                  size: f.size,
                  modifiedTime: f.modifiedTime,
                  webViewLink: f.webViewLink,
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
      { name: "gdrive_search" },
    );

    // --- gdrive_read ---
    api.registerTool(
      {
        name: "gdrive_read",
        label: "Drive Read",
        description:
          "Read the text content of a file from Google Drive. For Google Docs/Sheets/Slides, exports as plain text/CSV. For regular files (txt, csv, json, etc.), downloads content directly. Binary files will return metadata only.",
        parameters: Type.Object({
          fileId: Type.String({ description: "The file ID to read" }),
        }),
        async execute(_toolCallId, params) {
          const { fileId } = params as { fileId: string };

          try {
            const meta = await drive.getFile(fileId);
            const mimeType = meta.mimeType ?? "";

            let content: string;

            // Google Workspace files need export
            if (mimeType.startsWith("application/vnd.google-apps.")) {
              const exportInfo = EXPORT_MIME_TYPES[mimeType];
              if (exportInfo) {
                content = await drive.exportFile(fileId, exportInfo.mime);
              } else {
                return {
                  content: [
                    {
                      type: "text",
                      text: `Cannot export ${mimeType}. File: ${meta.name}\nLink: ${meta.webViewLink ?? "N/A"}`,
                    },
                  ],
                  details: meta,
                };
              }
            } else {
              // Regular file — download
              content = await drive.getFileContent(fileId);
            }

            // Truncate very large files
            const maxLen = 50_000;
            const truncated = content.length > maxLen;
            if (truncated) {
              content =
                content.slice(0, maxLen) +
                `\n\n... [truncated at ${maxLen} chars, full file is ${content.length} chars]`;
            }

            return {
              content: [
                {
                  type: "text",
                  text: `File: ${meta.name} (${mimeType})\n\n${content}`,
                },
              ],
              details: {
                id: meta.id,
                name: meta.name,
                mimeType,
                truncated,
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
      { name: "gdrive_read" },
    );

    // --- gdrive_info ---
    api.registerTool(
      {
        name: "gdrive_info",
        label: "Drive File Info",
        description:
          "Get detailed metadata about a file or the Drive account (storage quota, user info). Pass fileId for file info, or omit for account info.",
        parameters: Type.Object({
          fileId: Type.Optional(
            Type.String({
              description:
                "File ID to get info about. Omit to get account/storage info.",
            }),
          ),
        }),
        async execute(_toolCallId, params) {
          const { fileId } = params as { fileId?: string };

          try {
            if (!fileId) {
              const about = await drive.about();
              const user = about.user ?? {};
              const quota = about.storageQuota ?? {};
              return {
                content: [
                  {
                    type: "text",
                    text: [
                      `User: ${user.displayName} (${user.emailAddress})`,
                      `Storage Used: ${formatFileSize(quota.usage)}`,
                      `Storage Limit: ${formatFileSize(quota.limit)}`,
                      `Drive Used: ${formatFileSize(quota.usageInDrive)}`,
                      `Trash Used: ${formatFileSize(quota.usageInDriveTrash)}`,
                    ].join("\n"),
                  },
                ],
                details: about,
              };
            }

            const meta = await drive.getFile(fileId);
            const owners = (meta.owners ?? [])
              .map((o: any) => o.emailAddress)
              .join(", ");

            return {
              content: [
                {
                  type: "text",
                  text: [
                    `Name: ${meta.name}`,
                    `ID: ${meta.id}`,
                    `Type: ${meta.mimeType}`,
                    `Size: ${formatFileSize(meta.size)}`,
                    `Created: ${meta.createdTime}`,
                    `Modified: ${meta.modifiedTime}`,
                    `Owners: ${owners}`,
                    `Starred: ${meta.starred}`,
                    `Trashed: ${meta.trashed}`,
                    meta.webViewLink ? `Link: ${meta.webViewLink}` : "",
                    meta.description
                      ? `Description: ${meta.description}`
                      : "",
                  ]
                    .filter(Boolean)
                    .join("\n"),
                },
              ],
              details: meta,
            };
          } catch (err) {
            return {
              content: [{ type: "text", text: `Failed: ${String(err)}` }],
              details: { error: String(err) },
            };
          }
        },
      },
      { name: "gdrive_info" },
    );

    // --- gdrive_upload ---
    api.registerTool(
      {
        name: "gdrive_upload",
        label: "Drive Upload",
        description:
          "Create a new file in Google Drive with text content. For binary files, use the Drive web interface.",
        parameters: Type.Object({
          name: Type.String({ description: "File name (e.g. notes.txt)" }),
          content: Type.String({ description: "File content (text)" }),
          mimeType: Type.Optional(
            Type.String({
              description:
                'MIME type (default: "text/plain"). Use "application/json", "text/csv", etc.',
            }),
          ),
          folderId: Type.Optional(
            Type.String({
              description: "Parent folder ID (default: root)",
            }),
          ),
        }),
        async execute(_toolCallId, params) {
          const {
            name,
            content,
            mimeType = "text/plain",
            folderId,
          } = params as {
            name: string;
            content: string;
            mimeType?: string;
            folderId?: string;
          };

          try {
            const metadata: any = { name, mimeType };
            if (folderId) metadata.parents = [folderId];

            const result = await drive.createFile(metadata, content);

            return {
              content: [
                {
                  type: "text",
                  text: `File created: ${result.name}\nID: ${result.id}\nLink: ${result.webViewLink ?? "N/A"}`,
                },
              ],
              details: result,
            };
          } catch (err) {
            return {
              content: [{ type: "text", text: `Failed: ${String(err)}` }],
              details: { error: String(err) },
            };
          }
        },
      },
      { name: "gdrive_upload" },
    );

    // --- gdrive_mkdir ---
    api.registerTool(
      {
        name: "gdrive_mkdir",
        label: "Drive Create Folder",
        description: "Create a new folder in Google Drive.",
        parameters: Type.Object({
          name: Type.String({ description: "Folder name" }),
          parentId: Type.Optional(
            Type.String({
              description: "Parent folder ID (default: root)",
            }),
          ),
        }),
        async execute(_toolCallId, params) {
          const { name, parentId } = params as {
            name: string;
            parentId?: string;
          };

          try {
            const metadata: any = {
              name,
              mimeType: "application/vnd.google-apps.folder",
            };
            if (parentId) metadata.parents = [parentId];

            const result = await drive.createFile(metadata);

            return {
              content: [
                {
                  type: "text",
                  text: `Folder created: ${result.name}\nID: ${result.id}\nLink: ${result.webViewLink ?? "N/A"}`,
                },
              ],
              details: result,
            };
          } catch (err) {
            return {
              content: [{ type: "text", text: `Failed: ${String(err)}` }],
              details: { error: String(err) },
            };
          }
        },
      },
      { name: "gdrive_mkdir" },
    );

    // --- gdrive_drives ---
    api.registerTool(
      {
        name: "gdrive_drives",
        label: "Drive List Shared Drives",
        description:
          "List shared drives (Team Drives) available to the authenticated user. Use this to discover shared drive IDs for use with gdrive_list and gdrive_search.",
        parameters: Type.Object({
          maxResults: Type.Optional(
            Type.Number({
              description: "Max drives to return (default: 100)",
            }),
          ),
          pageToken: Type.Optional(
            Type.String({ description: "Pagination token" }),
          ),
        }),
        async execute(_toolCallId, params) {
          const { maxResults = 100, pageToken } = params as {
            maxResults?: number;
            pageToken?: string;
          };

          try {
            const result = await drive.listDrives({
              pageSize: Math.min(maxResults, 100),
              pageToken,
            });

            const drives = result.drives ?? [];

            if (drives.length === 0) {
              return {
                content: [
                  { type: "text", text: "No shared drives found." },
                ],
                details: { count: 0 },
              };
            }

            const lines = drives.map(
              (d: any) => `- ${d.id} | ${d.name} | created: ${d.createdTime ?? ""}`,
            );
            let text = `${drives.length} shared drives:\n\n${lines.join("\n")}`;
            if (result.nextPageToken) {
              text += `\n\nMore results available. Use pageToken: "${result.nextPageToken}"`;
            }

            return {
              content: [{ type: "text", text }],
              details: {
                count: drives.length,
                nextPageToken: result.nextPageToken,
                drives: drives.map((d: any) => ({
                  id: d.id,
                  name: d.name,
                  createdTime: d.createdTime,
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
      { name: "gdrive_drives" },
    );

    // --- gdrive_trash ---
    api.registerTool(
      {
        name: "gdrive_trash",
        label: "Drive Trash",
        description: "Move a file or folder to the trash.",
        parameters: Type.Object({
          fileId: Type.String({
            description: "File or folder ID to trash",
          }),
        }),
        async execute(_toolCallId, params) {
          const { fileId } = params as { fileId: string };

          try {
            const result = await drive.trashFile(fileId);
            return {
              content: [
                {
                  type: "text",
                  text: `"${result.name}" moved to trash.`,
                },
              ],
              details: result,
            };
          } catch (err) {
            return {
              content: [{ type: "text", text: `Failed: ${String(err)}` }],
              details: { error: String(err) },
            };
          }
        },
      },
      { name: "gdrive_trash" },
    );

    // --- gdrive_share ---
    api.registerTool(
      {
        name: "gdrive_share",
        label: "Drive Share",
        description:
          'Share a file or folder with another user, or list current permissions. Actions: "share" to grant access, "list" to see who has access.',
        parameters: Type.Object({
          action: Type.Union(
            [Type.Literal("share"), Type.Literal("list")],
            { description: '"share" to grant access or "list" permissions' },
          ),
          fileId: Type.String({ description: "File or folder ID" }),
          email: Type.Optional(
            Type.String({
              description: "Email address to share with (for share action)",
            }),
          ),
          role: Type.Optional(
            Type.Union(
              [
                Type.Literal("reader"),
                Type.Literal("writer"),
                Type.Literal("commenter"),
              ],
              {
                description:
                  'Permission level (default: "reader")',
              },
            ),
          ),
        }),
        async execute(_toolCallId, params) {
          const {
            action,
            fileId,
            email,
            role = "reader",
          } = params as {
            action: "share" | "list";
            fileId: string;
            email?: string;
            role?: string;
          };

          try {
            if (action === "list") {
              const result = await drive.listPermissions(fileId);
              const perms = result.permissions ?? [];

              const text = perms
                .map(
                  (p: any) =>
                    `- ${p.emailAddress ?? p.type} (${p.role})${p.displayName ? ` — ${p.displayName}` : ""}`,
                )
                .join("\n");

              return {
                content: [
                  {
                    type: "text",
                    text: `${perms.length} permissions:\n${text}`,
                  },
                ],
                details: { permissions: perms },
              };
            }

            if (!email) {
              return {
                content: [
                  {
                    type: "text",
                    text: "email is required for sharing.",
                  },
                ],
                details: { error: "missing_params" },
              };
            }

            const result = await drive.shareFile(
              fileId,
              email,
              role,
              "user",
            );

            return {
              content: [
                {
                  type: "text",
                  text: `Shared with ${email} as ${role}.`,
                },
              ],
              details: result,
            };
          } catch (err) {
            return {
              content: [{ type: "text", text: `Failed: ${String(err)}` }],
              details: { error: String(err) },
            };
          }
        },
      },
      { name: "gdrive_share" },
    );

    // ========================================================================
    // CLI Commands
    // ========================================================================

    api.registerCli(
      ({ program }) => {
        const driveCmd = program
          .command("gdrive")
          .description("Google Drive plugin commands");

        driveCmd
          .command("auth")
          .description(
            "Run Google Drive OAuth2 consent flow (opens browser)",
          )
          .action(async () => {
            try {
              await auth.runAuthFlow();
              console.log("\nAuthentication successful!");

              const about = await drive.about();
              const user = about.user ?? {};
              const quota = about.storageQuota ?? {};
              console.log(`Account: ${user.displayName} (${user.emailAddress})`);
              console.log(
                `Storage: ${formatFileSize(quota.usage)} / ${formatFileSize(quota.limit)}`,
              );
            } catch (err) {
              console.error(`Authentication failed: ${String(err)}`);
              process.exit(1);
            }
          });

        driveCmd
          .command("status")
          .description("Check Drive authentication status")
          .action(async () => {
            try {
              const about = await drive.about();
              const user = about.user ?? {};
              const quota = about.storageQuota ?? {};
              console.log(
                `Authenticated as: ${user.displayName} (${user.emailAddress})`,
              );
              console.log(
                `Storage: ${formatFileSize(quota.usage)} / ${formatFileSize(quota.limit)}`,
              );
            } catch (err) {
              console.log(
                `Not authenticated. Run "openclaw gdrive auth" to sign in.`,
              );
              console.log(`Error: ${String(err)}`);
            }
          });
      },
      { commands: ["gdrive"] },
    );

    // ========================================================================
    // Service
    // ========================================================================

    api.registerService({
      id: "openclaw-gdrive",
      start: () => {
        api.logger.info(
          `openclaw-gdrive: initialized (token: ${cfg.tokenPath})`,
        );
      },
      stop: () => {
        api.logger.info("openclaw-gdrive: stopped");
      },
    });
  },
};

export default gdrivePlugin;
