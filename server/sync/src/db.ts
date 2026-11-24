export type Query = { query: string; params?: unknown[] };
export type QueryResult<T = Record<string, unknown>> = { rows: T[] };
export interface Database {
  query<T = Record<string, unknown>>(sql: string, params?: unknown[]): Promise<QueryResult<T>>;
}

/** Minimal Neon SQL-over-HTTP client; wire format verified against @neondatabase/serverless 1.0.2. */
export class NeonDatabase implements Database {
  constructor(
    private readonly connectionString: string,
    // Never store the bare global `fetch` and call it as a method: in Workers that
    // throws "Illegal invocation" because `this` would be the database object.
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
  ) {}
  async query<T>(sql: string, params: unknown[] = []): Promise<QueryResult<T>> {
    const url = new URL(this.connectionString);
    const endpoint = `https://${url.hostname}/sql`;
    const response = await this.fetcher(endpoint, {
      method: "POST",
      headers: {
        "Neon-Connection-String": this.connectionString,
        "Neon-Raw-Text-Output": "true",
        "Neon-Array-Mode": "true",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ query: sql, params }),
    });
    const body = (await response.json()) as {
      fields?: { name: string; dataTypeID?: number }[];
      rows?: unknown[][];
      message?: string;
    };
    if (!response.ok) throw new Error(`Database request failed (${response.status})`);
    const fields = body.fields ?? [];
    return {
      rows: (body.rows ?? []).map(
        (row) =>
          Object.fromEntries(
            fields.map((f, i) => {
              const value = row[i];
              return [
                f.name,
                (f.dataTypeID === 114 || f.dataTypeID === 3802) && typeof value === "string"
                  ? JSON.parse(value)
                  : value,
              ];
            }),
          ) as T,
      ),
    };
  }
}
