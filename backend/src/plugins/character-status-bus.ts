import fp from "fastify-plugin";
import { SERVER_MESSAGE } from "../godot-link/protocol.js";
import {
  CHARACTER_STATUS_BUS_PATTERN,
  parseCharacterStatusBusChannel,
  parseCharacterStatusBusPayload,
} from "../services/character-status-bus.js";

export const characterStatusBusPlugin = fp(async (app) => {
  const onStatusMessage = (pattern: string, channel: string, raw: string) => {
    if (pattern !== CHARACTER_STATUS_BUS_PATTERN) {
      return;
    }

    const townId = parseCharacterStatusBusChannel(channel);
    if (!townId) {
      app.log.warn({ channel }, "received character status bus message on malformed channel");
      return;
    }

    let payload: ReturnType<typeof parseCharacterStatusBusPayload>;
    try {
      payload = parseCharacterStatusBusPayload(raw);
    } catch (error) {
      app.log.warn({ error, channel, raw }, "received malformed character status bus payload");
      return;
    }

    const envelope = app.agentConnections.send(townId, SERVER_MESSAGE.agentThinking, payload);
    if (!envelope && app.agentConnections.hasConnection(townId)) {
      app.log.warn({ townId, payload }, "failed to forward character status to runtime");
    }
  };

  app.subRedis.on("pmessage", onStatusMessage);
  await app.subRedis.psubscribe(CHARACTER_STATUS_BUS_PATTERN);

  app.addHook("onClose", async () => {
    app.subRedis.off("pmessage", onStatusMessage);
    await app.subRedis.punsubscribe(CHARACTER_STATUS_BUS_PATTERN);
  });
});
