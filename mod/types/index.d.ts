declare module 'claude-code' {
  interface PluginState {
    'read-aloud': { phase: 'idle' | 'queued' | 'speaking' | 'paused' | string; who: string }
  }
}
