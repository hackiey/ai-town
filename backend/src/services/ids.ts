import { randomUUID } from "node:crypto";

export function createMessageId(prefix: string): string {
  return `${prefix}_${randomUUID()}`;
}
