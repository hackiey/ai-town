import fp from "fastify-plugin";
import { FastifyBaseLogger } from "fastify";

// 进程内事件总线，取代原先的 Redis pub/sub。网关 + agent runtime 合并成单进程后，
// 各条 bus（world-event / perception-manifest / game-time / action / character-status）
// 都走这里。保留 Redis 的两条语义：
//  1. publish 是 fire-and-forget——经 setImmediate 异步派发，发布方不等订阅方，
//     也不会把订阅方逻辑同步嵌进发布方调用栈（避免 Godot WS 处理栈深层重入）。
//  2. 订阅方异常被隔离（try/catch + promise.catch），不会拖垮发布方。
// payload 直接传结构化对象，不做 JSON 序列化（同进程无意义）。channel / pattern 路由
// 语义与 Redis 一致（pattern 只用到 `*` 通配）。

export type BusListener = (channel: string, payload: unknown) => void | Promise<void>;

type Subscription = {
  pattern: string;
  regex: RegExp;
  listener: BusListener;
};

function patternToRegExp(pattern: string): RegExp {
  // 转义所有正则元字符，再把 `*` 还原成 `.*`。
  const escaped = pattern.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/\\\*/g, ".*");
  return new RegExp(`^${escaped}$`);
}

export class MessageBus {
  private subscriptions: Subscription[] = [];

  constructor(private readonly logger?: FastifyBaseLogger) {}

  psubscribe(pattern: string, listener: BusListener): void {
    this.subscriptions.push({ pattern, regex: patternToRegExp(pattern), listener });
  }

  punsubscribe(pattern: string, listener: BusListener): void {
    this.subscriptions = this.subscriptions.filter(
      (sub) => !(sub.pattern === pattern && sub.listener === listener),
    );
  }

  // 返回匹配到的订阅数（对齐 Redis publish 的返回语义，调用方一般忽略）。
  publish(channel: string, payload: unknown): number {
    const matched = this.subscriptions.filter((sub) => sub.regex.test(channel));
    for (const sub of matched) {
      setImmediate(() => {
        Promise.resolve()
          .then(() => sub.listener(channel, payload))
          .catch((error) => {
            this.logger?.error({ error, channel, pattern: sub.pattern }, "message bus listener failed");
          });
      });
    }
    return matched.length;
  }
}

declare module "fastify" {
  interface FastifyInstance {
    bus: MessageBus;
  }
}

export const messageBusPlugin = fp(async (app) => {
  const bus = new MessageBus(app.log);
  app.decorate("bus", bus);
});
