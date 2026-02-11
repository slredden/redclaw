/**
 * OpenClaw Google Calendar Plugin
 *
 * Direct Google Calendar API integration via OAuth2.
 *
 * Tools: gcal_list, gcal_get, gcal_create, gcal_update, gcal_delete,
 *        gcal_freebusy, gcal_calendars
 *
 * CLI: openclaw gcal auth — run initial OAuth consent flow
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
  "https://www.googleapis.com/auth/calendar",
  "https://www.googleapis.com/auth/calendar.events",
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
  "gcal-token.json",
);

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
        "Not authenticated. Run the appropriate `openclaw <service> auth` command.",
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
// Calendar API Client
// ============================================================================

class CalendarClient {
  constructor(private readonly auth: GoogleAuth) {}

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
      `https://www.googleapis.com/calendar/v3/${endpoint}`,
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
      throw new Error(`Calendar API ${resp.status}: ${errText}`);
    }

    if (resp.status === 204) return {};
    return resp.json();
  }

  async listCalendars() {
    return this.request("users/me/calendarList");
  }

  async listEvents(
    calendarId: string,
    options: {
      timeMin?: string;
      timeMax?: string;
      maxResults?: number;
      query?: string;
      singleEvents?: boolean;
      orderBy?: string;
      pageToken?: string;
    } = {},
  ) {
    const params: Record<string, string> = {};
    if (options.timeMin) params.timeMin = options.timeMin;
    if (options.timeMax) params.timeMax = options.timeMax;
    if (options.maxResults) params.maxResults = String(options.maxResults);
    if (options.query) params.q = options.query;
    if (options.singleEvents !== undefined)
      params.singleEvents = String(options.singleEvents);
    if (options.orderBy) params.orderBy = options.orderBy;
    if (options.pageToken) params.pageToken = options.pageToken;
    return this.request(
      `calendars/${encodeURIComponent(calendarId)}/events`,
      { params },
    );
  }

  async getEvent(calendarId: string, eventId: string) {
    return this.request(
      `calendars/${encodeURIComponent(calendarId)}/events/${encodeURIComponent(eventId)}`,
    );
  }

  async createEvent(calendarId: string, event: any) {
    return this.request(
      `calendars/${encodeURIComponent(calendarId)}/events`,
      { method: "POST", body: event },
    );
  }

  async updateEvent(calendarId: string, eventId: string, event: any) {
    return this.request(
      `calendars/${encodeURIComponent(calendarId)}/events/${encodeURIComponent(eventId)}`,
      { method: "PATCH", body: event },
    );
  }

  async deleteEvent(calendarId: string, eventId: string) {
    return this.request(
      `calendars/${encodeURIComponent(calendarId)}/events/${encodeURIComponent(eventId)}`,
      { method: "DELETE" },
    );
  }

  async freeBusy(
    timeMin: string,
    timeMax: string,
    calendarIds: string[],
  ) {
    return this.request("freeBusy", {
      method: "POST",
      body: {
        timeMin,
        timeMax,
        items: calendarIds.map((id) => ({ id })),
      },
    });
  }
}

// ============================================================================
// Helpers
// ============================================================================

function formatEvent(event: any): string {
  const start =
    event.start?.dateTime ?? event.start?.date ?? "no start";
  const end = event.end?.dateTime ?? event.end?.date ?? "no end";
  const status = event.status ?? "confirmed";
  const location = event.location ? `\nLocation: ${event.location}` : "";
  const description = event.description
    ? `\nDescription: ${event.description}`
    : "";
  const attendees = event.attendees?.length
    ? `\nAttendees: ${event.attendees.map((a: any) => `${a.email} (${a.responseStatus ?? "unknown"})`).join(", ")}`
    : "";
  const recurrence = event.recurrence?.length
    ? `\nRecurrence: ${event.recurrence.join(", ")}`
    : "";
  const hangoutLink = event.hangoutLink
    ? `\nMeet: ${event.hangoutLink}`
    : "";

  return `ID: ${event.id}\nSummary: ${event.summary ?? "(no title)"}\nStart: ${start}\nEnd: ${end}\nStatus: ${status}${location}${description}${attendees}${recurrence}${hangoutLink}`;
}

function formatEventOneLiner(event: any): string {
  const start =
    event.start?.dateTime ?? event.start?.date ?? "?";
  const summary = event.summary ?? "(no title)";
  const location = event.location ? ` @ ${event.location}` : "";
  return `- ${event.id} | ${start} | ${summary}${location}`;
}

// ============================================================================
// Plugin Definition
// ============================================================================

const gcalPlugin = {
  id: "openclaw-gcal",
  name: "Google Calendar",
  description:
    "Google Calendar integration via OAuth2 — events, scheduling, free/busy",
  kind: "tool" as const,
  configSchema,

  register(api: OpenClawPluginApi) {
    const cfg = configSchema.parse(api.pluginConfig);
    const auth = new GoogleAuth(
      cfg.clientSecretPath,
      cfg.tokenPath,
      SCOPES,
      8096,
    );
    const cal = new CalendarClient(auth);

    api.logger.info(
      `openclaw-gcal: registered (token: ${cfg.tokenPath})`,
    );

    // ========================================================================
    // Tools
    // ========================================================================

    // --- gcal_calendars ---
    api.registerTool(
      {
        name: "gcal_calendars",
        label: "Calendar List",
        description:
          "List all calendars the user has access to. Returns calendar IDs, names, and access roles.",
        parameters: Type.Object({}),
        async execute() {
          try {
            const result = await cal.listCalendars();
            const items = result.items ?? [];

            const text = items
              .map(
                (c: any) =>
                  `- ${c.id} | ${c.summary} (${c.accessRole})${c.primary ? " [PRIMARY]" : ""}`,
              )
              .join("\n");

            return {
              content: [
                {
                  type: "text",
                  text: `${items.length} calendars:\n${text}`,
                },
              ],
              details: {
                calendars: items.map((c: any) => ({
                  id: c.id,
                  summary: c.summary,
                  accessRole: c.accessRole,
                  primary: c.primary ?? false,
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
      { name: "gcal_calendars" },
    );

    // --- gcal_list ---
    api.registerTool(
      {
        name: "gcal_list",
        label: "Calendar Events List",
        description:
          'List or search calendar events. Defaults to upcoming events from now. Use timeMin/timeMax (ISO 8601) to specify a range. Supports text search via query parameter.',
        parameters: Type.Object({
          calendarId: Type.Optional(
            Type.String({
              description:
                'Calendar ID (default: "primary"). Use gcal_calendars to list available calendars.',
            }),
          ),
          timeMin: Type.Optional(
            Type.String({
              description:
                "Start of time range (ISO 8601, e.g. 2026-02-08T00:00:00Z). Defaults to now.",
            }),
          ),
          timeMax: Type.Optional(
            Type.String({
              description:
                "End of time range (ISO 8601). Defaults to 7 days from now.",
            }),
          ),
          query: Type.Optional(
            Type.String({
              description: "Free text search terms to find events",
            }),
          ),
          maxResults: Type.Optional(
            Type.Number({
              description: "Max events to return (default: 25, max: 250)",
            }),
          ),
          pageToken: Type.Optional(
            Type.String({ description: "Pagination token" }),
          ),
        }),
        async execute(_toolCallId, params) {
          const {
            calendarId = "primary",
            timeMin,
            timeMax,
            query,
            maxResults = 25,
            pageToken,
          } = params as {
            calendarId?: string;
            timeMin?: string;
            timeMax?: string;
            query?: string;
            maxResults?: number;
            pageToken?: string;
          };

          try {
            const now = new Date().toISOString();
            const weekLater = new Date(
              Date.now() + 7 * 24 * 60 * 60 * 1000,
            ).toISOString();

            const result = await cal.listEvents(calendarId, {
              timeMin: timeMin ?? now,
              timeMax: timeMax ?? weekLater,
              maxResults: Math.min(maxResults, 250),
              query,
              singleEvents: true,
              orderBy: "startTime",
              pageToken,
            });

            const events = result.items ?? [];

            if (events.length === 0) {
              return {
                content: [
                  {
                    type: "text",
                    text: `No events found${query ? ` for "${query}"` : ""} in the specified time range.`,
                  },
                ],
                details: { count: 0 },
              };
            }

            const lines = events.map(formatEventOneLiner);
            let text = `${events.length} events:\n\n${lines.join("\n")}`;
            if (result.nextPageToken) {
              text += `\n\nMore results available. Use pageToken: "${result.nextPageToken}"`;
            }

            return {
              content: [{ type: "text", text }],
              details: {
                count: events.length,
                nextPageToken: result.nextPageToken,
                events: events.map((e: any) => ({
                  id: e.id,
                  summary: e.summary,
                  start: e.start,
                  end: e.end,
                  location: e.location,
                  status: e.status,
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
      { name: "gcal_list" },
    );

    // --- gcal_get ---
    api.registerTool(
      {
        name: "gcal_get",
        label: "Calendar Event Get",
        description:
          "Get full details of a specific calendar event by ID.",
        parameters: Type.Object({
          eventId: Type.String({ description: "The event ID" }),
          calendarId: Type.Optional(
            Type.String({ description: 'Calendar ID (default: "primary")' }),
          ),
        }),
        async execute(_toolCallId, params) {
          const { eventId, calendarId = "primary" } = params as {
            eventId: string;
            calendarId?: string;
          };

          try {
            const event = await cal.getEvent(calendarId, eventId);
            return {
              content: [{ type: "text", text: formatEvent(event) }],
              details: event,
            };
          } catch (err) {
            return {
              content: [{ type: "text", text: `Failed: ${String(err)}` }],
              details: { error: String(err) },
            };
          }
        },
      },
      { name: "gcal_get" },
    );

    // --- gcal_create ---
    api.registerTool(
      {
        name: "gcal_create",
        label: "Calendar Event Create",
        description:
          "Create a new calendar event. Supports timed events, all-day events, attendees, location, and recurrence.",
        parameters: Type.Object({
          summary: Type.String({ description: "Event title" }),
          start: Type.String({
            description:
              'Start time (ISO 8601 for timed: "2026-02-10T14:00:00-07:00", or date for all-day: "2026-02-10")',
          }),
          end: Type.String({
            description:
              'End time (ISO 8601 for timed, or date for all-day). For all-day events, use the day after: "2026-02-11"',
          }),
          calendarId: Type.Optional(
            Type.String({ description: 'Calendar ID (default: "primary")' }),
          ),
          description: Type.Optional(
            Type.String({ description: "Event description/notes" }),
          ),
          location: Type.Optional(
            Type.String({ description: "Event location" }),
          ),
          attendees: Type.Optional(
            Type.Array(Type.String(), {
              description: "Email addresses of attendees",
            }),
          ),
          recurrence: Type.Optional(
            Type.Array(Type.String(), {
              description:
                'RRULE strings, e.g. ["RRULE:FREQ=WEEKLY;COUNT=10"]',
            }),
          ),
          timeZone: Type.Optional(
            Type.String({
              description:
                'IANA timezone (default: "America/Denver")',
            }),
          ),
        }),
        async execute(_toolCallId, params) {
          const {
            summary,
            start,
            end,
            calendarId = "primary",
            description,
            location,
            attendees,
            recurrence,
            timeZone = "America/Denver",
          } = params as {
            summary: string;
            start: string;
            end: string;
            calendarId?: string;
            description?: string;
            location?: string;
            attendees?: string[];
            recurrence?: string[];
            timeZone?: string;
          };

          try {
            const isAllDay = /^\d{4}-\d{2}-\d{2}$/.test(start);

            const event: any = {
              summary,
              start: isAllDay
                ? { date: start }
                : { dateTime: start, timeZone },
              end: isAllDay
                ? { date: end }
                : { dateTime: end, timeZone },
            };

            if (description) event.description = description;
            if (location) event.location = location;
            if (attendees) {
              event.attendees = attendees.map((email) => ({ email }));
            }
            if (recurrence) event.recurrence = recurrence;

            const result = await cal.createEvent(calendarId, event);

            return {
              content: [
                {
                  type: "text",
                  text: `Event created.\n${formatEvent(result)}${result.htmlLink ? `\nLink: ${result.htmlLink}` : ""}`,
                },
              ],
              details: { id: result.id, htmlLink: result.htmlLink },
            };
          } catch (err) {
            return {
              content: [{ type: "text", text: `Failed: ${String(err)}` }],
              details: { error: String(err) },
            };
          }
        },
      },
      { name: "gcal_create" },
    );

    // --- gcal_update ---
    api.registerTool(
      {
        name: "gcal_update",
        label: "Calendar Event Update",
        description:
          "Update an existing calendar event. Only provide fields you want to change.",
        parameters: Type.Object({
          eventId: Type.String({ description: "The event ID to update" }),
          calendarId: Type.Optional(
            Type.String({ description: 'Calendar ID (default: "primary")' }),
          ),
          summary: Type.Optional(
            Type.String({ description: "New event title" }),
          ),
          start: Type.Optional(
            Type.String({ description: "New start time (ISO 8601 or date)" }),
          ),
          end: Type.Optional(
            Type.String({ description: "New end time (ISO 8601 or date)" }),
          ),
          description: Type.Optional(
            Type.String({ description: "New description" }),
          ),
          location: Type.Optional(
            Type.String({ description: "New location" }),
          ),
          status: Type.Optional(
            Type.Union(
              [
                Type.Literal("confirmed"),
                Type.Literal("tentative"),
                Type.Literal("cancelled"),
              ],
              { description: "Event status" },
            ),
          ),
          timeZone: Type.Optional(
            Type.String({ description: "IANA timezone" }),
          ),
        }),
        async execute(_toolCallId, params) {
          const {
            eventId,
            calendarId = "primary",
            summary,
            start,
            end,
            description,
            location,
            status,
            timeZone = "America/Denver",
          } = params as {
            eventId: string;
            calendarId?: string;
            summary?: string;
            start?: string;
            end?: string;
            description?: string;
            location?: string;
            status?: string;
            timeZone?: string;
          };

          try {
            const patch: any = {};
            if (summary !== undefined) patch.summary = summary;
            if (description !== undefined) patch.description = description;
            if (location !== undefined) patch.location = location;
            if (status !== undefined) patch.status = status;

            if (start !== undefined) {
              const isAllDay = /^\d{4}-\d{2}-\d{2}$/.test(start);
              patch.start = isAllDay
                ? { date: start }
                : { dateTime: start, timeZone };
            }
            if (end !== undefined) {
              const isAllDay = /^\d{4}-\d{2}-\d{2}$/.test(end);
              patch.end = isAllDay
                ? { date: end }
                : { dateTime: end, timeZone };
            }

            const result = await cal.updateEvent(
              calendarId,
              eventId,
              patch,
            );

            return {
              content: [
                {
                  type: "text",
                  text: `Event updated.\n${formatEvent(result)}`,
                },
              ],
              details: { id: result.id },
            };
          } catch (err) {
            return {
              content: [{ type: "text", text: `Failed: ${String(err)}` }],
              details: { error: String(err) },
            };
          }
        },
      },
      { name: "gcal_update" },
    );

    // --- gcal_delete ---
    api.registerTool(
      {
        name: "gcal_delete",
        label: "Calendar Event Delete",
        description: "Delete a calendar event by ID.",
        parameters: Type.Object({
          eventId: Type.String({ description: "The event ID to delete" }),
          calendarId: Type.Optional(
            Type.String({ description: 'Calendar ID (default: "primary")' }),
          ),
        }),
        async execute(_toolCallId, params) {
          const { eventId, calendarId = "primary" } = params as {
            eventId: string;
            calendarId?: string;
          };

          try {
            await cal.deleteEvent(calendarId, eventId);
            return {
              content: [
                {
                  type: "text",
                  text: `Event ${eventId} deleted.`,
                },
              ],
              details: { eventId, action: "deleted" },
            };
          } catch (err) {
            return {
              content: [{ type: "text", text: `Failed: ${String(err)}` }],
              details: { error: String(err) },
            };
          }
        },
      },
      { name: "gcal_delete" },
    );

    // --- gcal_freebusy ---
    api.registerTool(
      {
        name: "gcal_freebusy",
        label: "Calendar Free/Busy",
        description:
          "Check free/busy status for one or more calendars in a given time range. Useful for finding open slots.",
        parameters: Type.Object({
          timeMin: Type.String({
            description: "Start of range (ISO 8601)",
          }),
          timeMax: Type.String({
            description: "End of range (ISO 8601)",
          }),
          calendarIds: Type.Optional(
            Type.Array(Type.String(), {
              description:
                'Calendar IDs to check (default: ["primary"])',
            }),
          ),
        }),
        async execute(_toolCallId, params) {
          const {
            timeMin,
            timeMax,
            calendarIds = ["primary"],
          } = params as {
            timeMin: string;
            timeMax: string;
            calendarIds?: string[];
          };

          try {
            const result = await cal.freeBusy(
              timeMin,
              timeMax,
              calendarIds,
            );

            const calendars = result.calendars ?? {};
            const lines: string[] = [];

            for (const [calId, data] of Object.entries(calendars) as any) {
              const busy = data.busy ?? [];
              if (busy.length === 0) {
                lines.push(`${calId}: Free for entire range`);
              } else {
                lines.push(
                  `${calId}: ${busy.length} busy block(s)`,
                );
                for (const b of busy) {
                  lines.push(`  - ${b.start} to ${b.end}`);
                }
              }
            }

            return {
              content: [
                {
                  type: "text",
                  text: `Free/busy from ${timeMin} to ${timeMax}:\n\n${lines.join("\n")}`,
                },
              ],
              details: { calendars },
            };
          } catch (err) {
            return {
              content: [{ type: "text", text: `Failed: ${String(err)}` }],
              details: { error: String(err) },
            };
          }
        },
      },
      { name: "gcal_freebusy" },
    );

    // ========================================================================
    // CLI Commands
    // ========================================================================

    api.registerCli(
      ({ program }) => {
        const gcalCmd = program
          .command("gcal")
          .description("Google Calendar plugin commands");

        gcalCmd
          .command("auth")
          .description(
            "Run Google Calendar OAuth2 consent flow (opens browser)",
          )
          .action(async () => {
            try {
              await auth.runAuthFlow();
              console.log("\nAuthentication successful!");

              const result = await cal.listCalendars();
              const primary = (result.items ?? []).find(
                (c: any) => c.primary,
              );
              if (primary) {
                console.log(`Primary calendar: ${primary.summary} (${primary.id})`);
              }
              console.log(
                `Total calendars: ${(result.items ?? []).length}`,
              );
            } catch (err) {
              console.error(`Authentication failed: ${String(err)}`);
              process.exit(1);
            }
          });

        gcalCmd
          .command("status")
          .description("Check Calendar authentication status")
          .action(async () => {
            try {
              const result = await cal.listCalendars();
              const primary = (result.items ?? []).find(
                (c: any) => c.primary,
              );
              console.log(
                `Authenticated. Primary calendar: ${primary?.summary ?? "unknown"} (${primary?.id ?? "unknown"})`,
              );
              console.log(
                `Total calendars: ${(result.items ?? []).length}`,
              );
            } catch (err) {
              console.log(
                `Not authenticated. Run "openclaw gcal auth" to sign in.`,
              );
              console.log(`Error: ${String(err)}`);
            }
          });
      },
      { commands: ["gcal"] },
    );

    // ========================================================================
    // Service
    // ========================================================================

    api.registerService({
      id: "openclaw-gcal",
      start: () => {
        api.logger.info(
          `openclaw-gcal: initialized (token: ${cfg.tokenPath})`,
        );
      },
      stop: () => {
        api.logger.info("openclaw-gcal: stopped");
      },
    });
  },
};

export default gcalPlugin;
