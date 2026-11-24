export interface Storage {
  get<T>(key: string): Promise<T | undefined>;
  put<T>(key: string, value: T): Promise<void>;
  delete(key: string): Promise<boolean>;
  take<T>(key: string): Promise<T | undefined>;
  advanceHead?(next: Head): Promise<Head>;
}
export type Head = { libraryId: string | null; state: string; seq: number };
export class CoordinatorStore {
  constructor(
    private readonly storage: Storage,
    private readonly now = () => Date.now(),
  ) {}
  async head(): Promise<Head> {
    return (await this.storage.get<Head>("head")) ?? { libraryId: null, state: "empty", seq: 0 };
  }
  async advance(next: Head): Promise<Head> {
    if (this.storage.advanceHead) return this.storage.advanceHead(next);
    const current = await this.head();
    if (current.libraryId !== next.libraryId || next.seq >= current.seq) {
      const value = {
        ...next,
        seq: Math.max(current.libraryId === next.libraryId ? current.seq : 0, next.seq),
      };
      await this.storage.put("head", value);
      return value;
    }
    return current;
  }
  async putCode(
    code: string,
    value: { challenge: string; name: string; exp: number },
  ): Promise<void> {
    await this.storage.put(`code:${code}`, value);
  }
  async takeCode(
    code: string,
  ): Promise<{ challenge: string; name: string; exp: number } | undefined> {
    const key = `code:${code}`;
    const value = await this.storage.take<{ challenge: string; name: string; exp: number }>(key);
    return value && value.exp > this.now() ? value : undefined;
  }
}

export class Coordinator implements DurableObject {
  private readonly store: CoordinatorStore;
  constructor(_state: DurableObjectState, env: unknown) {
    const state = _state;
    this.store = new CoordinatorStore({
      get: <T>(k: string) => state.storage.get<T>(k),
      put: <T>(k: string, v: T) => state.storage.put(k, v),
      delete: (k: string) => state.storage.delete(k),
      take: <T>(k: string) =>
        state.storage.transaction(async (tx) => {
          const value = await tx.get<T>(k);
          await tx.delete(k);
          return value;
        }),
      advanceHead: (next: Head) =>
        state.storage.transaction(async (tx) => {
          const current = (await tx.get<Head>("head")) ?? {
            libraryId: null,
            state: "empty",
            seq: 0,
          };
          if (current.libraryId !== next.libraryId || next.seq >= current.seq) {
            const value = {
              ...next,
              seq: Math.max(current.libraryId === next.libraryId ? current.seq : 0, next.seq),
            };
            await tx.put("head", value);
            return value;
          }
          return current;
        }),
    });
  }
  async fetch(request: Request): Promise<Response> {
    const { pathname } = new URL(request.url);
    const body =
      request.method === "POST"
        ? ((await request.json()) as {
            head?: Head;
            code?: string;
            value?: { challenge: string; name: string; exp: number };
          })
        : {};
    if (pathname === "/head") return Response.json(await this.store.head());
    if (pathname === "/advance" && body.head)
      return Response.json(await this.store.advance(body.head));
    if (pathname === "/code" && body.code && body.value) {
      await this.store.putCode(body.code, body.value);
      return Response.json({ ok: true });
    }
    if (pathname === "/take" && body.code)
      return Response.json({ value: (await this.store.takeCode(body.code)) ?? null });
    return new Response("not found", { status: 404 });
  }
}
