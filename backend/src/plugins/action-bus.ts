import fp from "fastify-plugin";
import { handleActionCancelDelivery, handleActionDelivery } from "../services/action-log-service.js";
import { ACTION_BUS_PATTERN, parseActionBusChannel, parseActionBusPayload } from "../services/action-bus.js";

export const actionBusPlugin = fp(async (app) => {
  const onActionMessage = (pattern: string, channel: string, raw: string) => {
    if (pattern !== ACTION_BUS_PATTERN) {
      return;
    }

    const townId = parseActionBusChannel(channel);
    if (!townId) {
      app.log.warn({ channel }, "received action bus message on malformed channel");
      return;
    }

    let payload: ReturnType<typeof parseActionBusPayload>;
    try {
      payload = parseActionBusPayload(raw);
    } catch (error) {
      app.log.warn({ error, channel, raw }, "received malformed action bus payload");
      return;
    }

    const delivery = payload.kind === "cancel"
      ? handleActionCancelDelivery(app.db, app.agentConnections, townId, payload.actionId)
      : handleActionDelivery(app.db, app.redis, app.agentConnections, townId, payload.actionId);
    delivery.catch((error) => {
      app.log.error({ error, townId, actionId: payload.actionId, kind: payload.kind }, "failed to deliver action bus message");
    });
  };

  app.subRedis.on("pmessage", onActionMessage);
  await app.subRedis.psubscribe(ACTION_BUS_PATTERN);

  app.addHook("onClose", async () => {
    app.subRedis.off("pmessage", onActionMessage);
    await app.subRedis.punsubscribe(ACTION_BUS_PATTERN);
  });
});
