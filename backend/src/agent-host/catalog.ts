export interface AgentHostCatalog {
  resolveCharacterName(id: string): string;
  resolveItemName(id: string): string;
  resolveLocationName(id: string): string;
}

export class IdentityAgentHostCatalog implements AgentHostCatalog {
  resolveCharacterName(id: string): string {
    return id;
  }

  resolveItemName(id: string): string {
    return id;
  }

  resolveLocationName(id: string): string {
    return id;
  }
}
