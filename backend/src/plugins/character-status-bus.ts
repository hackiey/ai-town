import fp from "fastify-plugin";
import { SERVER_MESSAGE } from "../godot-link/protocol.js";
import {
  CHARACTER_STATUS_BUS_PATTERN,
  parseCharacterStatusBusChannel,
  parseCharacterStatusBusPayload,
} from "../services/character-status-bus.js";

export const characterStatusBusPlugin = fp(async (app) => {
  const onStatusMessage = (channel: string, raw: unknown) => {
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

  app.bus.psubscribe(CHARACTER_STATUS_BUS_PATTERN, onStatusMessage);

  app.addHook("onClose", async () => {
    app.bus.punsubscribe(CHARACTER_STATUS_BUS_PATTERN, onStatusMessage);
  });
});
