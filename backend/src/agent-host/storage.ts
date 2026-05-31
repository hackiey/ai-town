export type RuntimeStorageValue =
  | null
  | boolean
  | number
  | string
  | RuntimeStorageValue[]
  | { [key: string]: RuntimeStorageValue };

export interface RuntimeStorage {
  get(key: string): Promise<RuntimeStorageValue | undefined>;
  set(key: string, value: RuntimeStorageValue): Promise<void>;
  delete(key: string): Promise<void>;
  list(prefix?: string): Promise<Array<{ key: string; value: RuntimeStorageValue }>>;
}

export class InMemoryRuntimeStorage implements RuntimeStorage {
  private readonly values = new Map<string, RuntimeStorageValue>();

  async get(key: string): Promise<RuntimeStorageValue | undefined> {
    return this.values.get(key);
  }

  async set(key: string, value: RuntimeStorageValue): Promise<void> {
    this.values.set(key, value);
  }

  async delete(key: string): Promise<void> {
    this.values.delete(key);
  }

  async list(prefix = ""): Promise<Array<{ key: string; value: RuntimeStorageValue }>> {
    return [...this.values.entries()]
      .filter(([key]) => key.startsWith(prefix))
      .map(([key, value]) => ({ key, value }));
  }
}
