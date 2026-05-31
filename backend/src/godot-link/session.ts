import { PROTOCOL_VERSION, type MessageEnvelope, type TownId } from "./protocol.js";

export type GodotLinkConnectionSnapshot = {
  townId: TownId;
  instanceId: string;
  connectedAt: string;
  lastSeenAt: string;
  lastAckSeq: number;
  nextSeq: number;
};

export type ReplayCursor = {
  townId: TownId;
  afterSeq: number;
};

export class GodotLinkSequencer {
  private nextSeq: number;
  private lastAckSeq: number;

  constructor(lastAckSeq = 0) {
    this.lastAckSeq = lastAckSeq;
    this.nextSeq = lastAckSeq + 1;
  }

  createEnvelope<TPayload, TType extends string>(townId: TownId, type: TType, payload: TPayload): MessageEnvelope<TPayload, TType> {
    const envelope: MessageEnvelope<TPayload, TType> = {
      id: `${type.replaceAll(".", "_")}_${Date.now()}_${this.nextSeq}`,
      seq: this.nextSeq,
      type,
      townId,
      createdAt: new Date().toISOString(),
      version: PROTOCOL_VERSION,
      payload,
    };
    this.nextSeq += 1;
    return envelope;
  }

  markAck(ackSeq: number): void {
    this.lastAckSeq = Math.max(this.lastAckSeq, ackSeq);
  }

  replayCursor(townId: TownId): ReplayCursor {
    return { townId, afterSeq: this.lastAckSeq };
  }

  snapshot(params: { townId: TownId; instanceId: string; connectedAt: string; lastSeenAt: string }): GodotLinkConnectionSnapshot {
    return {
      ...params,
      lastAckSeq: this.lastAckSeq,
      nextSeq: this.nextSeq,
    };
  }
}
